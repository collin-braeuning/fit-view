# Contract: `LibraryStore.updateDeviceAlias` / `DeviceNicknameStore`

Internal Swift-protocol/type contract (no network surface) — `FitViewCore`'s single
mechanism for merging a device's raw, source-reported name onto a chosen display label.
**Unchanged by this feature** (already shipped and tested); documented here because
`DeviceAliasSheet` (Settings' UI) is this contract's only caller and this spec is what
formalizes that UI's obligations.

```swift
public protocol LibraryStore: Sendable {
    func updateDeviceAlias(deviceKey: String, label: String) async throws
    func deviceAliases() async throws -> [String: String]
    // ...
}

public enum LibraryStoreError: Error, Sendable, Equatable {
    case aliasCycleDetected(deviceKey: String, label: String)
    // ...
}
```

## Preconditions / postconditions

**`updateDeviceAlias(deviceKey:label:)`**
- Precondition: `deviceKey` is a device's *currently displayed* key (i.e. already
  alias-resolved, as returned in `DeviceIdentity.key` from the batch the UI is showing) —
  not necessarily its original raw name.
- Postcondition on success: every item whose raw `deviceKey` resolves to `deviceKey` now
  reports `label` (and `label.lowercased()` as its key) from `allItems()` onward, with no
  re-import of any item required (FR-002). The rename is visible immediately everywhere
  device labels are shown (activity list, activity detail, device management).
- Postcondition on failure: throws `LibraryStoreError.aliasCycleDetected(deviceKey:label:)`
  if resolving `label` would chase back to `deviceKey` — the write MUST be rejected
  outright, not partially applied (FR-003, edge case: "cycle rejected outright, not
  partially applied").
- MUST NOT modify or move any file outside the app's own library/blob store (FR-004).

**`deviceAliases()`**
- Postcondition: returns the raw table (pre-resolution) so a caller merging two stores'
  alias tables (`RemoteLibraryStore`) can do so field-by-field — not used directly by
  Settings UI, which instead reads `DeviceNicknameStore.all()` via `AppGroup.defaults`
  for its "Originally: …" display (see `DeviceAliasSheet.originalNames(for:)`).

## Consumer contract: `DeviceAliasSheet`

| Obligation | Where enforced |
|---|---|
| MUST seed its editable fields from the batch's already alias-resolved `DeviceIdentity` list, not raw per-file device names. | `DeviceAliasSheet.devices: [DeviceIdentity]`, passed in from `SettingsContent` via `batch.grouping.devices`. |
| MUST call `onChanged()` after a successful rename so the caller reloads the whole batch — a rename can change which sessions group together, not just relabel one row. | `DeviceAliasSheet.save(_:)` → `onChanged()` → `SettingsContent`'s `Task { await model.reload() }`. |
| MUST surface `aliasCycleDetected` as a clear, non-technical explanation, not the raw error. | `DeviceAliasSheet.describe(_:)`. |
| MUST NOT allow saving an empty or unchanged label (no-op save). | `save(_:)`'s guard on `newLabel.isEmpty` / `== device.label`. |

## Out of scope for this contract

Data-source switching, folder management, third-party connection, and diagnostic-log
export are separate concerns within the same Settings screen — see
`polar-connection-contract.md` and `diagnostic-log-contract.md` for the parts of this
feature that are actually new.
