# Contract: `ActivitySource`

This is an internal Swift-protocol contract (not a network API) — `FitViewCore`'s single
interface every import origin implements, and the one seam `ImportSheet`, `FolderIngestor`, and
`RemoteActivitySync` all program against instead of knowing about files/Polar/COROS individually.
Documented here because it's the real "interface this feature exposes" for a project type with
no HTTP surface — Principle I depends on every source honoring it identically.

```swift
public protocol ActivitySource: Sendable {
    var id: String { get }
    var displayName: String { get }
    var requiresAuthorization: Bool { get }

    func authorize() async throws
    func listAvailable() async throws -> [ImportCandidate]
    func fetch(_ candidate: ImportCandidate) async throws -> ImportedActivity
}
```

## Preconditions / postconditions per method

**`authorize()`**
- Precondition: none — safe to call even if already authorized (must be idempotent).
- Postcondition on success: subsequent `listAvailable()`/`fetch(_:)` calls may proceed.
- Postcondition on failure: throws `ActivitySourceError` — MUST be `.notConfigured` if the
  source has no credentials at all (FR-013), `.unauthorized` if credentials exist but sign-in
  hasn't happened/has expired, `.notAvailable` if the source doesn't exist yet (COROS).
- No-op sources (bundled, files, COROS) return immediately without throwing.

**`listAvailable()`**
- Precondition: `authorize()` must have succeeded if `requiresAuthorization == true`; callers
  (`ImportSheet.run`) MUST call it first when required.
- Postcondition: returns every currently-importable `ImportCandidate` for this source — MUST
  include candidates already present in the library (dedup happens at the `LibraryStore.add`
  layer, per data-model.md, not here) so "nothing new" and "not authorized" stay distinguishable
  from each other by callers.
- MUST NOT throw for "zero results" — an empty array is a valid, non-error result (`ImportSheet`
  treats it as `.failure("Nothing to import…")` at the UI layer, not as a protocol-level error).

**`fetch(_ candidate:)`**
- Precondition: `candidate` MUST have come from a `listAvailable()` call on the same source
  instance (`sourceId` is source-scoped, not global — data-model.md).
- Postcondition on success: returns `ImportedActivity` with raw bytes ready for
  `loadFitFile`/`ImportCoordinator` to decode.
- Postcondition on failure: throws `.candidateNotFound(sourceId:)` if the candidate is stale
  (e.g. a superseded listing — FR-016's supersede semantics can make this happen legitimately,
  not just as a bug), or `.underlying(String)` for I/O-level failures (FR-007's iCloud timeout
  message is delivered this way).

## Consumers and their contract with `ActivitySource`

| Consumer | Contract obligation |
|---|---|
| `ImportSheet` | MUST call `authorize()` before `listAvailable()` when `requiresAuthorization`; MUST show `listAvailable()`'s full result for user confirmation before calling `fetch` on anything (FR-003); MUST NOT call `fetch` on a candidate the user didn't confirm. |
| `ImportCoordinator.startImport` | Calls `fetch` concurrently per candidate (`withTaskGroup`), collects each outcome as success-or-`ImportFailure` — MUST NOT let one candidate's throw abort the batch (FR-017). MUST discard a superseded run's result entirely (FR-016) — never partially merge. |
| `FolderIngestor` | Calls `listAvailable()` on `WatchedFolderSource`, diffs against `store.allItems()` by `(source, sourceId)` before ever calling `fetch` — MUST NOT re-fetch/re-decode an already-known `sourceId` (FR-005). |
| `RemoteActivitySync` | Calls `listAvailable()` on `PolarAccessLinkSource`, diffs against `RemoteSyncIdStore` before `fetch` — same non-re-fetch obligation as `FolderIngestor`, one layer up (Polar → folder, not Polar → library directly). |

## Out of scope for this contract

Connecting/disconnecting `PolarAccessLinkSource` (i.e. calling its `authorize()`/`disconnect()`
from UI) is driven by `SettingsView`, specified in `004-settings-device-alias` — this contract
only covers what every `ActivitySource` conformance promises once wired into an import path, not
the Settings screen that decides when to wire it in.
