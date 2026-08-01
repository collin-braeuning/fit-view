import FitViewCore
import SwiftUI
import UniformTypeIdentifiers

/// Toolbar-launched import flow: pick a source, authorize if it needs it,
/// list what's available, import it through `ImportCoordinator`, then report
/// a summary — failures and unparsed names included, never hidden, matching
/// `overview.md`'s "a broken join should be visible, not quietly hidden"
/// principle for the existing filename-grouping code.
struct ImportSheet: View {
    let coordinator: ImportCoordinator
    /// Called once, only when at least one activity actually imported, with
    /// the full new set of files. The caller (`BatchOverviewView`) treats
    /// this as replacing the current batch outright — the atomic-batch rule
    /// from `overview.md` §11 applies from the moment an import is
    /// confirmed, not just while it's in flight.
    var onImported: ([LoadedFile]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .pickingSource
    @State private var bundledSource = BundledSampleSource()
    @State private var fileSource = FileImportSource()
    @State private var polarSource = PolarAccessLinkSource()
    @State private var corosSource = CorosSource()
    @State private var isPresentingFilePicker = false

    private enum Phase {
        case pickingSource
        case working(sourceName: String, message: String)
        case confirmingImport(source: any ActivitySource, candidates: [ImportCandidate])
        case summary(Summary)
        case failure(sourceName: String, message: String)
    }

    private struct Summary {
        var sourceName: String
        var files: [LoadedFile]
        var failures: [ImportFailure]
        var unparsedNames: [String]
    }

    private var sources: [any ActivitySource] {
        [bundledSource, fileSource, polarSource, corosSource]
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import Activities")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .fileImporter(
            isPresented: $isPresentingFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    await fileSource.setSelection(urls)
                    await run(fileSource)
                }
            case .failure(let error):
                phase = .failure(sourceName: "Files", message: describe(error))
            }
        }
        .onDisappear {
            Task { await coordinator.cancelAll() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .pickingSource:
            sourcePicker
        case .working(let sourceName, let message):
            workingView(sourceName: sourceName, message: message)
        case .confirmingImport(let source, let candidates):
            confirmView(source: source, candidates: candidates)
        case .summary(let summary):
            summaryView(summary)
        case .failure(let sourceName, let message):
            failureView(sourceName: sourceName, message: message)
        }
    }

    private var sourcePicker: some View {
        List(sources, id: \.id) { source in
            Button {
                select(source)
            } label: {
                VStack(alignment: .leading) {
                    Text(source.displayName)
                    if source.id == "polar", !polarSource.isConfigured {
                        Text("Not configured — see Secrets.xcconfig.template")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(source.id == "polar" && !polarSource.isConfigured)
        }
    }

    private func workingView(sourceName: String, message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(sourceName)
    }

    private func confirmView(source: any ActivitySource, candidates: [ImportCandidate]) -> some View {
        VStack(spacing: 16) {
            Text("\(candidates.count) activit\(candidates.count == 1 ? "y" : "ies") found on \(source.displayName).")
                .font(.callout)
            Button("Import \(candidates.count)") {
                startImport(source: source, candidates: candidates)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func summaryView(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(summary.files.count) imported from \(summary.sourceName).")
                .font(.headline)

            if !summary.failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(summary.failures.count) failed").font(.subheadline).bold()
                    ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, failure in
                        Text("\(failure.candidate.suggestedName): \(failure.message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !summary.unparsedNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(summary.unparsedNames.count) couldn't be grouped").font(.subheadline).bold()
                    ForEach(summary.unparsedNames, id: \.self) { name in
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if summary.files.isEmpty {
                Button("Close") { dismiss() }
            } else {
                Button("Use these \(summary.files.count) activities") {
                    onImported(summary.files)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func failureView(sourceName: String, message: String) -> some View {
        ContentUnavailableView(
            sourceName,
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
    }

    private func select(_ source: any ActivitySource) {
        if source.id == fileSource.id {
            isPresentingFilePicker = true
            return
        }
        Task { await run(source) }
    }

    private func run(_ source: any ActivitySource) async {
        phase = .working(sourceName: source.displayName, message: "Connecting…")
        do {
            if source.requiresAuthorization {
                try await source.authorize()
            }
            phase = .working(sourceName: source.displayName, message: "Finding activities…")
            let candidates = try await source.listAvailable()
            guard !candidates.isEmpty else {
                phase = .failure(
                    sourceName: source.displayName,
                    message: "Nothing to import from \(source.displayName)."
                )
                return
            }
            phase = .confirmingImport(source: source, candidates: candidates)
        } catch {
            phase = .failure(sourceName: source.displayName, message: describe(error))
        }
    }

    private func startImport(source: any ActivitySource, candidates: [ImportCandidate]) {
        Task {
            phase = .working(
                sourceName: source.displayName,
                message: "Importing \(candidates.count) activit\(candidates.count == 1 ? "y" : "ies")…"
            )
            guard let result = await coordinator.startImport(from: source, candidates: candidates) else {
                // Superseded by a newer import (e.g. the sheet was dismissed
                // and reopened quickly) — that newer run owns the sheet's
                // state now, so this stale result is discarded outright.
                return
            }
            let unparsed = groupActivityFiles(result.files.map(\.fileName)).unparsed.map(\.fileName)
            phase = .summary(Summary(
                sourceName: source.displayName,
                files: result.files,
                failures: result.failures,
                unparsedNames: unparsed
            ))
        }
    }

    private func describe(_ error: Error) -> String {
        if let sourceError = error as? ActivitySourceError {
            switch sourceError {
            case .notConfigured(let reason), .notAvailable(let reason), .underlying(let reason):
                return reason
            case .unauthorized:
                return "Not signed in."
            case .candidateNotFound(let sourceId):
                return "Couldn't find \(sourceId) — it may have been removed."
            }
        }
        return String(describing: error)
    }
}
