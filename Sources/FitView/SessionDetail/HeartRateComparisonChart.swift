import Charts
import SwiftUI

/// A device's reading at the scrubbed second, or nil if that device has a
/// gap there. Kept distinct from `HeartRatePoint` so the tooltip can show a
/// fixed row per device — including a "-" row — without needing a real
/// sample to exist.
private struct ScrubReading: Identifiable {
    var id: String { device }
    let device: String
    let bpm: Int?
}

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
    /// Whether the scrub tooltip must stay within the chart's own bounds
    /// vertically. Embedded in the scrollable session page, the chart is
    /// compact and there's page content above it, so letting the tooltip
    /// overflow above the plot (the default) looks better than squeezing it
    /// inside a short chart. Full-screen, there's nothing above the chart to
    /// overflow into — off the top edge there just means off the screen —
    /// so that presentation opts into constraining it.
    var constrainsTooltipToChart: Bool = false

    /// Drag/hover position while scrubbing, in chart-plot coordinates. Nil
    /// when nothing is being scrubbed.
    @State private var selectedDate: Date?

    /// Pinned per-device colours, consistent between sessions. Not
    /// red/green — those already mean bad/good via `AgreementLevel`.
    private static let colors: [Color] = [.blue, .purple]

    /// One row per device at the exact second under the cursor — not the
    /// closest sample in time. A device with a gap at that second reads nil
    /// (shown as "-") rather than snapping to some other, possibly distant,
    /// sample; the row count is always `deviceLabels.count`, so the tooltip
    /// doesn't grow or shrink as the cursor crosses gaps.
    private var selectedReadings: [ScrubReading] {
        guard let selectedDate else { return [] }
        let rounded = roundedToSecond(selectedDate)
        var bpmByDevice: [String: Int] = [:]
        for point in points where point.date == rounded {
            bpmByDevice[point.device] = point.bpm
        }
        return deviceLabels.map { ScrubReading(device: $0, bpm: bpmByDevice[$0]) }
    }

    /// The actual samples (if any) at the exact second under the cursor, for
    /// drawing point marks on the chart. Unlike `selectedReadings`, devices
    /// with no sample at that second are simply absent — there's nothing to
    /// plot for them.
    private var selectedPoints: [HeartRatePoint] {
        guard let selectedDate else { return [] }
        let rounded = roundedToSecond(selectedDate)
        return points.filter { $0.date == rounded }
    }

    private func roundedToSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
    }

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

    /// The scrub cursor and the per-device readings it's pointing at. Drawn
    /// last so it sits on top of both the traces and the lap dividers.
    @ChartContentBuilder
    private var scrubbingMarks: some ChartContent {
        if let selectedDate {
            RuleMark(x: .value("Selected", selectedDate))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(Color.secondary)
                .annotation(
                    position: .top,
                    alignment: .leading,
                    spacing: 8,
                    // x is always kept within the chart's bounds — without
                    // it, an overflowing annotation isn't clipped, so it
                    // grows the chart's natural layout size, making the
                    // x-axis look like it extends past the actual data.
                    // y is caller-controlled: see `constrainsTooltipToChart`.
                    overflowResolution: AnnotationOverflowResolution(
                        x: .fit(to: .chart),
                        y: constrainsTooltipToChart ? .fit(to: .chart) : .disabled
                    )
                ) {
                    scrubTooltip
                }
            ForEach(selectedPoints) { point in
                PointMark(
                    x: .value("Time", point.date),
                    y: .value("Heart Rate", point.bpm)
                )
                .foregroundStyle(by: .value("Device", point.device))
                .symbolSize(60)
            }
        }
    }

    private func color(forDevice device: String) -> Color {
        guard let index = deviceLabels.firstIndex(of: device) else { return .primary }
        return Self.colors[index % Self.colors.count]
    }

    private var scrubTooltip: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let selectedDate {
                Text(roundedToSecond(selectedDate), format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(selectedReadings) { reading in
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(forDevice: reading.device))
                        .frame(width: 6, height: 6)
                    // Lower priority than the reading below: if the row is
                    // too narrow to fit both on one line (a squeezed
                    // annotation near the chart edge, or large Dynamic
                    // Type), the device name truncates before the reading
                    // is allowed to wrap.
                    Text(reading.device)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .layoutPriority(0)
                    Spacer(minLength: 8)
                    // Only wraps to a second line if truncating the device
                    // name above still isn't enough room.
                    Text(reading.bpm.map { "\($0) bpm" } ?? "-")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 44, alignment: .trailing)
                        .layoutPriority(1)
                }
            }
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 2)
        // Annotation alignment is .leading, which pins this view's leading
        // edge exactly at the cursor's x-position — `spacing:` on the
        // annotation only offsets vertically (position: .top), so this is
        // the only way to keep the card off the scrubbed point horizontally.
        .padding(.leading, 12)
    }

    var body: some View {
        Chart {
            lapDividers
            heartRateTraces
            scrubbingMarks
        }
        .chartForegroundStyleScale(
            domain: deviceLabels,
            range: Array(Self.colors.prefix(deviceLabels.count))
        )
        .chartXAxis {
            // No AxisGridLine() here: the only vertical lines on this chart
            // should be the lap dividers above, not Swift Charts' default
            // evenly-spaced gridlines.
            AxisMarks { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYScale(domain: yDomain)
        .frame(minHeight: minHeight)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                updateSelection(at: value.location, proxy: proxy, geometry: geometry)
                            }
                            .onEnded { _ in selectedDate = nil }
                    )
                    #if os(macOS)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateSelection(at: location, proxy: proxy, geometry: geometry)
                        case .ended:
                            selectedDate = nil
                        }
                    }
                    #endif
            }
        }
    }

    private func updateSelection(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else {
            selectedDate = nil
            return
        }
        let plotArea = geometry[plotFrame]
        let xPosition = location.x - plotArea.origin.x
        guard xPosition >= 0, xPosition <= plotArea.width,
              let date: Date = proxy.value(atX: xPosition)
        else {
            selectedDate = nil
            return
        }
        selectedDate = date
    }
}
