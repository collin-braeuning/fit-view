import Foundation
import Testing
@testable import FitViewCore

/// A fresh temp directory per call so folders never see each other's state —
/// mirrors `FolderSyncStoreTests`'s helper of the same name. Created eagerly
/// because bookmark creation (`setFolder`) requires the target to already
/// exist, which is true of anything the real document picker could return but
/// not of a bare temp URL.
private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ contents: String, to folder: URL, named name: String) throws {
    let url = folder.appendingPathComponent(name)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
}

private func makeSource(_ folder: URL) async throws -> WatchedFolderSource {
    let defaults = UserDefaults(suiteName: "WatchedFolderSourceTests.\(UUID().uuidString)")!
    let source = WatchedFolderSource(defaults: defaults)
    try await source.setFolder(folder)
    return source
}

/// Like `FolderSyncStore`, this is tested only against plain temp directories
/// — there's no way to drive real iCloud Drive materialisation from CI.
/// `ensureMaterialized` is a documented no-op for a non-ubiquitous file, which
/// a temp file always is, so these exercise scanning and naming exhaustively
/// without exercising the download path at all. The one iCloud-specific
/// behaviour that *is* testable offline is placeholder-name normalisation,
/// since a `.name.fit.icloud` stub is just a hidden file as far as the
/// filesystem is concerned.
@Suite("WatchedFolderSource")
struct WatchedFolderSourceTests {
    @Test("a fresh source isn't configured until a folder is set")
    func isConfiguredTracksSetFolder() async throws {
        let defaults = UserDefaults(suiteName: "WatchedFolderSourceTests.\(UUID().uuidString)")!
        let source = WatchedFolderSource(defaults: defaults)
        #expect(source.isConfigured == false)
        try await source.setFolder(makeTempDirectory())
        #expect(source.isConfigured == true)
        await source.clearFolder()
        #expect(source.isConfigured == false, "clearing must return the source to unconfigured")
    }

    @Test("listing before a folder is set reports notConfigured rather than an empty folder")
    func listBeforeConfigurationThrows() async throws {
        let defaults = UserDefaults(suiteName: "WatchedFolderSourceTests.\(UUID().uuidString)")!
        let source = WatchedFolderSource(defaults: defaults)
        await #expect(throws: ActivitySourceError.self) {
            _ = try await source.listAvailable()
        }
    }

    @Test("both .fit and .FIT are found, recursively, and nothing else is")
    func listsFitFilesRecursively() async throws {
        let folder = makeTempDirectory()
        // The reference corpus ships `pace4` lowercase and `polarSense`
        // uppercase (overview.md §8) — the extension case split is real data,
        // not a hypothetical.
        try write("a", to: folder, named: "2026-07-23_pace4_run.fit")
        try write("b", to: folder, named: "2026-07-23_polarSense_run.FIT")
        try write("c", to: folder, named: "nested/2026-07-24_pace4_run.fit")
        try write("not a fit file", to: folder, named: "README.md")
        try write("d", to: folder, named: "nested/deeper/2026-07-25_polarSense_ride.fit")

        let source = try await makeSource(folder)
        let candidates = try await source.listAvailable()

        #expect(candidates.count == 4, "the .md must be excluded and both extension cases included")
        #expect(Set(candidates.map(\.sourceId)) == [
            "2026-07-23_pace4_run.fit",
            "2026-07-23_polarSense_run.FIT",
            "nested/2026-07-24_pace4_run.fit",
            "nested/deeper/2026-07-25_polarSense_ride.fit",
        ], "sourceIds must be paths relative to the folder, so they survive the folder moving")
    }

    @Test("candidates carry a filename-parsed suggestedName and device, like a hand-picked file")
    func candidatesParseTheirFilenames() async throws {
        let folder = makeTempDirectory()
        try write("a", to: folder, named: "2026-07-26-pace4_run.fit")

        let source = try await makeSource(folder)
        let candidate = try #require(try await source.listAvailable().first)

        // The hyphen-after-date form is a real file in the corpus
        // (overview.md §6), so it has to parse here too.
        #expect(candidate.suggestedName == "2026-07-26-pace4_run")
        #expect(candidate.deviceLabel == "pace4")
        #expect(candidate.startTime == nil, "a file-backed candidate has no start time until it's decoded")
    }

    @Test("an undownloaded iCloud placeholder is listed under the name it stands for")
    func normalizesICloudPlaceholderNames() async throws {
        let folder = makeTempDirectory()
        try write("downloaded", to: folder, named: "2026-07-23_pace4_run.fit")
        // iCloud represents a not-yet-downloaded item as a hidden
        // `.<name>.icloud` stub. If the scan judged files by that name, a
        // folder's newest arrivals would be exactly the ones it ignored.
        try write("stub", to: folder, named: ".2026-07-25_polarSense_run.fit.icloud")

        let source = try await makeSource(folder)
        let candidates = try await source.listAvailable()

        #expect(candidates.count == 2)
        #expect(Set(candidates.map(\.sourceId)) == [
            "2026-07-23_pace4_run.fit",
            "2026-07-25_polarSense_run.fit",
        ], "the placeholder must be listed under its real name, so its id is the same once downloaded")
        let placeholder = try #require(candidates.first { $0.sourceId.contains("polarSense") })
        #expect(placeholder.suggestedName == "2026-07-25_polarSense_run")
        #expect(placeholder.deviceLabel == "polarSense")
    }

    @Test("a FolderSyncStore mirror's blobs are skipped, not imported as activities")
    func skipsSyncMirrorBlobs() async throws {
        // `FolderSyncStore` writes `manifest.json` + `blobs/<sha256>.fit` into
        // whatever folder it syncs to. Those blobs are real `.fit` files, so
        // pointing both features at one folder would otherwise re-import every
        // activity under a hex-digest name that `parseActivityFileName` can't
        // read — collapsing all of them into one junk `unknown-date` session.
        let folder = makeTempDirectory()
        try write("a", to: folder, named: "2026-07-23_pace4_run.fit")
        try write("{}", to: folder, named: "manifest.json")
        try write("blob", to: folder, named: "blobs/\(String(repeating: "a", count: 64)).fit")
        try write("blob", to: folder, named: "blobs/\(String(repeating: "b", count: 64)).fit")

        let source = try await makeSource(folder)
        let candidates = try await source.listAvailable()

        #expect(candidates.map(\.sourceId) == ["2026-07-23_pace4_run.fit"])
    }

    @Test("a directory called blobs with no manifest beside it is scanned normally")
    func onlySkipsBlobsThatAreActuallyAMirror() async throws {
        // The exclusion keys on structure, not on the name `blobs` — a user
        // folder that happens to use that name must still be read.
        let folder = makeTempDirectory()
        try write("a", to: folder, named: "blobs/2026-07-23_pace4_run.fit")

        let source = try await makeSource(folder)
        #expect(try await source.listAvailable().map(\.sourceId) == ["blobs/2026-07-23_pace4_run.fit"])
    }

    @Test("a hidden file that isn't an iCloud placeholder is still judged by its own name")
    func ignoresUnrelatedHiddenFiles() async throws {
        let folder = makeTempDirectory()
        try write("a", to: folder, named: "2026-07-23_pace4_run.fit")
        try write("junk", to: folder, named: ".DS_Store")

        let source = try await makeSource(folder)
        #expect(try await source.listAvailable().count == 1)
    }

    @Test("fetch returns the file's bytes, tagged with this source's id")
    func fetchReadsBytes() async throws {
        let folder = makeTempDirectory()
        try write("hello fit bytes", to: folder, named: "nested/2026-07-23_pace4_run.fit")

        let source = try await makeSource(folder)
        let candidate = try #require(try await source.listAvailable().first)
        let imported = try await source.fetch(candidate)

        #expect(imported.data == Data("hello fit bytes".utf8))
        #expect(imported.source == "folder")
        #expect(imported.candidate.sourceId == "nested/2026-07-23_pace4_run.fit")
    }

    @Test("fetching a candidate whose file has since been deleted reports candidateNotFound")
    func fetchOfMissingFileThrows() async throws {
        let folder = makeTempDirectory()
        try write("a", to: folder, named: "2026-07-23_pace4_run.fit")

        let source = try await makeSource(folder)
        let candidate = try #require(try await source.listAvailable().first)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("2026-07-23_pace4_run.fit"))

        await #expect(throws: ActivitySourceError.candidateNotFound(sourceId: "2026-07-23_pace4_run.fit")) {
            _ = try await source.fetch(candidate)
        }
    }

    @Test("folderName reports the picked folder's own name, for display in settings")
    func reportsFolderName() async throws {
        let folder = makeTempDirectory()
        let source = try await makeSource(folder)
        #expect(await source.folderName() == folder.lastPathComponent)
    }
}
