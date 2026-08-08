# Phase 1 Data Model: Session Deletion

Types are described by their role and invariants. Signatures are indicative, not final.

## Existing types — unchanged

### `LibraryItem` (`FitViewCore/LibraryStore.swift`)

No field changes. Two existing fields become load-bearing for reconciliation:

| Field | Role in this feature |
|---|---|
| `source: String` | `"folder"`, `"bundled"`, `"files"`, `"polar"`. Only items matching the scanning source's id are reconcilable (FR-011). |
| `sourceId: String?` | Folder-relative path. The join key against `ImportCandidate.sourceId`. **`nil` means never reconcilable** — a legacy item predating the field cannot be matched and must not be inferred missing. |

### `LibraryStore.remove(itemId:)`

Unchanged, and already correct for this feature. `FileSystemLibraryStore` implements it as
`manifest.items.removeAll { $0.id == itemId }` — idempotent, throws nothing for an absent id,
leaves the blob. Reconciliation and in-app deletion both go through it.

## Changed types

### `FolderIngestReport` (`FitViewCore/FolderIngestor.swift`)

Gains one field.

| Field | Type | Meaning |
|---|---|---|
| `discovered` | `Int` | Existing. `.fit` files currently in the folder, downloaded or not. |
| `imported` | `Int` | Existing. Library growth, measured as a count delta. Re-baselined **after** removals so reconciliation cannot corrupt it. |
| `removed` | `Int` | **New.** Items removed because their file left the folder (FR-009). Zero on every scan that removed nothing, which is the overwhelmingly common case. |
| `failures` | `[ImportFailure]` | Existing. New-but-unreadable files. |

**Changed derived property:**

```swift
var didChangeLibrary: Bool { imported > 0 || removed > 0 }
```

This is what drives `AppModel` to call `reload()`, so a scan that only removed items must
report `true` or the activity list would keep showing activities that are gone.

**Invariants**

- `removed` counts items whose `remove(itemId:)` call completed. A removal that throws is not
  counted and does not abort the rest of the pass — same "one bad item must not sink the
  batch" rule the failure collection already follows.
- `removed == 0` whenever the listing was untrustworthy, because no reconciliation is
  attempted at all in that case (FR-010).

### `DeletionOutcome` (`Sources/FitView/AppModel.swift`) — new

Replaces `deleteSession`'s `String?` return, which cannot express "partially deleted".

| Case | Meaning | What the user is told |
|---|---|---|
| `succeeded` | Every device file removed | Nothing; the view dismisses |
| `partiallyFailed(removed: Int, failed: Int, firstError: String)` | Some removed, some not | The deletion was incomplete and part of the activity remains (FR-006) |
| `failed(firstError: String)` | Nothing removed | "Couldn't Delete", as today |

**Invariants**

- `partiallyFailed` requires `removed > 0 && failed > 0`. A two-device activity where both
  removals fail is `failed`, not `partiallyFailed`.
- The distinction is about what was *removed*, not what was attempted — FR-006 requires every
  device be attempted regardless.
- No case implies rollback. Successful removals stay removed in every case.

### `FileCoordinationError` (`FitViewCore/FileCoordination.swift`)

Gains one case:

| Case | Raised when |
|---|---|
| `directoryNotEnumerable(path: String)` | **New.** `FileManager.enumerator(at:)` returned `nil` — the URL is not an enumerable directory (replaced by a regular file, permissions lost, no longer resolves). Previously returned an empty listing with no error. |

This is the type-level change that makes FR-010's guard possible: without it, "folder is
empty" and "folder is unreadable" are the same value.

## Derived sets (computed per scan, not persisted)

Within one `ingest` pass, over one listing:

| Set | Definition | Used for |
|---|---|---|
| `present` | `Set(candidates.map(\.sourceId))` | Both directions of the diff |
| `known` | `sourceId`s of library items where `source == source.id`, nils dropped | Import: `candidates` whose id ∉ `known` |
| `stale` | Library items where `source == source.id` **and** `sourceId != nil` **and** `sourceId ∉ present` | Reconciliation: these are removed |

Both directions are computed from **one** `listAvailable()` result, so import and removal can
never act on two different observations of the folder.

## State transitions

One activity's lifecycle with respect to the library:

```
        import (file appears in folder)
absent ─────────────────────────────────> present
   ^                                         │
   │  reconcile (file leaves folder,         │  in-app delete
   │  trustworthy listing)                   │  (FR-001-FR-006)
   └─────────────────────────────────────────┤
                                             │
   ┌─────────────────────────────────────────┘
   │  re-import: if the file is STILL in the folder, the next
   └─ successful scan returns it to `present` (FR-008)
```

The loop on the right is the behavior the clarification made intentional: in-app deletion of a
still-present file is a temporary state, not a terminal one. The only durable path to `absent`
for a folder-sourced activity is removing the file from the folder.

**Untrustworthy listing**: no transition in either direction. Not a state of its own — the
scan makes no changes and the library stays exactly as it was (FR-010).
