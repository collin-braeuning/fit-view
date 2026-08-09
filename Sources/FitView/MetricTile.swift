import FitViewCore
import SwiftUI

/// A stat value paired with its label and, optionally, the agreement level
/// that colours *and* glyphs it, a qualifying detail line — e.g. CCC's
/// McBride word and HR range, which overview.md §7 requires stay adjacent to
/// the number — and an in-context explainer. When `explainer` is set the
/// tile becomes tappable, opening a popover/sheet that explains what the
/// number means — see `MetricExplainerView`.
///
/// `style` selects one of two presentations used across the app, and drives
/// only the value's font and whether the card chrome (padding, background,
/// `maxWidth: .infinity`) is applied:
/// - `.card` — the detail screen's larger, tappable-for-explanation tiles.
/// - `.inline` — the overview card's compact summary rows, no chrome.
///
/// Everything else — the label row, the level glyph (never colour alone;
/// see `AgreementLevel.symbolName`), the value's colouring, and the
/// accessibility label — is shared between both presentations.
struct MetricTile: View {
    enum Style {
        case card
        case inline
    }

    let label: String
    let value: String
    var level: AgreementLevel?
    var detail: String?
    var explainer: MetricExplainer?
    var style: Style = .card

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
            .metricExplainerPopover(explainer, isPresented: $isShowingExplainer)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metricTileAccessibilityLabel(label: label, value: value, level: level))
            .accessibilityHint("Explains what \(label) means")
        } else {
            tileContent(showsInfoGlyph: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(metricTileAccessibilityLabel(label: label, value: value, level: level))
        }
    }

    private var valueFont: Font {
        switch style {
        case .card: .title3.monospacedDigit()
        case .inline: .subheadline.monospacedDigit()
        }
    }

    /// Carried over per-style rather than unified: the card's larger value
    /// font needs the looser gap the detail screen already used, and matching
    /// the overview card's tighter `2` there would visually change a screen
    /// this consolidation is only meant to add a glyph to.
    private var rowSpacing: CGFloat {
        switch style {
        case .card: 4
        case .inline: 2
        }
    }

    @ViewBuilder
    private func tileContent(showsInfoGlyph: Bool) -> some View {
        let content = VStack(alignment: .leading, spacing: rowSpacing) {
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
            HStack(spacing: 4) {
                if let level {
                    Image(systemName: level.symbolName)
                        .font(.caption2)
                }
                Text(value)
                    .font(valueFont)
            }
            .foregroundStyle(level?.color ?? .primary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        switch style {
        case .card:
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        case .inline:
            content
        }
    }
}

extension MetricTile {
    /// Convenience for the common case of an inline row driven by a `Metric`
    /// (a value that always carries a level) rather than separate `value`/
    /// `level` arguments.
    init(label: String, metric: Metric, style: Style = .inline, explainer: MetricExplainer? = nil) {
        self.init(label: label, value: metric.text, level: metric.level,
                  explainer: explainer, style: style)
    }
}

/// Builds the VoiceOver label for a `MetricTile`: the value's agreement
/// level, when present, is spoken alongside the label and value rather than
/// relying on colour (or the glyph, which VoiceOver doesn't otherwise
/// describe). Pulled out as a plain, SwiftUI-free function — unlike the view
/// itself — so it can be unit tested directly; see `MetricTileTests`.
func metricTileAccessibilityLabel(label: String, value: String, level: AgreementLevel?) -> String {
    guard let level else { return "\(label) \(value)" }
    return "\(label) \(value), \(level.spokenWord) agreement"
}
