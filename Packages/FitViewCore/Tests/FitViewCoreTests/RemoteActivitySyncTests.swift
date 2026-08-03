import Foundation
import Testing
@testable import FitViewCore

/// An in-memory `ActivitySource` double: `listAvailable()` returns whatever
/// candidates were configured, and `fetch` looks itself up in
/// `dataBySourceId` — a missing entry simulates a fetch failure, mirroring
/// `ImportCoordinatorTests`'s `FakeActivitySource`.
private struct FakeRemoteSource: ActivitySource {
    let id = "fake-remote"
    let displayName = "Fake Remote"
    let requiresAuthorization = true
    var candidates: [ImportCandidate]
    var dataBySourceId: [String: Data]

    func authorize() async throws {}
    func listAvailable() async throws -> [ImportCandidate] { candidates }

    func fetch(_ candidate: ImportCandidate) async throws -> ImportedActivity {
        guard let data = dataBySourceId[candidate.sourceId] else {
            throw ActivitySourceError.candidateNotFound(sourceId: candidate.sourceId)
        }
        return ImportedActivity(candidate: candidate, data: data, source: id)
    }
}

private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeBookmark() throws -> FolderBookmark {
    let defaults = UserDefaults(suiteName: "RemoteActivitySyncTests.\(UUID().uuidString)")!
    let bookmark = FolderBookmark(defaults: defaults, key: "test.bookmark")
    try bookmark.store(makeTempDirectory())
    return bookmark
}

private func makeIdStore(key: String = UUID().uuidString) -> RemoteSyncIdStore {
    RemoteSyncIdStore(defaults: UserDefaults(suiteName: "RemoteActivitySyncTests.\(UUID().uuidString)")!, key: key)
}

private func makeNicknameStore() -> DeviceNicknameStore {
    DeviceNicknameStore(defaults: UserDefaults(suiteName: "RemoteActivitySyncTests.\(UUID().uuidString)")!)
}

/// Real `.fit` bytes, so `defaultActivityFileName(forSharedData:incomingFileName:)`
/// actually exercises its device_info-based naming path rather than falling
/// back to the filename it was handed — same approach as `FolderIngestorTests`.
private func realFitData(named name: String = "2026-07-23_pace4_run.fit") throws -> Data {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FitViewCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FitViewCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
    return try Data(contentsOf: repoRoot.appendingPathComponent("Sources/FitView/Resources/SampleData/\(name)"))
}

@Suite("RemoteActivitySync")
struct RemoteActivitySyncTests {
    @Test("a first sync downloads every candidate and writes it into the folder")
    func firstSyncDownloadsEverything() async throws {
        let data = try realFitData()
        let candidate = ImportCandidate(sourceId: "ex-1", suggestedName: "polar-fallback-name")
        let source = FakeRemoteSource(candidates: [candidate], dataBySourceId: ["ex-1": data])
        let bookmark = try makeBookmark()
        let sync = RemoteActivitySync(downloadedIds: makeIdStore(), nicknames: makeNicknameStore())

        let report = try await sync.sync(source: source, into: bookmark)

        #expect(report.discovered == 1)
        #expect(report.downloaded == 1)
        #expect(report.failures.isEmpty)
        #expect(report.didChangeFolder)

        let written = try bookmark.withAccess { folder in
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        }
        #expect(written.count == 1)
    }

    @Test("a candidate already in the id store is not re-downloaded")
    func knownIdsAreSkipped() async throws {
        let data = try realFitData()
        let candidate = ImportCandidate(sourceId: "ex-1", suggestedName: "polar-fallback-name")
        let source = FakeRemoteSource(candidates: [candidate], dataBySourceId: ["ex-1": data])
        let bookmark = try makeBookmark()
        let idStore = makeIdStore()
        let sync = RemoteActivitySync(downloadedIds: idStore, nicknames: makeNicknameStore())

        let first = try await sync.sync(source: source, into: bookmark)
        #expect(first.downloaded == 1)

        let second = try await sync.sync(source: source, into: bookmark)
        #expect(second.discovered == 1, "still listed by the source")
        #expect(second.downloaded == 0, "already-downloaded ids must not be re-fetched")
        #expect(second.didChangeFolder == false)

        let written = try bookmark.withAccess { folder in
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        }
        #expect(written.count == 1, "a second sync must not write a duplicate file")
    }

    @Test("one failing fetch is collected as a failure without blocking the rest of the batch")
    func partialFailureDoesNotSinkTheBatch() async throws {
        let data = try realFitData()
        let good = ImportCandidate(sourceId: "good", suggestedName: "polar-good")
        let missing = ImportCandidate(sourceId: "missing", suggestedName: "polar-missing")
        let source = FakeRemoteSource(candidates: [good, missing], dataBySourceId: ["good": data])
        let bookmark = try makeBookmark()
        let sync = RemoteActivitySync(downloadedIds: makeIdStore(), nicknames: makeNicknameStore())

        let report = try await sync.sync(source: source, into: bookmark)

        #expect(report.discovered == 2)
        #expect(report.downloaded == 1)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.candidate.sourceId == "missing")
    }

    @Test("a failed candidate is retried on the next sync, not permanently skipped")
    func failedCandidatesAreRetried() async throws {
        let data = try realFitData()
        let candidate = ImportCandidate(sourceId: "ex-1", suggestedName: "polar-fallback-name")
        let missingSource = FakeRemoteSource(candidates: [candidate], dataBySourceId: [:])
        let bookmark = try makeBookmark()
        let idStore = makeIdStore()

        let firstReport = try await RemoteActivitySync(downloadedIds: idStore, nicknames: makeNicknameStore()).sync(source: missingSource, into: bookmark)
        #expect(firstReport.failures.count == 1)

        let workingSource = FakeRemoteSource(candidates: [candidate], dataBySourceId: ["ex-1": data])
        let secondReport = try await RemoteActivitySync(downloadedIds: idStore, nicknames: makeNicknameStore()).sync(source: workingSource, into: bookmark)
        #expect(secondReport.downloaded == 1)
        #expect(secondReport.failures.isEmpty)
    }

    @Test("the written filename is derived from the FIT's own device_info, not the candidate's suggested name")
    func nameIsDerivedFromFitContent() async throws {
        let data = try realFitData(named: "2026-07-23_polarSense_run.FIT")
        let candidate = ImportCandidate(sourceId: "ex-1", suggestedName: "totally-different-name")
        let source = FakeRemoteSource(candidates: [candidate], dataBySourceId: ["ex-1": data])
        let bookmark = try makeBookmark()
        let sync = RemoteActivitySync(downloadedIds: makeIdStore(), nicknames: makeNicknameStore())

        _ = try await sync.sync(source: source, into: bookmark)

        let written = try bookmark.withAccess { folder in
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        }
        let name = try #require(written.first?.lastPathComponent)
        #expect(name != "totally-different-name.fit")
        #expect(name == defaultActivityFileName(forSharedData: data, incomingFileName: candidate.suggestedName) + ".fit")
    }

    @Test("a pre-established nickname is baked into the written filename, not the FIT file's raw device name")
    func writtenFilenameUsesAnEstablishedNickname() async throws {
        let data = try realFitData(named: "2026-07-23_polarSense_run.FIT")
        let candidate = ImportCandidate(sourceId: "ex-1", suggestedName: "irrelevant")
        let source = FakeRemoteSource(candidates: [candidate], dataBySourceId: ["ex-1": data])
        let bookmark = try makeBookmark()
        let nicknames = makeNicknameStore()
        // This fixture's FIT content reports "Polar Verity Sense"
        // (`file_id.product_name`) — establish the library's historical
        // convention as its nickname before syncing.
        nicknames.setNickname("polarSense", forRawDeviceName: "Polar Verity Sense")
        let sync = RemoteActivitySync(downloadedIds: makeIdStore(), nicknames: nicknames)

        _ = try await sync.sync(source: source, into: bookmark)

        let written = try bookmark.withAccess { folder in
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        }
        let name = try #require(written.first?.lastPathComponent)
        #expect(name.contains("polarSense"))
        #expect(!name.contains("Polar Verity Sense"))
    }

    @Test("an empty candidate list is a successful no-op")
    func emptyListIsANoOp() async throws {
        let source = FakeRemoteSource(candidates: [], dataBySourceId: [:])
        let bookmark = try makeBookmark()
        let sync = RemoteActivitySync(downloadedIds: makeIdStore(), nicknames: makeNicknameStore())

        let report = try await sync.sync(source: source, into: bookmark)
        #expect(report == RemoteSyncReport())
    }
}

@Suite("RemoteSyncIdStore")
struct RemoteSyncIdStoreTests {
    @Test("a fresh store contains nothing")
    func startsEmpty() {
        let store = RemoteSyncIdStore(defaults: UserDefaults(suiteName: "RemoteSyncIdStoreTests.\(UUID().uuidString)")!, key: "ids")
        #expect(store.contains("abc") == false)
        #expect(store.ids().isEmpty)
    }

    @Test("an inserted id is reported as contained, and persists across a fresh instance over the same defaults")
    func insertPersists() {
        let defaults = UserDefaults(suiteName: "RemoteSyncIdStoreTests.\(UUID().uuidString)")!
        let writer = RemoteSyncIdStore(defaults: defaults, key: "shared")
        writer.insert("abc")
        #expect(writer.contains("abc"))

        let reader = RemoteSyncIdStore(defaults: defaults, key: "shared")
        #expect(reader.contains("abc"))
    }

    @Test("two stores over different keys never see each other's ids")
    func keysAreIndependent() {
        let defaults = UserDefaults(suiteName: "RemoteSyncIdStoreTests.\(UUID().uuidString)")!
        let a = RemoteSyncIdStore(defaults: defaults, key: "a")
        let b = RemoteSyncIdStore(defaults: defaults, key: "b")

        a.insert("shared-id")
        #expect(a.contains("shared-id"))
        #expect(b.contains("shared-id") == false)
    }

    @Test("inserting the same id twice does not duplicate it")
    func insertIsIdempotent() {
        let store = RemoteSyncIdStore(defaults: UserDefaults(suiteName: "RemoteSyncIdStoreTests.\(UUID().uuidString)")!, key: "ids")
        store.insert("abc")
        store.insert("abc")
        #expect(store.ids() == ["abc"])
    }

    @Test("removeAll forgets every id, so a subsequent sync would re-download everything")
    func removeAllClearsTheStore() {
        let store = RemoteSyncIdStore(defaults: UserDefaults(suiteName: "RemoteSyncIdStoreTests.\(UUID().uuidString)")!, key: "ids")
        store.insert("abc")
        store.insert("def")
        #expect(store.ids() == ["abc", "def"])

        store.removeAll()
        #expect(store.ids().isEmpty)
        #expect(store.contains("abc") == false)
    }
}
