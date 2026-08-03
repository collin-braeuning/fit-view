import Charts
import FitViewCore
import SwiftUI

/// Concordance scatter: one device's reading plotted against the other's,
/// with the line of equality (y = x) for reference. Points are pre-reduced to
/// a density cloud by `SessionDetailModel` for the same reason as
/// `BlandAltmanChart`.
struct ConcordanceChart: View {
    let data: ConcordancePlotData
    var minHeight: CGFloat = 220

    private func weight(_ point: DensityPoint) -> Double {
        densityWeight(count: point.count, maxCount: data.cloud.maxCount)
    }

    /// Swift Charts has no diagonal rule mark, so draw a two-point `LineMark`
    /// across the domain corners. Drawn first so the cloud sits on top — the
    /// story is "how tight is the cloud around the line".
    @ChartContentBuilder
    private var equalityLine: some ChartContent {
        ForEach([data.domain.lowerBound, data.domain.upperBound], id: \.self) { value in
            LineMark(x: .value("A", value), y: .value("B", value), series: .value("Series", "equality"))
        }
        .foregroundStyle(Color.secondary)
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .annotation(position: .topTrailing) {
            Text("y = x").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ChartContentBuilder
    private var densityCloud: some ChartContent {
        ForEach(data.cloud.points) { point in
            PointMark(x: .value("A", point.x), y: .value("B", point.y))
                .symbol(.circle)
                .symbolSize(8 + weight(point) * 26)
                .foregroundStyle(Color.teal.opacity(0.18 + weight(point) * 0.62))
        }
    }

    private var accessibilitySummary: String {
        "\(data.cloud.totalCount.formatted()) matched pairs, \(data.xAxisTitle) against \(data.yAxisTitle)"
    }

    var body: some View {
        Chart {
            equalityLine
            densityCloud
        }
        .chartXScale(domain: data.domain)
        .chartYScale(domain: data.domain)
        // Equal domains alone are not enough — without a square plot area the
        // line of equality renders at whatever angle the aspect ratio
        // dictates, and a 45° line that isn't 45° silently misleads.
        .chartPlotStyle { $0.aspectRatio(1, contentMode: .fit) }
        .chartXAxisLabel(data.xAxisTitle, alignment: .center)
        .chartYAxisLabel(data.yAxisTitle, position: .leading, alignment: .center)
        .chartLegend(.hidden)
        .frame(minHeight: minHeight)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Concordance plot")
        .accessibilityValue(accessibilitySummary)
    }
}
