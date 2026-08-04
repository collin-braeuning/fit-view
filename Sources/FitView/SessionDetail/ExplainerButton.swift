import FitViewCore
import SwiftUI

/// A bare "what does this mean" button for a title row that isn't a `StatTile`
/// — e.g. a plot's header. Matches `StatTile`'s info glyph and popover/sheet
/// behavior via `metricExplainerPopover`.
struct ExplainerButton: View {
    let explainer: MetricExplainer

    @State private var isShowingExplainer = false

    var body: some View {
        Button {
            isShowingExplainer = true
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(explainer.summary)
        .metricExplainerPopover(explainer, isPresented: $isShowingExplainer)
        .accessibilityLabel("About \(explainer.title)")
    }
}
