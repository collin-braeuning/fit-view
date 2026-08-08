import FitViewCore
import Foundation
import Testing

/// Covers `ShareImportViewModel`'s phase transitions and `save()`/`canSave` behavior — see
/// specs/003-import-flow/research.md §1 (why this closes the Principle VI gap without extracting
/// a new presenter) and §5 (why "unreadable" does not mean "invalid FIT content").
///
/// `ShareImportViewModel` lives in `Sources/ShareExtension/Shared`, not `Sources/FitView`, so
/// this file needs no `@testable import FitView` — `project.yml` compiles that directory
/// directly into `FitViewTests` (see the `sources` entry added alongside this file), making the
/// type visible with no import at all beyond `FitViewCore`/`Foundation`.

/// A minimal fake standing in for the real, system-only `NSExtensionContext` — there is no
/// public initializer that accepts custom `inputItems`, so this overrides just enough surface
/// (`inputItems`, `completeRequest`, `cancelRequest`) to drive `ShareImportViewModel` without a
/// real extension host. Confirmed to compile and to have its `inputItems` override actually
/// observed by `ShareImportViewModel.firstAttachment()` (T002's spike).
private final class FakeExtensionContext: NSExtensionContext {
    private let items: [Any]
    /// `ShareImportViewModel.save()` always calls `completeRequest(returningItems: nil)` — the
    /// items argument is never populated — so "did it get called at all" has to be tracked as
    /// its own flag rather than inferred from a non-nil argument.
    private(set) var didComplete = false
    private(set) var didCancel = false

    init(items: [Any]) {
        self.items = items
        super.init()
    }

    override var inputItems: [Any] { items }

    override func completeRequest(returningItems items: [Any]?, completionHandler: ((Bool) -> Void)?) {
        didComplete = true
        completionHandler?(true)
    }

    override func cancelRequest(withError error: Error) {
        didCancel = true
    }
}

private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeBookmark(pointingAt folder: URL?) throws -> FolderBookmark {
    let bookmark = FolderBookmark(
        defaults: UserDefaults(suiteName: "ShareImportViewModelTests.\(UUID().uuidString)")!,
        key: "test.bookmark"
    )
    if let folder {
        try bookmark.store(folder)
    }
    return bookmark
}

private func makeNicknames() -> DeviceNicknameStore {
    DeviceNicknameStore(defaults: UserDefaults(suiteName: "ShareImportViewModelTests.\(UUID().uuidString)")!)
}

/// Real `.fit` bytes with a decodable device, same file `ShareImportTests.swift`
/// (`FitViewCoreTests`) uses — reused here so both suites exercise the same known-good fixture.
/// `Tests/FitViewTests` is one directory shallower than `Packages/FitViewCore/Tests/
/// FitViewCoreTests`, so this walks up one fewer level to the repo root.
private func realFitData(named name: String = "2026-07-23_polarSense_run.FIT") throws -> Data {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FitViewTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
    return try Data(contentsOf: repoRoot.appendingPathComponent("Sources/FitView/Resources/SampleData/\(name)"))
}

/// Wraps `data` in a temp file and an `NSItemProvider` pointing at it, the shape
/// `ShareImportViewModel.loadFile(from:)` expects (`loadFileRepresentation`).
private func makeAttachmentProvider(data: Data, fileName: String = "shared.fit") throws -> NSItemProvider {
    let fileURL = makeTempDirectory().appendingPathComponent(fileName)
    try data.write(to: fileURL)
    guard let provider = NSItemProvider(contentsOf: fileURL) else {
        struct ProviderCreationFailed: Error {}
        throw ProviderCreationFailed()
    }
    return provider
}

@Suite("ShareImportViewModel")
@MainActor
struct ShareImportViewModelTests {
    @Test("an unconfigured folder bookmark short-circuits to .notConfigured before touching the extension context")
    func unconfiguredBookmark() async throws {
        let bookmark = try makeBookmark(pointingAt: nil)
        let model = ShareImportViewModel(extensionContext: nil, bookmark: bookmark, nicknames: makeNicknames())

        await model.start()

        #expect(model.phase == .notConfigured)
    }

    @Test("no extension context at all means no attachment, so start() reports nothing was shared")
    func noAttachment() async throws {
        let folder = makeTempDirectory()
        let bookmark = try makeBookmark(pointingAt: folder)
        let model = ShareImportViewModel(extensionContext: nil, bookmark: bookmark, nicknames: makeNicknames())

        await model.start()

        #expect(model.phase == .unreadable("No file was shared."))
    }

    @Test("an attachment that fails to hand over bytes is reported as unreadable")
    func attachmentLoadFailure() async throws {
        let folder = makeTempDirectory()
        let bookmark = try makeBookmark(pointingAt: folder)
        let item = NSExtensionItem()
        // An empty provider has no registered representations to load, so
        // `loadFileRepresentation` fails — this is the "system fails to hand
        // over bytes" half of spec.md's amended Acceptance Scenario 4, distinct
        // from garbage-but-present bytes (see readyWithGarbageData below).
        item.attachments = [NSItemProvider()]
        let context = FakeExtensionContext(items: [item])
        let model = ShareImportViewModel(extensionContext: context, bookmark: bookmark, nicknames: makeNicknames())

        await model.start()

        #expect(model.phase == .unreadable("Couldn't read the shared file."))
    }

    @Test("a real .fit attachment proposes a name derived from its own decoded content")
    func readyWithRealFitData() async throws {
        let folder = makeTempDirectory()
        let bookmark = try makeBookmark(pointingAt: folder)
        let data = try realFitData()
        let item = NSExtensionItem()
        item.attachments = [try makeAttachmentProvider(data: data)]
        let context = FakeExtensionContext(items: [item])
        let model = ShareImportViewModel(extensionContext: context, bookmark: bookmark, nicknames: makeNicknames())

        await model.start()

        #expect(model.phase == .ready)
        let expectedName = defaultActivityFileName(forSharedData: data, incomingFileName: nil)
        #expect(model.fileName == expectedName)
    }

    @Test("bytes that aren't valid FIT data still reach .ready with a fallback name — this is documented, not a bug")
    func readyWithGarbageData() async throws {
        let folder = makeTempDirectory()
        let bookmark = try makeBookmark(pointingAt: folder)
        let garbage = Data("not a fit file".utf8)
        let item = NSExtensionItem()
        item.attachments = [try makeAttachmentProvider(data: garbage, fileName: "shared.fit")]
        let context = FakeExtensionContext(items: [item])
        let model = ShareImportViewModel(extensionContext: context, bookmark: bookmark, nicknames: makeNicknames())

        await model.start()

        // research.md §5: undecodable bytes fall back to
        // defaultActivityFileName(forIncomingFileName:)'s "<date>_device_activity" shape rather
        // than being rejected — proving the share sheet still doesn't validate FIT content,
        // in either direction (a regression toward validating it would also fail this test).
        #expect(model.phase == .ready)
        #expect(model.fileName.hasSuffix("_device_activity"))
    }

    @Test("save() from .ready writes the file into the bookmarked folder under the (trimmed) proposed name")
    func saveWritesIntoBookmarkedFolder() async throws {
        let folder = makeTempDirectory()
        let bookmark = try makeBookmark(pointingAt: folder)
        let data = try realFitData()
        let item = NSExtensionItem()
        item.attachments = [try makeAttachmentProvider(data: data)]
        let context = FakeExtensionContext(items: [item])
        let model = ShareImportViewModel(extensionContext: context, bookmark: bookmark, nicknames: makeNicknames())
        await model.start()
        #expect(model.phase == .ready)

        model.fileName = "  2026-08-07_pace4_run  "
        model.save()

        let written = folder.appendingPathComponent("2026-08-07_pace4_run.fit")
        #expect(FileManager.default.fileExists(atPath: written.path))
        #expect(try Data(contentsOf: written) == data)
        #expect(model.saveError == nil)
        // `isSaving` is deliberately never reset to `false` on the success path — the extension
        // is about to terminate via `completeRequest`, so there's no UI left to un-disable.
        #expect(model.isSaving == true)
        #expect(context.didComplete == true)
    }

    @Test("canSave gates on phase, in-flight saving, and a non-empty trimmed name")
    func canSaveGating() async throws {
        let folder = makeTempDirectory()
        let bookmark = try makeBookmark(pointingAt: folder)
        let data = try realFitData()
        let item = NSExtensionItem()
        item.attachments = [try makeAttachmentProvider(data: data)]
        let context = FakeExtensionContext(items: [item])
        let model = ShareImportViewModel(extensionContext: context, bookmark: bookmark, nicknames: makeNicknames())

        // Not yet .ready.
        #expect(model.canSave == false)

        await model.start()
        #expect(model.phase == .ready)
        #expect(model.canSave == true)

        model.fileName = "   "
        #expect(model.canSave == false)

        model.fileName = "2026-08-07_pace4_run"
        #expect(model.canSave == true)
    }
}
