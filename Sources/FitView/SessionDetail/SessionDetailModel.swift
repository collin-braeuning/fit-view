import FitViewCore
import Foundation

/// One chart sample, gap-segmented so Swift Charts never interpolates across
/// a dropout or an auto-pause — `segment` increments at every nil->value
/// transition in the source series, and `series:` in `HeartRateComparisonChart`
/// keeps each run as its own line.
struct HeartRatePoint: Identifiable {
    let id: Int
    let date: Date
    let bpm: Int
    let device: String
    let segment: String
}

struct DeviceFacts {
    var label: String
    var fileName: String
    var sport: String
    var startTime: Date
    var endTime: Date
    var recordCount: Int
    var lapCount: Int
    var avgHeartRate: Int
    var maxHeartRate: Int
}

/// Plain, SwiftUI-free presenter for the session detail screen — same spirit
/// as `BatchOverviewModel`. A pure function of `(LoadedBatch, sessionId)`.
struct SessionDetailModel {
    var sessionId: String
    var session: ActivitySession
    var formattedDate: String

    /// Present devices only, in [primary, secondary] order.
    var deviceLabels: [String]
    var deviceFacts: [DeviceFacts]

    var chartPoints: [HeartRatePoint]
    var chartYDomain: ClosedRange<Double>

    /// Non-nil for a normal session; nil for a skipped one.
    var agreement: SessionAgreement?
    var coverage: [DeviceCoverage]

    init?(batch: LoadedBatch, sessionId: String) {
        guard let session = batch.grouping.sessions.first(where: { $0.id == sessionId }) else { return nil }
        self.sessionId = sessionId
        self.session = session
        formattedDate = formatSessionDate(session.date)

        let orderedDeviceKeys = [batch.primaryDeviceKey, batch.secondaryDeviceKey]
        var devices: [DeviceRecords] = []
        var labels: [String] = []
        var facts: [DeviceFacts] = []
        for deviceKey in orderedDeviceKeys {
            guard let sessionFile = session.filesByDeviceKey[deviceKey],
                  let loaded = batch.filesByName[sessionFile.fileName]
            else { continue }

            let label = batch.deviceLabels[deviceKey] ?? deviceKey
            devices.append(DeviceRecords(deviceKey: deviceKey, records: loaded.activity.records))
            labels.append(label)
            facts.append(DeviceFacts(
                label: label,
                fileName: loaded.fileName,
                sport: loaded.activity.sport,
                startTime: loaded.activity.startTime,
                endTime: loaded.activity.endTime,
                recordCount: loaded.activity.totalRecords,
                lapCount: loaded.activity.laps.count,
                avgHeartRate: loaded.activity.avgHeartRate,
                maxHeartRate: loaded.activity.maxHeartRate
            ))
        }
        deviceLabels = labels
        deviceFacts = facts

        let timeline = buildComparisonTimeline(devices)

        var points: [HeartRatePoint] = []
        var yMin = Double.infinity
        var yMax = -Double.infinity
        var nextPointId = 0
        for series in timeline.heartRate {
            let label = batch.deviceLabels[series.deviceKey] ?? series.deviceKey
            var runIndex = 0
            var previousWasValue = false
            for (index, value) in series.values.enumerated() {
                guard let bpm = value else {
                    previousWasValue = false
                    continue
                }
                if !previousWasValue { runIndex += 1 }
                previousWasValue = true

                points.append(HeartRatePoint(
                    id: nextPointId,
                    date: Date(timeIntervalSince1970: Double(timeline.seconds[index])),
                    bpm: bpm,
                    device: label,
                    segment: "\(series.deviceKey)#\(runIndex)"
                ))
                nextPointId += 1
                yMin = min(yMin, Double(bpm))
                yMax = max(yMax, Double(bpm))
            }
        }
        chartPoints = points
        chartYDomain = yMin.isFinite ? (yMin - 5)...(yMax + 5) : 0...200

        let sessionAgreement = batch.agreement.sessions.first { $0.sessionId == sessionId }
        agreement = sessionAgreement
        if let sessionAgreement {
            coverage = sessionAgreement.coverage
        } else if devices.count == 2 {
            coverage = intersectHeartRate([
                DeviceSamples(deviceKey: devices[0].deviceKey, bySecond: heartRateBySecond(devices[0].records)),
                DeviceSamples(deviceKey: devices[1].deviceKey, bySecond: heartRateBySecond(devices[1].records)),
            ]).coverage
        } else {
            coverage = []
        }
    }
}
