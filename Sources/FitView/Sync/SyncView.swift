import FitViewCore
import SwiftUI
import UniformTypeIdentifiers

/// Toolbar-launched sync flow: pick an iCloud Drive (or any) folder once via
/// the directory document picker, then sync explicitly via a button — no
/// automatic/background sync, per the Phase 3 plan, so every failure mode
/// (a stale bookmark, an un-materialised `.icloud` placeholder) surfaces at a
/// moment the user is already looking at the app, not silently in the
/// background.
///
/// A sync is a pull followed by a push: pulling first means anything another
/// device already put in the folder lands locally (and in the batch reload
/// that follows) before this device's own activities go out, so a single tap
/// converges both sides rather than requiring two separate actions.
struct SyncView: View {
    let syncStore: FolderSyncStore
    let libraryStore: any LibraryStore
    /// Called after a sync completes with at least one change, so the caller
    /// can reload the batch — a pull can add items or reconcile device
    /// aliases, either of which can change how sessions group.
    var onSynced: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfigured = false
    @State private var isPresentingFolderPicker = false
    @State private var phase: Phase = .idle
    @State private var lastReport: (pull: SyncReport, push: SyncReport)?

    private enum Phase: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isConfigured {
                        Label("Folder configured", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("No folder chosen yet", systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    Button(isConfigured ? "Choose a Different Folder…" : "Choose Folder…") {
                        isPresentingFolderPicker = true
                    }
                } header: {
                    Text("iCloud Drive Folder")
                } footer: {
                    Text("Pick a folder (ideally inside iCloud Drive) to sync your library into. "
                        + "Every device pointed at the same folder can push and pull the same activities.")
                }

                Section {
                    Button {
                        Task { await sync() }
                    } label: {
                        if phase == .syncing {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Syncing…")
                            }
                        } else {
                            Text("Sync Now")
                        }
                    }
                    .disabled(!isConfigured || phase == .syncing)

                    if let lastReport {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pulled \(lastReport.pull.itemsCopied) item"
                                + "\(lastReport.pull.itemsCopied == 1 ? "" : "s"), "
                                + "pushed \(lastReport.push.itemsCopied) item"
                                + "\(lastReport.push.itemsCopied == 1 ? "" : "s").")
                                .font(.callout)
                            let aliasesMerged = lastReport.pull.aliasesMerged + lastReport.push.aliasesMerged
                            if aliasesMerged > 0 {
                                Text("\(aliasesMerged) device alias\(aliasesMerged == 1 ? "" : "es") reconciled.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if case .failed(let message) = phase {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Sync")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            isConfigured = await syncStore.isConfigured
        }
        .fileImporter(
            isPresented: $isPresentingFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        try await syncStore.setFolder(url)
                        isConfigured = await syncStore.isConfigured
                    } catch {
                        phase = .failed(String(describing: error))
                    }
                }
            case .failure(let error):
                phase = .failed(String(describing: error))
            }
        }
    }

    private func sync() async {
        phase = .syncing
        do {
            let pullReport = try await syncStore.pull(into: libraryStore)
            let pushReport = try await syncStore.push(libraryStore)
            lastReport = (pull: pullReport, push: pushReport)
            phase = .idle
            if pullReport.itemsCopied > 0 || pullReport.aliasesMerged > 0 {
                onSynced()
            }
        } catch {
            phase = .failed(describe(error))
        }
    }

    private func describe(_ error: Error) -> String {
        if let syncError = error as? FolderSyncError {
            switch syncError {
            case .notConfigured:
                return "No folder configured yet."
            case .bookmarkResolutionFailed:
                return "Couldn't reach the chosen folder — it may have moved, or access may have been revoked. "
                    + "Choose it again."
            case .materializationTimedOut:
                return "Timed out waiting for iCloud Drive to download a file. Check your connection and try again."
            }
        }
        return String(describing: error)
    }
}
