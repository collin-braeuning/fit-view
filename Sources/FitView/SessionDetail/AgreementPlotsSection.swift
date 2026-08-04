import FitViewCore
import SwiftUI

/// Bland-Altman and concordance plots for a session, surfacing the raw pair
/// data that `bias` / `loaText` / `ccc` on `statsGrid` only summarise as
/// numbers. Section header, no card chrome — matches `coverageSection` /
/// `deviceFactsSection`.
struct AgreementPlotsSection: View {
    let blandAltman: BlandAltmanPlotData?
    let concordance: ConcordancePlotData?
    var minHeight: CGFloat = 220

    @State private var isPresentingBlandAltman = false
    @State private var isPresentingConcordance = false

    var body: some View {
        // Each block below renders independently — a session can have
        // Bland-Altman stats but no CCC (calculateConcordanceStats returns
        // nil when both series are the same constant) — so a missing plot
        // means a missing block, not a gap.
        if blandAltman == nil && concordance == nil {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agreement Plots")
                .font(.headline)
            VStack(alignment: .leading, spacing: 64) {
                if let blandAltman {
                    plotBlock(
                        title: "Bland-Altman Agreement",
                        subtitle: "Mean vs difference",
                        explainer: MetricKind.blandAltmanPlot.explainer,
                        caption: blandAltman.densityCaption,
                        isPresentingFullScreen: $isPresentingBlandAltman
                    ) {
                        // Taller than the shared minHeight: unlike the concordance
                        // plot, whose square aspect ratio already caps its height
                        // to its width, this chart's height is otherwise governed
                        // by minHeight alone.
                        BlandAltmanChart(data: blandAltman, minHeight: minHeight + 80)
                    }
                }
                if let concordance {
                    plotBlock(
                        title: "Lin's Concordance Correlation Coefficient",
                        subtitle: "Reading against reading",
                        explainer: MetricKind.concordancePlot.explainer,
                        caption: concordance.densityCaption,
                        isPresentingFullScreen: $isPresentingConcordance
                    ) {
                        ConcordanceChart(data: concordance, minHeight: minHeight)
                    }
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isPresentingBlandAltman) {
            if let blandAltman {
                FullScreenPlotView(title: "Bland-Altman Agreement") {
                    BlandAltmanChart(data: blandAltman)
                }
            }
        }
        .fullScreenCover(isPresented: $isPresentingConcordance) {
            if let concordance {
                FullScreenPlotView(title: "Lin's Concordance") {
                    ConcordanceChart(data: concordance)
                }
            }
        }
        #else
        .sheet(isPresented: $isPresentingBlandAltman) {
            if let blandAltman {
                FullScreenPlotView(title: "Bland-Altman Agreement") {
                    BlandAltmanChart(data: blandAltman)
                }
                .frame(minWidth: 560, minHeight: 480)
            }
        }
        .sheet(isPresented: $isPresentingConcordance) {
            if let concordance {
                FullScreenPlotView(title: "Lin's Concordance") {
                    ConcordanceChart(data: concordance)
                }
                .frame(minWidth: 560, minHeight: 480)
            }
        }
        #endif
    }

    @ViewBuilder
    private func plotBlock<Content: View>(
        title: String,
        subtitle: String,
        explainer: MetricExplainer,
        caption: String,
        isPresentingFullScreen: Binding<Bool>,
        @ViewBuilder chart: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                ExplainerButton(explainer: explainer)
                Spacer()
                expandButton(isPresentingFullScreen)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            chart()
            // The legend substitute: without this, the opacity ramp on the
            // cloud is uninterpretable.
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func expandButton(_ isPresenting: Binding<Bool>) -> some View {
        Button {
            isPresenting.wrappedValue = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand chart")
    }
}
