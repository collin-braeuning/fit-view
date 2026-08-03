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
/// that device's *currently displayed* key. `LibraryStore` now backs this
/// with the shared `DeviceNicknameStore`, which chases a rename chain to its
/// end (and rejects one that would loop), so renaming an already-renamed
/// device — e.g. renaming "polarSense" itself to something else after a
/// Polar-reported name was already merged onto it — carries every
/// previously-merged device along rather than stranding it.
///
/// Forward-only, on purpose: renaming only changes how already-imported
/// activities group, and how anything written *after* the rename gets named
/// (Polar sync, the share extension). It never touches a `.fit` file
/// already sitting in the watched folder.
struct DeviceAliasSheet: View {
    let store: any LibraryStore
    let devices: [DeviceIdentity]
    /// Called after a rename is saved, so the caller can reload the batch —
    /// a renamed device can change which sessions group together, so the
    /// whole batch (not just this sheet's list) needs to be rebuilt.
    var onChanged: () -> Void

    /// Reads the same shared table `RemoteActivitySync`/the share extension
    /// consult when naming a file — purely for this sheet's own display
    /// (the "originally" caption below); writes still go through
    /// `store.updateDeviceAlias`, which is what actually persists a rename.
    private let nicknames = DeviceNicknameStore(defaults: AppGroup.defaults)

    @Environment(\.dismiss) private var dismiss
    @State private var edits: [String: String] = [:]
    @State private var savingKey: String?
    @State private var errorMessage: String?
    @State private var aliasTable: [String: DeviceNickname] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        "Renaming a device merges every device whose name matches after removing "
                            + "spaces and ignoring case. This changes how already-imported activities "
                            + "group right away, and applies to anything written after the rename — a "
                            + "Polar-synced file or one shared in from another app — but it never renames "
                            + "a file already in your library or iCloud folder.",
                        systemImage: "arrow.triangle.merge"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(devices, id: \.key) { device in
                        deviceRow(device)
                    }
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
            .task {
                aliasTable = nicknames.all()
            }
        }
    }

    private func deviceRow(_ device: DeviceIdentity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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

            // The original, pre-rename name(s) this device's current label
            // covers — the "unique identifier" a device had before anyone
            // renamed it. Empty for a device that's never been renamed,
            // which is itself informative (nothing merged into it yet).
            let raw = originalNames(for: device)
            if !raw.isEmpty {
                Text("Originally: \(raw.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Every raw device name whose rename chain (in `aliasTable`, chased the
    /// same way `DeviceNicknameStore.resolvedLabel` does) currently lands on
    /// `device`'s key — i.e. what "Originally: …" shows. Neither of this
    /// app's two real devices writes a stable hardware serial number into
    /// its `.fit` files (confirmed against the bundled sample corpus), so
    /// the raw name a device first appeared under is the only meaningful
    /// "unique identifier" available here.
    private func originalNames(for device: DeviceIdentity) -> [String] {
        aliasTable
            .filter { rawKey, _ in
                let resolved = DeviceNicknameStore.resolvedLabel(for: rawKey, in: aliasTable)
                return DeviceNicknameStore.key(for: resolved) == device.key
            }
            .map(\.value.originalName)
            .sorted()
    }

    private func save(_ device: DeviceIdentity) {
        let newLabel = (edits[device.key] ?? device.label).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newLabel.isEmpty, newLabel != device.label else { return }
        savingKey = device.key
        errorMessage = nil
        Task {
            do {
                try await store.updateDeviceAlias(deviceKey: device.key, label: newLabel)
                aliasTable = nicknames.all()
                savingKey = nil
                onChanged()
            } catch {
                savingKey = nil
                errorMessage = describe(error)
            }
        }
    }

    private func describe(_ error: Error) -> String {
        if case .aliasCycleDetected = error as? LibraryStoreError {
            return "Can't rename to that — it would merge this device back onto itself through "
                + "another rename already in place."
        }
        return String(describing: error)
    }
}
