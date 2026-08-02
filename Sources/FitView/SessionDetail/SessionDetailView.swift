import FitViewCore
import SwiftUI

struct SessionDetailView: View {
    let batch: LoadedBatch
    let sessionId: String

    @State private var model: SessionDetailModel?
    @State private var isPresentingFullScreenChart = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var chartMinHeight: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .regular ? 360 : 240
        #else
        360
        #endif
    }

    var body: some View {
        Group {
            if let model {
                content(for: model)
            } else {
                ContentUnavailableView("Session unavailable", systemImage: "questionmark.folder")
            }
        }
        .task(id: sessionId) {
            model = await Task.detached(priority: .userInitiated) {
                SessionDetailModel(batch: batch, sessionId: sessionId)
            }.value
        }
    }

    private func content(for model: SessionDetailModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(for: model)
                HeartRateComparisonChart(
                    points: model.chartPoints,
                    deviceLabels: model.deviceLabels,
                    yDomain: model.chartYDomain,
                    lapBoundaries: model.lapBoundaries,
                    minHeight: chartMinHeight
                )
                .overlay(alignment: .topTrailing) {
                    expandChartButton
                }
                if let lapSourceLabel = model.lapSourceLabel {
                    Text("Lap dividers from \(lapSourceLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                statsGrid(for: model)
                coverageSection(for: model)
                deviceFactsSection(for: model)
            }
            .padding()
        }
        .navigationTitle(model.session.activity)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $isPresentingFullScreenChart) {
            fullScreenChart(for: model)
        }
        #else
        .sheet(isPresented: $isPresentingFullScreenChart) {
            fullScreenChart(for: model)
                .frame(minWidth: 700, minHeight: 420)
        }
        #endif
    }

    private var expandChartButton: some View {
        Button {
            isPresentingFullScreenChart = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption)
                .padding(6)
                .background(.background.secondary, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("Expand chart")
    }

    private func fullScreenChart(for model: SessionDetailModel) -> some View {
        FullScreenHeartRateChartView(
            points: model.chartPoints,
            deviceLabels: model.deviceLabels,
            yDomain: model.chartYDomain,
            lapBoundaries: model.lapBoundaries
        )
    }

    private func header(for model: SessionDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.formattedDate)
                .font(.title2.bold())
            Text(model.deviceLabels.joined(separator: " vs "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statsGrid(for model: SessionDetailModel) -> some View {
        if model.agreement != nil {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                if let matchedSecondsText = model.matchedSecondsText {
                    StatTile(label: "Matched Seconds", value: matchedSecondsText)
                }
                if let bias = model.bias {
                    StatTile(label: "Bias", value: bias.text, level: bias.level)
                }
                if let loaText = model.loaText {
                    StatTile(label: "95% LoA", value: loaText)
                }
                if let meanAbsDiff = model.meanAbsDiff {
                    StatTile(label: "Mean |Diff|", value: meanAbsDiff.text, level: meanAbsDiff.level)
                }
                if let maxAbsDiffText = model.maxAbsDiffText {
                    StatTile(label: "Max |Diff|", value: maxAbsDiffText)
                }
                if let ccc = model.ccc {
                    StatTile(label: "CCC", value: ccc.text, level: ccc.level, detail: model.cccDetailText)
                }
            }
        } else if let skipBannerText = model.skipBannerText {
            VStack(alignment: .leading, spacing: 6) {
                Label(skipBannerText, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let startTimeDeltaText = model.startTimeDeltaText {
                    Text(startTimeDeltaText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func coverageSection(for model: SessionDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coverage")
                .font(.headline)
            ForEach(model.coverageDetails, id: \.label) { detail in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(detail.label)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(detail.percentText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(detail.ownSpanText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func deviceFactsSection(for model: SessionDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Devices")
                .font(.headline)
            ForEach(model.deviceFacts, id: \.label) { facts in
                VStack(alignment: .leading, spacing: 2) {
                    Text(facts.label)
                        .font(.subheadline.weight(.medium))
                    Text("\(facts.fileName) · \(facts.sport)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(facts.startTimeText) – \(facts.endTimeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(facts.recordCount.formatted()) records · \(facts.lapCount) laps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("avg \(facts.avgHeartRate) bpm · max \(facts.maxHeartRate) bpm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A stat value paired with its label and, optionally, the agreement level
/// that colours it and a qualifying detail line — e.g. CCC's McBride word and
/// HR range, which overview.md §7 requires stay adjacent to the number.
private struct StatTile: View {
    let label: String
    let value: String
    var level: AgreementLevel?
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
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

#Preview("Normal") {
    NavigationStack {
        SessionDetailView(batch: SessionDetailPreviewFixture.makeBatch(), sessionId: "2026-08-01|run")
    }
}

#Preview("No overlap") {
    NavigationStack {
        SessionDetailView(batch: SessionDetailPreviewFixture.makeBatch(), sessionId: "2026-08-02|run")
    }
}

#Preview("Too few points") {
    NavigationStack {
        SessionDetailView(batch: SessionDetailPreviewFixture.makeBatch(), sessionId: "2026-08-03|run")
    }
}

#Preview("Missing device") {
    NavigationStack {
        SessionDetailView(batch: SessionDetailPreviewFixture.makeBatch(), sessionId: "2026-08-04|run")
    }
}
