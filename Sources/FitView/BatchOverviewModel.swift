import FitViewCore
import Foundation

/// Plain, SwiftUI-free presentation model built once from a `BatchAgreement`.
///
/// Both the Mac table and the phone/iPad card list render from this so the two
/// layouts can never drift from each other, or from the pinned reference
/// numbers `FitViewCore`'s statistics are validated against — there is exactly
/// one place that turns a `SessionAgreement` into display strings.
struct BatchOverviewModel {
    var title: String
    var rows: [SessionRow]
    var skipped: [SkippedRow]

    init(agreement: BatchAgreement) {
        title = "\(agreement.primaryName) vs \(agreement.secondaryName)"
        rows = agreement.sessions
            .map { SessionRow(session: $0, agreement: agreement) }
            .sorted { $0.date > $1.date }
        skipped = agreement.skipped.map { SkippedRow(skipped: $0) }
    }
}

/// A formatted value paired with the agreement level it falls into, so a
/// consuming view has one thing to color/badge rather than re-deriving the
/// level from the raw number at every call site.
struct Metric {
    var text: String
    var level: AgreementLevel
}

/// One device's coverage detail for a session, formatted for both the
/// one-line table subtitle and the fuller card disclosure (which also shows
/// the own-seconds/span-seconds auto-pause diagnostic from overview.md §7).
struct DeviceCoverageDetail {
    var label: String
    var percentText: String
    var ownSpanText: String
}

struct SessionRow: Identifiable {
    var id: String { sessionId }
    var sessionId: String
    var date: String
    var formattedDate: String
    var activity: String

    var matchedSecondsText: String
    var hrRangeText: String

    var primaryCoverage: DeviceCoverageDetail
    var secondaryCoverage: DeviceCoverageDetail
    /// "pace4 100% · polarSense 78%" — the table's one-line subtitle.
    var coverageSummary: String

    var bias: Metric?
    var loaText: String?
    var meanAbsDiff: Metric
    var maxAbsDiffText: String

    var ccc: Metric?
    /// McBride's wording (e.g. "substantial") — a non-color signal for the
    /// same level, since color alone doesn't work for color-vision
    /// deficiency or (today, via `.help()`) on touch.
    var cccWord: String?
    /// Combines the CCC value with the HR range it was measured over into one
    /// sentence, so VoiceOver never reads a decontextualized CCC number —
    /// overview.md §7 is emphatic that a CCC is only interpretable next to
    /// its HR range.
    var cccAccessibilityLabel: String

    init(session: SessionAgreement, agreement: BatchAgreement) {
        sessionId = session.sessionId
        date = session.date
        formattedDate = formatSessionDate(session.date)
        activity = session.activity

        matchedSecondsText = session.matchedSeconds.formatted()
        hrRangeText = "\(Int(session.hrRange.min))–\(Int(session.hrRange.max)) bpm"

        let primaryDeviceCoverage = session.coverage.first
        let secondaryDeviceCoverage = session.coverage.count > 1 ? session.coverage[1] : nil
        primaryCoverage = DeviceCoverageDetail(
            label: agreement.primaryName,
            percentText: Self.formatPercent(primaryDeviceCoverage?.coverage),
            ownSpanText: Self.formatOwnSpan(primaryDeviceCoverage)
        )
        secondaryCoverage = DeviceCoverageDetail(
            label: agreement.secondaryName,
            percentText: Self.formatPercent(secondaryDeviceCoverage?.coverage),
            ownSpanText: Self.formatOwnSpan(secondaryDeviceCoverage)
        )
        coverageSummary = "\(primaryCoverage.label) \(primaryCoverage.percentText) · "
            + "\(secondaryCoverage.label) \(secondaryCoverage.percentText)"

        if let blandAltman = session.blandAltman {
            bias = Metric(
                text: "\(Self.decimal(blandAltman.meanDiff, places: 1)) bpm",
                level: differenceLevel(abs(blandAltman.meanDiff))
            )
            loaText = "[\(Self.decimal(blandAltman.lowerLimit, places: 1)), "
                + "\(Self.decimal(blandAltman.upperLimit, places: 1))]"
        } else {
            bias = nil
            loaText = nil
        }

        meanAbsDiff = Metric(
            text: "\(Self.decimal(session.difference.avgAbsDiff, places: 1)) bpm",
            level: differenceLevel(session.difference.avgAbsDiff)
        )
        maxAbsDiffText = "\(Int(session.difference.maxAbsDiff)) bpm"

        if let concordance = session.concordance {
            let level = cccLevel(concordance.ccc)
            ccc = Metric(text: Self.decimal(concordance.ccc, places: 3), level: level)
            cccWord = cccLabel(concordance.ccc)
            cccAccessibilityLabel = "CCC \(Self.decimal(concordance.ccc, places: 3)), "
                + "\(cccLabel(concordance.ccc)) agreement, measured over "
                + "\(Int(session.hrRange.min)) to \(Int(session.hrRange.max)) beats per minute"
        } else {
            ccc = nil
            cccWord = nil
            cccAccessibilityLabel = "No CCC available — both devices read a constant value "
                + "over \(Int(session.hrRange.min)) to \(Int(session.hrRange.max)) beats per minute"
        }
    }

    private static func formatPercent(_ coverage: Double?) -> String {
        guard let coverage else { return "—" }
        return "\(Int((coverage * 100).rounded()))%"
    }

    private static func formatOwnSpan(_ coverage: DeviceCoverage?) -> String {
        guard let coverage else { return "—" }
        return "\(coverage.ownSeconds.formatted())s recorded over a "
            + "\(coverage.spanSeconds.formatted())s span"
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", value)
    }
}

struct SkippedRow: Identifiable {
    var id: String { sessionId }
    var sessionId: String
    var formattedDate: String
    var activity: String
    var reasonText: String

    init(skipped: SkippedSession) {
        sessionId = skipped.sessionId
        formattedDate = formatSessionDate(skipped.date)
        // `sessionId` is "\(date)|\(activityKey)" (see ActivitySessions.swift) —
        // `SkippedSession` itself carries no display-cased activity name, so
        // this recovers the (lower-cased) key rather than inventing a field
        // on the core model.
        let parts = skipped.sessionId.split(separator: "|", maxSplits: 1)
        activity = parts.count > 1 ? String(parts[1]) : ""
        reasonText = switch skipped.reason {
        case .noOverlap: "no overlapping seconds between the two devices"
        case .tooFewPoints: "too few matched seconds to compute agreement"
        }
    }
}
