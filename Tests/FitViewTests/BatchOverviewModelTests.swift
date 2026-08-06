import FitViewCore
import Testing
@testable import FitView

/// Covers `BatchOverviewModel`'s mapping from a `BatchAgreement` into the
/// `SessionRow`/`SkippedRow` display values both the card and table layouts
/// render — see specs/001-activity-list/data-model.md and research.md §1.
@Suite("BatchOverviewModel")
struct BatchOverviewModelTests {
    @Test("a full session (both Bland-Altman and CCC present) maps every headline field correctly")
    func fullSessionMapping() {
        let agreement = AgreementFixtures.batch(
            date: "2026-07-23",
            primarySamples: [0: 100, 1: 102, 2: 104, 3: 106, 4: 108],
            secondarySamples: [0: 98, 1: 100, 2: 102, 3: 104, 4: 106]
        )
        let row = BatchOverviewModel(agreement: agreement).rows.first!

        #expect(row.matchedSecondsText == "5")
        #expect(row.hrRangeText == "98–108 bpm")

        #expect(row.bias?.text == "2.0 bpm")
        #expect(row.bias?.level == .good)
        #expect(row.loaText == "[2.0, 2.0]")
        #expect(row.meanAbsDiff.text == "2.0 bpm")
        #expect(row.meanAbsDiff.level == .good)
        #expect(row.maxAbsDiffText == "2 bpm")

        #expect(row.ccc?.text == "0.800")
        #expect(row.ccc?.level == .bad)
        #expect(row.cccWord == "poor")
        #expect(row.cccAccessibilityLabel == "CCC 0.800, poor agreement, measured over 98 to 108 beats per minute")
    }

    @Test("both devices reading an identical constant value: CCC is nil, but Bland-Altman (bias) is not")
    func nilConcordanceFallback() {
        // Denominator of CCC (varX + varY + (meanX-meanY)^2) is zero only when
        // both series are the same constant — calculateConcordanceStats returns
        // nil for exactly that case. Bland-Altman has no equivalent nil case for
        // paired, non-empty input, so bias stays populated (bias 0, LoA [0, 0]).
        let agreement = AgreementFixtures.batch(
            date: "2026-07-24",
            primarySamples: [0: 100, 1: 100],
            secondarySamples: [0: 100, 1: 100]
        )
        let row = BatchOverviewModel(agreement: agreement).rows.first!

        #expect(row.ccc == nil)
        #expect(row.cccWord == nil)
        #expect(
            row.cccAccessibilityLabel
                == "No CCC available — both devices read a constant value over 100 to 100 beats per minute"
        )

        #expect(row.bias?.text == "0.0 bpm")
        #expect(row.bias?.level == .good)
        #expect(row.loaText == "[0.0, 0.0]")
    }

    @Test("skipped sessions carry the right reason text for both SkippedSession.Reason cases")
    func skippedReasonText() {
        let agreement = AgreementFixtures.batch([
            .init(date: "2026-07-25", primarySamples: [0: 100, 1: 101], secondarySamples: [10: 90, 11: 91]),
            .init(date: "2026-07-26", primarySamples: [0: 100, 1: 101], secondarySamples: [0: 100, 2: 99]),
        ])
        let model = BatchOverviewModel(agreement: agreement)

        #expect(model.rows.isEmpty)
        #expect(model.skipped.count == 2)
        #expect(model.skipped[0].reasonText == "no overlapping seconds between the two devices")
        #expect(model.skipped[0].formattedDate == formatSessionDate("2026-07-25"))
        #expect(model.skipped[0].activity == "run")
        #expect(model.skipped[1].reasonText == "too few matched seconds to compute agreement")
    }

    @Test("title formats as \"primary vs secondary\", and rows sort by date descending")
    func titleAndSortOrder() {
        let agreement = AgreementFixtures.batch([
            .init(date: "2026-07-23", primarySamples: [0: 100, 1: 102, 2: 104, 3: 106, 4: 108],
                  secondarySamples: [0: 98, 1: 100, 2: 102, 3: 104, 4: 106]),
            .init(date: "2026-07-30", primarySamples: [0: 110, 1: 112], secondarySamples: [0: 108, 1: 110]),
        ])
        let model = BatchOverviewModel(agreement: agreement)

        #expect(model.title == "pace4 vs polarSense")
        #expect(model.rows.map(\.date) == ["2026-07-30", "2026-07-23"])
    }

    @Test("per-device coverage detail formats percent and own-span text")
    func deviceCoverageDetailFormatting() {
        let agreement = AgreementFixtures.batch(
            date: "2026-07-23",
            primarySamples: [0: 100, 1: 102, 2: 104, 3: 106, 4: 108],
            secondarySamples: [0: 98, 1: 100, 2: 102, 3: 104, 4: 106]
        )
        let row = BatchOverviewModel(agreement: agreement).rows.first!

        #expect(row.primaryCoverage.label == "pace4")
        #expect(row.primaryCoverage.percentText == "100%")
        #expect(row.primaryCoverage.ownSpanText == "5s recorded over a 5s span")

        #expect(row.secondaryCoverage.label == "polarSense")
        #expect(row.secondaryCoverage.percentText == "100%")
        #expect(row.secondaryCoverage.ownSpanText == "5s recorded over a 5s span")

        #expect(row.coverageSummary == "pace4 100% · polarSense 100%")
    }
}
