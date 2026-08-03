import FitViewCore
import Foundation
import Observation
import UniformTypeIdentifiers

/// Drives the share extension's one screen: pull the shared file's bytes out
/// of the `NSExtensionContext`, propose a default name, and write it into the
/// watched folder on save.
///
/// Plain `NSExtensionItem`/`NSExtensionContext` (declared in `Foundation`,
/// not `UIKit`/`AppKit`) rather than anything platform-specific, so this one
/// type drives both the iOS and macOS extension's view controller.
@MainActor
@Observable
final class ShareImportViewModel {
    enum Phase: Equatable {
        case loading
        case ready
        case notConfigured
        /// The share couldn't be read at all — nothing to save, so the UI
        /// has no form to show, only a message and a way to dismiss.
        case unreadable(String)
    }

    var fileName = ""
    private(set) var phase = Phase.loading
    private(set) var isSaving = false
    private(set) var saveError: String?

    var canSave: Bool {
        phase == .ready && !isSaving && !trimmedFileName.isEmpty
    }

    private let extensionContext: NSExtensionContext?
    private let bookmark: FolderBookmark
    private var data: Data?

    /// `bookmark` defaults to the exact key `WatchedFolderSource` uses, so
    /// this always points at the same folder Settings shows — the extension
    /// and the host app agree on "the folder" only because both read the
    /// same App-Group-shared `UserDefaults` under the same key.
    init(
        extensionContext: NSExtensionContext?,
        bookmark: FolderBookmark = FolderBookmark(defaults: AppGroup.defaults, key: "FitView.WatchedFolder.bookmark")
    ) {
        self.extensionContext = extensionContext
        self.bookmark = bookmark
    }

    func start() async {
        guard bookmark.isConfigured else {
            phase = .notConfigured
            return
        }
        guard let provider = firstAttachment() else {
            phase = .unreadable("No file was shared.")
            return
        }

        do {
            let (data, suggestedName) = try await Self.loadFile(from: provider)
            self.data = data
            // Prefers the file's own recorded date/device/activity
            // (`extractSharedActivityMetadata`) over the source app's
            // filename — the file's own content is the truest source
            // available, when it decodes at all.
            fileName = defaultActivityFileName(forSharedData: data, incomingFileName: suggestedName)
            phase = .ready
        } catch {
            phase = .unreadable("Couldn't read the shared file.")
        }
    }

    func save() {
        guard phase == .ready, let data else { return }
        isSaving = true
        saveError = nil
        do {
            _ = try writeSharedActivity(data: data, desiredBaseName: trimmedFileName, into: bookmark)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            isSaving = false
            saveError = "Couldn't save the file. \(error.localizedDescription)"
        }
    }

    func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private var trimmedFileName: String {
        fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The extension's own exported type (declared in the host apps'
    /// Info.plist) if the source app's attachment is tagged with it,
    /// otherwise whatever type the attachment actually offers — a source app
    /// that predates FitView being installed, or that never re-resolved the
    /// file's UTI, may still hand the file over as generic `public.data`.
    private static let fitTypeIdentifier = "com.fitview.fit-file"

    private func firstAttachment() -> NSItemProvider? {
        extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .compactMap { $0.attachments }
            .flatMap { $0 }
            .first
    }

    private static func loadFile(from provider: NSItemProvider) async throws -> (Data, String?) {
        let typeIdentifier = provider.hasItemConformingToTypeIdentifier(fitTypeIdentifier)
            ? fitTypeIdentifier
            : (provider.registeredTypeIdentifiers.first ?? UTType.data.identifier)

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    // The system deletes its temp file once this closure
                    // returns, so the bytes have to be read synchronously
                    // here rather than handed off for later.
                    let data = try Data(contentsOf: url)
                    continuation.resume(returning: (data, url.lastPathComponent))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
