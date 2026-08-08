# Contract: Folder Reconciliation

The internal contract between `WatchedFolderSource`, `FolderIngestor`, `LibraryStore`, and
`AppModel` for removing library items whose source file has left the watched folder.

This is an app-internal contract; FitView exposes no network or public API surface. The
"consumers" are the app layer (`AppModel`) and the test suites.

## C1 — Listing trustworthiness

> `ActivitySource.listAvailable()` returning normally MUST mean the source enumerated its
> entire contents. A source that cannot determine its full contents MUST throw.

**Obligation on `WatchedFolderSource`**: satisfied once `coordinatedContents(of:recursive:)`
throws `FileCoordinationError.directoryNotEnumerable` instead of returning `[]` when
`FileManager.enumerator(at:)` yields `nil`.

**Right of `FolderIngestor`**: may treat a returned candidate list as complete, and therefore
may treat any folder-sourced library item absent from it as genuinely deleted.

**Why it is stated this way**: the destructive direction of the diff is only sound if an empty
listing means "the folder is empty" and never "I couldn't look." Everything else in this
contract depends on C1.

| Condition | Required behavior |
|---|---|
| Folder readable, contains files | Return candidates |
| Folder readable, genuinely empty | Return `[]` — a valid, actionable observation |
| Folder not configured | Throw `ActivitySourceError.notConfigured` |
| Bookmark unresolvable / access revoked | Throw `ActivitySourceError.underlying` |
| Path is not an enumerable directory | Throw — **currently returns `[]`; this is the fix** |
| File present but not yet downloaded from iCloud | Listed normally, from its placeholder's real name — **not** an error, and never treated as missing |

## C2 — Reconciliation eligibility

> A library item MUST be removed by reconciliation iff all three hold:
> 1. `item.source == source.id`
> 2. `item.sourceId != nil`
> 3. `item.sourceId!` ∉ the candidate set from this scan's listing

Failing any clause, the item MUST be left untouched.

| Item | Reconciled? | Clause |
|---|---|---|
| `source: "folder"`, `sourceId: "run.fit"`, file gone | **Yes** | all three hold |
| `source: "folder"`, `sourceId: "run.fit"`, file present | No | (3) |
| `source: "bundled"` | No | (1) — FR-011 |
| `source: "files"` (share sheet) | No | (1) — FR-011 |
| `source: "folder"`, `sourceId: nil` (legacy item) | No | (2) — unmatchable, must not be inferred missing |

## C3 — No listing, no removal

> If `listAvailable()` throws, the scan MUST NOT remove any item, MUST NOT import any item,
> and MUST leave the library byte-identical.

Directly FR-010. The scan reports its error through the existing `folderError` path.

## C4 — One observation per scan

> Import and reconciliation within a single `ingest` pass MUST be computed from the same
> `listAvailable()` result.

Prevents a file that arrived or vanished between two listings from being simultaneously
imported and reconciled away, or missed by both.

## C5 — Partial progress is kept

> A removal that throws MUST NOT abort the pass. Remaining removals and the import phase MUST
> still be attempted, and the failed item MUST remain in the library.

Mirrors the existing rule for import failures, and matches the deletion contract (FR-006):
progress already made is never rolled back.

## C6 — Truthful counts

> `FolderIngestReport.removed` MUST equal the number of items actually removed.
> `FolderIngestReport.imported` MUST remain a measure of library growth, unaffected by
> removals in the same pass.

Requires re-baselining the item count after the removal phase. `imported` is a count delta,
not a decode count, precisely because `add` can succeed without appending.

## C7 — A changed library is a reloaded library

> `didChangeLibrary` MUST be true when `removed > 0`, and `AppModel` MUST reload the batch
> when it is.

Without this, reconciliation would remove items that stay visible in the activity list until
something else forces a reload (SC-005).

## C8 — Removals are reported, not announced

> A scan that removed items MUST surface the count in the same summary that already reports
> imports, and MUST NOT present a modal, alert, or other interruption (FR-012).

## C9 — Deletion outcome fidelity

> `AppModel.deleteSession` MUST attempt every device file regardless of earlier failures, MUST
> NOT undo successful removals, and MUST return an outcome that distinguishes complete
> success, partial failure, and total failure (FR-006).

**Consumer obligation on `SessionDetailView`**: a partial failure MUST be reported as an
incomplete deletion with part of the activity remaining — not as a flat "Couldn't Delete",
which misdescribes a state where data was in fact removed.

## C10 — Diagnosability

> Every removal (in-app or reconciliation), every deletion failure, and every scan that
> declined to reconcile because the listing was untrustworthy MUST be recorded in the local
> diagnostic log (FR-014, Constitution V).

The declined-reconciliation case is the one worth insisting on: it is invisible in the UI by
design, so without a log entry there is no way to tell "the guard is working" from "the guard
is stuck on."
