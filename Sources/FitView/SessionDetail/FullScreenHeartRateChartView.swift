import SwiftUI

/// Full-screen presentation of `HeartRateComparisonChart`.
///
/// This intentionally does *not* fake a landscape layout by rotating the
/// view with `.rotationEffect` — the device's real orientation change
/// already drives a relayout here (confirmed by the fact that physically
/// rotating the device visibly reflows this screen), so a second, manual
/// rotation on top of that fights the system one: it broke the scrub
/// tooltip's touch coordinates and produced a visible flicker as the two
/// rotations landed at slightly different times. Letting the system handle
/// it means turning the device sideways gets a wide chart with correct
/// safe-area insets and working gestures, for free.
struct FullScreenHeartRateChartView: View {
    let points: [HeartRatePoint]
    let deviceLabels: [String]
    let yDomain: ClosedRange<Double>
    let lapBoundaries: [Date]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HeartRateComparisonChart(
            points: points,
            deviceLabels: deviceLabels,
            yDomain: yDomain,
            lapBoundaries: lapBoundaries,
            // Full-screen, there's no page content above the chart for the
            // tooltip to overflow into — keep it inside the chart's bounds
            // so it can't render off the top of the screen.
            constrainsTooltipToChart: true
        )
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay(alignment: .topTrailing) {
            closeButton
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding()
    }
}
