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
    var startTimeText: String
    var endTimeText: String
    var recordCount: Int
    var lapCount: Int
    var avgHeartRate: Int
    var maxHeartRate: Int
}

private func decimal(_ value: Double, places: Int) -> String {
    String(format: "%.\(places)f", value)
}

private let deviceFactTimeFormat = Date.FormatStyle().hour().minute().second()

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
    /// Where to draw lap divider lines on the chart, bucketed to whole seconds
    /// so they land on the same axis as `chartPoints`. Interior boundaries
    /// only — the first lap starts at the chart's left edge, where a rule would
    /// just double the plot border.
    var lapBoundaries: [Date]
    /// The device `lapBoundaries` came from, for the chart's caption. Nil when
    /// no device in this session recorded more than one lap.
    var lapSourceLabel: String?

    /// Non-nil for a normal session; nil for a skipped one.
    var agreement: SessionAgreement?
    var coverage: [DeviceCoverage]
    var coverageDetails: [DeviceCoverageDetail]

    /// All nil when `agreement` is nil (skipped session — no stats to show).
    var matchedSecondsText: String?
    var hrRangeText: String?
    var bias: Metric?
    var loaText: String?
    var meanAbsDiff: Metric?
    var maxAbsDiffText: String?
    var ccc: Metric?
    /// "substantial · 90–173 bpm" — CCC's McBride word plus the HR range it
    /// was measured over, kept together per overview.md §7.
    var cccDetailText: String?

    /// Non-nil only for a skipped session — explains why the stats grid is
    /// replaced with a banner instead of numbers.
    var skipBannerText: String?
    /// "first sample 17:06:53 vs 17:00:41 — 6:12 apart" — with no clock-offset
    /// correction anywhere in the app, the start-time gap often *is* the
    /// explanation for a skip, so it's shown next to the banner.
    var startTimeDeltaText: String?

    init?(batch: LoadedBatch, sessionId: String) {
        guard let session = batch.grouping.sessions.first(where: { $0.id == sessionId }) else { return nil }
        self.sessionId = sessionId
        self.session = session
        formattedDate = formatSessionDate(session.date)

        let orderedDeviceKeys = [batch.primaryDeviceKey, batch.secondaryDeviceKey]
        var devices: [DeviceRecords] = []
        var labels: [String] = []
        var facts: [DeviceFacts] = []
        var lapsByDevice: [(label: String, laps: [FitLap])] = []
        for deviceKey in orderedDeviceKeys {
            guard let sessionFile = session.filesByDeviceKey[deviceKey],
                  let loaded = batch.filesByName[sessionFile.fileName]
            else { continue }

            let label = batch.deviceLabels[deviceKey] ?? deviceKey
            devices.append(DeviceRecords(deviceKey: deviceKey, records: loaded.activity.records))
            labels.append(label)
            lapsByDevice.append((label: label, laps: loaded.activity.laps))
            facts.append(DeviceFacts(
                label: label,
                fileName: loaded.fileName,
                sport: loaded.activity.sport,
                startTimeText: loaded.activity.startTime.formatted(deviceFactTimeFormat),
                endTimeText: loaded.activity.endTime.formatted(deviceFactTimeFormat),
                recordCount: loaded.activity.totalRecords,
                lapCount: loaded.activity.laps.count,
                avgHeartRate: loaded.activity.avgHeartRate,
                maxHeartRate: loaded.activity.maxHeartRate
            ))
        }
        deviceLabels = labels
        deviceFacts = facts

        // Lap lines come from one device, not both. The two devices lap
        // independently — polarSense writes a single lap spanning the entire
        // run, pace4 auto-laps every kilometre — so overlaying both would mean
        // drawing one meaningless rule at the start on top of the real
        // divisions. Most laps wins, which picks the device that actually
        // recorded them. `lapsByDevice` is built in [primary, secondary]
        // order and the comparison is strict, so a tie keeps the primary and
        // the choice can't flip between loads (same reasoning as the
        // deterministic device ranking in `groupActivities`).
        var lapSource: (label: String, laps: [FitLap])?
        for candidate in lapsByDevice where candidate.laps.count > (lapSource?.laps.count ?? 0) {
            lapSource = candidate
        }
        let boundaries = (lapSource?.laps ?? [])
            .map(\.startTime)
            .sorted()
            .dropFirst()
            .map { Date(timeIntervalSince1970: Double(secondBucket(for: $0))) }
        lapBoundaries = boundaries
        lapSourceLabel = boundaries.isEmpty ? nil : lapSource?.label

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
        var matchedSecondsWhenSkipped: Int?
        if let sessionAgreement {
            coverage = sessionAgreement.coverage
        } else if devices.count == 2 {
            let aligned = intersectHeartRate([
                DeviceSamples(deviceKey: devices[0].deviceKey, bySecond: heartRateBySecond(devices[0].records)),
                DeviceSamples(deviceKey: devices[1].deviceKey, bySecond: heartRateBySecond(devices[1].records)),
            ])
            coverage = aligned.coverage
            matchedSecondsWhenSkipped = aligned.seconds.count
        } else {
            coverage = []
        }

        var coverageByDeviceKey: [String: DeviceCoverage] = [:]
        for entry in coverage { coverageByDeviceKey[entry.deviceKey] = entry }
        coverageDetails = zip(devices, labels).map { device, label in
            let own = coverageByDeviceKey[device.deviceKey]
            return DeviceCoverageDetail(
                label: label,
                percentText: own.map { "\(Int(($0.coverage * 100).rounded()))%" } ?? "—",
                ownSpanText: own.map { "\($0.ownSeconds.formatted())s recorded over a \($0.spanSeconds.formatted())s span" } ?? "—"
            )
        }

        if let sessionAgreement {
            matchedSecondsText = sessionAgreement.matchedSeconds.formatted()
            hrRangeText = "\(Int(sessionAgreement.hrRange.min))–\(Int(sessionAgreement.hrRange.max)) bpm"

            if let blandAltman = sessionAgreement.blandAltman {
                bias = Metric(
                    text: "\(decimal(blandAltman.meanDiff, places: 1)) bpm",
                    level: differenceLevel(abs(blandAltman.meanDiff))
                )
                loaText = "[\(decimal(blandAltman.lowerLimit, places: 1)), \(decimal(blandAltman.upperLimit, places: 1))]"
            }

            meanAbsDiff = Metric(
                text: "\(decimal(sessionAgreement.difference.avgAbsDiff, places: 1)) bpm",
                level: differenceLevel(sessionAgreement.difference.avgAbsDiff)
            )
            maxAbsDiffText = "\(Int(sessionAgreement.difference.maxAbsDiff)) bpm"

            if let concordance = sessionAgreement.concordance {
                let level = cccLevel(concordance.ccc)
                ccc = Metric(text: decimal(concordance.ccc, places: 3), level: level)
                cccDetailText = "\(cccLabel(concordance.ccc)) · \(hrRangeText ?? "")"
            }
        } else {
            // A broken join should be visible, not quietly hidden: distinguish
            // "only one file exists" (undetectable from BatchAgreement alone —
            // it also lands in `.skipped` as `.noOverlap`) from a genuine
            // no-overlap or too-few-points skip using `grouping`.
            if orderedDeviceKeys.contains(where: { session.filesByDeviceKey[$0] == nil }) {
                let missingKey = orderedDeviceKeys.first { session.filesByDeviceKey[$0] == nil }!
                let missingLabel = batch.deviceLabels[missingKey] ?? missingKey
                skipBannerText = "No \(missingLabel) file for this date."
            } else if let matchedSecondsWhenSkipped, matchedSecondsWhenSkipped > 0 {
                skipBannerText = "Only \(matchedSecondsWhenSkipped) matched "
                    + "second\(matchedSecondsWhenSkipped == 1 ? "" : "s") between these recordings — "
                    + "too few to compute agreement statistics."
            } else {
                skipBannerText = "No overlapping seconds. These recordings never share a whole "
                    + "second, so no agreement statistics can be computed."
            }

            if devices.count == 2,
               let firstA = devices[0].records.first?.timestamp,
               let firstB = devices[1].records.first?.timestamp {
                let deltaSeconds = Int(abs(firstA.timeIntervalSince(firstB)).rounded())
                let deltaText = "\(deltaSeconds / 60):\(String(format: "%02d", deltaSeconds % 60))"
                startTimeDeltaText = "first sample \(firstA.formatted(deviceFactTimeFormat)) vs "
                    + "\(firstB.formatted(deviceFactTimeFormat)) — \(deltaText) apart"
            }
        }
    }
}
