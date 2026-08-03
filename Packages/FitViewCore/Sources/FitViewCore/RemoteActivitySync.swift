import Foundation

/// What one Polar (or future remote-service) sync did.
public struct RemoteSyncReport: Sendable, Equatable {
    /// How many candidates the source currently lists, downloaded or not.
    public var discovered: Int
    /// How many of those were new and were written into the watched folder.
    /// Not the same as "imported into the library" — `FolderIngestor` still
    /// has to pick the file up from disk before it shows up anywhere, same as
    /// a file shared in by hand.
    public var downloaded: Int
    /// Candidates that were new but couldn't be fetched or written. Collected
    /// rather than thrown, so one bad exercise in a batch of thirty doesn't
    /// cost the other twenty-nine — `FolderIngestReport.failures` follows the
    /// same principle.
    public var failures: [ImportFailure]

    public init(discovered: Int = 0, downloaded: Int = 0, failures: [ImportFailure] = []) {
        self.discovered = discovered
        self.downloaded = downloaded
        self.failures = failures
    }

    /// Whether this sync added anything for `FolderIngestor` to pick up —
    /// the signal a caller needs to decide whether a folder rescan is worth
    /// running at all.
    public var didChangeFolder: Bool { downloaded > 0 }
}

/// Carries a `UserDefaults` across an isolation boundary — the same narrow,
/// local `@unchecked Sendable` promise `FolderBookmark` makes, duplicated
/// here rather than shared because that one is private to its own file.
private struct SendableUserDefaults: @unchecked Sendable {
    let store: UserDefaults
}

/// A persisted set of ids `RemoteActivitySync` has already downloaded.
///
/// `RemoteActivitySync` can't dedupe the way `FolderIngestor` does — diffing
/// against `LibraryStore.allItems()` — because a Polar-downloaded file is
/// written into the watched folder and then imported by `FolderIngestor`
/// like any other file, so its resulting `LibraryItem.source` reads
/// `"folder"`, not `"polar"`. This is what stands in for that diff instead:
/// membership here means "already written to disk", independent of whatever
/// happens to the file afterward.
public struct RemoteSyncIdStore: Sendable {
    private let defaults: SendableUserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = SendableUserDefaults(store: defaults)
        self.key = key
    }

    public func contains(_ id: String) -> Bool {
        ids().contains(id)
    }

    public func insert(_ id: String) {
        var current = ids()
        guard current.insert(id).inserted else { return }
        defaults.store.set(Array(current), forKey: key)
    }

    /// Forgets every id, so the next sync re-downloads everything the source
    /// currently lists — a deliberate escape hatch for "the file I got was
    /// bad and I deleted it, now what" (a real `RemoteActivitySync` can't
    /// tell "downloaded and fine" from "downloaded and later deleted", so
    /// there's no way to re-fetch just one id without this).
    public func removeAll() {
        defaults.store.removeObject(forKey: key)
    }

    public func ids() -> Set<String> {
        Set(defaults.store.stringArray(forKey: key) ?? [])
    }
}

/// Pulls new activities from a remote `ActivitySource` (Polar today) and
/// writes each one into the watched folder, so `FolderIngestor` picks it up
/// exactly like a file the user shared in by hand — one library, one import
/// path, rather than a second `DataSourceMode`.
///
/// Modelled closely on `FolderIngestor`: list, diff against what's already
/// known, fetch and write only what's new, and never let one bad candidate
/// sink the rest of the batch. The dedupe key here is `RemoteSyncIdStore`
/// rather than a scan of the library, for the reason documented on that type.
///
/// An `actor` — `downloadedIds` is read and written across the loop below,
/// and this type is meant to be called from `AppModel`'s main-actor context
/// without its caller needing to reason about reentrancy itself.
public actor RemoteActivitySync {
    private let downloadedIds: RemoteSyncIdStore
    private let nicknames: DeviceNicknameStore

    public init(downloadedIds: RemoteSyncIdStore, nicknames: DeviceNicknameStore) {
        self.downloadedIds = downloadedIds
        self.nicknames = nicknames
    }

    /// Syncs once. Safe to call repeatedly — nothing already in
    /// `downloadedIds` is re-fetched, so a sync with nothing new costs one
    /// `listAvailable()` call and no downloads.
    @discardableResult
    public func sync(source: any ActivitySource, into bookmark: FolderBookmark) async throws -> RemoteSyncReport {
        let candidates = try await source.listAvailable()
        guard !candidates.isEmpty else { return RemoteSyncReport() }

        let fresh = candidates.filter { !downloadedIds.contains($0.sourceId) }
        guard !fresh.isEmpty else {
            return RemoteSyncReport(discovered: candidates.count)
        }

        var downloaded = 0
        var failures: [ImportFailure] = []
        for candidate in fresh {
            do {
                let imported = try await source.fetch(candidate)
                // Deriving the name from the FIT's own `device_info` (when it
                // decodes) rather than trusting `candidate.suggestedName`
                // outright means a Polar-synced file and the same file shared
                // in by hand land on the same name, so `overview.md` §6's
                // filename grouping treats them as the same activity. The
                // device name itself is further resolved against the shared
                // nickname table, so a device the user already renamed
                // (e.g. "Polar Verity Sense" -> "polarSense") gets its
                // nickname baked into the filename from the very first sync,
                // rather than needing the file re-imported afterward.
                let baseName = defaultActivityFileName(
                    forSharedData: imported.data,
                    incomingFileName: candidate.suggestedName,
                    resolveDeviceLabel: nicknames.resolvedLabel(for:)
                )
                _ = try writeSharedActivity(data: imported.data, desiredBaseName: baseName, into: bookmark)
                // Recorded only on success — like `FolderIngestor`'s failed
                // imports, a candidate that failed here is retried on the
                // next sync rather than permanently skipped.
                downloadedIds.insert(candidate.sourceId)
                downloaded += 1
            } catch {
                failures.append(ImportFailure(candidate: candidate, message: String(describing: error)))
            }
        }

        return RemoteSyncReport(discovered: candidates.count, downloaded: downloaded, failures: failures)
    }
}
