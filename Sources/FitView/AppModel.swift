import FitViewCore
import Foundation
import Observation

/// The app's single owner of "what data are we showing, and where did it come
/// from" — the library store, the loaded batch, the chosen data source, and
/// the watched folder.
///
/// This state used to live as `@State` inside `BatchOverviewView`. It had to
/// move: on macOS the Settings scene is a *sibling* of `WindowGroup`, not a
/// descendant, so it can't reach another view's `@State` no matter how the
/// hierarchy is arranged. Settings has to be able to switch the data source
/// and repoint the folder, which means both it and the overview must read the
/// same instance — and the only place that can hang off is the `App` itself.
@MainActor
@Observable
final class AppModel {
    // MARK: - Observable state

    /// The store backing the *current* data source. `nil` until `activate()`
    /// has opened one, which is what the toolbar's disabled states key off.
    private(set) var store: (any LibraryStore)?
    private(set) var batch: LoadedBatch?
    private(set) var overview: BatchOverviewModel?
    /// A failure loading or rebuilding the batch. Shown in place of the table.
    private(set) var loadError: String?

    /// Mirrors of the watched folder's actor-isolated state, so SwiftUI can
    /// observe them. `WatchedFolderSource.isConfigured` is readable
    /// synchronously, but `@Observable` only tracks *this* object's stored
    /// properties — a view reading through to the actor would never be
    /// invalidated when it changed.
    private(set) var isFolderConfigured = false
    private(set) var folderName: String?
    /// The last scan's outcome, for the Settings summary. Only set by an
    /// explicit "Scan Now" or a scan that actually imported something —
    /// a routine foreground rescan that finds nothing leaves the previous
    /// report alone rather than replacing it with a row of zeroes.
    private(set) var lastIngest: FolderIngestReport?
    private(set) var folderError: String?
    private(set) var isScanning = false

    /// Whether the last attempt to load a cached Polar session succeeded.
    /// Reflects reality lazily — nothing probes the keychain until `activate()`
    /// or an explicit sync runs `restoreSession()` — rather than being set
    /// eagerly from `init`, since that would need to be `async`.
    private(set) var isPolarConnected = false
    private(set) var isSyncingPolar = false
    /// The last sync's outcome, for the Settings summary. Same "only replaced
    /// by something meaningful" rule as `lastIngest`.
    private(set) var lastPolarSync: RemoteSyncReport?
    private(set) var polarError: String?
    /// A rolling trace of what `syncPolar`/`connectPolar`/`disconnectPolar`
    /// actually did, most recent last. Exists because this connector can only
    /// ever be exercised live (no sandbox — see `PolarAccessLinkSource`'s doc
    /// comment), and "nothing visibly happened" is otherwise undebuggable
    /// without a screenshot of every intermediate state. In-memory only,
    /// capped, and never persisted — this is a debugging aid, not a feature.
    private(set) var debugLog: [String] = []
    private static let debugLogCap = 200

    var dataSource: DataSourceMode {
        didSet {
            guard oldValue != dataSource else { return }
            defaults.set(dataSource.rawValue, forKey: Self.dataSourceKey)
            Task { await activate() }
        }
    }

    // MARK: - Collaborators

    /// The user-driven import pipeline (Files, drag-and-drop, Polar). Distinct
    /// from the one `FolderIngestor` holds privately: `startImport` cancels
    /// whatever is in flight, and an automatic rescan must never kill an
    /// import the user started by hand.
    let importCoordinator = ImportCoordinator()
    let watchedFolder: WatchedFolderSource
    let polarSource = PolarAccessLinkSource()

    private let ingestor: FolderIngestor
    private let remoteSync: RemoteActivitySync
    /// The same store `remoteSync` holds internally — kept here too so
    /// Settings' "Forget Downloaded Activities" can clear it directly.
    /// `RemoteActivitySync` only knows "not in the set yet", never "was
    /// downloaded but the file turned out bad and got deleted", so this is
    /// the only way to force a re-download of something already marked done.
    private let polarDownloadedIds: RemoteSyncIdStore
    /// Points at the same folder as `watchedFolder` (same key, same App
    /// Group) — a separate `FolderBookmark` instance because
    /// `RemoteActivitySync` only knows `FolderBookmark`, not
    /// `WatchedFolderSource`, but it must land files in the one folder
    /// `FolderIngestor` actually scans. Constructed the same way the share
    /// extension points at this folder.
    private let polarFolderBookmark: FolderBookmark
    /// The shared "raw device name -> nickname" table — one instance, passed
    /// into every `FileSystemLibraryStore` (so renaming a device in one data
    /// source's library view affects every mode) and into `RemoteActivitySync`
    /// (so a Polar-synced file gets the nickname baked into its filename from
    /// the first sync, not just after a later manual re-alias).
    private let deviceNicknames: DeviceNicknameStore
    private let defaults: UserDefaults
    /// One store per mode, kept alive once opened so switching back and forth
    /// hands out the *same* instance the sheets already captured rather than
    /// opening a second handle onto the same manifest.
    private var storesByMode: [DataSourceMode: any LibraryStore] = [:]
    private var lastScanFinishedAt: Date?
    /// Set when a rescan is requested while one is already running, so it
    /// isn't silently dropped — see `scanFolder`.
    private var rescanQueued = false
    private var lastPolarSyncFinishedAt: Date?

    private static let dataSourceKey = "FitView.dataSource"
    /// How recently a scan must have run for the next automatic one to be
    /// skipped. Exists because launch and the first `scenePhase == .active`
    /// both fire within a moment of each other, and scanning twice back to
    /// back is pure waste. "Scan Now" bypasses it. Reused as-is for
    /// `syncPolar`'s own debounce — the same "don't redo this within a
    /// moment of the last time" reasoning applies unchanged.
    private static let rescanDebounce: TimeInterval = 2
    private static let polarDownloadedIdsKey = "FitView.PolarSync.downloadedExerciseIds"

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        let watchedFolder = WatchedFolderSource(defaults: defaults)
        self.watchedFolder = watchedFolder
        self.ingestor = FolderIngestor(source: watchedFolder)
        let polarDownloadedIds = RemoteSyncIdStore(defaults: defaults, key: Self.polarDownloadedIdsKey)
        self.polarDownloadedIds = polarDownloadedIds
        let deviceNicknames = DeviceNicknameStore(defaults: defaults)
        self.deviceNicknames = deviceNicknames
        self.remoteSync = RemoteActivitySync(downloadedIds: polarDownloadedIds, nicknames: deviceNicknames)
        self.polarFolderBookmark = FolderBookmark(defaults: defaults, key: "FitView.WatchedFolder.bookmark")
        self.dataSource = defaults.string(forKey: Self.dataSourceKey)
            .flatMap(DataSourceMode.init(rawValue:)) ?? .bundledSamples
        self.isFolderConfigured = watchedFolder.isConfigured
    }

    // MARK: - Lifecycle

    /// Opens the store for the current data source, picks up anything new in
    /// the watched folder, and loads the batch. Safe to call again on a data
    /// source change — it replaces what's on screen outright rather than
    /// merging, per `overview.md` §11's atomic-batch rule.
    func activate() async {
        batch = nil
        overview = nil
        loadError = nil

        let mode = dataSource
        do {
            let store = try openStore(for: mode)
            self.store = store
            // Unconditionally, not only in folder mode — Settings shows the
            // chosen folder's name whichever source is currently active, since
            // picking a folder and switching to it are separate steps.
            folderName = await watchedFolder.folderName()
            if mode == .watchedFolder {
                // `reloadIfChanged: false` because the batch load below will
                // read whatever this imports anyway; reloading here would
                // decode the whole library twice on launch.
                await scanFolder(store: store, force: true, reloadIfChanged: false)
            }
            // After, not before, the scan above: `syncPolar` runs its own
            // `rescanFolder(force: true)` internally once it downloads
            // anything, and that has to see the folder in the state the scan
            // above already brought it to — otherwise its report of what's
            // newly imported would be clobbered by the redundant scan above
            // finding the same files a second time.
            await syncPolar()
            try await loadBatch(store: store, mode: mode)
        } catch {
            loadError = String(describing: error)
        }
    }

    /// Rebuilds the batch from the current store outright — the atomic-batch
    /// rule again: a new load replaces, it never merges with what was there
    /// before. Reloading from the store (rather than assembling whatever files
    /// an import happened to produce in memory) is what keeps the on-screen
    /// batch and the on-disk library from ever diverging.
    func reload() async {
        guard let store else { return }
        do {
            try await loadBatch(store: store, mode: dataSource)
        } catch {
            loadError = String(describing: error)
        }
    }

    // MARK: - Deletion

    /// Removes every device file backing `session` from the library and
    /// reloads the batch. `session.filesByDeviceKey`'s values carry
    /// `LibraryItem.id` for a store-backed batch — `BatchAssembler` builds
    /// each session's descriptors with `id: item.id` — so this deletes
    /// exactly the files making up this one (date, activity) session and
    /// nothing else.
    ///
    /// Every removal is attempted even if an earlier one fails, and the batch
    /// is always reloaded afterward, so the UI reflects whatever actually
    /// happened on disk rather than stopping partway through. Returns the
    /// first error encountered, if any.
    @discardableResult
    func deleteSession(_ session: ActivitySession) async -> String? {
        guard let store else { return "No library open." }
        var firstError: String?
        for file in session.filesByDeviceKey.values {
            do {
                try await store.remove(itemId: file.fileName)
            } catch {
                if firstError == nil { firstError = String(describing: error) }
            }
        }
        await reload()
        return firstError
    }

    private func loadBatch(store: some LibraryStore, mode: DataSourceMode) async throws {
        let seed = mode.seedsBundledSamples
        let loaded = try await Task.detached(priority: .userInitiated) {
            try await BatchBuilder.load(store: store, seedBundledSamples: seed)
        }.value
        batch = loaded
        overview = BatchOverviewModel(agreement: loaded.agreement)
        loadError = nil
    }

    private func openStore(for mode: DataSourceMode) throws -> any LibraryStore {
        if let existing = storesByMode[mode] { return existing }
        let store = try FileSystemLibraryStore(
            rootURL: FileSystemLibraryStore.defaultRootURL(named: mode.libraryName),
            nicknames: deviceNicknames
        )
        storesByMode[mode] = store
        return store
    }

    // MARK: - Watched folder

    /// Points the watched folder at `url` and immediately scans it, so picking
    /// a folder and seeing its contents is one action rather than two.
    func setWatchedFolder(_ url: URL) async {
        folderError = nil
        do {
            try await watchedFolder.setFolder(url)
            isFolderConfigured = watchedFolder.isConfigured
            folderName = await watchedFolder.folderName()
        } catch {
            folderError = String(describing: error)
            return
        }
        await rescanFolder(force: true)
    }

    /// Stops watching. Everything already imported stays — copies live in the
    /// app's own library, so "stop watching" is not "delete my activities".
    func clearWatchedFolder() async {
        await watchedFolder.clearFolder()
        isFolderConfigured = watchedFolder.isConfigured
        folderName = nil
        lastIngest = nil
        folderError = nil
        // Falling back rather than staying put: the folder source without a
        // folder can only ever show a frozen library nothing can refresh, and
        // Settings disables the picker while unconfigured, which would strand
        // the user there with no way back.
        if dataSource == .watchedFolder {
            dataSource = .bundledSamples
        }
    }

    /// Surfaces a failure that happened outside this model — currently only
    /// the document picker's own errors, which the view has no other place to
    /// put.
    func reportFolderError(_ error: Error) {
        folderError = String(describing: error)
    }

    /// Picks up anything new in the folder and reloads the batch if it found
    /// something. Called on launch, on every return to the foreground, and
    /// from Settings' "Scan Now".
    ///
    /// - Parameter force: bypasses the debounce. True for a user-initiated
    ///   scan, which must always feel like it did something.
    func rescanFolder(force: Bool = false) async {
        guard dataSource == .watchedFolder, let store else { return }
        await scanFolder(store: store, force: force, reloadIfChanged: true)
    }

    private func scanFolder(store: some LibraryStore, force: Bool, reloadIfChanged: Bool) async {
        guard watchedFolder.isConfigured else { return }
        guard !isScanning else {
            // Don't drop this request on the floor — a share extension can
            // write a new file while a scan triggered moments earlier is
            // still waiting on iCloud materialization (up to 15s), and
            // without this the card list would stay stale until the next
            // foreground event or a full relaunch, since nothing else would
            // ever trigger the rescan that new file needs.
            rescanQueued = true
            return
        }
        if !force, let lastScanFinishedAt,
           Date().timeIntervalSince(lastScanFinishedAt) < Self.rescanDebounce {
            return
        }

        isScanning = true
        defer {
            isScanning = false
            lastScanFinishedAt = Date()
        }

        // A loop, not recursion: `isScanning` stays true across every pass,
        // so a request that arrives *during* a pass (setting `rescanQueued`)
        // is picked up by the next pass instead of recursing into a fresh
        // `scanFolder` call that would immediately bounce off the `guard
        // !isScanning` above and re-queue itself without ever re-ingesting —
        // exactly the bug that let the card list stay stale until a full
        // relaunch, which the queuing here was supposed to prevent.
        var isForced = force
        repeat {
            rescanQueued = false
            do {
                let report = try await ingestor.ingest(into: store)
                folderError = nil
                // A routine rescan that found nothing new leaves the last
                // meaningful report on screen instead of blanking it to zeroes.
                if isForced || report.didChangeLibrary || !report.failures.isEmpty {
                    lastIngest = report
                }
                if reloadIfChanged, report.didChangeLibrary {
                    await reload()
                }
            } catch {
                folderError = describeFolderError(error)
            }
            // A request queued mid-scan must not then be swallowed by the
            // debounce on the next pass either.
            isForced = true
        } while rescanQueued
    }

    private func describeFolderError(_ error: Error) -> String {
        guard let sourceError = error as? ActivitySourceError else { return String(describing: error) }
        switch sourceError {
        case .notConfigured:
            return "No folder chosen yet."
        case .underlying(let message):
            return message
        case .notAvailable(let reason):
            return reason
        case .unauthorized:
            return "Access to the folder was denied. Choose it again."
        case .candidateNotFound:
            return "A file disappeared from the folder mid-scan. Try scanning again."
        }
    }

    // MARK: - Polar Flow

    /// The user-gesture connect flow: runs OAuth (presents a sign-in sheet if
    /// there's no cached session), then immediately syncs. Settings' "Connect
    /// Polar Flow…" button and nothing else calls this — every other call
    /// site uses `syncPolar`, which never presents UI.
    func connectPolar() async {
        log("connectPolar: starting authorize()")
        polarError = nil
        do {
            try await polarSource.authorize()
            isPolarConnected = true
            log("connectPolar: authorize() succeeded")
        } catch {
            isPolarConnected = false
            let message = describePolarError(error)
            polarError = message
            log("connectPolar: authorize() threw — \(message)")
            return
        }
        await syncPolar(force: true)
    }

    /// Forgets the Polar session. Everything already downloaded stays — same
    /// "disconnecting isn't deleting" rule `clearWatchedFolder` follows for
    /// the watched folder.
    func disconnectPolar() async {
        log("disconnectPolar: clearing session")
        do {
            try await polarSource.disconnect()
        } catch {
            let message = describePolarError(error)
            polarError = message
            log("disconnectPolar: tokenStore.clear() threw — \(message)")
        }
        isPolarConnected = false
        lastPolarSync = nil
    }

    /// Restores a cached Polar session (never presenting UI) and, if that
    /// succeeds, downloads anything new into the watched folder and rescans
    /// it. Called on launch, on every return to the foreground, and from
    /// Settings' "Sync Now" — a no-op unless Polar is configured, a folder is
    /// being watched, and a session is already on file.
    ///
    /// - Parameter force: bypasses the debounce, same as `rescanFolder`.
    func syncPolar(force: Bool = false) async {
        log("syncPolar(force: \(force)) called")
        guard polarSource.isConfigured else {
            log("syncPolar: stopped — Polar not configured (Secrets.xcconfig)")
            return
        }
        guard watchedFolder.isConfigured else {
            log("syncPolar: stopped — no watched folder chosen")
            return
        }
        guard !isSyncingPolar else {
            log("syncPolar: stopped — a sync is already running")
            return
        }
        if !force, let lastPolarSyncFinishedAt,
           Date().timeIntervalSince(lastPolarSyncFinishedAt) < Self.rescanDebounce {
            log("syncPolar: stopped — debounced")
            return
        }

        guard await polarSource.restoreSession() else {
            isPolarConnected = false
            log("syncPolar: stopped — no cached session (restoreSession() found nothing)")
            return
        }
        isPolarConnected = true
        log("syncPolar: session restored, calling RemoteActivitySync")

        isSyncingPolar = true
        defer {
            isSyncingPolar = false
            lastPolarSyncFinishedAt = Date()
        }

        do {
            let report = try await remoteSync.sync(source: polarSource, into: polarFolderBookmark)
            polarError = nil
            lastPolarSync = report
            log("syncPolar: succeeded — \(report.discovered) discovered, "
                + "\(report.downloaded) downloaded, \(report.failures.count) failed")
            for failure in report.failures {
                log("syncPolar: candidate \(failure.candidate.sourceId) failed — \(failure.message)")
            }
            await rescanFolder(force: true)
        } catch {
            let message = describePolarError(error)
            polarError = message
            log("syncPolar: RemoteActivitySync threw — \(message)")
        }
    }

    /// Forgets every id `RemoteActivitySync` has recorded as downloaded, so
    /// the next sync re-fetches everything the source currently lists —
    /// Settings' "Forget Downloaded Activities" button. For when a
    /// downloaded file turns out bad (or was deleted by hand) and needs a
    /// genuine re-fetch rather than being silently skipped forever.
    func resetPolarSyncState() {
        polarDownloadedIds.removeAll()
        log("resetPolarSyncState: cleared the downloaded-ids set")
    }

    /// Clears the in-memory debug log — Settings' "Clear Log" button. Leaves
    /// the on-disk copy alone; that one is append-only, for pulling with
    /// `devicectl device copy from` after the fact.
    func clearDebugLog() {
        debugLog.removeAll()
    }

    private static let debugLogTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// In the app's own Documents directory — reachable from a development
    /// Mac via `xcrun devicectl device copy from --domain-type
    /// appDataContainer --domain-identifier com.fitview.app --source
    /// Documents/debug.log`, without needing Files-app sharing enabled or a
    /// screenshot of the in-app log. Append-only and not size-managed: this
    /// is a debugging aid for the Polar work, not a shipped feature.
    private static let debugLogFileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("debug.log")

    private func log(_ message: String) {
        let line = "\(Self.debugLogTimeFormatter.string(from: Date())) \(message)"
        debugLog.append(line)
        if debugLog.count > Self.debugLogCap {
            debugLog.removeFirst(debugLog.count - Self.debugLogCap)
        }
        appendToLogFile(line)
    }

    /// Appends a line to `debugLogFileURL`, creating it if needed. Best
    /// effort — a failure here (disk full, sandbox oddity) shouldn't take
    /// down whatever Polar operation is actually being logged, so this
    /// swallows its own errors rather than propagating them.
    private func appendToLogFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let url = Self.debugLogFileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func describePolarError(_ error: Error) -> String {
        guard let sourceError = error as? ActivitySourceError else { return String(describing: error) }
        switch sourceError {
        case .notConfigured(let reason):
            return reason
        case .underlying(let message):
            return message
        case .notAvailable(let reason):
            return reason
        case .unauthorized:
            return "Not connected to Polar Flow."
        case .candidateNotFound:
            return "An activity disappeared from Polar mid-sync. Try syncing again."
        }
    }
}
