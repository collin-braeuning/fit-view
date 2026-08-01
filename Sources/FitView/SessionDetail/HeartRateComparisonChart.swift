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
    var minHeight: CGFloat = 240

    /// Pinned per-device colours, consistent between sessions. Not
    /// red/green — those already mean bad/good via `AgreementLevel`.
    private static let colors: [Color] = [.blue, .purple]

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Heart Rate", point.bpm),
                series: .value("Segment", point.segment)
            )
            .foregroundStyle(by: .value("Device", point.device))
            .interpolationMethod(.linear)
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
