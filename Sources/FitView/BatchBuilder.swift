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

        var files: [LoadedFile] = []
        for item in try await store.allItems() {
            let data = try await store.data(for: item.id)
            // `item.originalName` is filename-shaped for every activity this
            // phase can actually produce (bundled samples, file imports), so
            // handing it to `loadFitFile` keeps `BatchAssembler`'s existing
            // `groupActivityFiles` path working unchanged — reusing Phase 1's
            // assembler as-is rather than routing through `ActivityDescriptor`
            // here, which only pays off once a real API import (no filename
            // to begin with) is wired into the store.
            files.append(try loadFitFile(data: data, fileName: item.originalName))
        }

        return BatchAssembler.assemble(files)
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
