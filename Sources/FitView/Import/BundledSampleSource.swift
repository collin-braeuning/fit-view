import FitViewCore
import Foundation

/// Every bundled sample `.fit` file's URL. Sample files are bundled under
/// both extension cases by design (`pace4` ships `.fit`, `polarSense` ships
/// `.FIT`). Shared between `BundledSampleSource` (the "re-import the sample
/// data" entry in the import UI) and `BatchBuilder` (the first-launch seed
/// into the library store), so there is exactly one place that knows how the
/// bundle lays these files out.
func bundledSampleURLs() -> [URL] {
    ["fit", "FIT"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
}

/// `ActivitySource` conformance over the sample `.fit` files bundled with the
/// app (`Resources/SampleData/`).
///
/// The app's default `.task` load (`BatchOverviewView`, via `BatchBuilder`)
/// doesn't go through this — `BatchBuilder` seeds the library store directly
/// so the very first launch has no import-sheet UI in its critical path. This
/// conformance exists so "re-import the sample data" is reachable from the
/// same import UI as every other source, and so the `ActivitySource` protocol
/// has at least one conformance backed by known-good data to validate the
/// import pipeline against.
struct BundledSampleSource: ActivitySource {
    let id = "bundled"
    let displayName = "Sample Data"
    let requiresAuthorization = false

    func authorize() async throws {}

    func listAvailable() async throws -> [ImportCandidate] {
        bundledSampleURLs().map { url in
            let fileName = url.lastPathComponent
            let parsed = parseActivityFileName(fileName)
            return ImportCandidate(
                sourceId: fileName,
                suggestedName: stripFileExtension(fileName),
                deviceLabel: parsed?.device
            )
        }
    }

    func fetch(_ candidate: ImportCandidate) async throws -> ImportedActivity {
        guard let url = bundledSampleURLs().first(where: { $0.lastPathComponent == candidate.sourceId }) else {
            throw ActivitySourceError.candidateNotFound(sourceId: candidate.sourceId)
        }
        let data = try Data(contentsOf: url)
        return ImportedActivity(candidate: candidate, data: data, source: id)
    }
}
