import FitViewCore
import Foundation

/// Loads every bundled sample `.fit` file and runs the batch comparison
/// pipeline over it, mirroring the web app's `useBatchAgreement`: group by
/// filename, extract each file's per-second heart rate once, then compare the
/// two most common devices.
enum SampleBatchLoader {
    static func load() throws -> LoadedBatch {
        let files = try loadSampleFiles()
        return BatchAssembler.assemble(files)
    }

    /// Sample files are bundled under both extension cases by design
    /// (`pace4` ships `.fit`, `polarSense` ships `.FIT`).
    private static func loadSampleFiles() throws -> [LoadedFile] {
        let urls = ["fit", "FIT"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        return try urls.map { url in
            let data = try Data(contentsOf: url)
            return try loadFitFile(data: data, fileName: url.lastPathComponent)
        }
    }
}
