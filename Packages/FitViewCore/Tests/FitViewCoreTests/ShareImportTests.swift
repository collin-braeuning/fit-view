import Foundation
import Testing
@testable import FitViewCore

private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeBookmark(pointingAt folder: URL) throws -> FolderBookmark {
    let bookmark = FolderBookmark(
        defaults: UserDefaults(suiteName: "ShareImportTests.\(UUID().uuidString)")!,
        key: "test.bookmark"
    )
    try bookmark.store(folder)
    return bookmark
}

@Suite("defaultActivityFileName")
struct DefaultActivityFileNameTests {
    @Test("reuses the date, device and activity of an already-conventional name")
    func reusesParseableName() {
        let name = defaultActivityFileName(forIncomingFileName: "2026-07-23_pace4_run.fit")
        #expect(name == "2026-07-23_pace4_run")
    }

    @Test("reuses a hyphen-separated name's parsed components too")
    func reusesHyphenatedName() {
        let name = defaultActivityFileName(forIncomingFileName: "2026-07-26-pace4_run.fit")
        #expect(name == "2026-07-26_pace4_run")
    }

    @Test("falls back to today's date with placeholders when the name doesn't parse")
    func fallsBackForUnparseableName() {
        let today = Date(timeIntervalSince1970: 1_785_000_000) // 2026-07-25T17:20:00Z
        let name = defaultActivityFileName(forIncomingFileName: "Activity_12345.fit", today: today)
        #expect(name == "2026-07-25_device_activity")
    }

    @Test("falls back the same way when there's no incoming name at all")
    func fallsBackForMissingName() {
        let today = Date(timeIntervalSince1970: 1_785_000_000) // 2026-07-25T17:20:00Z
        let name = defaultActivityFileName(forIncomingFileName: nil, today: today)
        #expect(name == "2026-07-25_device_activity")
    }
}

@Suite("defaultActivityFileName(forSharedData:)")
struct DefaultActivityFileNameForSharedDataTests {
    @Test("falls back to the filename-based default when the bytes don't decode as FIT")
    func fallsBackWhenUndecodable() {
        let today = Date(timeIntervalSince1970: 1_785_000_000) // 2026-07-25T17:20:00Z
        let name = defaultActivityFileName(
            forSharedData: Data("not a fit file".utf8),
            incomingFileName: "2026-07-23_pace4_run.fit",
            today: today
        )
        #expect(name == "2026-07-23_pace4_run")
    }

    @Test("falls back all the way to today's date when neither the bytes nor the name are usable")
    func fallsBackToTodayWhenNeitherUsable() {
        let today = Date(timeIntervalSince1970: 1_785_000_000) // 2026-07-25T17:20:00Z
        let name = defaultActivityFileName(
            forSharedData: Data("not a fit file".utf8),
            incomingFileName: "Activity_12345.fit",
            today: today
        )
        #expect(name == "2026-07-25_device_activity")
    }
}

@Suite("writeSharedActivity")
struct WriteSharedActivityTests {
    @Test("writes the file under the requested name when nothing collides")
    func writesWithNoCollision() throws {
        let folder = makeTempDirectory()
        let bookmark = try makeBookmark(pointingAt: folder)
        let data = Data("fake fit bytes".utf8)

        let written = try writeSharedActivity(data: data, desiredBaseName: "2026-07-30_pace4_run", into: bookmark)

        #expect(written.lastPathComponent == "2026-07-30_pace4_run.fit")
        #expect(try Data(contentsOf: written) == data)
    }

    @Test("appends a Finder-style numeric suffix when the name is already taken")
    func avoidsCollision() throws {
        let folder = makeTempDirectory()
        let bookmark = try makeBookmark(pointingAt: folder)

        let first = try writeSharedActivity(data: Data("one".utf8), desiredBaseName: "2026-07-30_pace4_run", into: bookmark)
        let second = try writeSharedActivity(data: Data("two".utf8), desiredBaseName: "2026-07-30_pace4_run", into: bookmark)
        let third = try writeSharedActivity(data: Data("three".utf8), desiredBaseName: "2026-07-30_pace4_run", into: bookmark)

        #expect(first.lastPathComponent == "2026-07-30_pace4_run.fit")
        #expect(second.lastPathComponent == "2026-07-30_pace4_run 2.fit")
        #expect(third.lastPathComponent == "2026-07-30_pace4_run 3.fit")
        #expect(try Data(contentsOf: second) == Data("two".utf8))
    }

    @Test("neutralizes a path-traversal attempt in the requested name")
    func sanitizesSlashes() throws {
        let folder = makeTempDirectory()
        let bookmark = try makeBookmark(pointingAt: folder)

        let written = try writeSharedActivity(data: Data("x".utf8), desiredBaseName: "../../elsewhere", into: bookmark)

        #expect(written.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(written.lastPathComponent == "..-..-elsewhere.fit")
    }
}
