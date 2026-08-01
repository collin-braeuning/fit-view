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

    @State private var batch: LoadedBatch?
    @State private var model: BatchOverviewModel?
    @State private var loadError: String?
    @State private var selectedSessionId: String?
    @State private var isPresentingImportSheet = false
    /// Owns the currently in-flight import, if any — a single instance for
    /// the view's lifetime so a new import (or dismissing the sheet) can
    /// cancel whatever's already running, per `overview.md` §11's
    /// atomic-batch rule.
    @State private var importCoordinator = ImportCoordinator()
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
            if let model {
                content(for: model)
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn't load sample data",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView("Loading sample activities…")
            }
        }
        .navigationDestination(for: SessionRoute.self) { route in
            if let batch {
                SessionDetailView(batch: batch, sessionId: route.sessionId)
            } else {
                ContentUnavailableView("Session unavailable", systemImage: "questionmark.folder")
            }
        }
        .task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try SampleBatchLoader.load()
                }.value
                batch = loaded
                model = BatchOverviewModel(agreement: loaded.agreement)
            } catch {
                loadError = String(describing: error)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isPresentingImportSheet = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
        }
        .sheet(isPresented: $isPresentingImportSheet) {
            ImportSheet(coordinator: importCoordinator) { files in
                applyImport(files)
            }
        }
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

    /// Replaces the current batch outright with a freshly imported set of
    /// files — the atomic-batch rule from `overview.md` §11: a new load
    /// replaces, it never merges with what was there before.
    private func applyImport(_ files: [LoadedFile]) {
        let loaded = BatchAssembler.assemble(files)
        batch = loaded
        model = BatchOverviewModel(agreement: loaded.agreement)
        loadError = nil
    }

    #if os(macOS)
    /// macOS drag-and-drop onto the overview — the same import path as
    /// picking "Files" from the toolbar sheet, just skipping the picker UI.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
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

            if let result = await importCoordinator.startImport(from: source, candidates: candidates) {
                applyImport(result.files)
            }
        }
        return true
    }
    #endif

    @ViewBuilder
    private func content(for model: BatchOverviewModel) -> some View {
        Group {
            switch layout {
            case .table: tableContent(for: model)
            case .cards: BatchOverviewCardList(model: model)
            }
        }
        .navigationTitle(model.title)
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

#Preview("Table") {
    NavigationStack {
        BatchOverviewView(layoutOverride: .table)
    }
}

#Preview("Cards") {
    NavigationStack {
        BatchOverviewView(layoutOverride: .cards)
    }
}
