import Foundation
import Testing
@testable import FitViewCore

/// A fresh temp directory per call so stores/folders never see each other's
/// state — mirrors `FileSystemLibraryStoreTests`'s `makeTempRoot()`.
private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    // Bookmark creation (`setFolder`) requires the target to already exist —
    // true of anything the real document picker could ever return, but a
    // fresh temp URL isn't a directory until something creates it.
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeCandidate(
    suggestedName: String = "2026-07-23_pace4_run",
    startTime: Date? = nil,
    deviceLabel: String? = nil,
    sport: String? = nil
) -> ImportCandidate {
    ImportCandidate(
        sourceId: suggestedName, suggestedName: suggestedName, startTime: startTime,
        deviceLabel: deviceLabel, sport: sport
    )
}

/// `FolderSyncStore` is tested only against a plain temp directory — there is
/// no way to drive real iCloud Drive materialisation from CI. `setFolder`
/// works identically against any directory URL; the ubiquitous-item
/// materialisation path (`ensureMaterialized`) is a documented no-op for a
/// non-ubiquitous file, which a plain temp directory always is, so these
/// tests exercise the merge policy exhaustively without exercising that path
/// at all — real iCloud Drive round-tripping needs manual verification.
@Suite("FolderSyncStore")
struct FolderSyncStoreTests {
    private func makeSyncStore() async -> FolderSyncStore {
        let suiteName = "FolderSyncStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return FolderSyncStore(defaults: defaults)
    }

    @Test("a fresh store isn't configured until a folder is set")
    func isConfiguredTracksSetFolder() async throws {
        let sync = await makeSyncStore()
        #expect(sync.isConfigured == false)
        try await sync.setFolder(makeTempDirectory())
        #expect(sync.isConfigured == true)
    }

    @Test("push/pull before a folder is set reports notConfigured")
    func operationsBeforeConfigurationThrow() async throws {
        let sync = await makeSyncStore()
        let local = try FileSystemLibraryStore(rootURL: makeTempDirectory())
        await #expect(throws: FolderSyncError.notConfigured) {
            _ = try await sync.push(local)
        }
        await #expect(throws: FolderSyncError.notConfigured) {
            _ = try await sync.pull(into: local)
        }
    }

    @Test("push then pull into a second local store round-trips an item and its bytes")
    func pushThenPullRoundTrips() async throws {
        let sync = await makeSyncStore()
        try await sync.setFolder(makeTempDirectory())

        let local = try FileSystemLibraryStore(rootURL: makeTempDirectory())
        let added = try await local.add(ImportedActivity(
            candidate: makeCandidate(), data: Data("hello fit bytes".utf8), source: "files"
        ))

        let pushReport = try await sync.push(local)
        #expect(pushReport.itemsCopied == 1)
        #expect(pushReport.blobsCopied == 1)

        let otherLocal = try FileSystemLibraryStore(rootURL: makeTempDirectory())
        let pullReport = try await sync.pull(into: otherLocal)
        #expect(pullReport.itemsCopied == 1)
        #expect(pullReport.blobsCopied == 1)

        let items = try await otherLocal.allItems()
        #expect(items.count == 1)
        #expect(items.first?.id == added.id, "the item's identity must survive the round trip unchanged")
        #expect(items.first?.date == added.date)
        #expect(items.first?.device == added.device)

        let data = try await otherLocal.data(for: added.id)
        #expect(data == Data("hello fit bytes".utf8))
    }

    @Test("pushing twice never duplicates items on the remote (union-by-id)")
    func pushIsIdempotent() async throws {
        let sync = await makeSyncStore()
        let remoteFolder = makeTempDirectory()
        try await sync.setFolder(remoteFolder)

        let local = try FileSystemLibraryStore(rootURL: makeTempDirectory())
        _ = try await local.add(ImportedActivity(candidate: makeCandidate(), data: Data([1, 2, 3]), source: "files"))

        let first = try await sync.push(local)
        #expect(first.itemsCopied == 1)

        let second = try await sync.push(local)
        #expect(second.itemsCopied == 0, "the same item id must not be appended twice")

        let manifestData = try Data(contentsOf: remoteFolder.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct Manifest: Codable { var items: [LibraryItem] }
        let manifest = try decoder.decode(Manifest.self, from: manifestData)
        #expect(manifest.items.count == 1)
    }

    @Test("identical bytes across two items collapse onto one remote blob (copy-if-absent)")
    func blobsAreContentAddressedOnPush() async throws {
        let sync = await makeSyncStore()
        let remoteFolder = makeTempDirectory()
        try await sync.setFolder(remoteFolder)

        let local = try FileSystemLibraryStore(rootURL: makeTempDirectory())
        let sharedBytes = Data("identical".utf8)
        _ = try await local.add(ImportedActivity(
            candidate: makeCandidate(suggestedName: "2026-07-23_pace4_run"), data: sharedBytes, source: "files"
        ))
        _ = try await local.add(ImportedActivity(
            candidate: makeCandidate(suggestedName: "2026-07-24_pace4_run"), data: sharedBytes, source: "files"
        ))

        let report = try await sync.push(local)
        #expect(report.itemsCopied == 2)
        #expect(report.blobsCopied == 1, "two items with identical bytes must write only one blob")

        let blobFiles = try FileManager.default.contentsOfDirectory(
            at: remoteFolder.appendingPathComponent("blobs"), includingPropertiesForKeys: nil
        )
        #expect(blobFiles.count == 1)
    }

    @Test("pulling twice never duplicates items locally, and only fetches genuinely new ones")
    func pullIsIdempotent() async throws {
        let sync = await makeSyncStore()
        try await sync.setFolder(makeTempDirectory())

        let pusher = try FileSystemLibraryStore(rootURL: makeTempDirectory())
        _ = try await pusher.add(ImportedActivity(candidate: makeCandidate(), data: Data([9, 9]), source: "files"))
        try await sync.push(pusher)

        let puller = try FileSystemLibraryStore(rootURL: makeTempDirectory())
        let first = try await sync.pull(into: puller)
        #expect(first.itemsCopied == 1)

        let second = try await sync.pull(into: puller)
        #expect(second.itemsCopied == 0, "an already-pulled item must not be re-added")

        let items = try await puller.allItems()
        #expect(items.count == 1)
    }

    @Test("device aliases merge last-writer-wins per key: pulling overwrites shared keys with the remote's value")
    func aliasesMergeOnPull() async throws {
        let sync = await makeSyncStore()
        try await sync.setFolder(makeTempDirectory())

        let pusher = try FileSystemLibraryStore(rootURL: makeTempDirectory())
        try await pusher.updateDeviceAlias(deviceKey: "polarvantagev2", label: "polarSense")
        try await pusher.updateDeviceAlias(deviceKey: "remote-only-key", label: "Remote Only")
        try await sync.push(pusher)

        let puller = try FileSystemLibraryStore(rootURL: makeTempDirectory())
        try await puller.updateDeviceAlias(deviceKey: "polarvantagev2", label: "a local guess, should be overwritten")
        try await puller.updateDeviceAlias(deviceKey: "local-only-key", label: "Local Only")

        let report = try await sync.pull(into: puller)
        #expect(report.aliasesMerged == 2, "one shared, differing key plus one remote-only key")

        let merged = try await puller.deviceAliases()
        #expect(merged["polarvantagev2"] == "polarSense", "the remote's value must win the shared key on a pull")
        #expect(merged["remote-only-key"] == "Remote Only", "a remote-only key must be adopted")
        #expect(merged["local-only-key"] == "Local Only", "a local-only key the remote never mentioned must survive")
    }

    @Test("device aliases merge last-writer-wins per key: pushing overwrites shared keys with the local's value")
    func aliasesMergeOnPush() async throws {
        let sync = await makeSyncStore()
        let remoteFolder = makeTempDirectory()
        try await sync.setFolder(remoteFolder)

        let seeder = try FileSystemLibraryStore(rootURL: makeTempDirectory())
        try await seeder.updateDeviceAlias(deviceKey: "polarvantagev2", label: "a stale remote value")
        try await sync.push(seeder)

        let pusher = try FileSystemLibraryStore(rootURL: makeTempDirectory())
        try await pusher.updateDeviceAlias(deviceKey: "polarvantagev2", label: "polarSense")
        let report = try await sync.push(pusher)
        #expect(report.aliasesMerged == 1)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct Manifest: Codable { var deviceAliases: [String: String] }
        let manifestData = try Data(contentsOf: remoteFolder.appendingPathComponent("manifest.json"))
        let manifest = try decoder.decode(Manifest.self, from: manifestData)
        #expect(manifest.deviceAliases["polarvantagev2"] == "polarSense")
    }

    @Test("pulling from a never-pushed-to folder is an empty, successful no-op")
    func pullFromEmptyFolderIsANoOp() async throws {
        let sync = await makeSyncStore()
        try await sync.setFolder(makeTempDirectory())
        let local = try FileSystemLibraryStore(rootURL: makeTempDirectory())

        let report = try await sync.pull(into: local)
        #expect(report == SyncReport())
        #expect(try await local.allItems().isEmpty)
    }
}
