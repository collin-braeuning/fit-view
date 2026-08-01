import FitViewCore
import Foundation

/// Loads every bundled sample `.fit` file and runs the batch comparison
/// pipeline over it, mirroring the web app's `useBatchAgreement`: group by
/// filename, extract each file's per-second heart rate once, then compare the
/// two most common devices.
enum SampleBatchLoader {
    static func load() throws -> BatchAgreement {
        let files = try loadSampleFiles()
        let grouping = groupActivityFiles(files.map(\.fileName))

        var samplesByName: [String: [Int: Int]] = [:]
        for file in files {
            samplesByName[file.fileName] = heartRateBySecond(file.activity.records)
        }

        guard let primaryDeviceKey = grouping.devices.first?.key else {
            return BatchAgreement(
                primaryName: "", secondaryName: "", sessions: [], spread: nil, pooled: nil, skipped: []
            )
        }
        let secondaryDeviceKey = grouping.devices.first { $0.key != primaryDeviceKey }?.key ?? primaryDeviceKey

        let deviceLabels = Dictionary(uniqueKeysWithValues: grouping.devices.map { ($0.key, $0.label) })

        let sessions = grouping.sessions.map { session -> BatchAgreementInput.SessionSamples in
            var samplesByDeviceKey: [String: [Int: Int]] = [:]
            for (deviceKey, file) in session.filesByDeviceKey {
                if let samples = samplesByName[file.fileName] {
                    samplesByDeviceKey[deviceKey] = samples
                }
            }
            return BatchAgreementInput.SessionSamples(session: session, samplesByDeviceKey: samplesByDeviceKey)
        }

        let input = BatchAgreementInput(
            sessions: sessions,
            primaryDeviceKey: primaryDeviceKey,
            secondaryDeviceKey: secondaryDeviceKey,
            deviceLabels: deviceLabels
        )

        return buildBatchAgreement(input)
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
