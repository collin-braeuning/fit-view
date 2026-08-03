import Foundation
import Testing
@testable import FitViewCore

private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Real `.fit` bytes, because ingest runs the full `ImportCoordinator` →
/// `loadFitFile` path — plain bytes would land in `failures` and prove nothing
/// about the dedupe these tests exist to pin down. Same relative-path approach
/// as `ImportCoordinatorTests`.
private func realFitData(named name: String = "2026-07-23_pace4_run.fit") throws -> Data {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FitViewCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FitViewCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
    return try Data(contentsOf: repoRoot.appendingPathComponent("Sources/FitView/Resources/SampleData/\(name)"))
}

private func placeFitFile(named name: String, in folder: URL, from fixture: String) throws {
    let url = folder.appendingPathComponent(name)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try realFitData(named: fixture).write(to: url)
}

private func makeIngestor(watching folder: URL) async throws -> FolderIngestor {
    let defaults = UserDefaults(suiteName: "FolderIngestorTests.\(UUID().uuidString)")!
    let source = WatchedFolderSource(defaults: defaults)
    try await source.setFolder(folder)
    return FolderIngestor(source: source)
}

/// A fresh, isolated `DeviceNicknameStore` per store — these tests don't
/// exercise aliasing, so isolation just needs to hold, not anything more.
private func makeStore(rootURL: URL) throws -> FileSystemLibraryStore {
    try FileSystemLibraryStore(
        rootURL: rootURL,
        nicknames: DeviceNicknameStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    )
}

@Suite("FolderIngestor")
struct FolderIngestorTests {
    @Test("a first scan imports every .fit file in the folder")
    func firstScanImportsEverything() async throws {
        let folder = makeTempDirectory()
        try placeFitFile(named: "2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")
        try placeFitFile(named: "2026-07-23_polarSense_run.FIT", in: folder, from: "2026-07-23_polarSense_run.FIT")

        let ingestor = try await makeIngestor(watching: folder)
        let store = try makeStore(rootURL: makeTempDirectory())

        let report = try await ingestor.ingest(into: store)
        #expect(report.discovered == 2)
        #expect(report.imported == 2)
        #expect(report.failures.isEmpty)
        #expect(report.didChangeLibrary)
        #expect(try await store.allItems().count == 2)
    }

    /// The load-bearing test for the whole watched-folder design. This runs on
    /// every launch and every return to the foreground, and
    /// `LibraryStore.add` appends unconditionally with a fresh `id` — so
    /// without the `sourceId` diff, a week of ordinary use would multiply the
    /// library by the number of times the app was opened.
    @Test("rescanning an unchanged folder imports nothing and adds no items")
    func rescanOfUnchangedFolderIsANoOp() async throws {
        let folder = makeTempDirectory()
        try placeFitFile(named: "2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")

        let ingestor = try await makeIngestor(watching: folder)
        let store = try makeStore(rootURL: makeTempDirectory())

        let first = try await ingestor.ingest(into: store)
        #expect(first.imported == 1)

        let second = try await ingestor.ingest(into: store)
        #expect(second.discovered == 1, "the file is still there and must still be reported as discovered")
        #expect(second.imported == 0, "an already-imported file must never be imported twice")
        #expect(second.didChangeLibrary == false)

        let third = try await ingestor.ingest(into: store)
        #expect(third.imported == 0)

        #expect(try await store.allItems().count == 1, "three scans of one file must leave exactly one item")
    }

    @Test("a rescan imports only the genuinely new file, leaving existing items untouched")
    func rescanImportsOnlyNewFiles() async throws {
        let folder = makeTempDirectory()
        try placeFitFile(named: "2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")

        let ingestor = try await makeIngestor(watching: folder)
        let store = try makeStore(rootURL: makeTempDirectory())

        let first = try await ingestor.ingest(into: store)
        #expect(first.imported == 1)
        let firstItemId = try #require(try await store.allItems().first?.id)

        try placeFitFile(named: "2026-07-23_polarSense_run.FIT", in: folder, from: "2026-07-23_polarSense_run.FIT")

        let second = try await ingestor.ingest(into: store)
        #expect(second.discovered == 2)
        #expect(second.imported == 1, "only the file that wasn't there before")

        let items = try await store.allItems()
        #expect(items.count == 2)
        #expect(items.contains { $0.id == firstItemId }, "the already-imported item keeps its identity")
        #expect(Set(items.compactMap(\.sourceId)) == [
            "2026-07-23_pace4_run.fit", "2026-07-23_polarSense_run.FIT",
        ])
    }

    @Test("an empty folder is a successful no-op, not an error")
    func emptyFolderIsANoOp() async throws {
        let ingestor = try await makeIngestor(watching: makeTempDirectory())
        let store = try makeStore(rootURL: makeTempDirectory())

        let report = try await ingestor.ingest(into: store)
        #expect(report == FolderIngestReport())
        #expect(try await store.allItems().isEmpty)
    }

    @Test("ingesting without a folder configured throws rather than silently importing nothing")
    func unconfiguredIngestThrows() async throws {
        let defaults = UserDefaults(suiteName: "FolderIngestorTests.\(UUID().uuidString)")!
        let ingestor = FolderIngestor(source: WatchedFolderSource(defaults: defaults))
        let store = try makeStore(rootURL: makeTempDirectory())

        await #expect(throws: ActivitySourceError.self) {
            _ = try await ingestor.ingest(into: store)
        }
    }

    @Test("a corrupt file is reported as a failure without blocking the rest of the folder")
    func corruptFileDoesNotBlockTheBatch() async throws {
        let folder = makeTempDirectory()
        try placeFitFile(named: "2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: folder.appendingPathComponent("2026-07-24_pace4_run.fit"))

        let ingestor = try await makeIngestor(watching: folder)
        let store = try makeStore(rootURL: makeTempDirectory())

        let report = try await ingestor.ingest(into: store)
        #expect(report.discovered == 2)
        #expect(report.imported == 1)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.candidate.sourceId == "2026-07-24_pace4_run.fit")
    }

    /// The failure isn't recorded anywhere, so a corrupt file is retried on
    /// every scan. That's deliberate — the fix for a corrupt file is usually
    /// to replace it, and a retry is one cheap local read.
    @Test("a file that failed to import is retried on the next scan, not permanently skipped")
    func failedImportsAreRetried() async throws {
        let folder = makeTempDirectory()
        let corruptURL = folder.appendingPathComponent("2026-07-24_pace4_run.fit")
        try Data([0x00, 0x01]).write(to: corruptURL)

        let ingestor = try await makeIngestor(watching: folder)
        let store = try makeStore(rootURL: makeTempDirectory())

        #expect(try await ingestor.ingest(into: store).failures.count == 1)

        // Replaced with something readable — the next scan must pick it up.
        try realFitData().write(to: corruptURL)
        let report = try await ingestor.ingest(into: store)
        #expect(report.imported == 1)
        #expect(report.failures.isEmpty)
    }

    @Test("the same activity placed at two paths is discovered twice but lands as one item")
    func duplicatePathsCollapseToOneItem() async throws {
        // Two paths are still two *candidates* — `sourceId` is the path, and
        // the scan-level diff only knows about paths it has already stored.
        // But both files share bytes and (because they share a filename) the
        // same descriptor triple, so `FileSystemLibraryStore.add`'s
        // (blobId, descriptor) dedupe now recognises the second decode as
        // the same activity and appends nothing for it.
        let folder = makeTempDirectory()
        try placeFitFile(named: "2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")
        try placeFitFile(named: "copy/2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")

        let ingestor = try await makeIngestor(watching: folder)
        let store = try makeStore(rootURL: makeTempDirectory())

        let report = try await ingestor.ingest(into: store)
        #expect(report.discovered == 2, "both paths are still listed as candidates")
        #expect(report.imported == 1, "but the library only actually grew by one item")

        let items = try await store.allItems()
        #expect(items.count == 1)

        // The property that actually matters: because the un-landed path's
        // `sourceId` was never persisted (its `add` call returned the
        // existing item rather than storing a new one), it's still "unknown"
        // by path on the next scan — yet re-importing it must still be a
        // no-op, not a second item.
        #expect(try await ingestor.ingest(into: store).imported == 0)
    }
}
