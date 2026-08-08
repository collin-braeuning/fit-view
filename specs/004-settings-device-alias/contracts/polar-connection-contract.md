# Contract: Polar connection state (`PolarConnectionState`, `TokenStore`)

Internal contract — no network surface of this app's own (it's a *consumer* of Polar's
HTTP API via `PolarAPIClient`). This documents the connection-state machine `AppModel`
exposes to `SettingsView`, which is this feature's actual new surface (FR-015).

```swift
enum PolarConnectionState: Equatable {
    case notConnected
    case connected
    case connectionLost
}

protocol TokenStore: Sendable {
    func load() async throws -> PolarSession?
    func save(_ session: PolarSession) async throws
    func clear() async throws
}
```

`TokenStore` itself is unchanged by this feature (already shipped, `KeychainTokenStore`/
`InMemoryTokenStore`) — included here because `PolarConnectionState` transitions are
driven by what happens *after* a `TokenStore.load()`, not by `TokenStore` itself.

## Preconditions / postconditions

**`AppModel.connectPolar()`**
- Precondition: `isFolderConfigured == true` (FR-009) — the UI already disables the
  control otherwise; the method itself should still be safe to no-op/error if called
  when unconfigured, not assume the UI gate is the only enforcement.
- Postcondition on success: `polarConnectionState == .connected`, regardless of prior
  state (`.notConnected` or `.connectionLost` — both are valid starting points for a
  fresh connect).
- Postcondition on failure: `polarConnectionState` unchanged; `polarError` set to a
  user-facing message.

**Any authenticated Polar request (`syncPolar`, or any `PolarAPIClient` call gated on a
loaded session)**
- Precondition: `polarConnectionState == .connected`.
- Postcondition: if the server responds HTTP 401, `polarConnectionState` transitions to
  `.connectionLost` — MUST be a state distinct from `.notConnected`, not a silent revert
  (FR-015). Any other non-2xx status leaves `polarConnectionState` at `.connected` and
  only sets `polarError` (an ordinary transient failure, not an auth failure).

**`AppModel.disconnectPolar()`**
- Postcondition: `polarConnectionState == .notConnected` from any prior state; the stored
  `PolarSession` is cleared via `TokenStore.clear()`; activities already retrieved
  through the connection remain in the library untouched (FR-010).

**`AppModel.resetPolarSyncState()`**
- Postcondition: sync-history tracking (`RemoteSyncIdStore` or equivalent) is cleared so
  previously retrieved activities can be re-checked; `polarConnectionState` is
  unaffected (this is a sync-history reset, not a connection change — FR-011); no
  activity already in the library is deleted.

## Consumer contract: `SettingsView` (`SettingsContent`)

| `polarConnectionState` | Required UI |
|---|---|
| `.notConnected` | "Connect Polar Flow…" button, disabled with an explanation if `!isFolderConfigured` (FR-009 edge case). |
| `.connected` | "Sync Now" / "Disconnect" / "Forget Downloaded Activities" controls (existing). |
| `.connectionLost` | A distinct, explicit label (e.g. "Connection lost — reconnect needed") MUST be shown — MUST NOT render identically to `.notConnected`'s "Connect Polar Flow…" prompt with no explanation (FR-015). A reconnect action MUST be reachable from this state. |

## Out of scope for this contract

The actual HTTP 401 detection lives in `PolarAPIClient.requireSuccess` /
`PolarAccessLinkSource` — this contract specifies the state machine those call sites must
drive `AppModel` into, not their internal HTTP handling.
