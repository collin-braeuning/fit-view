import FitViewCore
import SwiftUI

/// A stat value paired with its label and, optionally, the agreement level
/// that colours it and a qualifying detail line — e.g. CCC's McBride word and
/// HR range, which overview.md §7 requires stay adjacent to the number. When
/// `explainer` is set the tile becomes tappable, opening a popover/sheet that
/// explains what the number means — see `MetricExplainerView`.
struct StatTile: View {
    let label: String
    let value: String
    var level: AgreementLevel?
    var detail: String?
    var explainer: MetricExplainer?

    @State private var isShowingExplainer = false

    var body: some View {
        if let explainer {
            Button {
                isShowingExplainer = true
            } label: {
                tileContent(showsInfoGlyph: true)
            }
            .buttonStyle(.plain)
            .help(explainer.summary)
            .popover(isPresented: $isShowingExplainer, arrowEdge: .top) {
                MetricExplainerView(explainer: explainer)
                    .frame(idealWidth: 320)
                    #if os(iOS)
                    .presentationCompactAdaptation(.sheet)
                    .presentationDetents([.medium, .large])
                    #endif
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(level.map { "\(label) \(value), \($0.spokenWord) agreement" } ?? "\(label) \(value)")
            .accessibilityHint("Explains what \(label) means")
        } else {
            tileContent(showsInfoGlyph: false)
        }
    }

    @ViewBuilder
    private func tileContent(showsInfoGlyph: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showsInfoGlyph {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(value)
                .font(.title3.monospacedDigit())
                .foregroundStyle(level?.color ?? .primary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
