# Implementation Plan: Import Flow

**Branch**: `003-import-flow` | **Date**: 2026-08-07 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/003-import-flow/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

Formalize the existing, shipped import surface — `ImportSheet` (file picker + bundled sample +
COROS placeholder), `FileImportSource`/macOS drag-and-drop, `WatchedFolderSource` +
`FolderIngestor` (auto-import), the Share Extension (`ShareImportViewModel`/`ShareEditView`),
and `PolarAccessLinkSource` + `RemoteActivitySync` (Polar Flow sync, configured from Settings) —
as the governing spec, and close the three real gaps found while doing so:

1. **Spec-vs-code mismatch, drag-and-drop (resolved by amending the spec, not the code)**: macOS
   drag-and-drop (`BatchOverviewView.handleDrop`) imports immediately, bypassing `ImportSheet`'s
   preview/confirmation step and discarding `ImportCoordinator`'s per-item failure list. The
   original spec draft required drag-and-drop to match the file picker exactly (FR-002/FR-003)
   and to report partial failures (FR-017) on every path uniformly — neither is true of the
   shipped code. Per user decision, spec.md now documents this as drag-and-drop's intended,
   current exemption (FR-002, FR-003, FR-017, SC-004, plus a new Edge Case and Assumptions
   entry) rather than treating it as a bug to fix in this feature.
2. **Spec-vs-code mismatch, share extension (resolved by amending the spec, not the code)**:
   `ShareImportViewModel.start()` never validates that shared bytes are actually valid FIT
   data — a garbage file still reaches `.ready` with a fallback-named proposal and can be saved;
   the failure only surfaces later via a folder rescan, not in the share sheet itself. The
   original spec draft's US3 Acceptance Scenario 4 implied the share sheet catches this
   directly. Per the same user decision (research.md §5), spec.md's Acceptance Scenario 4 now
   describes the actual two-tier behavior (attachment-transfer failure vs. content validity)
   instead.
3. **Test-coverage gap (Principle VI)**: `ImportSheet` (SwiftUI, drives FR-001/FR-003/FR-016)
   and the Share Extension's `ShareImportViewModel` (FR-008/FR-009/FR-010) have zero automated
   coverage today. Everything domain-level they depend on (`ImportCoordinator`,
   `FolderIngestor`, `WatchedFolderSource`, `RemoteActivitySync`, `PolarAccessLinkModels`, and
   the pure Share Extension helpers `defaultActivityFileName`/`writeSharedActivity`) is already
   covered by `FitViewCoreTests` and runs in CI today — this plan does not touch that layer.
   Unlike `002-activity-detail`'s gap, this one needs no new SwiftUI-free type to be extracted:
   `ShareImportViewModel` (`Sources/ShareExtension/Shared/ShareImportViewModel.swift`) already
   `import`s only `FitViewCore`/`Foundation`/`Observation`/`UniformTypeIdentifiers` — no
   `SwiftUI` — and is directly constructible and drivable in a test using real
   `NSExtensionItem`/`NSItemProvider(contentsOf:)` fixtures pointing at temp files, with `nil`
   passed for `extensionContext`. The actual gap is that its source directory,
   `Sources/ShareExtension/Shared`, is compiled only into the two extension targets
   (`FitViewShareExtension-iOS`/`-macOS`), never into anything `FitViewTests` links against —
   so nothing about it runs in CI purely because no test target compiles it. Closing it is a
   `project.yml` change (add `Sources/ShareExtension/Shared` as an extra `sources` path on the
   existing `FitViewTests` target) plus new tests — not new CI plumbing and not new production
   code. `ImportSheet` itself is not extracted into a presenter, for the same reason given in the
   Constitution Check below.

No UI redesign and no new import source are in scope. Polar connect/disconnect UI and watched-
folder selection UI belong to `004-settings-device-alias`, not here (per spec.md's "Note on
scope").

## Technical Context

**Language/Version**: Swift 5 (`SWIFT_VERSION: "5.0"` in `project.yml`), Xcode toolchain implied
by iOS 17 / macOS 14 deployment targets.

**Primary Dependencies**: SwiftUI (`ImportSheet`, `BatchOverviewView`'s drop handling,
`ShareEditView`), `UniformTypeIdentifiers` (file picker/drop UTType filtering),
`ASWebAuthenticationSession` (`PolarOAuthRunner`, inside `PolarAccessLinkSource` — app-layer
only, not in `FitViewCore`), `FitViewCore` local Swift package — specifically
`ActivitySource.swift` (`ActivitySource` protocol, `ImportCandidate`, `ImportedActivity`,
`ActivitySourceError`), `ImportCoordinator.swift` (atomic-batch fetch/decode/store-write with
cancel-on-supersede), `WatchedFolderSource.swift`/`FolderIngestor.swift` (folder scan, iCloud
materialization wait, id-diff dedup), `RemoteActivitySync.swift`/`PolarAccessLinkModels.swift`
(Polar polling, `RemoteSyncIdStore` dedup, wire-format decode), and the Share Extension's shared
helpers `defaultActivityFileName`/`writeSharedActivity`.

**Storage**: `FileSystemLibraryStore` (content-addressed blob storage keyed by `sha256Hex`, plus
a `(blobId, date, deviceKey, activityKey)` manifest match) is the actual cross-path dedup
mechanism behind FR-015 — `FolderIngestor`'s path-based id-diff and `RemoteSyncIdStore`'s
sourceId-diff are cheap pre-filters in front of it, not the source of truth. A shared App Group
container (`group.com.fitview.app`, `FolderBookmark` key `"FitView.WatchedFolder.bookmark"`)
lets the Share Extension write into the same watched folder the main app scans, which is how a
shared file becomes a library item without the app needing to be foregrounded.

**Testing**: Swift Testing (`@Suite`/`@Test`), not XCTest, throughout `FitViewCoreTests` —
`ImportCoordinatorTests`, `WatchedFolderSourceTests`, `FolderIngestorTests`,
`RemoteActivitySyncTests`, `PolarAccessLinkModelsTests`, `ShareImportTests`,
`FolderBookmarkTests`, `FolderSyncStoreTests`, `SharedActivityMetadataTests` all exist and run
in CI (`Packages/FitViewCore`'s `swift test` job in `.github/workflows/tests.yml`). The
`FitViewTests` target (`Tests/FitViewTests/`, hosted by `FitView-macOS`, created in
`001-activity-list`, extended in `002-activity-detail`) also already runs in CI but has no
import-related test file today. Resolved in Phase 0 research below (research.md §1–2).

**Target Platform**: iOS 17+ (iPhone + iPadOS), macOS 14+ for the main app
(`FitView-iOS`/`FitView-macOS`, sharing `Sources/FitView`); drag-and-drop is macOS-only
(`#if os(macOS)` in `BatchOverviewView`). The Share Extension ships as two separate targets,
`FitViewShareExtension-iOS` and `FitViewShareExtension-macOS`, both building
`Sources/ShareExtension/Shared` plus their platform-specific `ShareViewController`.

**Project Type**: Multiplatform SwiftUI app (mobile + desktop) from a single shared codebase,
plus two small App Extension targets.

**Performance Goals**: None explicitly stated in the spec. `WatchedFolderSource.fetch`'s iCloud
materialization wait (FR-007) has an existing default timeout (15s) that already satisfies "wait
up to a reasonable limit."

**Constraints**: Every source-listing/fetch path is `async throws` over the platform-agnostic
`ActivitySource` protocol — no networking or file-picker UI lives in `FitViewCore` itself
(Principle I). A batch import is one atomic operation (`overview.md` §11): starting a new one
cancels and discards whatever was in flight (FR-016), which `ImportCoordinator`'s
generation-counter already guarantees for every path that calls it. `RemoteActivitySync`
deliberately uses its own private `ImportCoordinator` instance inside `FolderIngestor`'s
consumer (`AppModel`), not the app's shared one, so a background rescan can never cancel a
user-initiated import and vice versa.

**Scale/Scope**: Four import sources (manual file/drop, watched folder, share extension, Polar
sync) plus one inert placeholder (COROS) plus the bundled sample source, all funneling through
the same `ActivitySource` → `ImportCoordinator` → `LibraryStore` pipeline.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Separation of Concerns & Shared Code | ✅ Pass | Every source's fetch/decode/dedup logic already lives in `FitViewCore` behind the `ActivitySource` protocol (`ActivitySource.swift`), independent of SwiftUI, and is unit-tested there. `ShareImportViewModel` is already SwiftUI-free (`Observation`, not `SwiftUI`) — it just isn't compiled into a CI-tested target yet (research.md §1). `ImportSheet` is the one SwiftUI-coupled piece, and it stays that way (see Principle II below). |
| II. Self-Contained, Reusable Components | ✅ Pass | `ImportSheet` owns its own `phase`/source-selection `@State` with no parent lifting it. `ShareImportViewModel` already owns its own `phase`/`isSaving`/`saveError` state independent of `ShareEditView`. No extraction is needed for either — `ImportSheet`'s phase logic is thin dispatch to the already-tested `ImportCoordinator`, and there is exactly one `ImportSheet`/`ShareEditView` call site each, so pulling a presenter out now would be exactly the premature generalization this principle warns against ("generalize only once a second real call site needs it"). |
| III. Human-Readable, Comfortably Spaced UI | ✅ Pass | No layout changes are in scope; existing `ImportSheet`/`ShareEditView` spacing is unaffected. |
| IV. Configurable, Not Hardcoded | ⚠ Pre-existing, out of scope | Same pattern as `001-activity-list`/`002-activity-detail`: the iCloud materialization timeout (`WatchedFolderSource`, 15s) and the rescan debounce (`AppModel`, 2s) are hardcoded constants, not settings. Cross-cutting, not introduced or enlarged by this feature — not this plan's to fix. |
| V. Local Logging for Diagnosis | ✅ Pass | `ActivitySourceError`'s four cases (`.notConfigured`/`.notAvailable`/`.unauthorized`/`.underlying`) already give FR-013's "specific reason" distinction; `ImportFailure` already carries a per-candidate message. No decoding path is introduced by this feature — `loadFitFile` remains the sole FIT parse boundary, already covered by Principle V elsewhere. |
| VI. CI-Verified Testing | ⚠ Pass with a gap to close | `ShareImportViewModel` has zero coverage today only because its source directory isn't compiled into any test target (research.md §1) — not because it needs restructuring. Closed by Phase 2 (tasks.md): add `Sources/ShareExtension/Shared` to `FitViewTests`'s `sources` in `project.yml`, then add `Tests/FitViewTests/ShareImportViewModelTests.swift` to the existing, already-CI-wired target. `ImportSheet` stays untested directly (by design, per Principle II above) but every state transition it drives (`ImportCoordinator.startImport`/`cancelAll`) is already covered by `ImportCoordinatorTests`. |

No unjustified violations. Principle IV's gap is pre-existing and cross-feature scoped. Principle
VI's gap is closed by this plan (see research.md §1), not merely flagged. The two spec-vs-code
mismatches found (drag-and-drop, research.md §2; share extension unreadable-data handling,
research.md §5) were both resolved by amending spec.md (per explicit user decision), not by
changing shipped code — so neither appears here as an open gap.

**Post-Phase-1 re-check**: data-model.md and contracts/import-source-contract.md document
`ActivitySource`'s existing contract and `ShareImportViewModel`'s existing `Phase`/state shape —
no new production types, no new storage, no new state; the only change is a `project.yml`
`sources` addition plus tests. Gate re-passes with the same one addressed gap (Principle VI,
closed by tasks.md) and the same one pre-existing, out-of-scope gap (Principle IV).

## Project Structure

### Documentation (this feature)

```text
specs/003-import-flow/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md         # Phase 1 output (/speckit-plan command)
├── quickstart.md         # Phase 1 output (/speckit-plan command)
├── contracts/            # Phase 1 output (/speckit-plan command)
│   └── import-source-contract.md
├── checklists/
│   └── requirements.md
└── tasks.md              # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
Sources/FitView/Import/                  # Shared across FitView-iOS and FitView-macOS targets
├── ImportSheet.swift                    # Screen: source picker, working/confirm/summary phases (FR-001, FR-003, FR-016, FR-017, FR-018)
├── FileImportSource.swift               # File-picker ActivitySource; also backs BatchOverviewView's macOS drop handler (FR-001, FR-002)
└── Polar/PolarAccessLinkSource.swift    # Polar ActivitySource; authorize()/disconnect() driven from AppModel + SettingsView, not ImportSheet (FR-011, FR-013, FR-014)

Sources/FitView/BatchOverviewView.swift  # handleDrop(providers:) — macOS drag-and-drop entry point (FR-002, documented exemption from FR-003/FR-017)

Sources/FitView/AppModel.swift           # rescanFolder/syncPolar — foreground + on-demand rescan, rescanQueued serialization (FR-006, edge case: rescan-in-progress)

Sources/ShareExtension/
├── Shared/ShareImportViewModel.swift    # Phase state machine + save() (FR-008, FR-009, FR-010) — already SwiftUI-free; Phase 2 wires this directory into FitViewTests (research.md §1)
├── Shared/ShareEditView.swift           # Proposed-name TextField + confirm (FR-009)
├── iOS/ShareViewController.swift        # Thin UIHostingController shell
└── macOS/ShareViewController.swift      # Thin NSHostingController shell

Packages/FitViewCore/Sources/FitViewCore/
├── ActivitySource.swift                 # ActivitySource protocol, ImportCandidate, ImportedActivity, ActivitySourceError (FR-013)
├── ImportCoordinator.swift              # Atomic batch fetch/decode/store-write, cancel-on-supersede (FR-016, FR-017)
├── WatchedFolderSource.swift            # Folder scan, iCloud placeholder normalization, ensureMaterialized (FR-004, FR-007)
├── FolderIngestor.swift                 # Diffs against store, ingests only new items (FR-005, FR-006)
├── RemoteActivitySync.swift             # Polar polling, RemoteSyncIdStore dedup, writes into watched folder (FR-011, FR-012, FR-015)
├── PolarAccessLinkModels.swift          # Wire-format decode, polarImportCandidate(from:) (FR-011, FR-012)
└── ShareImport.swift                    # defaultActivityFileName / writeSharedActivity — shared by Share Extension and RemoteActivitySync (FR-009)

Packages/FitViewCore/Tests/FitViewCoreTests/   # Existing, CI-wired — ImportCoordinatorTests, WatchedFolderSourceTests,
                                                 # FolderIngestorTests, RemoteActivitySyncTests, PolarAccessLinkModelsTests,
                                                 # ShareImportTests, FolderBookmarkTests, FolderSyncStoreTests — unaffected

Tests/FitViewTests/
├── BatchOverviewModelTests.swift        # Existing (001-activity-list), unaffected
├── SessionDetailModelTests.swift        # Existing (002-activity-detail), unaffected
└── (new, Phase 2) ShareImportViewModelTests.swift — see research.md §1
```

**Structure Decision**: No new source directories and no new production files — every file
listed above is existing, shipped code this spec documents as-is. The Principle VI gap is
closed by one small `project.yml` change (add `Sources/ShareExtension/Shared` to `FitViewTests`'s
`sources`) plus one new test file, `Tests/FitViewTests/ShareImportViewModelTests.swift`, added to
the `FitViewTests` target that already exists and already runs in CI — no `tests.yml` change
needed, since that workflow already runs the whole `FitViewTests` target.

## Complexity Tracking

*No entries — Constitution Check found no violation requiring a justified deviation.*
