import SwiftUI

/// The share extension's one screen: a single editable name, prefilled with
/// the app's `YYYY-MM-DD_device_activity` default (`defaultActivityFileName`
/// in `FitViewCore`), saved into the watched folder on confirmation.
struct ShareEditView: View {
    @State private var viewModel: ShareImportViewModel

    init(extensionContext: NSExtensionContext?) {
        _viewModel = State(initialValue: ShareImportViewModel(extensionContext: extensionContext))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Save to FitView")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { viewModel.cancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { viewModel.save() }
                            .disabled(!viewModel.canSave)
                    }
                }
        }
        .task { await viewModel.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView()
        case .ready:
            editForm
        case .notConfigured:
            ContentUnavailableView(
                "No Folder Chosen",
                systemImage: "folder.badge.questionmark",
                description: Text("Choose a folder in FitView's Settings before sharing a file.")
            )
        case .unreadable(let message):
            ContentUnavailableView(
                "Couldn't Read File",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    private var editForm: some View {
        Form {
            Section {
                HStack {
                    TextField("File Name", text: $viewModel.fileName)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        #endif
                    Text(".fit")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Saved into the folder configured in FitView's Settings, named like "
                    + "2026-07-26_pace4_run.fit.")
            }

            if viewModel.isSaving {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                }
            }

            if let saveError = viewModel.saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}
