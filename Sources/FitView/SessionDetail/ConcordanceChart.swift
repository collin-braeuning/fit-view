import Charts
import FitViewCore
import SwiftUI

/// Concordance scatter: one device's reading plotted against the other's,
/// with the line of equality (y = x) for reference. Points are pre-reduced to
/// a density cloud by `SessionDetailModel` for the same reason as
/// `BlandAltmanChart`.
struct ConcordanceChart: View {
    /// Height tracks width at this ratio rather than being fixed. A full-width
    /// plot of fixed height flattens the line of equality towards horizontal on
    /// a wide Mac window, which reads as far better agreement than the data
    /// shows; letting height grow with width keeps the line a legible diagonal.
    private static let plotAspectRatio: CGFloat = 1.35

    let data: ConcordancePlotData
    /// Caps how wide the plot grows in a scrolling detail column. `nil` lifts
    /// the cap for the fullscreen presentation, where the plot should use
    /// whatever the window gives it.
    var maxWidth: CGFloat? = 720

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
        .chartXAxisLabel(data.xAxisTitle, alignment: .center)
        .chartYAxisLabel(data.yAxisTitle, position: .leading, alignment: .center)
        .chartLegend(.hidden)
        // A square plot area used to be forced here so that y = x drew at a
        // literal 45°, but paired with a 460pt cap it stranded a small chart
        // on the leading edge of an iPad or Mac column. The equal x/y domains
        // are what actually matter: they keep y = x on the corner-to-corner
        // diagonal, so the cloud stays centred on the line of equality at any
        // aspect ratio — it simply isn't drawn at 45° any more.
        .aspectRatio(Self.plotAspectRatio, contentMode: .fit)
        .frame(maxWidth: maxWidth)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Concordance plot")
        .accessibilityValue(accessibilitySummary)
    }
}
