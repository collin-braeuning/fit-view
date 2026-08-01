import FitViewCore
import Foundation

/// An `ActivitySource` backed by files the user explicitly picked — the
/// system document picker (`.fileImporter`) or a drag-and-drop onto the
/// overview on macOS — rather than a remote service.
///
/// `ActivitySource.listAvailable()` has no built-in notion of "ask the user
/// to pick something"; presenting a picker is a UI concern that has to
/// happen before the import pipeline runs. So the flow is: the view presents
/// the picker/drop target, calls `setSelection` with whatever URLs came back,
/// and only then does this behave like any other source. An actor because
/// `setSelection` (from the main-actor UI) and `fetch` (from the
/// `ImportCoordinator`'s task group, concurrently across candidates) both
/// touch `selectedURLs`.
actor FileImportSource: ActivitySource {
    nonisolated let id = "files"
    nonisolated let displayName = "Files"
    nonisolated let requiresAuthorization = false

    private var selectedURLs: [URL] = []

    func authorize() async throws {}

    /// Called by the UI once the document picker or a drop delivers URLs.
    /// Replaces any previous selection outright — this source only ever
    /// represents "what's currently picked", not an accumulating list.
    func setSelection(_ urls: [URL]) {
        selectedURLs = urls
    }

    func listAvailable() async throws -> [ImportCandidate] {
        selectedURLs.map { url in
            let fileName = url.lastPathComponent
            let parsed = parseActivityFileName(fileName)
            return ImportCandidate(
                sourceId: url.path,
                suggestedName: stripFileExtension(fileName),
                deviceLabel: parsed?.device
            )
        }
    }

    func fetch(_ candidate: ImportCandidate) async throws -> ImportedActivity {
        guard let url = selectedURLs.first(where: { $0.path == candidate.sourceId }) else {
            throw ActivitySourceError.candidateNotFound(sourceId: candidate.sourceId)
        }

        // Sandboxed file access (document picker URLs, and macOS drops from
        // outside the app's own container) requires bracketing every read
        // with start/stop — the access grant is scoped to exactly this call,
        // not persisted, since Phase 1 has no library to hold a longer-lived
        // bookmark in.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        return ImportedActivity(candidate: candidate, data: data, source: id)
    }
}
