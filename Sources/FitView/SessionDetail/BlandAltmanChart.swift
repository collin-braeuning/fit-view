import Charts
import FitViewCore
import SwiftUI

/// Bland-Altman scatter: each matched pair's mean plotted against its signed
/// difference, with bias and the 95% limits of agreement drawn as reference
/// lines. Points are pre-reduced to a density cloud by `SessionDetailModel` —
/// a real session has thousands of matched seconds, and Swift Charts drawing
/// one `PointMark` per second is both slow and a solid blob.
struct BlandAltmanChart: View {
    let data: BlandAltmanPlotData
    var minHeight: CGFloat = 220

    private func weight(_ point: DensityPoint) -> Double {
        densityWeight(count: point.count, maxCount: data.cloud.maxCount)
    }

    /// Split into three `@ChartContentBuilder` properties — matching
    /// `HeartRateComparisonChart`'s convention — because one `Chart` mixing
    /// this many rule marks and a mark loop defeats the type checker.
    @ChartContentBuilder
    private var densityCloud: some ChartContent {
        ForEach(data.cloud.points) { point in
            PointMark(x: .value("Mean", point.x), y: .value("Difference", point.y))
                .symbol(.circle)
                .symbolSize(8 + weight(point) * 26)
                .foregroundStyle(Color.teal.opacity(0.18 + weight(point) * 0.62))
        }
    }

    /// Unlabelled — the y-axis already prints a 0 tick.
    @ChartContentBuilder
    private var zeroLine: some ChartContent {
        RuleMark(y: .value("Zero", 0))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            .foregroundStyle(Color.secondary.opacity(0.3))
    }

    /// Labelled with names only, never the numbers — the Bias and 95% LoA
    /// tiles above already show these figures; repeating them inside a
    /// phone-width plot is clutter for zero information. Left-aligned: the
    /// y-axis sits on the leading edge, so anchoring labels to the trailing
    /// edge crowded them against it — leading space is more open.
    @ChartContentBuilder
    private var referenceLines: some ChartContent {
        RuleMark(y: .value("Bias", data.bias))
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            .foregroundStyle(Color.primary.opacity(0.7))
            .annotation(
                position: .top,
                alignment: .leading,
                spacing: 2,
                overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .fit(to: .plot))
            ) {
                Text("bias").font(.caption2).foregroundStyle(.secondary)
            }
        RuleMark(y: .value("Upper LoA", data.upperLimit))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(Color.secondary)
            .annotation(
                position: .top,
                alignment: .leading,
                spacing: 2,
                overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .fit(to: .plot))
            ) {
                Text("+1.96 SD").font(.caption2).foregroundStyle(.secondary)
            }
        RuleMark(y: .value("Lower LoA", data.lowerLimit))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(Color.secondary)
            .annotation(
                position: .top,
                alignment: .leading,
                spacing: 2,
                overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .fit(to: .plot))
            ) {
                Text("−1.96 SD").font(.caption2).foregroundStyle(.secondary)
            }
    }

    private var accessibilitySummary: String {
        let bias = data.bias.formatted(.number.precision(.fractionLength(1)))
        let lower = data.lowerLimit.formatted(.number.precision(.fractionLength(1)))
        let upper = data.upperLimit.formatted(.number.precision(.fractionLength(1)))
        return "Bias \(bias) bpm, 95 percent limits \(lower) to \(upper) bpm, "
            + "\(data.cloud.totalCount.formatted()) matched pairs"
    }

    var body: some View {
        Chart {
            // Reference lines are drawn over the cloud — a bias line buried
            // under hundreds of semi-transparent dots is invisible.
            densityCloud
            zeroLine
            referenceLines
        }
        .chartXScale(domain: data.xDomain)
        .chartYScale(domain: data.yDomain)
        .chartXAxisLabel(data.xAxisTitle, alignment: .center)
        .chartYAxisLabel(data.yAxisTitle, position: .leading, alignment: .center)
        .chartLegend(.hidden)
        .frame(minHeight: minHeight)
        // Swift Charts emits one accessibility element per mark; without this,
        // ~1,300 density points would make the screen unnavigable via VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bland-Altman agreement plot")
        .accessibilityValue(accessibilitySummary)
    }
}
