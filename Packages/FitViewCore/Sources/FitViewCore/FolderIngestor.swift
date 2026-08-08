import Foundation

/// What one folder scan did.
public struct FolderIngestReport: Sendable, Equatable {
    /// How many `.fit` files the folder currently holds, downloaded or not.
    public var discovered: Int
    /// How much the library actually grew — `store.allItems().count` after
    /// minus before, not the number of successful decodes. `LibraryStore.add`
    /// can now decode a file successfully and still append nothing (an
    /// identical activity already on file), so counting decodes would
    /// overstate what actually landed; this is the number shown to the user
    /// as "N newly imported", so it needs to be true. Zero on a rescan of an
    /// unchanged folder — the expected case.
    public var imported: Int
    /// Files that were new but couldn't be read, downloaded, or decoded.
    /// Collected rather than thrown, so one corrupt file in a folder of fifty
    /// doesn't cost the user the other forty-nine — the same "a broken join
    /// should be visible, not quietly hidden" principle the rest of this
    /// package follows.
    public var failures: [ImportFailure]
    /// Library items removed because their file left the folder (FR-009).
    /// Zero on every scan that removed nothing — the overwhelmingly common
    /// case. Always zero when the listing was untrustworthy (FR-010), since
    /// no reconciliation is attempted at all in that case.
    public var removed: Int

    public init(discovered: Int = 0, imported: Int = 0, failures: [ImportFailure] = [], removed: Int = 0) {
        self.discovered = discovered
        self.imported = imported
        self.failures = failures
        self.removed = removed
    }

    /// Whether this scan changed the library — the signal a caller needs to
    /// decide whether to rebuild the on-screen batch. A removal-only scan
    /// (nothing new imported) still counts: without this, reconciled-away
    /// items would stay visible until something else forced a reload.
    public var didChangeLibrary: Bool { imported > 0 || removed > 0 }
}

/// Scans a `WatchedFolderSource`, works out which files aren't in the library
/// yet, and imports only those.
///
/// The diff is what makes this cheap. Candidates are matched on
/// `(source, sourceId)`: `sourceId` is a path relative to the folder, so it's
/// stable across relaunches and across the folder itself being moved or
/// renamed. Content hashing would answer the same question more precisely, but
/// only by reading every file, which for an iCloud folder means materialising
/// the entire thing on every scan just to learn there's nothing to do — so the
/// path diff is what keeps the common "nothing new" case free.
///
/// It is not what makes this *correct*: `FileSystemLibraryStore.add` refuses
/// to append an activity whose bytes and descriptor it already holds, so a
/// file that slips past the path diff still can't duplicate anything. The two
/// checks answer different questions — "do I need to read this file?" here,
/// "is this already in the library?" there — and the cheap one runs first.
///
/// Two consequences worth knowing:
///
/// - Replacing a file with different bytes *under the same name* is not
///   re-imported, because the identity tracked here is "this path", not
///   "these bytes". Activity exports are write-once in practice, and the
///   alternative costs a full download on every scan.
/// - A file whose content duplicates one already in the library is read on
///   every scan, since it lands no item and so never gets its `sourceId`
///   recorded to diff against next time. Correct, just not free — the cost is
///   one redundant read per duplicate file per scan.
///
/// Placed in `FitViewCore` rather than the app layer for the reason
/// `FolderSyncStore` documents: it touches nothing platform-specific, and this
/// is the only way its dedupe logic lands under `swift test`, which is this
/// project's actual automated gate.
public actor FolderIngestor {
    private let source: WatchedFolderSource
    private let coordinator: ImportCoordinator

    /// - Parameter coordinator: defaults to a **private** one, and should stay
    ///   that way. `ImportCoordinator.startImport` cancels whatever import is
    ///   in flight (`overview.md` §11's atomic-batch rule), so sharing the
    ///   app's coordinator would let an automatic background rescan silently
    ///   kill a Polar import the user kicked off by hand.
    public init(source: WatchedFolderSource, coordinator: ImportCoordinator = ImportCoordinator()) {
        self.source = source
        self.coordinator = coordinator
    }

    /// Scans and imports anything new. Safe to call repeatedly — an unchanged
    /// folder costs one directory listing and no file reads at all.
    @discardableResult
    public func ingest(into store: any LibraryStore) async throws -> FolderIngestReport {
        let candidates = try await source.listAvailable()

        let itemsBefore = try await store.allItems()
        let present = Set(candidates.map(\.sourceId))
        let known = Set(
            itemsBefore
                .filter { $0.source == source.id }
                .compactMap(\.sourceId)
        )
        // FR-011/FR-010: only items this same source owns, whose sourceId is
        // set (a legacy item predating that field can't be matched and must
        // not be inferred missing — C2), and whose file this listing didn't
        // see. `candidates` is trusted complete here only because
        // `listAvailable()` returned without throwing (C1); an empty
        // `candidates` from a genuinely empty folder is a legitimate
        // observation, not a failure, so it reconciles away every remaining
        // folder item just like a partially-emptied folder would.
        let stale = itemsBefore.filter {
            $0.source == source.id && $0.sourceId != nil && !present.contains($0.sourceId!)
        }

        // A removal that throws must not abort the pass (C5) — matches the
        // "one bad item doesn't sink the batch" rule import failures already
        // follow. Nothing is collected per-failure: `removed` only ever
        // counts what actually left the library, which is the property
        // FR-012's report and C6's truthful-counts rule need.
        var removedCount = 0
        for item in stale {
            do {
                try await store.remove(itemId: item.id)
                removedCount += 1
            } catch {
                continue
            }
        }

        // Re-baselined against a post-removal read when anything was removed,
        // so removing 3 and importing 3 in the same pass can't be corrupted
        // into reporting 0 imported (research.md §4, contract C6) — taken
        // *before* the import phase runs, and the extra read is paid only on
        // scans that actually removed something.
        let importBaseline = removedCount > 0 ? try await store.allItems() : itemsBefore

        // A folder can legitimately contain the same file twice under
        // different paths; dedupe within the scan too, or a single pass would
        // import one of them and then re-import it as "new" forever after.
        var seen = Set<String>()
        let fresh = candidates.filter { candidate in
            guard !known.contains(candidate.sourceId) else { return false }
            return seen.insert(candidate.sourceId).inserted
        }

        guard !fresh.isEmpty else {
            return FolderIngestReport(discovered: candidates.count, removed: removedCount)
        }

        guard let result = await coordinator.startImport(from: source, candidates: fresh, store: store) else {
            // Superseded by another `startImport` on this same private
            // coordinator — i.e. two scans overlapped. The winner's report
            // covers the same folder, so reporting nothing here is right;
            // merging a discarded result is exactly what the atomic-batch rule
            // forbids.
            return FolderIngestReport(discovered: candidates.count, removed: removedCount)
        }

        // `result.files.count` is decodes, not library growth — with the
        // dedupe-on-(blob, descriptor) rule in `FileSystemLibraryStore.add`,
        // a decode can succeed while the store appends nothing. Measure the
        // actual delta instead so "imported" stays truthful.
        let itemsAfter = try await store.allItems()
        return FolderIngestReport(
            discovered: candidates.count,
            imported: itemsAfter.count - importBaseline.count,
            failures: result.failures,
            removed: removedCount
        )
    }
}
