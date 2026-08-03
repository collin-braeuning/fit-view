import FitViewCore
import SwiftUI

struct SessionDetailView: View {
    let batch: LoadedBatch
    let sessionId: String

    // Named `appModel` rather than `model` so it can't shadow the local
    // `SessionDetailModel` — same reasoning as `BatchOverviewView`'s builder
    // functions.
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var model: SessionDetailModel?
    @State private var isPresentingFullScreenChart = false
    @State private var isPresentingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?
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
        .toolbar {
            ToolbarItem {
                Menu {
                    Button(role: .destructive) {
                        isPresentingDeleteConfirmation = true
                    } label: {
                        Label("Delete Activity", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(isDeleting)
            }
        }
        // A separate confirmation step even though this is already tucked
        // behind a "..." menu — deletion is unrecoverable (the manifest entry
        // is gone; the blob is left orphaned, per `LibraryStore.remove`'s
        // contract, but nothing in this app exposes recovering it), so one
        // tap should never be enough to lose data.
        .confirmationDialog(
            "Delete this activity?",
            isPresented: $isPresentingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete(model) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes it from FitView's library. The original file, if any, is left untouched.")
        }
        .alert(
            "Couldn't Delete",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            ),
            presenting: deleteErrorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func delete(_ model: SessionDetailModel) {
        isDeleting = true
        Task {
            let error = await appModel.deleteSession(model.session)
            isDeleting = false
            if let error {
                deleteErrorMessage = error
            } else {
                dismiss()
            }
        }
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
                    StatTile(
                        label: "Matched Seconds",
                        value: matchedSecondsText,
                        explainer: MetricKind.matchedSeconds.explainer
                    )
                }
                if let bias = model.bias {
                    StatTile(
                        label: "Bias",
                        value: bias.text,
                        level: bias.level,
                        explainer: MetricKind.bias.explainer
                    )
                }
                if let loaText = model.loaText {
                    StatTile(
                        label: "95% LoA",
                        value: loaText,
                        explainer: MetricKind.limitsOfAgreement.explainer
                    )
                }
                if let meanAbsDiff = model.meanAbsDiff {
                    StatTile(
                        label: "Mean |Diff|",
                        value: meanAbsDiff.text,
                        level: meanAbsDiff.level,
                        explainer: MetricKind.meanAbsoluteDifference.explainer
                    )
                }
                if let maxAbsDiffText = model.maxAbsDiffText {
                    StatTile(
                        label: "Max |Diff|",
                        value: maxAbsDiffText,
                        explainer: MetricKind.maxAbsoluteDifference.explainer
                    )
                }
                if let ccc = model.ccc {
                    StatTile(
                        label: "CCC",
                        value: ccc.text,
                        level: ccc.level,
                        detail: model.cccDetailText,
                        explainer: MetricKind.concordance.explainer
                    )
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
