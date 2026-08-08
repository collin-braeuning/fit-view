---

description: "Task list for Session Deletion (005)"
---

# Tasks: Session Deletion

**Input**: Design documents from `/specs/005-session-deletion/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/folder-reconciliation.md, quickstart.md

**Tests**: Included — the spec's clarification made FR-010 (the safety guard) load-bearing
against unrecoverable data loss, and Constitution VI requires new suites be checked for vacuous
passing. Quickstart §1/§2/§4 name the exact scenarios and the deliberate-failure checks.

**Organization**: User Story 1 (P1) is already-shipped behavior — this plan does not touch it
except for the `DeletionOutcome` reporting change carved out by FR-006/C9, which lives in its
own phase below since it changes an existing return type. User Story 2 (P2) is the new
reconciliation work and is the bulk of this plan.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2)

## Path Conventions

Existing layout, no new modules (per plan.md's Structure Decision):

- `Packages/FitViewCore/Sources/FitViewCore/` — reconciliation + listing-completeness fix
- `Packages/FitViewCore/Tests/FitViewCoreTests/` — `swift test`
- `Sources/FitView/` — app-layer reporting and UI
- `Tests/FitViewTests/` — `xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests`

---

## Phase 1: Setup

No project initialization needed — existing Swift package and Xcode project, no new
dependencies or targets (plan.md Technical Context). Nothing to do in this phase.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The listing-completeness fix (C1) that both User Story 2's reconciliation and its
own test suite depend on. Nothing in Phase 4 can be written correctly until a scan can tell
"empty" from "unreadable."

**⚠️ CRITICAL**: Phase 4 (US2) cannot start until this phase is complete — reconciliation's
core safety property (FR-010) has no basis without it (research.md §2).

- [X] T001 Add `case directoryNotEnumerable(path: String)` to `FileCoordinationError` in
  `Packages/FitViewCore/Sources/FitViewCore/FileCoordination.swift` (near the existing
  `materializationTimedOut`/`accessorNeverRan` cases, line ~4-13)
- [X] T002 In `coordinatedContents(of:recursive:)`
  (`Packages/FitViewCore/Sources/FitViewCore/FileCoordination.swift:112-118`) — **implementation
  note**: the nil-check originally planned here was verified empirically to never fire for a
  regular file, a missing path, or a permission-denied directory; the real fix passes an
  `errorHandler` closure to `enumerator(at:...)` and throws
  `FileCoordinationError.directoryNotEnumerable(path: readURL.path)` when it fires, with the
  nil-check kept as defense in depth. research.md/data-model.md/contracts updated to match.
- [X] T003 [P] Add `Packages/FitViewCore/Tests/FitViewCoreTests/FileCoordinationTests.swift`
  with a test that replaces a directory with a regular file of the same name and asserts
  `coordinatedContents(of:recursive:
  true)` throws `FileCoordinationError.directoryNotEnumerable` instead of returning `[]`
  (quickstart.md §1 "Directory replaced by a regular file", contract C1)

**Checkpoint**: `coordinatedContents` throws instead of silently returning `[]` for an
unenumerable directory, and a test pins it down. Reconciliation work in Phase 4 can now rely on
"`listAvailable()` didn't throw" meaning "the folder was read completely" (C1).

---

## Phase 3: User Story 1 — Remove an unwanted activity from the library (Priority: P1)

**Goal**: FR-001–FR-005, FR-007 are already shipped and unchanged by this plan (plan.md
Summary). The only new work under US1 is FR-006/C9: replacing `deleteSession`'s `String?`
return with a `DeletionOutcome` that can express "partially deleted," and updating
`SessionDetailView` to report that state honestly instead of a flat "Couldn't Delete".

**Independent Test**: Import an activity from outside the watched folder, delete it, confirm it
is gone and the source file untouched (already passing, unaffected by this phase). For the new
behavior: delete a two-device activity where one device's removal is forced to fail and confirm
the user is told the deletion was incomplete rather than seeing a flat failure or a silent
success.

### Tests for User Story 1

- [X] T004 [P] [US1] Add `Tests/FitViewTests/SessionDeletionTests.swift` with tests for
  `DeletionOutcome` construction from removal results: both succeed → `.succeeded`; one succeeds
  one fails → `.partiallyFailed(removed: 1, failed: 1, firstError:)`; both fail → `.failed`, not
  `.partiallyFailed` (data-model.md's invariant: `partiallyFailed` requires `removed > 0 &&
  failed > 0`) (quickstart.md §2, contract C9)

### Implementation for User Story 1

- [X] T005 [US1] Add `enum DeletionOutcome` to `Sources/FitView/AppModel.swift` with cases
  `succeeded`, `partiallyFailed(removed: Int, failed: Int, firstError: String)`, and
  `failed(firstError: String)`, matching the invariants in data-model.md (`partiallyFailed`
  requires `removed > 0 && failed > 0`; no case implies rollback)
- [X] T006 [US1] Change `deleteSession(_:)` in `Sources/FitView/AppModel.swift:243-255` to
  return `DeletionOutcome` instead of `String?` — count successful vs. failed removals across
  `session.filesByDeviceKey.values` (still attempting every device regardless of earlier
  failures per FR-006/C9) and map the counts to the new enum; keep `await reload()` unconditional
  so the UI reflects the library's actual state either way (FR-007)
- [X] T007 [US1] Add a `log(...)` call in `deleteSession` for each device removal outcome
  (succeeded/failed, and which device) so a deletion or partial failure is diagnosable from the
  local log alone (FR-014, contract C10) — follow the existing pattern in
  `Sources/FitView/AppModel.swift`'s `syncPolar`/`connectPolar` (e.g. line ~500-513)
- [X] T008 [US1] Update `delete(_:)` and the "Couldn't Delete" alert in
  `Sources/FitView/SessionDetail/SessionDetailView.swift:128-153` to switch on `DeletionOutcome`:
  `.succeeded` dismisses as today; `.partiallyFailed` shows a message that the deletion was
  incomplete and part of the activity remains (not the flat "Couldn't Delete" title, since data
  was in fact removed); `.failed` keeps today's "Couldn't Delete" behavior

**Checkpoint**: User Story 1's already-shipped delete flow now reports partial failure honestly
instead of collapsing it into "Couldn't Delete." Independently testable/buildable without any of
Phase 4.

---

## Phase 4: User Story 2 — Keep the library matching the watched folder (Priority: P2)

**Goal**: Build folder reconciliation (FR-009–FR-012) — a scan that successfully and completely
reads the watched folder removes library items whose file has left it, reports the removal count
alongside imports, and (via Phase 2's fix) never removes anything when it can't confirm a
complete read.

**Independent Test**: With a watched folder configured, delete a `.fit` file from the folder
outside the app, trigger a scan, and confirm the corresponding activity is gone from the
library — then repeat with the folder made unreadable and confirm nothing is removed
(quickstart.md §6–§7).

**Depends on**: Phase 2 (Foundational) — reconciliation's safety guard has no basis without the
`directoryNotEnumerable` throw.

### Tests for User Story 2

> Per quickstart.md §4, these must be checked to fail when the guards they cover are removed —
> do this deliberately once implementation lands, not skipped as a formality.

- [X] T009 [P] [US2] Add reconciliation test cases to
  `Packages/FitViewCore/Tests/FitViewCoreTests/FolderIngestorTests.swift` covering the
  quickstart.md §1 table:
  - file removed from folder, scan runs → item gone from store, `report.removed == 1` (FR-009,
    SC-005)
  - file still in folder, item deleted from store beforehand → item re-imported,
    `report.imported == 1` (FR-008)
  - `listAvailable()` throws (e.g. folder unconfigured/bookmark revoked) → nothing removed,
    nothing imported, store unchanged (FR-010, SC-006, C3)
  - folder legitimately empty, library has folder-sourced items → all folder items removed
    (FR-009)
  - non-folder items (`source: "bundled"`, `source: "files"`) present, folder empty → left
    untouched (FR-011, C2)
  - folder item with `sourceId == nil` → left untouched (C2, the legacy-item guard)
  - one removal throws mid-pass → remaining removals and the import phase are still attempted
    (C5)
  - a scan that removes 2 and imports 2 → `report.removed == 2` **and** `report.imported == 2`
    (C6)
  - a scan that only removed items → `report.didChangeLibrary == true` (C7)
  - an unchanged folder → `removed == 0`, `imported == 0` (existing no-op behavior, must still
    hold)

### Implementation for User Story 2

- [X] T010 [US2] Add `public var removed: Int` to `FolderIngestReport` in
  `Packages/FitViewCore/Sources/FitViewCore/FolderIngestor.swift:4-31`, defaulted to `0` in
  `init`, and change `didChangeLibrary` to `imported > 0 || removed > 0` (data-model.md)
- [X] T011 [US2] In `FolderIngestor.ingest(into:)`
  (`Packages/FitViewCore/Sources/FitViewCore/FolderIngestor.swift:82-124`), remove the early
  `guard !candidates.isEmpty else { return FolderIngestReport() }` short-circuit (research.md
  §4 — an empty-but-successful listing is now a meaningful state, not a no-op) and compute the
  `stale` set: library items where `source == source.id`, `sourceId != nil`, and `sourceId` is
  absent from the candidate set's `sourceId`s (contract C2)
- [X] T012 [US2] In the same `ingest(into:)`, remove every item in `stale` via
  `store.remove(itemId:)` before the import phase, counting successful removals into
  `removed`; a removal that throws must not abort the pass — continue to the remaining removals
  and the import phase regardless (contract C5), matching the existing "one bad item doesn't
  sink the batch" pattern used for import `failures`
  (`Packages/FitViewCore/Sources/FitViewCore/FolderIngestor.swift:105-112`)
- [X] T013 [US2] Re-read `store.allItems()` after the removal phase and use it (not the
  original `itemsBefore`) as the baseline for the `imported` count delta, so `removed` and
  `imported` are both truthful in the same pass (research.md §4, contract C6); ensure the
  returned `FolderIngestReport` carries both `removed` and `imported` together with `discovered`
  and `failures`
- [X] T014 [US2] In `Sources/FitView/AppModel.swift`'s `scanFolder`
  (`Sources/FitView/AppModel.swift:329-380`), add a `log(...)` call for a scan whose `catch`
  branch fires — this is the "declined to reconcile because the listing was untrustworthy" case
  from contract C10, invisible in the UI by design (FR-014, FR-010) — and a `log(...)` call
  reporting `report.removed` when it is greater than 0, alongside the existing import logging
  pattern

**Checkpoint**: A scan that successfully reads the folder reconciles stale items; a scan that
can't confirm a complete read removes nothing; both are logged. Independently testable via
`swift test` in `Packages/FitViewCore` without touching `Sources/FitView` UI beyond T015-T017
below.

### UI Surface for User Story 2

- [X] T015 [US2] Update `scanSummary(_:)` in
  `Sources/FitView/Settings/SettingsView.swift:217-237` to show `report.removed` alongside
  `report.imported` when `removed > 0` — no alert or modal, in the same summary text/line that
  already reports imports (FR-012, contract C8)
- [X] T016 [US2] Rewrite the footer text at
  `Sources/FitView/Settings/SettingsView.swift:99-102` — it currently says "removing one from
  the folder won't remove it here," which is now the opposite of FR-009's behavior (research.md
  §7); correct it to state that removing a file from the watched folder removes the
  corresponding activity from the library on the next successful scan

**Checkpoint**: All of User Story 2's acceptance scenarios (spec.md lines 108-118) are now
implemented and independently testable per quickstart.md §6.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Verification steps that span both stories, called out explicitly by
plan.md/quickstart.md rather than left implicit.

- [ ] T017 **Partially verified locally, `gh pr checks` itself not run** (needs a pushed PR).
  Ran the local equivalent of both CI jobs directly: `swift test` in `Packages/FitViewCore`
  (166/166 passing) and `xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests`
  (31/31 passing, **TEST SUCCEEDED**) — also ran `xcodebuild build -scheme FitView-macOS`
  (**BUILD SUCCEEDED**), confirming the whole app target compiles with these changes. Once
  pushed, still confirm `fitviewcore-tests`/`fitview-tests` actually ran green on the PR itself
  (Constitution VI) — a local pass is a convenience, not verification, per quickstart.md §3.
- [X] T018 Deliberately break each new guard and confirm its test fails, then restore it
  (quickstart.md §4, Constitution VI's anti-vacuous-pass clause):
  1. removed the `sourceId != nil` clause from the reconciliation eligibility filter (T011) →
     the legacy-item test (T009) failed as expected, confirmed via `swift test`
  2. reverted the `directoryNotEnumerable` throw (T002) back to `return` → `FileCoordinationTests`
     (T003) failed as expected. **Finding**: `unenumerableFolderDoesNotReconcile` (T009) did
     *not* fail — at the full `WatchedFolderSource` pipeline level, replacing the watched
     folder with a regular file is independently caught one layer up, by
     `FolderBookmark.resolve()`'s `URL(resolvingBookmarkData:...)` noticing the resource's type
     changed, before `coordinatedContents` is ever reached. `FileCoordinationTests` remains the
     precise regression test for the `coordinatedContents` fix itself (it calls the function
     directly, bypassing bookmark resolution); the FolderIngestor-level test's comment was
     corrected to describe what it actually validates (end-to-end "never reconciles on an
     unenumerable folder," not the specific enumerator/errorHandler mechanism)
  3. restored both, re-ran `swift test` — all 166 tests pass
- [ ] T019 **Not run** — requires a real Xcode build/run against a live watched folder, which
  is outside this session's default scope per the project's workflow preference (no
  build/run/launch unless in a remote-control session). Run the manual passes in
  quickstart.md §5–§9 in Xcode against a real watched folder: deletion (already-shipped,
  confirm unaffected), reconciliation, the safety guard (rename the folder, then replace it
  with a regular file), the open detail view during a reconciling scan (FR-013), and exporting
  the diagnostic log to confirm it records removals, failures, and declined-reconciliation
  scans (FR-014)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: none — nothing to do
- **Foundational (Phase 2)**: no dependencies, start immediately — **BLOCKS Phase 4** (US2)
- **User Story 1 (Phase 3)**: no dependency on Phase 2; can proceed in parallel with it
- **User Story 2 (Phase 4)**: depends on Phase 2 completing first (T001-T003 before T009-T014)
- **Polish (Phase 5)**: depends on Phases 3 and 4 both being complete

### User Story Dependencies

- **User Story 1 (P1)**: independent of User Story 2 — touches `AppModel.deleteSession` and
  `SessionDetailView`, neither of which Phase 4 changes
- **User Story 2 (P2)**: independent of User Story 1's `DeletionOutcome` work — touches
  `FolderIngestor`, `FileCoordination`, and the Settings scan summary. Depends only on Phase 2.

### Within Each Phase

- Phase 2: T001 → T002 (same file, sequential) → T003 (test, can start once T001/T002 land)
- Phase 3: T004 (test) can be written before T005-T008 exist, per quickstart's "write tests
  first" note, then T005 → T006 → T007 → T008 (each builds on the prior in the same two files)
- Phase 4: T009 (tests) alongside T010-T013; T010 → T011 → T012 → T013 (same file, sequential
  — each step depends on the previous transformation of `ingest`); T014 depends on T013; T015 and
  T016 depend on T010/T013 (need `report.removed` to exist) but are independent of each other

### Parallel Opportunities

- T003 (new `FileCoordinationTests.swift`) can run alongside T001/T002 once drafted, though it
  will only pass once they land
- T004 (`SessionDeletionTests.swift`, new file) is fully parallel with all of Phase 4 — different
  files, no shared state
- T009 (`FolderIngestorTests.swift` additions) is a different file from T010-T013's
  `FolderIngestor.swift`, so it can be drafted in parallel, though (as with T003) it only passes
  once the implementation lands
- T015 and T016 are both in `SettingsView.swift` but touch disjoint regions (scanSummary vs.
  footer) — safe to do together, not marked [P] only because they share a file

---

## Parallel Example: Phase 2 → Phase 4 handoff

```bash
# Phase 2, sequential (same file):
Task: "Add directoryNotEnumerable case to FileCoordinationError"
Task: "Throw it from coordinatedContents instead of returning []"

# Then, in parallel:
Task: "FileCoordinationTests.swift — unenumerable directory throws"
Task: "Begin drafting FolderIngestorTests.swift reconciliation cases (Phase 4)"
```

---

## Implementation Strategy

### MVP First

Phase 3 (User Story 1's `DeletionOutcome` fix) is small, self-contained, and delivers FR-006's
honest partial-failure reporting on its own — it is a reasonable place to stop and ship if only
one increment is wanted. But per plan.md, User Story 2 (Phase 4, gated by Phase 2) is "the bulk
of the plan" and the feature's primary new capability; treat Phase 2 + Phase 4 as the real MVP
target, with Phase 3 landing alongside it since both are small.

### Incremental Delivery

1. Phase 2 (Foundational) — the listing-completeness fix, done first since Phase 4 cannot be
   correctly tested without it
2. Phase 3 (US1) and Phase 4 (US2) in parallel — they touch disjoint files and have no shared
   dependency once Phase 2 is done
3. Phase 5 (Polish) — the deliberate-failure check (T018) and manual passes (T019), last, since
   they validate both stories together

---

## Notes

- [P] tasks touch different files with no dependency on an incomplete task in this plan
- [US1]/[US2] map tasks to spec.md's user stories for traceability
- T018's deliberate-break-and-confirm step is not optional polish — it is Constitution VI's
  anti-vacuous-pass clause, and the guard it exercises (FR-010) is what stands between a bad
  scan and unrecoverable data loss (data-model.md, research.md §2)
- Commit after each task or logical group, per repo convention
