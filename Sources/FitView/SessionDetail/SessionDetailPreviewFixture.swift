#if DEBUG
import FitViewCore
import Foundation

/// A synthetic `LoadedBatch` covering the skipped-session cases the bundled
/// sample corpus can't — it has 16 files across 8 complete date pairs, so
/// none of them are actually skipped. Runs the real grouping/agreement
/// pipeline (not hand-built `BatchAgreement` objects) over made-up records,
/// so it exercises the same code path `BatchBuilder` does.
enum SessionDetailPreviewFixture {
    static func makeBatch() -> LoadedBatch {
        func record(_ secondOffset: Int, heartRate: Int) -> FitRecord {
            FitRecord(timestamp: Date(timeIntervalSince1970: Double(secondOffset)), heartRate: heartRate)
        }

        func activity(records: [FitRecord]) -> FitActivity {
            let start = records.first!.timestamp
            let end = records.last!.timestamp
            let heartRates = records.compactMap(\.heartRate)
            let avg = heartRates.isEmpty ? 0 : heartRates.reduce(0, +) / heartRates.count
            return FitActivity(
                sport: "running",
                subSport: "generic",
                startTime: start,
                endTime: end,
                avgHeartRate: avg,
                maxHeartRate: heartRates.max() ?? 0,
                laps: [FitLap(
                    startTime: start,
                    endTime: end,
                    elapsedSeconds: end.timeIntervalSince(start),
                    distance: 5,
                    avgHeartRate: avg,
                    maxHeartRate: heartRates.max() ?? 0,
                    minHeartRate: heartRates.min() ?? 0,
                    avgSpeed: 10,
                    maxSpeed: 12,
                    avgCadence: 80,
                    maxCadence: 90,
                    totalAscent: 10,
                    totalDescent: 10,
                    calories: 300,
                    records: records
                )]
            )
        }

        // Normal session: overlapping, agreeing HR — a baseline to compare against.
        let normalPrimary = (0..<200).map { record($0, heartRate: 130 + $0 % 10) }
        let normalSecondary = (0..<200).map { record($0, heartRate: 131 + $0 % 10) }

        // (a) .noOverlap, both files present: entirely disjoint time ranges.
        let noOverlapPrimary = (0..<100).map { record($0, heartRate: 120) }
        let noOverlapSecondary = (1000..<1100).map { record($0, heartRate: 122) }

        // (b) .tooFewPoints: exactly one shared second (minMatchedSeconds is 2).
        let fewPrimary = (0..<50).map { record($0, heartRate: 110) }
        let fewSecondary = (49..<99).map { record($0, heartRate: 112) }

        // (c) missing device: only the primary has a file at all.
        let missingPrimary = (0..<150).map { record($0, heartRate: 140) }

        let activitiesByFileName: [String: FitActivity] = [
            "2026-08-01_pace4_run": activity(records: normalPrimary),
            "2026-08-01_polarSense_run": activity(records: normalSecondary),
            "2026-08-02_pace4_run": activity(records: noOverlapPrimary),
            "2026-08-02_polarSense_run": activity(records: noOverlapSecondary),
            "2026-08-03_pace4_run": activity(records: fewPrimary),
            "2026-08-03_polarSense_run": activity(records: fewSecondary),
            "2026-08-04_pace4_run": activity(records: missingPrimary),
        ]

        let filesByName = Dictionary(uniqueKeysWithValues: activitiesByFileName.map { fileName, activity in
            (fileName, LoadedFile(fileName: fileName, activity: activity))
        })

        let grouping = groupActivityFiles(Array(activitiesByFileName.keys))

        var samplesByName: [String: [Int: Int]] = [:]
        for (fileName, file) in filesByName {
            samplesByName[fileName] = heartRateBySecond(file.activity.records)
        }

        let sessions = grouping.sessions.map { session -> BatchAgreementInput.SessionSamples in
            var samplesByDeviceKey: [String: [Int: Int]] = [:]
            for (deviceKey, file) in session.filesByDeviceKey {
                if let samples = samplesByName[file.fileName] {
                    samplesByDeviceKey[deviceKey] = samples
                }
            }
            return BatchAgreementInput.SessionSamples(session: session, samplesByDeviceKey: samplesByDeviceKey)
        }

        let deviceLabels = Dictionary(uniqueKeysWithValues: grouping.devices.map { ($0.key, $0.label) })

        let input = BatchAgreementInput(
            sessions: sessions,
            primaryDeviceKey: "pace4",
            secondaryDeviceKey: "polarsense",
            deviceLabels: deviceLabels
        )

        return LoadedBatch(
            agreement: buildBatchAgreement(input),
            grouping: grouping,
            filesByName: filesByName,
            primaryDeviceKey: "pace4",
            secondaryDeviceKey: "polarsense",
            deviceLabels: deviceLabels
        )
    }
}
#endif
