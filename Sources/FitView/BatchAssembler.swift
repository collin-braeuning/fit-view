import FitViewCore

/// Turns decoded activities into a `LoadedBatch` — group by
/// `ActivityDescriptor` (not by re-parsing a filename), extract each file's
/// per-second heart rate once, pick the two most common devices, run the
/// batch comparison pipeline.
///
/// Factored out of `BatchBuilder` so the store-backed load goes through
/// exactly one place that turns "some decoded activities" into a
/// `LoadedBatch` — mirroring `BatchOverviewModel`'s reasoning that there
/// should be exactly one place doing this kind of assembly.
enum BatchAssembler {
    /// One decoded activity paired explicitly with the descriptor
    /// `groupActivities` needs to place it in a session. Paired rather than
    /// re-derived from `file.fileName` — that round trip through a
    /// filename-shaped string is exactly the Phase 1 stopgap `groupActivities`
    /// replaces for every caller except `groupActivityFiles` itself (still the
    /// right entry point for filename-keyed callers like the preview
    /// fixture).
    struct Entry {
        var descriptor: ActivityDescriptor
        var file: LoadedFile
    }

    static func assemble(_ entries: [Entry]) -> LoadedBatch {
        let grouping = groupActivities(entries.map(\.descriptor))
        // Keyed by descriptor id — a `LibraryItem.id` for a store-backed
        // batch, not necessarily a real filename. `SessionFile.fileName`
        // carries the same id through (see `ActivityDescriptor`'s doc
        // comment), so this dictionary and `session.filesByDeviceKey`'s
        // values agree on what the key means.
        let filesByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.descriptor.id, $0.file) })

        var samplesById: [String: [Int: Int]] = [:]
        for entry in entries {
            samplesById[entry.descriptor.id] = heartRateBySecond(entry.file.activity.records)
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
                if let samples = samplesById[file.fileName] {
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
