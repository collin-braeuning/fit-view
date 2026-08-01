import FitViewCore
import SwiftUI

/// Placeholder destination — fleshed out in later steps with the HR
/// comparison chart, stats, and skipped-session handling.
struct SessionDetailView: View {
    let batch: LoadedBatch
    let sessionId: String

    private var session: ActivitySession? {
        batch.grouping.sessions.first { $0.id == sessionId }
    }

    var body: some View {
        Group {
            if let session {
                VStack(alignment: .leading, spacing: 12) {
                    Text(formatSessionDate(session.date))
                        .font(.title2.bold())
                    Text(session.activity)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    ForEach(session.deviceKeys, id: \.self) { deviceKey in
                        Text(batch.deviceLabels[deviceKey] ?? deviceKey)
                    }
                }
                .padding()
                .navigationTitle(session.activity)
            } else {
                ContentUnavailableView("Session unavailable", systemImage: "questionmark.folder")
            }
        }
    }
}
