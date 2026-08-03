import FitViewCore
import SwiftUI

/// The body of a stat tile's explainer popover/sheet — what the number
/// means, how to read it, and (when the metric has one) the good/fair/poor
/// scale that colours the tile. Copy lives in `MetricExplainer`
/// (FitViewCore) so its band thresholds stay pinned to `AgreementScale.swift`.
struct MetricExplainerView: View {
    let explainer: MetricExplainer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(explainer.title)
                    .font(.headline)
                if let subtitle = explainer.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(explainer.summary)
                .font(.subheadline.weight(.medium))
            Text(explainer.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            if explainer.bands.isEmpty {
                if let unscoredNote = explainer.unscoredNote {
                    Text(unscoredNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(explainer.bands, id: \.word) { band in
                        HStack(spacing: 6) {
                            Image(systemName: band.level.symbolName)
                                .foregroundStyle(band.level.color)
                                .font(.caption)
                            Text("\(band.range) — \(band.word)")
                                .font(.caption)
                        }
                    }
                }
            }
            if let learnMoreURL = explainer.learnMoreURL {
                Link("Learn more", destination: learnMoreURL)
                    .font(.caption)
            }
        }
        .padding(16)
    }
}

#Preview("CCC") {
    MetricExplainerView(explainer: MetricKind.concordance.explainer)
}

#Preview("95% LoA") {
    MetricExplainerView(explainer: MetricKind.limitsOfAgreement.explainer)
}
