# Phase 1 Data Model: Settings & Device Alias Management

This feature does not introduce a new persistence layer or schema migration — it extends
two existing entities and formalizes a third that's implicit in current code. All storage
mechanisms (UserDefaults via `AppGroup.defaults`, Keychain, a local file) already exist
and are unchanged in *kind*, only in cap/structure where noted.

## Device Alias *(existing, unchanged — documented for completeness)*

Source: `Packages/FitViewCore/Sources/FitViewCore/DeviceNicknameStore.swift`

| Field | Type | Notes |
|---|---|---|
| raw device key | `String` (dictionary key) | `DeviceNicknameStore.key(for:)` — spaces stripped, lowercased |
| `originalName` | `String` | The raw name first observed for this key, kept for display ("Originally: …") |
| `label` | `String` | Current display label; may itself be another raw key (chain) |

**Validation rule**: `setNickname(_:forRawDeviceName:)` rejects a write that would close
a cycle (chasing `label` back to `rawDeviceName`'s own key) — already implemented,
covered by `DeviceNicknameStoreTests.swift`. No change needed for this feature.

**Relationships**: Resolved lazily at read time (`resolvedLabel`), never rewritten into
storage — an activity's raw device name is looked up through this table each time it's
displayed or grouped, not baked into the activity record itself.

## Data Source *(existing, unchanged)*

Source: `Sources/FitView/DataSourceMode.swift`, `AppModel` (`dataSource`,
`isFolderConfigured`, `folderName`). Two modes (`sampleData`, presumably a
folder-backed case) each carrying their own independent library. No schema change; out
of scope for this plan beyond what's already shipped.

## Third-Party Connection *(MODIFIED — this is the feature's actual schema change)*

Source: `Sources/FitView/AppModel.swift`, `Sources/FitView/Import/Polar/TokenStore.swift`

**Current shape**: `isPolarConnected: Bool` + `polarError: String?` (free text,
overwritten per-operation) + `PolarSession` (`accessToken: String`, `xUserId: Int`,
Keychain-backed, unchanged by this feature).

**New shape**:

```swift
enum PolarConnectionState: Equatable {
    case notConnected
    case connected
    case connectionLost   // a session existed (PolarSession was loadable) but the
                           // server rejected it (HTTP 401) on last use
}
```

`AppModel` replaces `isPolarConnected: Bool` with `polarConnectionState:
PolarConnectionState`. `polarError: String?` is retained as-is for operation-specific
messages (e.g. a sync failure unrelated to auth) — `connectionLost` is a structural
state, not a rendering of the last error string, so the two remain independent.

**State transitions**:

| From | Event | To |
|---|---|---|
| `notConnected` | `connectPolar()` succeeds | `connected` |
| `notConnected` | app launch, `TokenStore.load()` returns a session | `connected` (existing `restoreSession()` behavior, unchanged) |
| `connected` | any authenticated Polar request returns HTTP 401 | `connectionLost` |
| `connectionLost` | user re-runs `connectPolar()` and it succeeds | `connected` |
| `connected` or `connectionLost` | `disconnectPolar()` | `notConnected` |

**Validation rule**: `connectPolar()` MUST NOT be reachable from Settings until
`isFolderConfigured` is true (existing FR-009 behavior, unchanged — already enforced by
the `.disabled(!model.isFolderConfigured)` modifier in `SettingsView.swift`).

## Diagnostic Log *(MODIFIED — new cap, new export surface)*

Source: `Sources/FitView/AppModel.swift` (in-memory), a new
`FitViewCore.DiagnosticLogRingBuffer` (pure trim logic), and the existing
`Documents/debug.log` file.

| Field | Type | Notes |
|---|---|---|
| entries | ordered list of formatted lines (`"HH:mm:ss.SSS  <message>"`) | Newest appended at the end |
| cap | `1000` (was 200 in-memory / unbounded on disk) | Applies uniformly to both the in-memory `debugLog` and the on-disk file — single cap, not two |

**Validation rule**: On every append, if the resulting entry count would exceed 1000,
the oldest entries are discarded first (ring buffer / FIFO eviction) — enforced by
`DiagnosticLogRingBuffer`'s pure trim function, exercised from both the in-memory array
update and the on-disk rewrite so the two never drift out of sync with each other's cap.

**Removed**: the manual "Clear Log" affordance (`AppModel.clearDebugLog()` and its
`SettingsView.swift` button) — per the spec's clarification, growth is bounded
automatically, so no manual clearing control is needed. (Whether `clearDebugLog()` itself
is deleted or just no longer surfaced in the UI is an implementation-phase call, not a
data-model concern — either way, no entity’s shape depends on it.)

**New surface, no new field**: log export produces a `ShareLink`/share-sheet transfer of
the existing file at `debugLogFileURL` — the file *is* the export payload; no separate
export-format entity exists.
