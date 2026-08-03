import Foundation
import Testing
@testable import FitViewCore

private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeBookmark(key: String = "test.bookmark") -> FolderBookmark {
    FolderBookmark(defaults: UserDefaults(suiteName: "FolderBookmarkTests.\(UUID().uuidString)")!, key: key)
}

@Suite("FolderBookmark")
struct FolderBookmarkTests {
    @Test("storing a folder makes it resolvable across a fresh instance over the same defaults")
    func storeThenResolveRoundTrips() async throws {
        let defaults = UserDefaults(suiteName: "FolderBookmarkTests.\(UUID().uuidString)")!
        let folder = makeTempDirectory()

        let writer = FolderBookmark(defaults: defaults, key: "shared.key")
        #expect(writer.isConfigured == false)
        try writer.store(folder)
        #expect(writer.isConfigured == true)

        // A separate instance stands in for the next launch: the grant has to
        // outlive the object that minted it, which is the entire point.
        let reader = FolderBookmark(defaults: defaults, key: "shared.key")
        #expect(reader.isConfigured == true)
        #expect(try reader.resolve().standardizedFileURL == folder.standardizedFileURL)
    }

    @Test("resolving before anything is stored reports notConfigured")
    func resolveBeforeStoreThrows() throws {
        let bookmark = makeBookmark()
        #expect(throws: FolderBookmarkError.notConfigured) {
            _ = try bookmark.resolve()
        }
    }

    @Test("clear returns the bookmark to unconfigured")
    func clearForgetsTheFolder() throws {
        let bookmark = makeBookmark()
        try bookmark.store(makeTempDirectory())
        #expect(bookmark.isConfigured == true)

        bookmark.clear()
        #expect(bookmark.isConfigured == false)
        #expect(throws: FolderBookmarkError.notConfigured) {
            _ = try bookmark.resolve()
        }
    }

    @Test("two bookmarks over different keys never see each other's folder")
    func keysAreIndependent() throws {
        // The watched activity folder and the sync mirror are different
        // folders serving different purposes — picking one must never
        // silently repoint the other.
        let defaults = UserDefaults(suiteName: "FolderBookmarkTests.\(UUID().uuidString)")!
        let watched = FolderBookmark(defaults: defaults, key: "FitView.WatchedFolder.bookmark")
        let sync = FolderBookmark(defaults: defaults, key: "FitView.FolderSyncStore.bookmark")

        let watchedFolder = makeTempDirectory()
        try watched.store(watchedFolder)

        #expect(watched.isConfigured == true)
        #expect(sync.isConfigured == false)

        let syncFolder = makeTempDirectory()
        try sync.store(syncFolder)
        #expect(try watched.resolve().standardizedFileURL == watchedFolder.standardizedFileURL)
        #expect(try sync.resolve().standardizedFileURL == syncFolder.standardizedFileURL)
    }

    @Test("withAccess hands the resolved folder to its body and returns the body's value")
    func withAccessProvidesTheFolder() throws {
        let bookmark = makeBookmark()
        let folder = makeTempDirectory()
        try bookmark.store(folder)

        let name = try bookmark.withAccess { $0.lastPathComponent }
        #expect(name == folder.lastPathComponent)
    }
}
