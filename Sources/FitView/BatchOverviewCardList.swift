import SwiftUI

/// Phone/compact-width layout: `Table` collapses to a single column below
/// `horizontalSizeClass == .regular`, so this is the real presentation there,
/// not a cramped variant of the Mac table.
struct BatchOverviewCardList: View {
    let model: BatchOverviewModel
    @State private var expandedSessionIds: Set<String> = []

    var body: some View {
        List {
            if model.rows.isEmpty {
                Section {
                    Text("No sessions could be compared.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(model.rows) { row in
                        SessionCard(
                            row: row,
                            isExpanded: expandedSessionIds.contains(row.id),
                            onToggleExpanded: { toggleExpanded(row.id) }
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                }
            }

            if !model.skipped.isEmpty {
                Section("Skipped (\(model.skipped.count))") {
                    ForEach(model.skipped) { skipped in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(skipped.formattedDate) · \(skipped.activity)")
                                .font(.subheadline)
                            Text(skipped.reasonText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(.default) {
            if !expandedSessionIds.insert(id).inserted {
                expandedSessionIds.remove(id)
            }
        }
    }
}
