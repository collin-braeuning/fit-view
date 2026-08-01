import Foundation

/// Errors specific to `FolderSyncStore`. Distinct from `LibraryStoreError`
/// (the local store's own bookkeeping) — these are about reaching, or
/// materialising, the remote folder at all.
public enum FolderSyncError: Error, Sendable, Equatable {
    /// No folder has been picked yet (`isConfigured == false`).
    case notConfigured
    /// The security-scoped bookmark couldn't be resolved back to a folder —
    /// most likely the user moved/deleted it, or revoked access, since it was
    /// picked.
    case bookmarkResolutionFailed(underlying: String)
    /// `startDownloadingUbiquitousItem(at:)` was called but the item never
    /// finished materialising within the timeout — the single most likely
    /// cause of "sync silently does nothing" against real iCloud Drive.
    case materializationTimedOut(path: String)
}

/// Syncs a local `LibraryStore` against a folder the user picked once via the
/// directory document picker — in practice an iCloud Drive folder, though
/// nothing here assumes that; a plain local folder works identically (and is
/// what the test suite exercises, since there's no way to drive real iCloud
/// Drive materialisation from CI).
///
/// Deliberately placed in `FitViewCore` rather than the app layer the
/// original plan sketched: everything this type touches — `Foundation`'s
/// `NSFileCoordinator`, `UserDefaults`, security-scoped bookmarks, and the
/// ubiquitous-item APIs — is available on both platforms and needs no
/// SwiftUI/UIKit/AppKit import, and putting it here is the only way its merge
/// policy and materialisation-wait logic land under `swift test`, which is
/// this project's actual automated gate (there is no XCTest target wired up
/// for the app layer). Only the directory document-picker *view* lives in
/// the app layer, calling `setFolder(_:)` with whatever URL it returns.
///
/// The remote folder's layout deliberately mirrors `FileSystemLibraryStore`'s
/// own (`manifest.json` + `blobs/<sha256>.fit`) — not because callers reach
/// into it directly (they go through `push`/`pull` like any other
/// `RemoteLibraryStore`), but because it's the simplest shape that already
/// solves content-addressing and manifest merging for a single local store,
/// and reusing it here means there's only one manifest shape in the codebase
/// to reason about.
public actor FolderSyncStore: RemoteLibraryStore {
    // `nonisolated(unsafe)`: both are immutable (`let`) and of `Sendable`
    // types (`UserDefaults` is `@unchecked Sendable`, `String` is `Sendable`),
    // so a nonisolated read can never race a mutation — there isn't one.
    // Needed so the protocol's synchronous `isConfigured` requirement can be
    // satisfied without making it `async`.
    private nonisolated(unsafe) let defaults: UserDefaults
    private nonisolated(unsafe) let bookmarkKey: String
    /// How long to wait for a single `.icloud` placeholder to materialise
    /// before giving up. Generous relative to typical Wi-Fi sync latency for
    /// a single small `.fit` file, but still bounded — a hung sync must fail
    /// loudly rather than hang the UI forever.
    private let materializationTimeout: TimeInterval

    public init(
        defaults: UserDefaults = .standard,
        bookmarkKey: String = "FitView.FolderSyncStore.bookmark",
        materializationTimeout: TimeInterval = 15
    ) {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
        self.materializationTimeout = materializationTimeout
    }

    // `nonisolated` (rather than actor-isolated, which is the default for a
    // computed property on an actor) because the protocol requirement is
    // synchronous — reading `defaults`/`bookmarkKey` without `await` is sound
    // here because both are `let`s of `Sendable` types, so there's no way
    // for this read to race a mutation.
    public nonisolated var isConfigured: Bool {
        defaults.data(forKey: bookmarkKey) != nil
    }

    /// Called once the user picks a folder via the directory document
    /// picker (or, in tests, any plain directory URL — no picker needed).
    /// Persists a security-scoped bookmark so future syncs don't need the
    /// picker again.
    public func setFolder(_ url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try Self.makeBookmark(for: url)
        defaults.set(bookmark, forKey: bookmarkKey)
    }

    @discardableResult
    public func push(_ local: any LibraryStore) async throws -> SyncReport {
        let folderURL = try resolveFolder()
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didAccess { folderURL.stopAccessingSecurityScopedResource() } }

        try FileManager.default.createDirectory(
            at: blobsURL(under: folderURL), withIntermediateDirectories: true
        )

        var remoteManifest = try await loadManifest(at: folderURL)
        let remoteIds = Set(remoteManifest.items.map(\.id))

        let localItems = try await local.allItems()
        var itemsCopied = 0
        var blobsCopied = 0
        for item in localItems where !remoteIds.contains(item.id) {
            let blobURL = blobURL(for: item.blobId, under: folderURL)
            if !FileManager.default.fileExists(atPath: blobURL.path) {
                let data = try await local.data(for: item.id)
                try coordinatedWrite(data, to: blobURL)
                blobsCopied += 1
            }
            remoteManifest.items.append(item)
            itemsCopied += 1
        }

        let localAliases = try await local.deviceAliases()
        var aliasesMerged = 0
        for (key, label) in localAliases where remoteManifest.deviceAliases[key] != label {
            remoteManifest.deviceAliases[key] = label
            aliasesMerged += 1
        }

        try saveManifest(remoteManifest, at: folderURL)
        return SyncReport(itemsCopied: itemsCopied, blobsCopied: blobsCopied, aliasesMerged: aliasesMerged)
    }

    @discardableResult
    public func pull(into local: any LibraryStore) async throws -> SyncReport {
        let folderURL = try resolveFolder()
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didAccess { folderURL.stopAccessingSecurityScopedResource() } }

        let manifestURL = manifestURL(under: folderURL)
        guard try await coordinatedFileExists(manifestURL) else {
            // Nothing has ever been pushed to this folder — an empty pull,
            // not an error (a first-time sync from a device that only ever
            // pulls shouldn't look like a failure).
            return SyncReport()
        }
        let remoteManifest = try await loadManifest(at: folderURL)

        let localItems = try await local.allItems()
        let localIds = Set(localItems.map(\.id))
        var itemsCopied = 0
        var blobsCopied = 0
        for item in remoteManifest.items where !localIds.contains(item.id) {
            let blobURL = blobURL(for: item.blobId, under: folderURL)
            try await ensureMaterialized(blobURL)
            let data = try coordinatedRead(blobURL)
            try await local.addRawItem(item, data: data)
            itemsCopied += 1
            blobsCopied += 1
        }

        let localAliases = try await local.deviceAliases()
        var aliasesMerged = 0
        for (key, label) in remoteManifest.deviceAliases where localAliases[key] != label {
            try await local.updateDeviceAlias(deviceKey: key, label: label)
            aliasesMerged += 1
        }

        return SyncReport(itemsCopied: itemsCopied, blobsCopied: blobsCopied, aliasesMerged: aliasesMerged)
    }

    // MARK: - Bookmark resolution

    private func resolveFolder() throws -> URL {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else {
            throw FolderSyncError.notConfigured
        }
        var isStale = false
        let url: URL
        do {
            url = try Self.resolveBookmark(bookmark, isStale: &isStale)
        } catch {
            throw FolderSyncError.bookmarkResolutionFailed(underlying: String(describing: error))
        }
        if isStale, let refreshed = try? Self.makeBookmark(for: url) {
            defaults.set(refreshed, forKey: bookmarkKey)
        }
        return url
    }

    #if os(macOS)
    private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolveBookmark(_ bookmark: Data, isStale: inout Bool) throws -> URL {
        try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
    #else
    private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolveBookmark(_ bookmark: Data, isStale: inout Bool) throws -> URL {
        try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
    #endif

    // MARK: - Remote layout

    private func manifestURL(under folderURL: URL) -> URL {
        folderURL.appendingPathComponent("manifest.json")
    }

    private func blobsURL(under folderURL: URL) -> URL {
        folderURL.appendingPathComponent("blobs", isDirectory: true)
    }

    private func blobURL(for blobId: String, under folderURL: URL) -> URL {
        blobsURL(under: folderURL).appendingPathComponent("\(blobId).fit")
    }

    /// The on-disk shape of the remote `manifest.json` — deliberately the
    /// same field names as `FileSystemLibraryStore`'s own (private) manifest
    /// struct, so the two are wire-compatible, even though neither type
    /// references the other.
    private struct RemoteManifest: Codable {
        var items: [LibraryItem] = []
        var deviceAliases: [String: String] = [:]
    }

    private func loadManifest(at folderURL: URL) async throws -> RemoteManifest {
        let url = manifestURL(under: folderURL)
        guard try await coordinatedFileExists(url) else { return RemoteManifest() }
        try await ensureMaterialized(url)
        let data = try coordinatedRead(url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RemoteManifest.self, from: data)
    }

    private func saveManifest(_ manifest: RemoteManifest, at folderURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try coordinatedWrite(data, to: manifestURL(under: folderURL))
    }

    // MARK: - iCloud materialisation

    /// Downloads (if needed) and waits for a ubiquitous item to stop being an
    /// `.icloud` placeholder stub before any read touches it. A no-op for a
    /// plain local file (`isUbiquitousItem` false) — which is what makes this
    /// safe to call unconditionally, including from tests against a plain
    /// temp directory.
    private func ensureMaterialized(_ url: URL) async throws {
        let isUbiquitous = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem
        guard isUbiquitous == true else { return }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(materializationTimeout)
        while Date() < deadline {
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
            if status == .current || status == .downloaded { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw FolderSyncError.materializationTimedOut(path: url.path)
    }

    // MARK: - NSFileCoordinator wrapping

    /// `NSFileCoordinator` is mandatory for iCloud Drive: reading or writing
    /// a ubiquitous file without it risks tearing a read against an in-flight
    /// sync, or racing another device's write. Every read/write in this store
    /// funnels through one of these three helpers so that invariant can't be
    /// accidentally bypassed by a future edit.
    private func coordinatedRead(_ url: URL) throws -> Data {
        var coordinatorError: NSError?
        var result: Data?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            do {
                result = try Data(contentsOf: readURL)
            } catch {
                thrown = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let thrown { throw thrown }
        guard let result else {
            throw FolderSyncError.bookmarkResolutionFailed(underlying: "coordinated read never ran")
        }
        return result
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinatorError: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinatorError) { writeURL in
            do {
                try FileManager.default.createDirectory(
                    at: writeURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: writeURL, options: .atomic)
            } catch {
                thrown = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let thrown { throw thrown }
    }

    private func coordinatedFileExists(_ url: URL) async throws -> Bool {
        var coordinatorError: NSError?
        var exists = false
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            exists = FileManager.default.fileExists(atPath: readURL.path)
        }
        if let coordinatorError { throw coordinatorError }
        return exists
    }
}
