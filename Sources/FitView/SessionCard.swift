import FitViewCore
import SwiftUI

/// One session's summary, sized for the phone-width card list. The headline pairs
/// CCC with the HR range it was measured over — overview.md §7 is explicit
/// that a CCC number is meaningless without that range, so the two must never
/// be allowed to drift apart visually.
///
/// Expansion is an explicit disclosure control, not a whole-card tap — the
/// tap is reserved for the not-yet-built single-session drill-down. That
/// expansion is the card's own state (Principle II): `@State` is keyed to
/// view identity, and the list's `ForEach` over stable `SessionRow` IDs
/// supplies that identity, so a `model.rows` reload is a value update and
/// leaves an expanded card expanded.
struct SessionCard: View {
    let row: SessionRow
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            headline
            primaryStats

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    expandedContent
                }
                // Slides/fades in from the top of its own space rather than
                // the whole card resizing around a center point — the card's
                // static content above stays put and only the bottom edge
                // moves.
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            disclosureButton
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.formattedDate)
                    .font(.headline)
                Text(row.activity)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let ccc = row.ccc, let word = row.cccWord {
                LevelChip(text: word, level: ccc.level)
            }
        }
    }

    @ViewBuilder
    private var headline: some View {
        if let ccc = row.ccc {
            (
                Text("CCC ").foregroundStyle(.secondary)
                    + Text(ccc.text).foregroundStyle(ccc.level.color).fontWeight(.semibold)
                    + Text(" over \(row.hrRangeText)").foregroundStyle(.secondary)
            )
            .font(.subheadline.monospacedDigit())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.cccAccessibilityLabel)
        } else {
            Text(row.cccAccessibilityLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Bias, LoA, and Max |Diff| — the numbers a glance at the card should
    /// lead with, alongside Mean |Diff| in the headline row. Matched-seconds
    /// and per-device coverage percentages are secondary (how much data
    /// backs the numbers, not the numbers themselves), so they live in
    /// `expandedContent` instead.
    @ViewBuilder
    private var primaryStats: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    MetricTile(label: "Mean |Diff|", metric: row.meanAbsDiff)
                    Spacer()
                    if let bias = row.bias {
                        MetricTile(label: "Bias", value: bias.text, level: bias.level, style: .inline)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    MetricTile(label: "Mean |Diff|", metric: row.meanAbsDiff)
                    if let bias = row.bias {
                        MetricTile(label: "Bias", value: bias.text, level: bias.level, style: .inline)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    if let loaText = row.loaText {
                        MetricTile(label: "95% LoA", value: loaText, style: .inline)
                    }
                    Spacer()
                    MetricTile(label: "Max |Diff|", value: row.maxAbsDiffText, style: .inline)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let loaText = row.loaText {
                        MetricTile(label: "95% LoA", value: loaText, style: .inline)
                    }
                    MetricTile(label: "Max |Diff|", value: row.maxAbsDiffText, style: .inline)
                }
            }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            matchedTile(alignment: .leading)
            Text(row.coverageSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            // The own-seconds/span-seconds auto-pause diagnostic from
            // overview.md §7 — not in the Mac table today, and cheap to add
            // here since the card already has room for it.
            VStack(alignment: .leading, spacing: 6) {
                deviceSpanRow(row.primaryCoverage)
                deviceSpanRow(row.secondaryCoverage)
            }
        }
    }

    private func matchedTile(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text("Matched")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(row.matchedSecondsText)
                .font(.subheadline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func deviceSpanRow(_ coverage: DeviceCoverageDetail) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(coverage.label)
                .font(.caption.weight(.medium))
            Text(coverage.ownSpanText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var disclosureButton: some View {
        Button {
            withAnimation(.default) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(isExpanded ? "Hide Details" : "Details")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
    }
}

/// A non-color signal for an agreement level — color alone doesn't work for
/// color-vision deficiency, and today's `.help()` tooltip on the Mac table
/// does nothing on touch.
struct LevelChip: View {
    let text: String
    let level: AgreementLevel

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(level.color.opacity(0.15), in: Capsule())
            .foregroundStyle(level.color)
    }
}
