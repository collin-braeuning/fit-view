import SwiftUI

/// Generic fullscreen container shared by both agreement plots, mirroring
/// `FullScreenHeartRateChartView`'s structure. Deliberately not rotating the
/// view — the system's own orientation relayout already drives a correct
/// relayout here, and a second manual rotation on top of that would fight it,
/// for the same reasoning `FullScreenHeartRateChartView` documents.
struct FullScreenPlotView<Chart: View>: View {
    let title: String
    @ViewBuilder let chart: Chart

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            chart
        }
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
