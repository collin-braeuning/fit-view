import Charts
import SwiftUI

/// Heart-rate time series for a session, one line per device.
///
/// Swift Charts draws a straight line across an omitted mark, which would
/// silently interpolate through `pace4`'s auto-pauses and `polarSense`'s
/// early-start gap — exactly what overview.md §5 rule 2 forbids. The fix is
/// explicit segmentation: `SessionDetailModel` assigns each contiguous run of
/// real samples its own `segment`, and `series:` here keeps those runs from
/// joining up. `foregroundStyle(by:)` still groups by device, so the legend
/// shows one entry per device no matter how many segments exist.
struct HeartRateComparisonChart: View {
    let points: [HeartRatePoint]
    let deviceLabels: [String]
    let yDomain: ClosedRange<Double>
    /// Interior lap boundaries from the lap-recording device, drawn as vertical
    /// dividers behind the traces. See `SessionDetailModel.lapBoundaries`.
    var lapBoundaries: [Date] = []
    var minHeight: CGFloat = 240

    /// Pinned per-device colours, consistent between sessions. Not
    /// red/green — those already mean bad/good via `AgreementLevel`.
    private static let colors: [Color] = [.blue, .purple]

    /// Split out of `body` rather than inlined: one `Chart` builder holding
    /// both a `RuleMark` and a `LineMark` loop is enough mixed generic content
    /// that the type checker gives up on it ("unable to type-check this
    /// expression in reasonable time"). Naming each half's `ChartContent` type
    /// keeps inference local to it.
    @ChartContentBuilder
    private var lapDividers: some ChartContent {
        // Drawn before the traces so the HR lines sit over the dividers rather
        // than under them. Dashed and de-emphasised: a lap boundary is context
        // for reading the HR lines, never a value in its own right, and it must
        // not compete with either device's colour.
        ForEach(lapBoundaries, id: \.self) { boundary in
            RuleMark(x: .value("Lap", boundary))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.secondary.opacity(0.35))
        }
    }

    @ChartContentBuilder
    private var heartRateTraces: some ChartContent {
        ForEach(points) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Heart Rate", point.bpm),
                series: .value("Segment", point.segment)
            )
            .foregroundStyle(by: .value("Device", point.device))
            .interpolationMethod(.linear)
        }
    }

    var body: some View {
        Chart {
            lapDividers
            heartRateTraces
        }
        .chartForegroundStyleScale(
            domain: deviceLabels,
            range: Array(Self.colors.prefix(deviceLabels.count))
        )
        .chartXAxis {
            AxisMarks(format: .dateTime.hour().minute())
        }
        .chartYScale(domain: yDomain)
        .frame(minHeight: minHeight)
    }
}
