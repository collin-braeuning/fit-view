import CryptoKit
import Foundation

/// Disk-backed `LibraryStore`, rooted at a directory the caller owns (in
/// practice `Application Support/FitView/Library`, but this type knows
/// nothing about that path — the app layer decides it so tests can point at
/// a temp directory instead).
///
/// ```
/// <rootURL>/
///   manifest.json     // [LibraryItem] + device aliases, atomic write
///   blobs/<sha256>.fit // content-addressed
/// ```
///
/// Raw bytes are the source of truth; `manifest.json` is just an index over
/// them. Content addressing is what makes this conflict-free for a future
/// folder-sync phase: a blob id can never refer to two different byte
/// sequences, so importing the same activity twice (once from a file, once
/// later from an API) collapses onto one blob rather than duplicating it.
///
/// An actor because `add`/`remove`/`updateDeviceAlias` all read-modify-write
/// the same manifest file — an `ImportCoordinator` task group fetching
/// several activities concurrently must not race two of those against each
/// other.
public actor FileSystemLibraryStore: LibraryStore {
    private let manifestURL: URL
    private let blobsURL: URL
    private let nicknames: DeviceNicknameStore

    /// - Parameters:
    ///   - rootURL: the library's root directory. Created (along with
    ///     `blobs/` inside it) if it doesn't already exist.
    ///   - nicknames: the shared device-nickname table (see
    ///     `DeviceNicknameStore`), required rather than defaulted so every
    ///     call site — production and test alike — states explicitly
    ///     whether it means to share one table across stores or keep an
    ///     isolated one. A convenience default onto `AppGroup.defaults`
    ///     would silently make every test-constructed store in `swift test`
    ///     (which has no App Group entitlement, so `AppGroup.defaults` falls
    ///     back to `.standard`) share one process-wide table — breaking the
    ///     "two independent stores that start diverged and later merge"
    ///     premise `FolderSyncStoreTests` depends on.
    public init(rootURL: URL, nicknames: DeviceNicknameStore) throws {
        manifestURL = rootURL.appendingPathComponent("manifest.json")
        blobsURL = rootURL.appendingPathComponent("blobs", isDirectory: true)
        self.nicknames = nicknames
        try FileManager.default.createDirectory(at: blobsURL, withIntermediateDirectories: true)
    }

    public func allItems() async throws -> [LibraryItem] {
        let manifest = try loadManifest()
        let table = nicknames.all()
        return manifest.items.map { resolvingAlias($0, using: table) }
    }

    public func data(for itemId: String) async throws -> Data {
        let manifest = try loadManifest()
        guard let item = manifest.items.first(where: { $0.id == itemId }) else {
            throw LibraryStoreError.itemNotFound(itemId: itemId)
        }
        return try Data(contentsOf: blobURL(for: item.blobId))
    }

    public func data(for itemIds: [String]) async throws -> [String: Data] {
        let manifest = try loadManifest()
        var byId: [String: Data] = [:]
        for itemId in itemIds {
            guard let item = manifest.items.first(where: { $0.id == itemId }) else {
                throw LibraryStoreError.itemNotFound(itemId: itemId)
            }
            byId[itemId] = try Data(contentsOf: blobURL(for: item.blobId))
        }
        return byId
    }

    @discardableResult
    public func add(_ activity: ImportedActivity) async throws -> LibraryItem {
        let blobId = Self.sha256Hex(activity.data)
        let url = blobURL(for: blobId)
        if !FileManager.default.fileExists(atPath: url.path) {
            // Content-addressed: identical bytes already have this exact
            // file on disk, so a duplicate import is a manifest-only append,
            // never a second write of the same content.
            try activity.data.write(to: url, options: .atomic)
        }

        let fields = activityDescriptorFields(for: activity.candidate)

        var manifest = try loadManifest()
        let table = nicknames.all()

        // Same bytes *and* the same descriptor slot: this is a re-import of
        // an activity already in the library, not a new one. Match against
        // the raw stored items — `resolvingAlias` rewrites `device`/
        // `deviceKey` at read time, and comparing resolved values would make
        // the match depend on the current alias table rather than what was
        // actually imported. Bytes alone would collapse two different
        // activities that happen to share content; the descriptor alone
        // would collapse two different files that legitimately group into
        // the same session slot — only both together identify a duplicate.
        if let existing = manifest.items.first(where: {
            $0.blobId == blobId && $0.date == fields.date && $0.deviceKey == fields.deviceKey
                && $0.activityKey == fields.activityKey
        }) {
            return resolvingAlias(existing, using: table)
        }

        let item = LibraryItem(
            id: UUID().uuidString,
            blobId: blobId,
            date: fields.date,
            device: fields.device,
            deviceKey: fields.deviceKey,
            activity: fields.activity,
            activityKey: fields.activityKey,
            sport: activity.candidate.sport,
            startTime: activity.candidate.startTime,
            source: activity.source,
            sourceId: activity.candidate.sourceId,
            originalName: activity.candidate.suggestedName,
            importedAt: Date()
        )

        manifest.items.append(item)
        try saveManifest(manifest)
        return resolvingAlias(item, using: table)
    }

    public func remove(itemId: String) async throws {
        var manifest = try loadManifest()
        manifest.items.removeAll { $0.id == itemId }
        try saveManifest(manifest)
    }

    public func updateDeviceAlias(deviceKey: String, label: String) async throws {
        guard nicknames.setNickname(label, forRawDeviceName: deviceKey) else {
            throw LibraryStoreError.aliasCycleDetected(deviceKey: deviceKey, label: label)
        }
    }

    public func deviceAliases() async throws -> [String: String] {
        nicknames.all().mapValues(\.label)
    }

    public func addRawItem(_ item: LibraryItem, data: Data) async throws {
        var manifest = try loadManifest()
        guard !manifest.items.contains(where: { $0.id == item.id }) else { return }

        // Recompute rather than trust `item.blobId` outright — cheap, and it
        // keeps this store's own content-addressing invariant (a blob id
        // always matches its bytes) true even for items handed in from
        // outside, not just ones built by `add(_:)`.
        let blobId = Self.sha256Hex(data)
        let url = blobURL(for: blobId)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }

        var stored = item
        stored.blobId = blobId
        manifest.items.append(stored)
        try saveManifest(manifest)
    }

    // MARK: - Manifest I/O

    /// The on-disk shape of `manifest.json`. Kept private to this file —
    /// callers only ever see `LibraryItem`, already alias-resolved.
    private struct Manifest: Codable {
        var items: [LibraryItem] = []
    }

    private func loadManifest() throws -> Manifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return Manifest() }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw LibraryStoreError.corruptManifest(underlying: String(describing: error))
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Manifest.self, from: data)
        } catch {
            throw LibraryStoreError.corruptManifest(underlying: String(describing: error))
        }
    }

    private func saveManifest(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        // `.atomic` writes to a temp file and renames over the destination,
        // so a crash mid-write leaves either the old manifest or the new one
        // intact — never a half-written, corrupt file from this store's own
        // code.
        try data.write(to: manifestURL, options: .atomic)
    }

    private func blobURL(for blobId: String) -> URL {
        blobsURL.appendingPathComponent("\(blobId).fit")
    }

    /// Resolves a persisted item's device identity against the shared
    /// nickname table — applied at read time, not baked into storage, so
    /// renaming a device later doesn't require rewriting every item it
    /// affects. Keyed off `item.device` (original casing) through
    /// `DeviceNicknameStore.key(for:)` rather than `item.deviceKey` directly
    /// — `deviceKey` is computed by two different algorithms elsewhere
    /// (`parseActivityFileName`'s plain lowercase versus
    /// `activityDescriptorFields`'s space-stripped-then-lowercased slug for
    /// API-sourced candidates) that disagree on whitespace, so keying off
    /// the raw display name through one canonical normalizer reconciles
    /// both instead of only ever matching one of them.
    private func resolvingAlias(_ item: LibraryItem, using table: [String: DeviceNickname]) -> LibraryItem {
        let label = DeviceNicknameStore.resolvedLabel(for: item.device, in: table)
        guard label != item.device else { return item }
        var resolved = item
        resolved.device = label
        // `DeviceNicknameStore.key(for:)`, not a bare `.lowercased()` — the
        // whole reason this resolves off `item.device` in the first place
        // is to reconcile the two existing `deviceKey` algorithms that
        // disagree on whitespace, so the alias's own resulting key must go
        // through the same normalizer or it would just introduce a third
        // spelling.
        resolved.deviceKey = DeviceNicknameStore.key(for: label)
        return resolved
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension FileSystemLibraryStore {
    /// `Application Support/FitView/<name>` in the platform's per-user
    /// Application Support directory — the conventional home for data that
    /// isn't user-visible documents but must survive a relaunch. Not
    /// sandbox-specific: `FileManager`'s `.applicationSupportDirectory`
    /// resolves to the right place under an App Sandbox container too, if
    /// one is ever added.
    ///
    /// - Parameter name: which library. The app keeps one root per data
    ///   source — `"Library"` (the default, and the original path, so the
    ///   bundled-sample library needs no migration) and `"FolderLibrary"` for
    ///   the watched folder. Separate roots rather than one mixed library so
    ///   switching sources is instant and reversible, and so sample data can
    ///   never contaminate a batch of real activities (or vice versa); each
    ///   also keeps its own device aliases, which is what you'd want anyway
    ///   since the two describe different device populations.
    static func defaultRootURL(named name: String = "Library", fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return base.appendingPathComponent("FitView", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
}
