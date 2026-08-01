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

    /// - Parameter rootURL: the library's root directory. Created (along
    ///   with `blobs/` inside it) if it doesn't already exist.
    public init(rootURL: URL) throws {
        manifestURL = rootURL.appendingPathComponent("manifest.json")
        blobsURL = rootURL.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobsURL, withIntermediateDirectories: true)
    }

    public func allItems() async throws -> [LibraryItem] {
        let manifest = try loadManifest()
        return manifest.items.map { resolvingAlias($0, in: manifest) }
    }

    public func data(for itemId: String) async throws -> Data {
        let manifest = try loadManifest()
        guard let item = manifest.items.first(where: { $0.id == itemId }) else {
            throw LibraryStoreError.itemNotFound(itemId: itemId)
        }
        return try Data(contentsOf: blobURL(for: item.blobId))
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
            originalName: activity.candidate.suggestedName,
            importedAt: Date()
        )

        var manifest = try loadManifest()
        manifest.items.append(item)
        try saveManifest(manifest)
        return resolvingAlias(item, in: manifest)
    }

    public func remove(itemId: String) async throws {
        var manifest = try loadManifest()
        manifest.items.removeAll { $0.id == itemId }
        try saveManifest(manifest)
    }

    public func updateDeviceAlias(deviceKey: String, label: String) async throws {
        var manifest = try loadManifest()
        manifest.deviceAliases[deviceKey] = label
        try saveManifest(manifest)
    }

    // MARK: - Manifest I/O

    /// The on-disk shape of `manifest.json`. Kept private to this file —
    /// callers only ever see `LibraryItem`, already alias-resolved.
    private struct Manifest: Codable {
        var items: [LibraryItem] = []
        /// Raw (pre-alias) `deviceKey` -> user-chosen display label.
        var deviceAliases: [String: String] = [:]
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

    /// Resolves a persisted item's device identity against the current alias
    /// table — applied at read time, not baked into storage, so editing an
    /// alias later doesn't require rewriting every item it affects.
    private func resolvingAlias(_ item: LibraryItem, in manifest: Manifest) -> LibraryItem {
        guard let label = manifest.deviceAliases[item.deviceKey] else { return item }
        var resolved = item
        resolved.device = label
        resolved.deviceKey = label.lowercased()
        return resolved
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension FileSystemLibraryStore {
    /// `Application Support/FitView/Library` in the platform's per-user
    /// Application Support directory — the conventional home for data that
    /// isn't user-visible documents but must survive a relaunch. Not
    /// sandbox-specific: `FileManager`'s `.applicationSupportDirectory`
    /// resolves to the right place under an App Sandbox container too, if
    /// one is ever added.
    static func defaultRootURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return base.appendingPathComponent("FitView", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }
}
