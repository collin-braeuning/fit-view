import FitViewCore
import Testing
@testable import FitView

/// Covers `SessionDetailModel`'s mapping from a `(LoadedBatch, sessionId)` pair into everything
/// `SessionDetailView` renders — see specs/002-activity-detail/data-model.md and research.md §1.
/// Fixtures come from `SessionDetailPreviewFixture.makeBatch()` rather than a separate builder:
/// it already runs the real grouping/agreement pipeline and has a dedicated session for the
/// normal case and all four edge cases this spec documents (missing device, no overlap, too few
/// points, concordance un-computable — the last added in research.md §2/tasks.md T002).
@Suite("SessionDetailModel")
struct SessionDetailModelTests {
    @Test("a normal session (varying, non-constant HR on both devices) maps every field correctly")
    func normalSessionMapping() {
        let batch = SessionDetailPreviewFixture.makeBatch()
        let model = SessionDetailModel(batch: batch, sessionId: "2026-08-01|run")!

        #expect(model.agreement != nil)
        #expect(model.matchedSecondsText == "200")

        // Every paired reading differs by exactly 1 (130 + i%10 vs 131 + i%10), so bias and the
        // 95% limits of agreement collapse to a single value — this is Bland-Altman's degenerate
        // case, distinct from the concordance-un-computable case in constantValueSession() below.
        #expect(model.bias?.text == "-1.0 bpm")
        #expect(model.bias?.level == .good)
        #expect(model.loaText == "[-1.0, -1.0]")
        #expect(model.meanAbsDiff?.text == "1.0 bpm")
        #expect(model.meanAbsDiff?.level == .good)
        #expect(model.maxAbsDiffText == "1 bpm")

        // Values vary (130...139 vs 131...140), so concordance is computable even though the
        // difference is constant.
        #expect(model.ccc != nil)
        #expect(model.blandAltmanPlot != nil)
        #expect(model.concordancePlot != nil)

        #expect(model.deviceLabels == ["pace4", "polarSense"])
        #expect(model.deviceFacts.count == 2)
        #expect(!model.chartPoints.isEmpty)
        #expect(Set(model.chartPoints.map(\.device)) == Set(model.deviceLabels))

        // Every fixture session's `activity()` helper produces exactly one lap per device, so no
        // device ever has >1 lap to source dividers from.
        #expect(model.lapBoundaries.isEmpty)
        #expect(model.lapSourceLabel == nil)
    }

    @Test("per-device coverage detail formats percent and own-span text for a normal session")
    func deviceCoverageDetailFormatting() {
        let batch = SessionDetailPreviewFixture.makeBatch()
        let model = SessionDetailModel(batch: batch, sessionId: "2026-08-01|run")!

        #expect(model.coverageDetails.count == 2)
        for detail in model.coverageDetails {
            #expect(detail.percentText != "—")
            #expect(detail.percentText.hasSuffix("%"))
            #expect(detail.ownSpanText.contains("s recorded over a"))
            #expect(detail.ownSpanText.hasSuffix("s span"))
        }
    }

    @Test("a session where one device's file is missing entirely gets its own distinct skip banner")
    func missingDeviceSkip() {
        let batch = SessionDetailPreviewFixture.makeBatch()
        let model = SessionDetailModel(batch: batch, sessionId: "2026-08-04|run")!

        #expect(model.agreement == nil)
        #expect(model.deviceLabels.count == 1)
        #expect(model.deviceFacts.count == 1)
        #expect(model.coverageDetails.count == 1)
        #expect(model.startTimeDeltaText == nil)
        #expect(model.skipBannerText?.hasPrefix("No ") == true)
        #expect(model.skipBannerText?.hasSuffix("file for this date.") == true)
    }

    @Test("a session with no overlapping seconds gets a distinct skip banner from the other two skip reasons")
    func noOverlapSkip() {
        let batch = SessionDetailPreviewFixture.makeBatch()
        let model = SessionDetailModel(batch: batch, sessionId: "2026-08-02|run")!

        #expect(model.agreement == nil)
        #expect(model.deviceLabels.count == 2)
        #expect(model.startTimeDeltaText != nil)
        #expect(model.skipBannerText == "No overlapping seconds. These recordings never share a whole "
            + "second, so no agreement statistics can be computed.")
    }

    @Test("a session with too few matched seconds gets a distinct skip banner from the other two skip reasons")
    func tooFewPointsSkip() {
        let batch = SessionDetailPreviewFixture.makeBatch()
        let model = SessionDetailModel(batch: batch, sessionId: "2026-08-03|run")!

        #expect(model.agreement == nil)
        #expect(model.deviceLabels.count == 2)
        #expect(model.startTimeDeltaText != nil)
        #expect(model.skipBannerText == "Only 1 matched second between these recordings — "
            + "too few to compute agreement statistics.")
    }

    @Test("both devices reading an identical constant value: CCC is nil, but Bland-Altman (bias) is not")
    func constantValueSession() {
        let batch = SessionDetailPreviewFixture.makeBatch()
        let model = SessionDetailModel(batch: batch, sessionId: "2026-08-06|run")!

        // Enough overlap to clear minMatchedSeconds, so this is NOT a skip — unlike the three
        // skip-reason tests above, agreement is present here.
        #expect(model.agreement != nil)
        #expect(model.matchedSecondsText == "100")

        #expect(model.ccc == nil)
        #expect(model.concordancePlot == nil)

        #expect(model.bias?.text == "0.0 bpm")
        #expect(model.loaText == "[0.0, 0.0]")
        #expect(model.blandAltmanPlot != nil)
    }
}
