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

/// Writes a `LibraryItem` directly into a store, bypassing the import
/// pipeline entirely — reconciliation's eligibility rule (contract C2) turns
/// on `source`/`sourceId` values that don't necessarily come from a real
/// scan (a legacy item with no `sourceId`, a bundled sample, a share-sheet
/// import), so these tests need to construct items with those fields set
/// directly rather than only ever through `FolderIngestor.ingest`.
@discardableResult
private func addItem(
    to store: FileSystemLibraryStore,
    source: String,
    sourceId: String?,
    fileName: String = "2026-07-23_pace4_run.fit"
) async throws -> LibraryItem {
    let data = try realFitData()
    let item = LibraryItem(
        id: UUID().uuidString,
        blobId: "placeholder", // recomputed by addRawItem from the real data
        date: "2026-07-23",
        device: "pace4",
        deviceKey: "pace4",
        activity: "run",
        activityKey: "run",
        source: source,
        sourceId: sourceId,
        originalName: fileName,
        importedAt: Date()
    )
    try await store.addRawItem(item, data: data)
    return item
}

/// Wraps a real store and injects a `remove(itemId:)` failure for chosen
/// item ids. `FileSystemLibraryStore.remove` is, by contract, infallible
/// against its own manifest (it's `removeAll { $0.id == itemId }`), so this
/// is the only way to exercise reconciliation's "one removal throws mid-pass"
/// rule (contract C5) without corrupting real on-disk state to force a
/// genuine I/O error.
private actor FailingRemovalStore: LibraryStore {
    let wrapped: FileSystemLibraryStore
    let itemIdsToFail: Set<String>

    init(wrapping store: FileSystemLibraryStore, failingToRemove itemIdsToFail: Set<String>) {
        self.wrapped = store
        self.itemIdsToFail = itemIdsToFail
    }

    func allItems() async throws -> [LibraryItem] { try await wrapped.allItems() }
    func data(for itemId: String) async throws -> Data { try await wrapped.data(for: itemId) }
    func data(for itemIds: [String]) async throws -> [String: Data] { try await wrapped.data(for: itemIds) }
    func deviceAliases() async throws -> [String: String] { try await wrapped.deviceAliases() }
    func addRawItem(_ item: LibraryItem, data: Data) async throws { try await wrapped.addRawItem(item, data: data) }
    func updateDeviceAlias(deviceKey: String, label: String) async throws {
        try await wrapped.updateDeviceAlias(deviceKey: deviceKey, label: label)
    }

    @discardableResult
    func add(_ activity: ImportedActivity) async throws -> LibraryItem { try await wrapped.add(activity) }

    func remove(itemId: String) async throws {
        if itemIdsToFail.contains(itemId) {
            throw LibraryStoreError.corruptManifest(underlying: "simulated removal failure")
        }
        try await wrapped.remove(itemId: itemId)
    }
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

    // MARK: - Reconciliation (FR-009–FR-012)

    @Test("a file removed from the folder is removed from the library on the next scan")
    func fileRemovedFromFolderIsReconciled() async throws {
        let folder = makeTempDirectory()
        let filePath = folder.appendingPathComponent("2026-07-23_pace4_run.fit")
        try placeFitFile(named: "2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")

        let ingestor = try await makeIngestor(watching: folder)
        let store = try makeStore(rootURL: makeTempDirectory())
        #expect(try await ingestor.ingest(into: store).imported == 1)

        try FileManager.default.removeItem(at: filePath)

        let report = try await ingestor.ingest(into: store)
        #expect(report.removed == 1)
        #expect(report.imported == 0)
        #expect(try await store.allItems().isEmpty)
    }

    @Test("an item deleted from the store while its file is still in the folder is re-imported, not left gone")
    func stillPresentFileIsReimportedAfterInAppDeletion() async throws {
        let folder = makeTempDirectory()
        try placeFitFile(named: "2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")

        let ingestor = try await makeIngestor(watching: folder)
        let store = try makeStore(rootURL: makeTempDirectory())
        #expect(try await ingestor.ingest(into: store).imported == 1)

        let itemId = try #require(try await store.allItems().first?.id)
        try await store.remove(itemId: itemId)
        #expect(try await store.allItems().isEmpty)

        let report = try await ingestor.ingest(into: store)
        #expect(report.imported == 1, "the folder is the source of truth (FR-008) — the file is still there")
        #expect(report.removed == 0)
        #expect(try await store.allItems().count == 1)
    }

    @Test("a scan that can't read the folder removes nothing and imports nothing")
    func untrustworthyListingRemovesNothing() async throws {
        let defaults = UserDefaults(suiteName: "FolderIngestorTests.\(UUID().uuidString)")!
        let ingestor = FolderIngestor(source: WatchedFolderSource(defaults: defaults))
        let store = try makeStore(rootURL: makeTempDirectory())
        try await addItem(to: store, source: "folder", sourceId: "gone.fit")

        await #expect(throws: ActivitySourceError.self) {
            _ = try await ingestor.ingest(into: store)
        }
        #expect(try await store.allItems().count == 1, "an unconfigured (unreadable) folder must not remove anything")
    }

    @Test("a directory replaced by a regular file throws instead of reconciling away everything in it")
    func unenumerableFolderDoesNotReconcile() async throws {
        let folder = makeTempDirectory()
        try placeFitFile(named: "2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")

        let ingestor = try await makeIngestor(watching: folder)
        let store = try makeStore(rootURL: makeTempDirectory())
        #expect(try await ingestor.ingest(into: store).imported == 1)

        // Replace the watched folder itself with a regular file. At this
        // full-pipeline level the throw is actually produced by bookmark
        // resolution noticing the resource's type changed
        // (`FolderBookmark.resolve()`, via `URL(resolvingBookmarkData:...)`)
        // rather than by `coordinatedContents`'s own guard — confirmed by
        // deliberately reverting that guard and re-running this test, which
        // still passed. `FileCoordinationTests` is the precise regression
        // test for the `coordinatedContents` fix itself, calling it directly
        // and bypassing bookmark resolution entirely. This test still earns
        // its place: it's the end-to-end proof that an unenumerable watched
        // folder never reconciles anything away, regardless of which layer
        // catches it.
        try FileManager.default.removeItem(at: folder)
        try Data("not a directory".utf8).write(to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        await #expect(throws: (any Error).self) {
            _ = try await ingestor.ingest(into: store)
        }
        #expect(try await store.allItems().count == 1, "an unenumerable folder must not remove anything")
    }

    @Test("a folder emptied of every file removes every folder-sourced item")
    func emptiedFolderRemovesAllFolderItems() async throws {
        let folder = makeTempDirectory()
        try placeFitFile(named: "2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")
        try placeFitFile(named: "2026-07-24_pace4_run.fit", in: folder, from: "2026-07-24_pace4_run.fit")

        let ingestor = try await makeIngestor(watching: folder)
        let store = try makeStore(rootURL: makeTempDirectory())
        #expect(try await ingestor.ingest(into: store).imported == 2)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("2026-07-23_pace4_run.fit"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("2026-07-24_pace4_run.fit"))

        let report = try await ingestor.ingest(into: store)
        #expect(report.removed == 2)
        #expect(try await store.allItems().isEmpty)
    }

    @Test("non-folder items are left untouched by reconciliation even when the folder is empty")
    func nonFolderItemsAreNeverReconciled() async throws {
        let store = try makeStore(rootURL: makeTempDirectory())
        try await addItem(to: store, source: "bundled", sourceId: nil)
        try await addItem(to: store, source: "files", sourceId: "shared.fit")

        let ingestor = try await makeIngestor(watching: makeTempDirectory())
        let report = try await ingestor.ingest(into: store)

        #expect(report.removed == 0)
        #expect(try await store.allItems().count == 2, "FR-011 — only the folder's own items are reconcilable")
    }

    @Test("a folder item with no sourceId is left untouched — it can never be matched against the folder")
    func legacyItemWithNoSourceIdIsNeverReconciled() async throws {
        let store = try makeStore(rootURL: makeTempDirectory())
        try await addItem(to: store, source: "folder", sourceId: nil)

        let ingestor = try await makeIngestor(watching: makeTempDirectory())
        let report = try await ingestor.ingest(into: store)

        #expect(report.removed == 0)
        #expect(try await store.allItems().count == 1, "a nil sourceId must never be inferred as missing from the folder")
    }

    @Test("one removal throwing does not stop the rest of the pass")
    func oneFailedRemovalDoesNotBlockTheRest() async throws {
        let folder = makeTempDirectory()
        try placeFitFile(named: "2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")

        let source = WatchedFolderSource(defaults: UserDefaults(suiteName: "FolderIngestorTests.\(UUID().uuidString)")!)
        try await source.setFolder(folder)
        let realStore = try makeStore(rootURL: makeTempDirectory())
        let ingestor = FolderIngestor(source: source)
        #expect(try await ingestor.ingest(into: realStore).imported == 1)
        let survivingId = try #require(try await realStore.allItems().first?.id)

        // A second item, whose file is also gone, but whose removal will be
        // forced to throw — the pass must still remove the other stale item.
        let failingItem = try await addItem(to: realStore, source: "folder", sourceId: "gone.fit", fileName: "gone.fit")
        let wrapped = FailingRemovalStore(wrapping: realStore, failingToRemove: [failingItem.id])

        try FileManager.default.removeItem(at: folder.appendingPathComponent("2026-07-23_pace4_run.fit"))
        let report = try await ingestor.ingest(into: wrapped)

        #expect(report.removed == 1, "the item whose removal succeeded is still counted")
        let remainingIds = try await realStore.allItems().map(\.id)
        #expect(remainingIds == [failingItem.id], "the item whose removal threw stays in the library")
        #expect(!remainingIds.contains(survivingId), "the item whose removal succeeded is actually gone")
    }

    @Test("a scan that removes 2 and imports 2 reports both counts correctly")
    func removedAndImportedCountsAreBothTruthfulInOnePass() async throws {
        let folder = makeTempDirectory()
        try placeFitFile(named: "2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")
        try placeFitFile(named: "2026-07-24_pace4_run.fit", in: folder, from: "2026-07-24_pace4_run.fit")

        let ingestor = try await makeIngestor(watching: folder)
        let store = try makeStore(rootURL: makeTempDirectory())
        #expect(try await ingestor.ingest(into: store).imported == 2)

        // Swap the folder's contents: remove both existing files, add two new ones.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("2026-07-23_pace4_run.fit"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("2026-07-24_pace4_run.fit"))
        try placeFitFile(named: "2026-07-25_pace4_run.fit", in: folder, from: "2026-07-25_pace4_run.fit")
        try placeFitFile(named: "2026-07-27_pace4_run.fit", in: folder, from: "2026-07-27_pace4_run.fit")

        let report = try await ingestor.ingest(into: store)
        #expect(report.removed == 2)
        #expect(report.imported == 2)
        #expect(try await store.allItems().count == 2)
    }

    @Test("a scan that only removed items still reports didChangeLibrary — the batch must be reloaded")
    func removalOnlyScanStillReportsChangedLibrary() async throws {
        let folder = makeTempDirectory()
        try placeFitFile(named: "2026-07-23_pace4_run.fit", in: folder, from: "2026-07-23_pace4_run.fit")

        let ingestor = try await makeIngestor(watching: folder)
        let store = try makeStore(rootURL: makeTempDirectory())
        #expect(try await ingestor.ingest(into: store).imported == 1)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("2026-07-23_pace4_run.fit"))

        let report = try await ingestor.ingest(into: store)
        #expect(report.imported == 0)
        #expect(report.removed == 1)
        #expect(report.didChangeLibrary, "a removal-only scan must still be reported as a library change")
    }
}
