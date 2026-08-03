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

    private let ingestor: FolderIngestor
    private let defaults: UserDefaults
    /// One store per mode, kept alive once opened so switching back and forth
    /// hands out the *same* instance the sheets already captured rather than
    /// opening a second handle onto the same manifest.
    private var storesByMode: [DataSourceMode: any LibraryStore] = [:]
    private var lastScanFinishedAt: Date?

    private static let dataSourceKey = "FitView.dataSource"
    /// How recently a scan must have run for the next automatic one to be
    /// skipped. Exists because launch and the first `scenePhase == .active`
    /// both fire within a moment of each other, and scanning twice back to
    /// back is pure waste. "Scan Now" bypasses it.
    private static let rescanDebounce: TimeInterval = 2

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let watchedFolder = WatchedFolderSource(defaults: defaults)
        self.watchedFolder = watchedFolder
        self.ingestor = FolderIngestor(source: watchedFolder)
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
            rootURL: FileSystemLibraryStore.defaultRootURL(named: mode.libraryName)
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
        guard watchedFolder.isConfigured, !isScanning else { return }
        if !force, let lastScanFinishedAt,
           Date().timeIntervalSince(lastScanFinishedAt) < Self.rescanDebounce {
            return
        }

        isScanning = true
        defer {
            isScanning = false
            lastScanFinishedAt = Date()
        }

        do {
            let report = try await ingestor.ingest(into: store)
            folderError = nil
            // A routine rescan that found nothing new leaves the last
            // meaningful report on screen instead of blanking it to zeroes.
            if force || report.didChangeLibrary || !report.failures.isEmpty {
                lastIngest = report
            }
            if reloadIfChanged, report.didChangeLibrary {
                await reload()
            }
        } catch {
            folderError = describeFolderError(error)
        }
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
}
