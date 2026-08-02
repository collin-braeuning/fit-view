import FitViewCore
import SwiftUI

/// Lets the user rename a device's display label — the UI half of
/// `LibraryStore.updateDeviceAlias`, which otherwise has no caller anywhere
/// in the app. Without this, an API-reported device name (Polar's raw
/// "Polar Vantage V2") can never be reconciled with the file corpus's
/// `polarSense` identity, and the two never group into the same session —
/// the whole reason the alias table exists (`ActivitySessions.swift`'s
/// `LibraryStore.updateDeviceAlias` doc comment).
///
/// One text field per device currently known to the batch, seeded from
/// `batch.grouping.devices` (already alias-resolved, ranked by file count).
/// Renaming writes through `store.updateDeviceAlias(deviceKey:label:)` using
/// that device's *currently displayed* key — which is only the device's raw,
/// never-aliased key the first time it's renamed. Re-renaming an
/// already-aliased device is a known limitation of `updateDeviceAlias`
/// itself (single-hop: the alias table is keyed by each stored item's raw
/// `deviceKey`, not by whatever label a previous alias resolved to), not
/// something this sheet tries to work around.
struct DeviceAliasSheet: View {
    let store: any LibraryStore
    let devices: [DeviceIdentity]
    /// Called after a rename is saved, so the caller can reload the batch —
    /// a renamed device can change which sessions group together, so the
    /// whole batch (not just this sheet's list) needs to be rebuilt.
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var edits: [String: String] = [:]
    @State private var savingKey: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(devices, id: \.key) { device in
                        deviceRow(device)
                    }
                } footer: {
                    Text("Renaming a device merges it with any other device sharing the new name — "
                        + "use this to reconcile an imported device's reported name (e.g. Polar's) with "
                        + "one already in your library (e.g. \"polarSense\").")
                }
            }
            .navigationTitle("Devices")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
            }
        }
    }

    private func deviceRow(_ device: DeviceIdentity) -> some View {
        HStack {
            TextField(
                "Device name",
                text: Binding(
                    get: { edits[device.key] ?? device.label },
                    set: { edits[device.key] = $0 }
                )
            )
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .disableAutocorrection(true)
            .onSubmit { save(device) }

            Text("\(device.fileCount) file\(device.fileCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            if savingKey == device.key {
                ProgressView().controlSize(.small)
            } else {
                Button("Save") { save(device) }
                    .buttonStyle(.borderless)
                    .disabled((edits[device.key] ?? device.label) == device.label)
            }
        }
    }

    private func save(_ device: DeviceIdentity) {
        let newLabel = (edits[device.key] ?? device.label).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newLabel.isEmpty, newLabel != device.label else { return }
        savingKey = device.key
        errorMessage = nil
        Task {
            do {
                try await store.updateDeviceAlias(deviceKey: device.key, label: newLabel)
                savingKey = nil
                onChanged()
            } catch {
                savingKey = nil
                errorMessage = String(describing: error)
            }
        }
    }
}
