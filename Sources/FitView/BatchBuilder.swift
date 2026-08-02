import FitViewCore
import Foundation

/// Loads the app's batch from the local library store, seeding the bundled
/// sample corpus into it on first launch so the app is never empty, then runs
/// the batch comparison pipeline over whatever's there — mirroring the web
/// app's `useBatchAgreement`: group by filename, extract each file's
/// per-second heart rate once, then compare the two most common devices.
///
/// Replaces the old `SampleBatchLoader`, which read the bundle directly on
/// every launch and never persisted anything. Now the bundle is only ever
/// read once — the moment the store is empty — and every subsequent launch
/// reads back through the store instead, which is what makes the library
/// durable across a relaunch (`overview.md` §10.6's "nothing persists" gap).
enum BatchBuilder {
    static func load(store: some LibraryStore) async throws -> LoadedBatch {
        try await seedBundledSamplesIfNeeded(store: store)

        let items = try await store.allItems()
        // One bulk fetch instead of one `data(for:)` hop per item — each hop
        // re-reads and re-parses the same `manifest.json` to resolve an id to
        // a blob path, which for a store-backed batch turned "read the
        // index" into an O(items) serial cost paid before decoding even
        // started.
        let dataById = try await store.data(for: items.map(\.id))

        // Decode across a task group rather than one file at a time: decode
        // is pure CPU work per file (see `loadFitFile`), so running it
        // serially leaves every core but one idle while the FIT SDK grinds
        // through 16 files back to back. Still worth it after the move to
        // `FitFileParser` — it takes the sample corpus from ~1,068ms to
        // ~301ms in a Debug build — though the stakes are far lower than
        // under the previous decoder, where the same task group was the
        // difference between a 17s and a 6s launch. Results come back in completion
        // order, not submission order, so each is tagged with its original
        // index and re-sorted afterward — `groupActivities`' "first one wins"
        // duplicate-device handling and first-seen device-label casing both
        // depend on a stable input order, and decode-completion order isn't
        // one (see the sibling fix for non-deterministic primary/secondary
        // device assignment).
        let indexed = try await withThrowingTaskGroup(of: (Int, BatchAssembler.Entry).self) { group in
            for (index, item) in items.enumerated() {
                // Guaranteed present: `store.data(for:)` throws before
                // returning if any id it was asked for is missing.
                let data = dataById[item.id]!
                group.addTask {
                    // `item.originalName` is only used for
                    // `LoadedFile.fileName`/decode bookkeeping (display,
                    // debugging) here — grouping itself goes through
                    // `item.descriptor`, built from the item's real
                    // date/device/activity fields rather than a re-parsed
                    // filename, so an API-sourced item (no filename to begin
                    // with) groups exactly like a file-backed one.
                    let file = try loadFitFile(data: data, fileName: item.originalName)
                    return (index, BatchAssembler.Entry(descriptor: item.descriptor, file: file))
                }
            }

            var indexed: [(Int, BatchAssembler.Entry)] = []
            for try await result in group {
                indexed.append(result)
            }
            return indexed
        }

        let entries = indexed.sorted { $0.0 < $1.0 }.map(\.1)
        return BatchAssembler.assemble(entries)
    }

    /// Imports every bundled sample exactly once. Guarded by "the store is
    /// currently empty" rather than a persisted first-launch flag, so a user
    /// who removes every item gets the samples back instead of a
    /// permanently empty app.
    private static func seedBundledSamplesIfNeeded(store: some LibraryStore) async throws {
        guard try await store.allItems().isEmpty else { return }

        for url in bundledSampleURLs() {
            let fileName = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let candidate = ImportCandidate(sourceId: fileName, suggestedName: stripFileExtension(fileName))
            try await store.add(ImportedActivity(candidate: candidate, data: data, source: "bundled"))
        }
    }
}
