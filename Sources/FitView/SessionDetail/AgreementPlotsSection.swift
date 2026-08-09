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

    #if os(iOS)
    @State private var isPresentingBlandAltman = false
    @State private var isPresentingConcordance = false
    #endif

    // `plotBlock` always takes a binding so its signature doesn't need to
    // fork by platform; on macOS there's no expand button to drive it (see
    // `plotBlock`'s `#if os(iOS)` around the button itself), so these are
    // just inert placeholders there.
    private var blandAltmanFullScreenBinding: Binding<Bool> {
        #if os(iOS)
        $isPresentingBlandAltman
        #else
        .constant(false)
        #endif
    }

    private var concordanceFullScreenBinding: Binding<Bool> {
        #if os(iOS)
        $isPresentingConcordance
        #else
        .constant(false)
        #endif
    }

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
                        isPresentingFullScreen: blandAltmanFullScreenBinding
                    ) {
                        // Taller than the shared minHeight: unlike the concordance
                        // plot, whose aspect ratio derives its height from its
                        // width, this chart's height is governed by minHeight
                        // alone.
                        BlandAltmanChart(data: blandAltman, minHeight: minHeight + 80)
                    }
                }
                if let concordance {
                    plotBlock(
                        title: "Lin's Concordance Correlation Coefficient",
                        subtitle: "Reading against reading",
                        explainer: MetricKind.concordancePlot.explainer,
                        caption: concordance.densityCaption,
                        isPresentingFullScreen: concordanceFullScreenBinding
                    ) {
                        ConcordanceChart(data: concordance)
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
                    ConcordanceChart(data: concordance, maxWidth: nil)
                }
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
                #if os(iOS)
                expandButton(isPresentingFullScreen)
                #endif
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
