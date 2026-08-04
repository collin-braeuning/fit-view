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

/// A store over a fresh, isolated `DeviceNicknameStore` — every test gets its
/// own nickname table (a fresh `UserDefaults` suite) unless it explicitly
/// wants to share one, same reasoning `RemoteActivitySyncTests`' helpers
/// already follow for `RemoteSyncIdStore`.
private func makeStore(rootURL: URL) throws -> FileSystemLibraryStore {
    try FileSystemLibraryStore(
        rootURL: rootURL,
        nicknames: DeviceNicknameStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    )
}

@Suite("FileSystemLibraryStore")
struct FileSystemLibraryStoreTests {
    @Test("add/list/remove a round trip")
    func addListRemoveRoundTrip() async throws {
        let store = try makeStore(rootURL: makeTempRoot())

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
        let store = try makeStore(rootURL: makeTempRoot())
        await #expect(throws: LibraryStoreError.itemNotFound(itemId: "nonexistent")) {
            _ = try await store.data(for: "nonexistent")
        }
    }

    @Test("bulk data(for:) returns every item's bytes keyed by id, same as fetching each one individually")
    func bulkDataFetchMatchesPerItemFetch() async throws {
        let store = try makeStore(rootURL: makeTempRoot())
        let first = try await store.add(ImportedActivity(
            candidate: makeCandidate(suggestedName: "2026-07-23_pace4_run"), data: Data("first".utf8), source: "files"
        ))
        let second = try await store.add(ImportedActivity(
            candidate: makeCandidate(suggestedName: "2026-07-25_polarSense_run"), data: Data("second".utf8), source: "files"
        ))

        let byId = try await store.data(for: [first.id, second.id])

        #expect(byId[first.id] == Data("first".utf8))
        #expect(byId[second.id] == Data("second".utf8))
    }

    @Test("bulk data(for:) reports itemNotFound if any requested id is stale, same as the single-item form")
    func bulkDataFetchThrowsOnAnyMissingId() async throws {
        let store = try makeStore(rootURL: makeTempRoot())
        let added = try await store.add(ImportedActivity(
            candidate: makeCandidate(), data: Data("fake fit bytes".utf8), source: "files"
        ))

        await #expect(throws: LibraryStoreError.itemNotFound(itemId: "nonexistent")) {
            _ = try await store.data(for: [added.id, "nonexistent"])
        }
    }

    @Test("identical bytes imported twice collapse onto one blob")
    func duplicateBytesCollapseOntoOneBlob() async throws {
        let root = try makeTempRoot()
        let store = try makeStore(rootURL: root)
        let bytes = Data("identical content".utf8)

        let first = try await store.add(ImportedActivity(
            candidate: makeCandidate(suggestedName: "2026-07-23_pace4_run"), data: bytes, source: "files"
        ))
        let second = try await store.add(ImportedActivity(
            candidate: makeCandidate(suggestedName: "2026-07-24_pace4_run"), data: bytes, source: "files"
        ))

        #expect(first.blobId == second.blobId, "identical bytes must hash to the same blob id")
        // The descriptor half of the dedupe rule: same content, but a
        // different date (from the different suggestedName) means these are
        // two genuinely distinct activities that happen to share bytes, so
        // both must land as separate items.
        #expect(first.id != second.id, "each import is still its own library item")

        let items = try await store.allItems()
        #expect(items.count == 2, "two manifest entries...")

        let blobFiles = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("blobs"), includingPropertiesForKeys: nil
        )
        #expect(blobFiles.count == 1, "...but only one physical blob on disk")
    }

    @Test("adding the identical activity twice is a no-op: one item, and the id is stable")
    func addingIdenticalActivityTwiceIsANoOp() async throws {
        let store = try makeStore(rootURL: makeTempRoot())
        let activity = ImportedActivity(
            candidate: makeCandidate(suggestedName: "2026-07-23_pace4_run"), data: Data("same bytes".utf8), source: "files"
        )

        let first = try await store.add(activity)
        let second = try await store.add(activity)

        // Same blobId *and* same (date, deviceKey, activityKey) descriptor
        // triple: `add` must recognise this as the activity already on file
        // and hand back the existing item rather than appending a new one.
        #expect(second.id == first.id, "a re-import of the same activity must return the existing item's id")

        let items = try await store.allItems()
        #expect(items.count == 1, "the second add must not append a second manifest entry")
    }

    @Test("the same descriptor with different bytes still produces two items — the content half of the rule")
    func sameDescriptorDifferentBytesProducesTwoItems() async throws {
        let store = try makeStore(rootURL: makeTempRoot())
        let candidate = makeCandidate(suggestedName: "2026-07-23_pace4_run")

        let first = try await store.add(ImportedActivity(candidate: candidate, data: Data("bytes one".utf8), source: "files"))
        let second = try await store.add(ImportedActivity(candidate: candidate, data: Data("bytes two".utf8), source: "files"))

        // Same date/deviceKey/activityKey, but different content hashes to a
        // different blobId — matching descriptor alone must never collapse
        // two genuinely different files into one item.
        #expect(first.blobId != second.blobId)
        #expect(first.id != second.id)

        let items = try await store.allItems()
        #expect(items.count == 2)
    }

    @Test("the manifest survives a relaunch — a fresh store instance over the same root sees prior items")
    func manifestPersistsAcrossStoreInstances() async throws {
        let root = try makeTempRoot()
        let added: LibraryItem
        do {
            let store = try makeStore(rootURL: root)
            added = try await store.add(ImportedActivity(candidate: makeCandidate(), data: Data([1, 2, 3]), source: "bundled"))
        }

        let reopened = try makeStore(rootURL: root)
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
        let store = try makeStore(rootURL: root)
        _ = try await store.add(ImportedActivity(candidate: makeCandidate(), data: Data([1]), source: "files"))

        try Data("{ not valid json".utf8).write(to: root.appendingPathComponent("manifest.json"))

        await #expect(throws: (any Error).self) {
            _ = try await store.allItems()
        }
    }

    @Test("a device alias reconciles a raw device key onto a new label and grouping key")
    func deviceAliasReconcilesIdentity() async throws {
        let store = try makeStore(rootURL: makeTempRoot())
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

    @Test("renaming an already-aliased device (a second hop) carries every device already merged into it along")
    func multiHopRenameCarriesPreviouslyMergedDevicesAlong() async throws {
        let store = try makeStore(rootURL: makeTempRoot())
        _ = try await store.add(ImportedActivity(
            candidate: makeCandidate(
                suggestedName: "irrelevant",
                startTime: Date(timeIntervalSince1970: 1_785_110_812),
                deviceLabel: "Polar Vantage V2",
                sport: "running"
            ),
            data: Data([9]),
            source: "polar"
        ))
        try await store.updateDeviceAlias(deviceKey: "polarvantagev2", label: "polarSense")

        // The "already-aliased device" rename this is the fix for: renaming
        // the *target* of an existing alias, not the original raw key.
        try await store.updateDeviceAlias(deviceKey: "polarsense", label: "Reference HR")

        let items = try await store.allItems()
        #expect(items.first?.device == "Reference HR", "the second hop must carry the first-hop device along, not strand it at the intermediate label")
        #expect(items.first?.deviceKey == "referencehr")
    }

    @Test("a device alias created against one deviceKey spelling still resolves an item whose deviceKey diverged on whitespace")
    func aliasReconcilesDivergentDeviceKeySpellings() async throws {
        // `parseActivityFileName` (used for file-backed candidates — every
        // folder-imported file, including Polar's auto-synced ones) keys
        // off `device.lowercased()` with no space-stripping, while
        // `activityDescriptorFields`'s API-sourced branch strips spaces
        // first. The same physical device can therefore end up stored under
        // two different raw `deviceKey`s depending on which import path
        // produced it — resolution must reconcile them via `item.device`
        // regardless.
        let store = try makeStore(rootURL: makeTempRoot())
        let added = try await store.add(ImportedActivity(
            candidate: makeCandidate(suggestedName: "2026-08-03_Polar Verity Sense_generic"),
            data: Data([1]),
            source: "folder"
        ))
        #expect(added.device == "Polar Verity Sense")
        #expect(added.deviceKey == "polar verity sense", "parseActivityFileName never strips spaces")

        // Aliased using the space-stripped spelling an API-sourced item
        // would have produced instead.
        try await store.updateDeviceAlias(deviceKey: "polarveritysense", label: "polarSense")

        let items = try await store.allItems()
        #expect(items.first?.device == "polarSense")
        #expect(items.first?.deviceKey == "polarsense")
    }

    @Test("an API-sourced candidate with real startTime is dated/keyed from that metadata, not a synthesized name")
    func apiSourcedCandidateUsesRealMetadata() async throws {
        let store = try makeStore(rootURL: makeTempRoot())
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
        let store = try makeStore(rootURL: makeTempRoot())
        let added = try await store.add(ImportedActivity(
            candidate: makeCandidate(suggestedName: "2026-07-26-pace4_run"), data: Data([1]), source: "bundled"
        ))

        #expect(added.date == "2026-07-26")
        #expect(added.device == "pace4")
        #expect(added.activity == "run")
    }

    /// Locates a bundled sample `.fit` file on disk — see
    /// `SharedActivityMetadataTests.sampleData`, duplicated here rather than
    /// shared because it's a five-line private helper and the two files
    /// aren't otherwise coupled.
    private func sampleData(_ fileName: String) throws -> Data {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // FitViewCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // FitViewCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
        let sampleURL = repoRoot
            .appendingPathComponent("Sources/FitView/Resources/SampleData")
            .appendingPathComponent(fileName)
        return try Data(contentsOf: sampleURL)
    }

    @Test("real FIT bytes are trusted over a misleading suggestedName — decoded content wins")
    func decodedContentOverridesAWrongFilename() async throws {
        let store = try makeStore(rootURL: makeTempRoot())
        let data = try sampleData("2026-07-24_pace4_run.fit")

        let added = try await store.add(ImportedActivity(
            candidate: makeCandidate(suggestedName: "2020-01-01_notarealdevice_notarealsport"),
            data: data,
            source: "folder"
        ))

        #expect(added.date == "2026-07-24", "the filename's 2020-01-01 must lose to the decoded date")
        #expect(added.device == "COROS PACE 4", "the filename's device token must lose to device_info/file_id")
        #expect(added.activity != "notarealsport")
        #expect(added.startTime != nil)
        #expect(added.endTime != nil)
    }

    @Test("add records the candidate's sourceId, so a re-scan can recognise what it already imported")
    func addRecordsSourceId() async throws {
        let store = try makeStore(rootURL: makeTempRoot())
        let added = try await store.add(ImportedActivity(
            candidate: ImportCandidate(
                sourceId: "nested/2026-07-23_pace4_run.fit", suggestedName: "2026-07-23_pace4_run"
            ),
            data: Data([1]),
            source: "folder"
        ))

        #expect(added.sourceId == "nested/2026-07-23_pace4_run.fit")
        let listed = try await store.allItems()
        #expect(listed.first?.sourceId == "nested/2026-07-23_pace4_run.fit", "it must survive a manifest round trip")
    }

    @Test("a manifest written before sourceId existed still decodes, with sourceId nil")
    func manifestWithoutSourceIdStillDecodes() async throws {
        // Guards every library already on disk, and every remote sync mirror
        // another device may have written — losing the whole index over one
        // added field would be a far bigger surprise than any it could fix.
        let root = try makeTempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyManifest = """
        {
          "deviceAliases" : {},
          "items" : [
            {
              "activity" : "run",
              "activityKey" : "run",
              "blobId" : "abc123",
              "date" : "2026-07-23",
              "device" : "pace4",
              "deviceKey" : "pace4",
              "id" : "11111111-2222-3333-4444-555555555555",
              "importedAt" : "2026-07-23T10:00:00Z",
              "originalName" : "2026-07-23_pace4_run",
              "source" : "bundled"
            }
          ]
        }
        """
        try Data(legacyManifest.utf8).write(to: root.appendingPathComponent("manifest.json"))

        let store = try makeStore(rootURL: root)
        let items = try await store.allItems()
        #expect(items.count == 1)
        #expect(items.first?.sourceId == nil)
        #expect(items.first?.originalName == "2026-07-23_pace4_run")
    }
}
