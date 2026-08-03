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

/// Real `.fit` bytes with a decodable device — a hand-written byte string
/// would never reach `resolveDeviceLabel` at all, since that closure is only
/// ever applied to a device name `extractSharedActivityMetadata` actually
/// decoded.
private func realFitData(named name: String = "2026-07-23_polarSense_run.FIT") throws -> Data {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FitViewCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FitViewCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
    return try Data(contentsOf: repoRoot.appendingPathComponent("Sources/FitView/Resources/SampleData/\(name)"))
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

    @Test("resolveDeviceLabel substitutes a nickname for the FIT-decoded device name")
    func resolveDeviceLabelSubstitutesTheDeviceName() throws {
        let data = try realFitData()
        let name = defaultActivityFileName(
            forSharedData: data,
            incomingFileName: nil,
            resolveDeviceLabel: { rawName in rawName == "Polar Verity Sense" ? "polarSense" : rawName }
        )
        #expect(name.contains("polarSense"))
        #expect(!name.contains("Polar Verity Sense"))
    }

    @Test("resolveDeviceLabel defaults to identity, so every existing call site keeps its exact old behavior")
    func resolveDeviceLabelDefaultsToIdentity() throws {
        let data = try realFitData()
        let withDefault = defaultActivityFileName(forSharedData: data, incomingFileName: nil)
        let withExplicitIdentity = defaultActivityFileName(
            forSharedData: data,
            incomingFileName: nil,
            resolveDeviceLabel: { $0 }
        )
        #expect(withDefault == withExplicitIdentity)
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
