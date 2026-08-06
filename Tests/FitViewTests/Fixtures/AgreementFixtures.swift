import FitViewCore
import Foundation

/// Builds `BatchAgreement` fixtures through the real `groupActivities` +
/// `buildBatchAgreement` pipeline, rather than constructing `SessionAgreement`/
/// `SkippedSession`/`ActivitySession` directly — those initializers are internal
/// to `FitViewCore`, not visible from this target, and going through the real
/// pipeline exercises the same alignment/statistics code production does.
enum AgreementFixtures {
    static let primaryDeviceKey = "pace4"
    static let primaryDeviceName = "pace4"
    static let secondaryDeviceKey = "polarsense"
    static let secondaryDeviceName = "polarSense"

    struct SessionSpec {
        var date: String
        var activity: String = "run"
        /// second -> bpm, per device.
        var primarySamples: [Int: Int]
        var secondarySamples: [Int: Int]
    }

    static func batch(_ specs: [SessionSpec]) -> BatchAgreement {
        let sessionSamples = specs.map { spec -> BatchAgreementInput.SessionSamples in
            let primary = ActivityDescriptor(
                id: "\(spec.date)_\(primaryDeviceName)_\(spec.activity)",
                date: spec.date, device: primaryDeviceName, deviceKey: primaryDeviceKey,
                activity: spec.activity, activityKey: spec.activity
            )
            let secondary = ActivityDescriptor(
                id: "\(spec.date)_\(secondaryDeviceName)_\(spec.activity)",
                date: spec.date, device: secondaryDeviceName, deviceKey: secondaryDeviceKey,
                activity: spec.activity, activityKey: spec.activity
            )
            // Same date + activityKey on both descriptors merges them into one
            // ActivitySession carrying both device keys (groupActivities'
            // groupByDateAndActivityKey path).
            let session = groupActivities([primary, secondary]).sessions.first!
            return BatchAgreementInput.SessionSamples(
                session: session,
                samplesByDeviceKey: [
                    primaryDeviceKey: spec.primarySamples,
                    secondaryDeviceKey: spec.secondarySamples,
                ]
            )
        }

        let input = BatchAgreementInput(
            sessions: sessionSamples,
            primaryDeviceKey: primaryDeviceKey,
            secondaryDeviceKey: secondaryDeviceKey,
            deviceLabels: [primaryDeviceKey: primaryDeviceName, secondaryDeviceKey: secondaryDeviceName]
        )
        return buildBatchAgreement(input)
    }

    static func batch(
        date: String = "2026-07-23", activity: String = "run",
        primarySamples: [Int: Int], secondarySamples: [Int: Int]
    ) -> BatchAgreement {
        batch([SessionSpec(date: date, activity: activity, primarySamples: primarySamples, secondarySamples: secondarySamples)])
    }
}
