# Phase 0 Research: Session Deletion

All findings are from a direct read of the current codebase on branch `005-session-deletion`.
No NEEDS CLARIFICATION markers remain from Technical Context.

## 1. Where does reconciliation belong?

**Decision**: `FolderIngestor.ingest(into:)` in `FitViewCore`.

**Rationale**: `ingest` already holds every input reconciliation needs and already computes
half the diff:

```swift
let candidates = try await source.listAvailable()   // what the folder has
let itemsBefore = try await store.allItems()        // what the library has
let known = Set(itemsBefore.filter { $0.source == source.id }.compactMap(\.sourceId))
```

Import is `candidates - known`. Reconciliation is `known - candidates`. Same two sets, opposite
direction, zero additional I/O on the common path. It also lands where `swift test` already
runs (`FolderIngestorTests.swift` exists), satisfying Constitution VI with no workflow change.

**Alternatives considered**:

- *`AppModel.rescanFolder`* — rejected. `AppModel` is `@MainActor` and app-layer; putting the
  app's only automatic data-destroying operation there puts it in the layer least covered by
  tests, and violates Principle I (this is not platform-specific logic).
- *A separate `FolderReconciler` type* — rejected as premature. It would need the same source,
  store, and candidate list `ingest` already has, forcing either a second `listAvailable()`
  call (an extra directory listing per scan, and a chance to observe a *different* folder
  state than the import half did) or a parameter-passing dance to share one. Principle II
  explicitly warns against generalizing before a second call site exists.

## 2. What counts as "read the folder completely"? (FR-010)

**Decision**: A listing is trustworthy iff `listAvailable()` returns without throwing **and**
`coordinatedContents` is first fixed to throw when it cannot enumerate.

**Rationale**: This is the most important finding in this research pass. Today,
`FileCoordination.swift:113-117`:

```swift
guard let enumerator = FileManager.default.enumerator(
    at: readURL, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
) else { return }        // <- result stays [], no error thrown
```

`FileManager.enumerator(at:)` returns `nil` when the URL is not an enumerable directory —
it was replaced by a regular file, permissions were lost, or the path no longer resolves to a
directory. The function then returns an **empty array and no error**. Reconciliation keyed on
"didn't throw" would interpret that as "the folder is empty, remove everything," which is
unrecoverable (`remove` drops the manifest entry; the orphaned blob is not exposed by any
in-app affordance). This is exactly the failure FR-010 was written to prevent, and the current
code cannot detect it.

**Fix**: throw a new `FileCoordinationError.directoryNotEnumerable(path:)` instead of
returning. This is correct for every existing caller — none of them want "empty" to be
indistinguishable from "unreadable" — so it is fixed at the source rather than papered over
in the ingestor.

**What is already safe and needs no work**:

- **Bookmark failures** — `listAvailable()` routes through `mappingBookmarkErrors`, which
  throws `ActivitySourceError.notConfigured` / `.underlying` for a missing, moved, or
  access-revoked folder. Already a throw, already correct.
- **Undownloaded iCloud files** — a genuine surprise, and good news. `candidate(for:in:)`
  resolves `.icloud` placeholder stubs back to their real filenames via
  `materializedFileName(for:)`, so a not-yet-downloaded file **is still listed**. It is
  therefore never mistaken for a deleted one. The spec's worry about "synced files have not
  been downloaded yet" is already structurally handled by the listing design; no extra guard
  needed.
- **Unconfigured folder** — guarded twice: `scanFolder` checks `watchedFolder.isConfigured`
  before calling, and `listAvailable()` throws `.notConfigured` anyway.

**Alternatives considered**:

- *Refuse to reconcile when the listing is empty* — rejected. It conflates a legitimate "the
  user emptied the folder" with a failure, permanently stranding the last activities, and it
  still would not catch a listing that is partially short rather than empty.
- *Require two consecutive scans to agree before removing* — rejected as unrequested
  complexity. It halves the blast radius of a bad listing rather than fixing it, adds
  cross-scan state to an actor that currently holds none, and delays every legitimate removal
  by a scan cycle.

## 3. Which library items are eligible for removal? (FR-011)

**Decision**: remove item `i` iff `i.source == source.id` **and** `i.sourceId != nil` **and**
`i.sourceId!` is absent from the current candidate set.

**Rationale**: Each clause blocks a distinct way to delete the wrong thing.

- `source == source.id` is FR-011 directly — bundled samples (`"bundled"`), share-sheet
  imports (`"files"`), and Polar items (`"polar"`) are not the folder's to reconcile.
- `sourceId != nil` matters because `LibraryItem.sourceId` is documented as optional
  specifically for items written before the field existed. A nil `sourceId` cannot be matched
  against any candidate, so an unguarded diff would classify every legacy folder item as
  "missing from the folder" and delete the user's oldest data on first launch after upgrade.
  This is a real migration hazard, not a hypothetical.
- `sourceId` is a folder-relative path, so it survives the folder being moved or renamed —
  the property that makes it safe to compare across scans at all.

## 4. Ordering of removals and imports within one scan

**Decision**: list → read items → remove stale → re-read items → import fresh.

**Rationale**: `imported` is deliberately measured as a count delta
(`itemsAfter.count - itemsBefore.count`) rather than as successful decodes, because
`FileSystemLibraryStore.add` can decode a file and still append nothing when an identical
activity is already stored. Removing items in the middle of that measurement would corrupt it
— a scan that removed 3 and imported 3 would report 0 imported. Re-reading `allItems()` after
the removals re-baselines the delta. The extra read is paid only on scans that removed
something.

The existing early return must also change:

```swift
guard !candidates.isEmpty else { return FolderIngestReport() }
```

An empty folder that listed successfully is now a meaningful state — it means every folder
item should be reconciled away — so this can no longer short-circuit. It stays only as a
fast path for the case where the library also has no folder-sourced items.

## 5. Reporting a deletion that partially failed (FR-006)

**Decision**: replace `deleteSession`'s `String?` return with a `DeletionOutcome` value
carrying attempted count, failure count, and the first error.

**Rationale**: The spec now distinguishes three user-visible states — succeeded, partially
succeeded (some of the activity remains), failed outright. `String?` encodes two. The current
`SessionDetailView` shows any non-nil string under a flat "Couldn't Delete" title, which is
actively misleading when one device's data was in fact removed: the user is told nothing
happened while half the activity is gone.

Deliberately **not** transactional. Per the clarification, removals that succeeded stay
removed; `LibraryStore` has no rollback, and synthesizing one by re-adding from the orphaned
blob would be a second write that can also fail, turning one bad state into two.

## 6. Does reconciliation break the open detail view? (FR-013)

**Decision**: no change needed. Verified against the current view code.

**Rationale**: `SessionDetailView` builds its model in `.task(id: sessionId)` and stores it in
`@State`. A reconciliation-triggered `reload()` replaces `AppModel.batch`, and SwiftUI
re-creates the view struct with the new `batch` — but `sessionId` is unchanged, so the task
does not re-fire and the `@State` model keeps rendering already-loaded data. That is exactly
the behavior FR-013 specifies, and it is what the user chose on smallest-footprint grounds.

Confirmed the stale-view interaction is safe: deleting an already-removed activity from a
stale detail view calls `remove(itemId:)`, whose implementation is
`manifest.items.removeAll { $0.id == itemId }` — a no-op that throws nothing. It reports
success and dismisses, which is the correct outcome for "make this go away."

## 7. Existing text that contradicts the new behavior

**Finding**: `Sources/FitView/Settings/SettingsView.swift:99-102` tells the user:

> "Files are copied into the app's library, so removing one from the folder won't remove it
> here."

That is a direct statement of the behavior FR-009 reverses. It must be rewritten in the same
change, or the app will document the opposite of what it does. Included as a task rather than
left to be noticed later.

## 8. CI status (Constitution VI)

**Finding**: no workflow change needed — a correction to the concern raised during
`/speckit-clarify`.

`.github/workflows/tests.yml` already runs two jobs: `fitviewcore-tests` (`swift test`) and
`fitview-tests` (`xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests`). The
`FitViewTests` target was wired up during 004. Both target directories this plan adds tests to
are therefore already covered. Per Principle VI's double-check clause, the new suites still
need to be confirmed to fail when the code they cover is broken — called out explicitly in
quickstart.md §4 rather than assumed.
