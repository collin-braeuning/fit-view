import FitViewCore
import SwiftUI

struct SessionDetailView: View {
    let batch: LoadedBatch
    let sessionId: String

    @State private var model: SessionDetailModel?
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
                    minHeight: chartMinHeight
                )
            }
            .padding()
        }
        .navigationTitle(model.session.activity)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
}
