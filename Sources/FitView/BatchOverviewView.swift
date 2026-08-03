import FitViewCore
import SwiftUI
import UniformTypeIdentifiers

/// Which presentation to use for the batch overview. `Table` collapses to a
/// single visible column below `horizontalSizeClass == .regular` (iPhone,
/// and iPad in Slide Over / a small Stage Manager window), so the choice is
/// keyed on width, not on platform — macOS always has room, iOS sometimes
/// does.
enum OverviewLayout {
    case table
    case cards
}

/// One row per session's Bland-Altman/CCC numbers — the batch overview
/// described in overview.md §7. A row that looks bad is a prompt to drill
/// into that one session (not yet built).
struct BatchOverviewView: View {
    /// Overrides the size-class-derived layout. Lets `#Preview` render the
    /// card layout on a Mac canvas without booting a simulator.
    var layoutOverride: OverviewLayout?
    @Binding var path: [SessionRoute]

    /// The batch, the store, and the chosen data source all live in
    /// `AppModel` — they have to outlive this view and be reachable from the
    /// macOS Settings scene, which is a sibling of `WindowGroup` rather than a
    /// descendant of it.
    @Environment(AppModel.self) private var model

    @State private var selectedSessionId: String?
    @State private var isPresentingImportSheet = false
    @State private var isPresentingDeviceAliasSheet = false
    #if os(iOS)
    @State private var isPresentingSettingsSheet = false
    #endif
    #if os(macOS)
    @State private var isDropTargeted = false
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(layoutOverride: OverviewLayout? = nil, path: Binding<[SessionRoute]> = .constant([])) {
        self.layoutOverride = layoutOverride
        self._path = path
    }

    private var layout: OverviewLayout {
        if let layoutOverride { return layoutOverride }
        #if os(macOS)
        return .table
        #else
        return horizontalSizeClass == .regular ? .table : .cards
        #endif
    }

    var body: some View {
        Group {
            if let overview = model.overview {
                content(for: overview)
            } else if let loadError = model.loadError {
                ContentUnavailableView(
                    "Couldn't load activities",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView("Loading activities…")
            }
        }
        .navigationDestination(for: SessionRoute.self) { route in
            if let batch = model.batch {
                SessionDetailView(batch: batch, sessionId: route.sessionId)
            } else {
                ContentUnavailableView("Session unavailable", systemImage: "questionmark.folder")
            }
        }
        .toolbar {
            #if os(iOS)
            // iOS only: on macOS the `Settings` scene in `FitViewApp` already
            // puts this behind ⌘, and the app menu, which is where Mac users
            // look for it — a second entry point in the toolbar would be
            // redundant and non-idiomatic.
            ToolbarItem {
                Button {
                    isPresentingSettingsSheet = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            #endif
            ToolbarItem {
                Button {
                    isPresentingDeviceAliasSheet = true
                } label: {
                    Label("Devices", systemImage: "tag")
                }
                .disabled(model.store == nil || model.overview == nil)
            }
            ToolbarItem {
                Button {
                    isPresentingImportSheet = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(model.store == nil)
            }
        }
        .sheet(isPresented: $isPresentingImportSheet) {
            if let store = model.store {
                ImportSheet(coordinator: model.importCoordinator, store: store) {
                    Task { await model.reload() }
                }
            }
        }
        .sheet(isPresented: $isPresentingDeviceAliasSheet) {
            if let store = model.store, let batch = model.batch {
                DeviceAliasSheet(store: store, devices: batch.grouping.devices) {
                    Task { await model.reload() }
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $isPresentingSettingsSheet) {
            SettingsSheet()
        }
        #endif
        #if os(macOS)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        #endif
    }

    #if os(macOS)
    /// macOS drag-and-drop onto the overview — the same import path as
    /// picking "Files" from the toolbar sheet, just skipping the picker UI.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty, let store = model.store else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                guard
                    let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil),
                    let data = item as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                else { continue }
                urls.append(url)
            }
            guard !urls.isEmpty else { return }

            let source = FileImportSource()
            await source.setSelection(urls)
            let candidates = (try? await source.listAvailable()) ?? []
            guard !candidates.isEmpty else { return }

            if await model.importCoordinator.startImport(
                from: source, candidates: candidates, store: store
            ) != nil {
                await model.reload()
            }
        }
        return true
    }
    #endif

    // The presentation model is passed in rather than read off `model` inside
    // these builders, so the outer `AppModel` isn't shadowed by a local named
    // `model` — they're different objects and confusing them would be easy.
    @ViewBuilder
    private func content(for overview: BatchOverviewModel) -> some View {
        Group {
            switch layout {
            case .table: tableContent(for: overview)
            case .cards: BatchOverviewCardList(model: overview)
            }
        }
        .navigationTitle(overview.title)
    }

    @ViewBuilder
    private func tableContent(for model: BatchOverviewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.rows.isEmpty {
                emptySessionsMessage
            } else {
                // Both iPad and Mac report `.regular`, but an iPad in
                // portrait (744-834pt) is still too narrow for all 9
                // columns — measure the actual width rather than trusting
                // the size class alone.
                GeometryReader { geometry in
                    if geometry.size.width < Self.narrowTableWidthThreshold {
                        narrowSessionsTable(for: model)
                    } else {
                        fullSessionsTable(for: model)
                    }
                }
            }

            if !model.skipped.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skipped")
                        .font(.headline)
                    ForEach(model.skipped) { skipped in
                        NavigationLink(value: SessionRoute(sessionId: skipped.sessionId)) {
                            Text("\(skipped.formattedDate) — \(skipped.reasonText)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .onChange(of: selectedSessionId) { _, newValue in
            guard let newValue else { return }
            path.append(SessionRoute(sessionId: newValue))
            selectedSessionId = nil
        }
    }

    private static let narrowTableWidthThreshold: CGFloat = 900

    private func fullSessionsTable(for model: BatchOverviewModel) -> some View {
        Table(model.rows, selection: $selectedSessionId) {
            TableColumn("Date") { row in
                Text(row.formattedDate)
            }
            TableColumn("Activity") { row in
                Text(row.activity)
            }
            matchedSecondsColumn
            TableColumn("HR Range") { row in
                Text(row.hrRangeText)
            }
            TableColumn("Bias") { row in
                if let bias = row.bias {
                    Text(bias.text)
                        .foregroundStyle(bias.level.color)
                }
            }
            TableColumn("95% LoA") { row in
                if let loaText = row.loaText {
                    Text(loaText)
                }
            }
            TableColumn("Mean |Diff|") { row in
                Text(row.meanAbsDiff.text)
                    .foregroundStyle(row.meanAbsDiff.level.color)
            }
            TableColumn("Max |Diff|") { row in
                Text(row.maxAbsDiffText)
            }
            cccColumn
        }
    }

    /// Same data, minus 95% LoA and Max |Diff| — for iPad portrait widths
    /// where all 9 columns don't fit. Bias and Mean |Diff| already carry the
    /// headline signal; LoA and max are exactly what the (already-built)
    /// card disclosure exists to hold on the narrow side.
    private func narrowSessionsTable(for model: BatchOverviewModel) -> some View {
        Table(model.rows, selection: $selectedSessionId) {
            TableColumn("Date") { row in
                Text(row.formattedDate)
            }
            TableColumn("Activity") { row in
                Text(row.activity)
            }
            matchedSecondsColumn
            TableColumn("HR Range") { row in
                Text(row.hrRangeText)
            }
            TableColumn("Bias") { row in
                if let bias = row.bias {
                    Text(bias.text)
                        .foregroundStyle(bias.level.color)
                }
            }
            TableColumn("Mean |Diff|") { row in
                Text(row.meanAbsDiff.text)
                    .foregroundStyle(row.meanAbsDiff.level.color)
            }
            cccColumn
        }
    }

    private var matchedSecondsColumn: some TableColumnContent<SessionRow, Never> {
        TableColumn("Matched Seconds") { row in
            VStack(alignment: .leading) {
                Text(row.matchedSecondsText)
                Text(row.coverageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .width(min: 180, ideal: 220)
    }

    private var cccColumn: some TableColumnContent<SessionRow, Never> {
        TableColumn("CCC") { row in
            if let ccc = row.ccc {
                Text(ccc.text)
                    .foregroundStyle(ccc.level.color)
                    .help(row.cccWord ?? "")
            }
        }
    }

    private var emptySessionsMessage: some View {
        Text("No sessions could be compared.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding()
    }
}

/// Holds the `AppModel` in `@State` so it survives re-renders and gets exactly
/// one `activate()`. A bare `.environment(AppModel())` in the `#Preview` body
/// would mint a fresh model on every evaluation and lose the loaded batch.
/// (`@Previewable`, which would make this unnecessary, needs iOS 18/macOS 15 —
/// this target is 17/14.)
private struct BatchOverviewPreviewHost: View {
    let layout: OverviewLayout
    @State private var model = AppModel()

    var body: some View {
        NavigationStack {
            BatchOverviewView(layoutOverride: layout)
        }
        .environment(model)
        .task { await model.activate() }
    }
}

#Preview("Table") {
    BatchOverviewPreviewHost(layout: .table)
}

#Preview("Cards") {
    BatchOverviewPreviewHost(layout: .cards)
}
