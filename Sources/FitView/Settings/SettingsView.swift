import FitViewCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything about where the app's data comes from, in one place: which
/// source is active and which folder is being watched.
///
/// There is deliberately no device-to-device sync section. `FolderSyncStore`
/// still exists in `FitViewCore` (with its tests), but the watched folder
/// subsumes what it was for: every device pointed at the same folder
/// discovers the same files independently, so replicating the app's own
/// library mirror alongside that was a second folder to configure for no gain.
/// The one thing it carried that filenames can't — device aliases — doesn't
/// justify the confusion of two folder pickers in one screen.
///
/// Split into content and sheet so a single `Form` serves both hosts — macOS
/// puts `SettingsContent` straight into the `Settings` scene (⌘,), iOS wraps
/// it in `SettingsSheet` for presentation from the overview's toolbar.
struct SettingsContent: View {
    @Environment(AppModel.self) private var model
    @State private var isPresentingFolderPicker = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker("Data Source", selection: $model.dataSource) {
                    ForEach(DataSourceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .disabled(!model.isFolderConfigured)
            } header: {
                Text("Data Source")
            } footer: {
                if model.isFolderConfigured {
                    Text("Sample Data is the bundled corpus the app ships with. "
                        + "iCloud Folder reads the FIT files in the folder below. "
                        + "Each keeps its own library and device names, so switching between them "
                        + "loses nothing.")
                } else {
                    Text("Choose a folder below to enable the iCloud Folder source.")
                }
            }

            Section {
                LabeledContent("Folder") {
                    Text(model.folderName ?? "None chosen")
                        .foregroundStyle(model.folderName == nil ? .secondary : .primary)
                }

                Button(model.isFolderConfigured ? "Choose a Different Folder…" : "Choose Folder…") {
                    isPresentingFolderPicker = true
                }

                if model.isFolderConfigured {
                    Button("Scan Now") {
                        Task { await model.rescanFolder(force: true) }
                    }
                    .disabled(model.isScanning)

                    Button("Stop Watching", role: .destructive) {
                        Task { await model.clearWatchedFolder() }
                    }
                }

                if model.isScanning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Scanning…")
                    }
                }

                if let report = model.lastIngest {
                    scanSummary(report)
                }

                if let folderError = model.folderError {
                    Text(folderError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Activity Folder")
            } footer: {
                Text("Pick a folder (ideally in iCloud Drive) holding your FIT files, named like "
                    + "2026-07-26_pace4_run.fit. New files are picked up when the app launches and "
                    + "each time you return to it. Files are copied into the app's library, so "
                    + "removing one from the folder won't remove it here.")
            }

            Section {
                if !model.polarSource.isConfigured {
                    Text("Not configured — add a client id/secret to Secrets.xcconfig "
                        + "(see Secrets.xcconfig.template).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !model.isPolarConnected {
                    Button("Connect Polar Flow…") {
                        Task { await model.connectPolar() }
                    }
                    .disabled(!model.isFolderConfigured)
                } else {
                    Button("Sync Now") {
                        Task { await model.syncPolar(force: true) }
                    }
                    .disabled(model.isSyncingPolar)

                    Button("Disconnect", role: .destructive) {
                        Task { await model.disconnectPolar() }
                    }

                    Button("Forget Downloaded Activities", role: .destructive) {
                        model.resetPolarSyncState()
                    }
                }

                if model.isSyncingPolar {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Syncing…")
                    }
                }

                if let report = model.lastPolarSync {
                    polarSyncSummary(report)
                }

                if let polarError = model.polarError {
                    Text(polarError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Polar Flow")
            } footer: {
                if model.polarSource.isConfigured, !model.isFolderConfigured {
                    Text("Choose an activity folder above first — synced activities are written into it, "
                        + "same as a file shared in by hand.")
                } else {
                    Text("Polar only shares activities recorded after you connect, and only from the "
                        + "last 30 days. Older activities have to be imported by hand.")
                }
            }

            Section {
                if model.debugLog.isEmpty {
                    Text("No log entries yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.debugLog.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                Button("Clear Log", role: .destructive) {
                    model.clearDebugLog()
                }
                .disabled(model.debugLog.isEmpty)
            } header: {
                Text("Debug Log")
            } footer: {
                Text("A running trace of what Connect/Sync/Disconnect actually did — useful for "
                    + "diagnosing a sync that appears to do nothing. Not saved between launches.")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isPresentingFolderPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                Task { await model.setWatchedFolder(url) }
            case .failure(let error):
                // A cancel isn't a failure, so this is a genuine problem —
                // saying nothing after the user picked a folder would be
                // indistinguishable from a bug.
                model.reportFolderError(error)
            }
        }
    }

    @ViewBuilder
    private func scanSummary(_ report: FolderIngestReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(report.discovered) file\(report.discovered == 1 ? "" : "s") in the folder, "
                + "\(report.imported) newly imported.")
                .font(.callout)
            if !report.failures.isEmpty {
                // Named individually rather than counted: a file that won't
                // import is something the user has to go fix in the folder,
                // and "3 failed" doesn't tell them which three.
                Text("Couldn't import \(report.failures.count) "
                    + "file\(report.failures.count == 1 ? "" : "s"):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(report.failures.prefix(5), id: \.candidate.sourceId) { failure in
                    Text("• \(failure.candidate.sourceId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func polarSyncSummary(_ report: RemoteSyncReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(report.discovered) activit\(report.discovered == 1 ? "y" : "ies") on Polar Flow, "
                + "\(report.downloaded) newly downloaded.")
                .font(.callout)
            if !report.failures.isEmpty {
                Text("Couldn't download \(report.failures.count) "
                    + "activit\(report.failures.count == 1 ? "y" : "ies"):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(report.failures.prefix(5), id: \.candidate.sourceId) { failure in
                    Text("• \(failure.candidate.suggestedName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// iOS presentation of `SettingsContent`. macOS uses the `Settings` scene in
/// `FitViewApp` instead, which supplies its own window chrome.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsContent()
                .navigationTitle("Settings")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
