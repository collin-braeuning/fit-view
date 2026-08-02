import SwiftUI

/// Phone/compact-width layout: `Table` collapses to a single column below
/// `horizontalSizeClass == .regular`, so this is the real presentation there,
/// not a cramped variant of the Mac table.
///
/// Built on `ScrollView`/`LazyVStack` rather than `List`: `List` is backed by
/// `UITableView` on iOS, and animating a row's height there makes its content
/// appear to grow from the center instead of from the edge that actually
/// changed — exactly the "Details" disclosure glitch this layout needs to
/// avoid. A plain `VStack` doesn't have that failure mode.
struct BatchOverviewCardList: View {
    let model: BatchOverviewModel
    @State private var expandedSessionIds: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.rows.isEmpty {
                    Text("No sessions could be compared.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                } else {
                    ForEach(model.rows) { row in
                        // The disclosure chevron `List` draws for a `NavigationLink`
                        // row doesn't exist outside `List` — cards are already known
                        // to be tappable, so plain `ScrollView` content gets that for
                        // free without needing a hidden-link workaround.
                        NavigationLink(value: SessionRoute(sessionId: row.id)) {
                            SessionCard(
                                row: row,
                                isExpanded: expandedSessionIds.contains(row.id),
                                onToggleExpanded: { toggleExpanded(row.id) }
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }
                }

                if !model.skipped.isEmpty {
                    Text("Skipped (\(model.skipped.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, model.rows.isEmpty ? 0 : 8)

                    ForEach(model.skipped) { skipped in
                        NavigationLink(value: SessionRoute(sessionId: skipped.sessionId)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(skipped.formattedDate) · \(skipped.activity)")
                                    .font(.subheadline)
                                Text(skipped.reasonText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(.default) {
            if !expandedSessionIds.insert(id).inserted {
                expandedSessionIds.remove(id)
            }
        }
    }
}
