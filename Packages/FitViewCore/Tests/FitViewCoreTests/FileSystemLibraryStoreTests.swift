import Foundation
import Testing
@testable import FitViewCore

/// Real `.fit`-shaped bytes aren't needed here — `LibraryStore` never decodes
/// what it stores (see its "no decoded-record cache" doc comment), so plain
/// bytes distinguishable by content are enough to exercise content
/// addressing, manifest persistence, and alias resolution.
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

/// A fresh temp directory per test so stores never see each other's state.
private func makeTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return root
}

@Suite("FileSystemLibraryStore")
struct FileSystemLibraryStoreTests {
    @Test("add/list/remove a round trip")
    func addListRemoveRoundTrip() async throws {
        let store = try FileSystemLibraryStore(rootURL: makeTempRoot())

        let added = try await store.add(ImportedActivity(
            candidate: makeCandidate(), data: Data("fake fit bytes".utf8), source: "files"
        ))
        #expect(added.date == "2026-07-23")
        #expect(added.device == "pace4")
        #expect(added.deviceKey == "pace4")
        #expect(added.activity == "run")
        #expect(added.source == "files")
        #expect(added.originalName == "2026-07-23_pace4_run")

        let items = try await store.allItems()
        #expect(items.count == 1)
        #expect(items.first?.id == added.id)

        let data = try await store.data(for: added.id)
        #expect(data == Data("fake fit bytes".utf8))

        try await store.remove(itemId: added.id)
        let afterRemove = try await store.allItems()
        #expect(afterRemove.isEmpty)
    }

    @Test("fetching a removed (or never-added) item's data reports itemNotFound, not a crash")
    func dataForMissingItemThrows() async throws {
        let store = try FileSystemLibraryStore(rootURL: makeTempRoot())
        await #expect(throws: LibraryStoreError.itemNotFound(itemId: "nonexistent")) {
            _ = try await store.data(for: "nonexistent")
        }
    }

    @Test("identical bytes imported twice collapse onto one blob")
    func duplicateBytesCollapseOntoOneBlob() async throws {
        let root = try makeTempRoot()
        let store = try FileSystemLibraryStore(rootURL: root)
        let bytes = Data("identical content".utf8)

        let first = try await store.add(ImportedActivity(
            candidate: makeCandidate(suggestedName: "2026-07-23_pace4_run"), data: bytes, source: "files"
        ))
        let second = try await store.add(ImportedActivity(
            candidate: makeCandidate(suggestedName: "2026-07-24_pace4_run"), data: bytes, source: "files"
        ))

        #expect(first.blobId == second.blobId, "identical bytes must hash to the same blob id")
        #expect(first.id != second.id, "each import is still its own library item")

        let items = try await store.allItems()
        #expect(items.count == 2, "two manifest entries...")

        let blobFiles = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("blobs"), includingPropertiesForKeys: nil
        )
        #expect(blobFiles.count == 1, "...but only one physical blob on disk")
    }

    @Test("the manifest survives a relaunch — a fresh store instance over the same root sees prior items")
    func manifestPersistsAcrossStoreInstances() async throws {
        let root = try makeTempRoot()
        let added: LibraryItem
        do {
            let store = try FileSystemLibraryStore(rootURL: root)
            added = try await store.add(ImportedActivity(candidate: makeCandidate(), data: Data([1, 2, 3]), source: "bundled"))
        }

        let reopened = try FileSystemLibraryStore(rootURL: root)
        let items = try await reopened.allItems()
        #expect(items.count == 1)
        #expect(items.first?.id == added.id)
        #expect(items.first?.blobId == added.blobId)
        #expect(items.first?.date == added.date)
        #expect(items.first?.device == added.device)
        // `manifest.json` round-trips dates through ISO-8601, which is
        // whole-second precision — comparing exactly would be comparing an
        // encoding artifact, not a real regression.
        #expect(abs((items.first?.importedAt ?? .distantPast).timeIntervalSince(added.importedAt)) < 1)
    }

    @Test("a corrupt manifest.json is reported, not silently treated as an empty library")
    func corruptManifestIsReported() async throws {
        let root = try makeTempRoot()
        let store = try FileSystemLibraryStore(rootURL: root)
        _ = try await store.add(ImportedActivity(candidate: makeCandidate(), data: Data([1]), source: "files"))

        try Data("{ not valid json".utf8).write(to: root.appendingPathComponent("manifest.json"))

        await #expect(throws: (any Error).self) {
            _ = try await store.allItems()
        }
    }

    @Test("a device alias reconciles a raw device key onto a new label and grouping key")
    func deviceAliasReconcilesIdentity() async throws {
        let store = try FileSystemLibraryStore(rootURL: makeTempRoot())
        let added = try await store.add(ImportedActivity(
            candidate: makeCandidate(
                suggestedName: "irrelevant",
                startTime: Date(timeIntervalSince1970: 1_785_110_812), // 2026-07-27T00:06:52Z
                deviceLabel: "Polar Vantage V2",
                sport: "running"
            ),
            data: Data([9]),
            source: "polar"
        ))
        #expect(added.deviceKey == "polarvantagev2")

        try await store.updateDeviceAlias(deviceKey: "polarvantagev2", label: "polarSense")

        let items = try await store.allItems()
        #expect(items.first?.device == "polarSense")
        #expect(items.first?.deviceKey == "polarsense")

        let refetched = try await store.data(for: added.id)
        #expect(refetched == Data([9]), "aliasing changes identity, never the stored bytes")
    }

    @Test("an API-sourced candidate with real startTime is dated/keyed from that metadata, not a synthesized name")
    func apiSourcedCandidateUsesRealMetadata() async throws {
        let store = try FileSystemLibraryStore(rootURL: makeTempRoot())
        // 2026-07-27T00:06:52Z, matching PolarAccessLinkModelsTests's offset example.
        let startTime = Date(timeIntervalSince1970: 1_785_110_812)

        let added = try await store.add(ImportedActivity(
            candidate: makeCandidate(
                suggestedName: "shouldnt-be-parsed-2026-07-27_polarvantagev2_running",
                startTime: startTime, deviceLabel: "Polar Vantage V2", sport: "RUNNING"
            ),
            data: Data([1]),
            source: "polar"
        ))

        #expect(added.date == "2026-07-27")
        #expect(added.device == "Polar Vantage V2")
        #expect(added.deviceKey == "polarvantagev2")
        #expect(added.activity == "running")
        #expect(added.sport == "RUNNING")
        #expect(added.startTime == startTime)
    }

    @Test("a file-backed candidate with no startTime falls back to parsing suggestedName")
    func fileBackedCandidateParsesSuggestedName() async throws {
        let store = try FileSystemLibraryStore(rootURL: makeTempRoot())
        let added = try await store.add(ImportedActivity(
            candidate: makeCandidate(suggestedName: "2026-07-26-pace4_run"), data: Data([1]), source: "bundled"
        ))

        #expect(added.date == "2026-07-26")
        #expect(added.device == "pace4")
        #expect(added.activity == "run")
    }
}
