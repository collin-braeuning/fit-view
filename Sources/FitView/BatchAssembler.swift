import FitViewCore

/// Turns a flat list of decoded files into a `LoadedBatch` — group by
/// filename, extract each file's per-second heart rate once, pick the two
/// most common devices, run the batch comparison pipeline.
///
/// Factored out of `BatchBuilder` so the store-backed load and an
/// imported batch (`ImportCoordinator`'s `ImportResult.files`) go through
/// exactly one place that turns "some `LoadedFile`s" into "a `LoadedBatch`" —
/// mirroring `BatchOverviewModel`'s reasoning that there should be exactly
/// one place doing this kind of assembly, so the two callers can never drift.
enum BatchAssembler {
    static func assemble(_ files: [LoadedFile]) -> LoadedBatch {
        let grouping = groupActivityFiles(files.map(\.fileName))
        let filesByName = Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0) })

        var samplesByName: [String: [Int: Int]] = [:]
        for file in files {
            samplesByName[file.fileName] = heartRateBySecond(file.activity.records)
        }

        guard let primaryDeviceKey = grouping.devices.first?.key else {
            return LoadedBatch(
                agreement: BatchAgreement(
                    primaryName: "", secondaryName: "", sessions: [], spread: nil, pooled: nil, skipped: []
                ),
                grouping: grouping,
                filesByName: filesByName,
                primaryDeviceKey: "",
                secondaryDeviceKey: "",
                deviceLabels: [:]
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

        return LoadedBatch(
            agreement: buildBatchAgreement(input),
            grouping: grouping,
            filesByName: filesByName,
            primaryDeviceKey: primaryDeviceKey,
            secondaryDeviceKey: secondaryDeviceKey,
            deviceLabels: deviceLabels
        )
    }
}
