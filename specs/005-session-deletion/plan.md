# Implementation Plan: Session Deletion

**Branch**: `005-session-deletion` | **Date**: 2026-08-08 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/005-session-deletion/spec.md`

## Summary

The spec splits cleanly into shipped behavior and new work.

**Already shipped (User Story 1, FR-001–FR-005, FR-007):** `SessionDetailView`'s "…" menu →
`confirmationDialog` → `AppModel.deleteSession` → `LibraryStore.remove` per device file →
`reload()`. Two-step confirmation, whole-activity deletion, source file untouched, and
post-attempt reload all work today.

**New work, three pieces:**

1. **Folder reconciliation (User Story 2, FR-009–FR-012)** — does not exist. Today
   `FolderIngestor.ingest` only ever adds: it diffs the folder against the library and imports
   what's new. Nothing removes a library item whose file left the folder. This is the bulk of
   the plan and lands in `FitViewCore`, where `swift test` already runs it in CI.

2. **A trustworthy "I read the whole folder" signal (FR-010)** — the safety guard the
   clarification asked for has no basis in the current code.
   `coordinatedContents(of:recursive:)` returns an **empty array with no error** when
   `FileManager.enumerator(at:)` returns nil (`FileCoordination.swift:117`). Reconciliation
   built on today's "didn't throw" would read that as "the user deleted every file" and wipe
   the library. Fixed at the source rather than worked around in the ingestor.

3. **Honest partial-failure reporting (FR-006)** — `deleteSession` returns `String?`, the
   first error only. The view shows it as a flat "Couldn't Delete". The spec now requires
   telling the user the deletion was *incomplete and part of the activity remains*, which the
   current return type cannot express.

Plus **FR-014** (diagnostic logging for deletion/reconciliation outcomes, Constitution V) and
one **documentation correction**: `SettingsView.swift:99-102`'s footer currently promises the
opposite of FR-009 — "removing one from the folder won't remove it here."

## Technical Context

**Language/Version**: Swift 5.9 (`SWIFT_VERSION 5.0` toolchain setting in `project.yml`)

**Primary Dependencies**: Foundation (`NSFileCoordinator`, `FileManager`), SwiftUI,
`Observation` (`@Observable`). No new third-party dependencies.

**Storage**: `FileSystemLibraryStore` — `manifest.json` + content-addressed
`blobs/<sha256>.fit` in the app container. `remove(itemId:)` drops the manifest entry only;
the blob is deliberately left (no reference counting). Unchanged by this plan.

**Testing**: XCTest. `swift test` in `Packages/FitViewCore` (where `FolderIngestorTests.swift`
and `WatchedFolderSourceTests.swift` already live) and `xcodebuild test -scheme FitView-macOS
-only-testing:FitViewTests` for `Sources/FitView`. Both already run in
`.github/workflows/tests.yml`, satisfying Constitution VI without workflow changes — the
concern raised at clarify time turned out to be already closed by 004.

**Target Platform**: macOS 14+, iOS 17+ (iPadOS via `TARGETED_DEVICE_FAMILY: "1,2"`)

**Project Type**: Native Apple app (`FitView-macOS`, `FitView-iOS`, share extension) over the
platform-independent `FitViewCore` package.

**Performance Goals**: Reconciliation must not add I/O to the common "nothing changed" scan.
It reuses the candidate listing and the `allItems()` read `ingest` already takes, so a clean
scan stays at one directory listing and zero file reads. One extra `allItems()` read is paid
only on scans that actually removed something.

**Constraints**: Removal is irreversible from inside the app (`remove` drops the manifest
entry; the orphaned blob is not exposed anywhere). That makes FR-010's guard the load-bearing
requirement in this plan — a false "the folder is empty" is unrecoverable data loss, not a
cosmetic bug.

**Scale/Scope**: Tens to low hundreds of activities in a watched folder; set-difference over
`sourceId` strings is not a scaling concern at this size.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment |
|---|---|
| I. Separation of Concerns & Shared Code | **PASS.** Reconciliation is folder/library diff logic with no SwiftUI dependency, so it belongs in `FitViewCore` beside the import diff it mirrors — placing it in `AppModel` would put the app's most destructive operation in the layer that is hardest to test. The listing-completeness fix lands in `FileCoordination.swift`, at the level that actually knows the enumerator failed. `AppModel` keeps only the thin call-through and user-facing reporting. |
| II. Self-Contained, Reusable Components | **PASS.** No new UI components. `scanSummary` gains a removal line; `SessionDetailView` keeps owning its own `isDeleting`/`deleteErrorMessage`/confirmation state. No state is lifted to a parent. |
| III. Human-Readable, Comfortably Spaced UI | **PASS.** Additions are one line in the existing scan summary and a longer alert message. No density increase; the corrected footer text is a rewrite, not an addition. |
| IV. Configurable, Not Hardcoded | **PASS with a noted decision.** Reconciliation is deliberately *not* user-configurable — the clarification chose "automatic with a safety guard" over a manual/opt-in flow, so a preference toggle would re-open a settled decision. This is a behavior contract, not a tunable threshold. Recorded in Complexity Tracking rather than silently absorbed. |
| V. Local Logging for Diagnosis | **PASS — and load-bearing here.** FR-014 exists because reconciliation deletes data without user action. Every removal, and every scan that *declined* to remove because the listing was untrustworthy, must be logged, or "my activities vanished" is undiagnosable after the fact. |
| VI. CI-Verified Testing | **PASS.** New tests go into `FitViewCoreTests` (already run by `swift test` in CI) and `FitViewTests` (already run via `xcodebuild test` in CI). Per the principle's double-check clause, the reconciliation tests must be confirmed to fail when reconciliation is broken — specifically, a test that asserts nothing is removed on an untrustworthy listing must be checked to fail if the guard is deleted. |

## Project Structure

### Documentation (this feature)

```text
specs/005-session-deletion/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   └── folder-reconciliation.md
├── checklists/
│   └── requirements.md
├── spec.md
└── tasks.md             # /speckit-tasks output — NOT created here
```

### Source Code (repository root)

```text
Packages/FitViewCore/Sources/FitViewCore/
├── FolderIngestor.swift        # CHANGED: reconciliation + FolderIngestReport.removed
├── FileCoordination.swift      # CHANGED: throw instead of silently returning []
├── WatchedFolderSource.swift   # unchanged — listAvailable already throws on bookmark failure
└── LibraryStore.swift          # unchanged — remove(itemId:) is already idempotent

Packages/FitViewCore/Tests/FitViewCoreTests/
├── FolderIngestorTests.swift   # CHANGED: reconciliation cases
└── FileCoordinationTests.swift # NEW: non-enumerable directory throws

Sources/FitView/
├── AppModel.swift              # CHANGED: DeletionOutcome, logging, scan reporting
├── Settings/SettingsView.swift # CHANGED: removal count in scanSummary; corrected footer
└── SessionDetail/SessionDetailView.swift  # CHANGED: incomplete-deletion message

Tests/FitViewTests/
└── SessionDeletionTests.swift  # NEW: DeletionOutcome message construction
```

**Structure Decision**: Existing layout, no new modules. The split follows Principle I —
diff/removal logic in `FitViewCore` under `swift test`, user-facing reporting in
`Sources/FitView`.

## Constitution Re-Check (post-Phase 1)

*Re-evaluated after research.md, data-model.md, contracts/, and quickstart.md.*

| Principle | Post-design assessment |
|---|---|
| I. Separation of Concerns & Shared Code | **PASS, strengthened.** Phase 0 confirmed reconciliation needs nothing beyond what `ingest` already holds, so it lands in `FitViewCore` with no new plumbing. The one app-layer addition (`DeletionOutcome`) is user-facing reporting, correctly placed in `Sources/FitView`. |
| II. Self-Contained, Reusable Components | **PASS.** Research §1 explicitly rejected extracting a `FolderReconciler` as premature — one call site, and splitting it would force a second `listAvailable()` call that breaks contract C4. Design adds no new types beyond the two values the spec's states require. |
| III. Human-Readable, Comfortably Spaced UI | **PASS.** Final surface is one extra line in `scanSummary`, a longer alert message, and a corrected footer. |
| IV. Configurable, Not Hardcoded | **PASS with the documented exception** in Complexity Tracking. No new hardcoded thresholds were introduced during design — notably, the "require two agreeing scans" idea was rejected in research §2, which would have added exactly the kind of tunable constant this principle governs. |
| V. Local Logging for Diagnosis | **PASS.** Contract C10 pins the non-obvious case: a scan that *declined* to reconcile is invisible in the UI, so it must be logged or the guard is unfalsifiable in the field. |
| VI. CI-Verified Testing | **PASS.** Both target directories already run in CI (research §8) — the gap flagged during `/speckit-clarify` was already closed by 004, so no workflow edit. The principle's anti-vacuous-pass clause is discharged by quickstart §4, which names the specific guards to delete and the tests that must then fail. |

**New violations introduced by the design: none.** The one deviation (reconciliation is not
user-configurable) was present at the pre-design gate and is unchanged.

## Complexity Tracking

| Decision | Why | Alternative rejected because |
|---|---|---|
| Reconciliation is not user-configurable, despite Principle IV | The clarification settled on automatic-with-guard; a toggle would reintroduce the manual-cleanup option that was explicitly weighed and rejected | Principle IV targets preferences like thresholds and defaults, not behavioral contracts the spec fixes. A "reconcile automatically?" switch would make FR-009 conditional and double the states the spec has to describe |
| `coordinatedContents` changes behavior for all callers, not just reconciliation | The silent-empty-on-nil-enumerator case is wrong for every caller; scoping the fix to reconciliation would leave the same trap for the next one | A reconciliation-local check cannot tell "empty folder" from "unenumerable folder" — that information only exists where the enumerator is created |
