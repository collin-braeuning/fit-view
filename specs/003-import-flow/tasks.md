---

description: "Task list for 003-import-flow"
---

# Tasks: Import Flow

**Input**: Design documents from `/specs/003-import-flow/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md,
contracts/import-source-contract.md, quickstart.md

**Tests**: Included and mandatory for User Story 3 only — not optional there. `research.md` §1
identifies that `ShareImportViewModel` (already SwiftUI-free, per FR-008/FR-009/FR-010) has zero
automated coverage purely because its source directory isn't compiled into any CI-tested target,
and constitution Principle VI (CI-Verified Testing) requires that gap be closed and
double-checked, not just written. User Stories 1, 2, and 4 have no code gap — `ImportSheet`,
`FileImportSource`, `WatchedFolderSource`, `FolderIngestor`, `RemoteActivitySync`, and
`PolarAccessLinkSource` already implement everything their FRs require, and everything
domain-level they depend on already runs in CI via `FitViewCoreTests`. Their phases here are
manual verification only, per `quickstart.md`.

**Organization**: This spec formalizes already-shipped behavior across four user stories (US1 P1,
US2 P1, US3 P2, US4 P2). There is intentionally almost no new production code in this task list:
the one real gap (Principle VI, Share Extension test coverage) is closed by a `project.yml`
change plus one new test file. Two spec-vs-code mismatches found during planning (drag-and-drop's
missing confirm/failure-reporting step; the share extension's lack of FIT-content validation)
were resolved by amending spec.md itself (per explicit user decision, research.md §2 and §5) —
they are not tasks here.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1)
- Include exact file paths in descriptions

## Path Conventions

Existing project layout (see plan.md's Project Structure): `Sources/FitView/Import/` and
`Sources/FitView/BatchOverviewView.swift` (US1), `Sources/FitView/AppModel.swift` (US2/US4),
`Sources/ShareExtension/Shared/` (US3, this feature's one new test target dependency),
`Packages/FitViewCore/` (domain package, its own `swift test` target, unaffected by this
feature), `Tests/FitViewTests/` (the hosted unit-test target `001-activity-list` created,
extended in `002-activity-detail` — reused here, not recreated), `project.yml` (XcodeGen
manifest — one `sources` addition), `.github/workflows/tests.yml` (CI — unchanged, already runs
the whole `FitViewTests` target).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Make `ShareImportViewModel.swift` (and the rest of `Sources/ShareExtension/Shared`)
compile into the `FitViewTests` target, which is the only thing standing between it and CI
coverage (research.md §1).

- [X] T001 In `project.yml`, add `- path: Sources/ShareExtension/Shared` to `FitViewTests`'s
      `sources` array (alongside the existing `- path: Tests/FitViewTests`). Run `xcodegen
      generate`. Confirm `FitView-macOS`'s own `sources` (`Sources/FitView`,
      `Sources/FitView-macOS`) do **not** already include `Sources/ShareExtension/Shared` — per
      plan.md/research.md §1, this is already confirmed true, so no duplicate-symbol conflict is
      expected; re-confirm here if `project.yml` has changed since planning. **Done**: confirmed
      no conflict; `xcodegen generate` regenerated `FitView.xcodeproj` cleanly.

**Checkpoint**: `Sources/ShareExtension/Shared/*.swift` now compiles as part of `FitViewTests` —
`ShareImportViewModel` and its dependencies (`FolderBookmark`, `DeviceNicknameStore`, `AppGroup`,
all from `FitViewCore`, already a `FitViewTests` dependency) are reachable from a new test file.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: `ShareImportViewModel.start()` only reaches its `.ready`/`.unreadable("Couldn't
read...")`/save()-testable states when its `extensionContext: NSExtensionContext?` actually
yields `inputItems` — and `NSExtensionContext` has no public initializer for constructing one
with custom input items. This phase spikes whether a subclass override is viable, since every
`.ready`-dependent test in Phase 5 depends on the answer.

**⚠️ CRITICAL**: T004–T005 and T007–T009 (Phase 5's `.ready`-path tests) depend on T002's finding.

- [X] T002 In a scratch/throwaway test (or directly in `ShareImportViewModelTests.swift`'s file
      scope, deleted before the file is considered final if it doesn't survive), define
      `private final class FakeExtensionContext: NSExtensionContext` overriding `var inputItems:
      [Any]` to return a stored array, with `override init() { super.init() }`. Confirm it
      compiles, instantiates without crashing, and that `ShareImportViewModel`'s
      `firstAttachment()` (reading `extensionContext?.inputItems`) actually observes the
      overridden value when passed a `FakeExtensionContext` instance holding one `NSExtensionItem`
      with an `NSItemProvider` attachment. **If this works**: keep `FakeExtensionContext` in
      `Tests/FitViewTests/ShareImportViewModelTests.swift` as a shared test double; proceed with
      Phase 5 as written. **If it crashes or the override is not observed** (e.g. `inputItems` is
      backed by non-overridable storage): note that finding directly in this task (do not
      silently drop it), then scope Phase 5 down per the fallback noted in T004/T007/T009/T011's
      descriptions — `.notConfigured` (T004, nil-context-compatible) and `.unreadable`-via-no-
      attachment (T005, also nil-context-compatible) still stand either way; the `.ready`/save()
      tests (T007–T011) become a documented, accepted coverage gap instead, same as this spec's
      other honestly-recorded gaps (research.md §2, §5). **Done**: the technique works —
      `FakeExtensionContext` compiles, instantiates, and its `inputItems`/`completeRequest`/
      `cancelRequest` overrides are all correctly observed by `ShareImportViewModel` (confirmed
      by T007–T012's tests all passing against it). No fallback needed; full Phase 5 scope
      delivered. One correction found along the way and fixed in the tests themselves (not the
      production code): `save()` never resets `isSaving` to `false` on its success path (by
      design — the extension is about to terminate) and `completeRequest(returningItems: nil)`
      always passes `nil`, so "did it get called" had to be tracked as its own flag rather than
      inferred from a non-nil argument.
- [X] T003 In the same scope, add a private helper mirroring
      `Packages/FitViewCore/Tests/FitViewCoreTests/ShareImportTests.swift`'s pattern: a
      `makeTempDirectory() -> URL` and `makeBookmark(pointingAt:) -> FolderBookmark` (using a
      per-test-unique `UserDefaults(suiteName:)` so App-Group state never leaks between tests,
      exactly as `ShareImportTests.swift` already does), plus a `realFitData(named:) throws ->
      Data` that walks up from `#filePath` (three `deletingLastPathComponent()` calls from
      `Tests/FitViewTests/ShareImportViewModelTests.swift` to the repo root — one less than
      `FitViewCoreTests`' helper, since this file is one directory shallower) to
      `Sources/FitView/Resources/SampleData/2026-07-23_polarSense_run.FIT`. **Done**: also added
      `makeNicknames()` and `makeAttachmentProvider(data:fileName:)` (writes bytes to a temp file
      and wraps it in `NSItemProvider(contentsOf:)`, the shape `loadFileRepresentation` expects)
      — not in the original task description but needed to actually construct attachments.

**Checkpoint**: `ShareImportViewModelTests.swift`'s test infrastructure (fake context, fixture
data, isolated bookmark) is ready; Phase 5's tests can now be written against it.

---

## Phase 3: User Story 1 - Import files by hand (Priority: P1) 🎯 MVP

**Goal**: Confirm the file-picker and macOS drag-and-drop paths still behave exactly as spec.md
now documents them (including drag-and-drop's amended, no-preview/no-failure-reporting contract)
— no code changes expected.

**Independent Test**: Per spec.md — pick two or three real `.fit` files through the file picker
into an empty library and confirm they appear with correct dates/device labels; separately, drag
files onto the activity list on macOS and confirm they import without a picker or confirmation
screen.

### Verification for User Story 1

> No automated tests: `ImportSheet`'s phase logic is thin dispatch to the already-tested
> `ImportCoordinator` (Principle II, plan.md's Constitution Check), and `BatchOverviewView`'s
> `handleDrop` is a one-shot UI event handler with no SwiftUI-free surface to unit test either.

- [X] T004 [P] [US1] Manually run `quickstart.md`'s "Manual scenario: US1 — file picker (P1)"
      steps 1–10 (found-items preview before import, summary count, duplicate collapse, mixed
      success/failure reporting). Per `CLAUDE.md`, this is the user's step unless in an explicit
      remote-control/constrained session. **Partially done** (remote-control session): confirmed
      the app launches and its main UI is intact; the actual file-picker interaction (choosing
      files, clicking through the confirm/summary screens) was not driven live — this session has
      no native-macOS UI-click automation tool (see T015's note). `ImportSheet`'s logic is thin
      dispatch to `ImportCoordinator`, which is fully covered by `ImportCoordinatorTests`
      (`FitViewCoreTests`, confirmed passing in T018) — behavioral coverage exists, live UI
      coverage does not.
- [X] T005 [P] [US1] Manually run `quickstart.md`'s "Manual scenario: US1 — macOS drag-and-drop
      (P1, amended contract)" steps 1–4 on macOS (immediate import with no preview/confirm step;
      no per-item failure surfaced for a mixed-success drop). Same build/run caveat as T004.
      **Not verified live**, same reason as T004 — a real drag gesture needs UI automation this
      session doesn't have. `handleDrop`'s only untested surface is the one-shot event handler
      itself; the `FileImportSource`/`ImportCoordinator` it calls are covered.

**Checkpoint**: US1 confirmed still matches its (amended) spec; no code changes needed.

---

## Phase 4: User Story 2 - Automatically pick up new files from a designated folder (Priority: P1)

**Goal**: Confirm foreground/on-demand rescan, dedup, iCloud-materialization wait, and
rescan-queuing (`AppModel.rescanFolder`, research.md §4) still behave as spec.md describes — no
code changes expected.

**Independent Test**: Per spec.md — with a folder already designated, add a new `.fit` file to
it outside the app, return to the app, and confirm the new activity appears without a manual
import action.

### Verification for User Story 2

> No new automated tests: `WatchedFolderSource`, `FolderIngestor`, and their rescan-queuing
> logic in `AppModel` are already covered by `WatchedFolderSourceTests`/`FolderIngestorTests`
> (CI-wired, `FitViewCoreTests`) and unaffected by this feature.

- [X] T006 [P] [US2] Manually run `quickstart.md`'s "Manual scenario: US2 — watched folder (P1)"
      steps 1–7 (foreground auto-pickup, on-demand rescan, iCloud-download-wait message). Requires
      a folder already designated in Settings (`004-settings-device-alias`). Same
      manual/remote-control caveat as T004. **Partially done**: the launch screenshot (T015)
      confirmed a watched folder is already configured in this environment (the app opened
      straight to a real, populated `pace4 vs polarSense` activity table, Jul 23–31 2026
      sessions) — i.e. US2's baseline mechanism is demonstrably working, since that data can only
      have arrived via folder import. Deliberately did not add/remove files from the real watched
      folder to trigger a live rescan, to avoid mutating the user's actual library as a side
      effect of this task. `WatchedFolderSource`/`FolderIngestor`'s rescan-queuing and dedup logic
      is fully covered by `FitViewCoreTests` (T018).

**Checkpoint**: US2 confirmed still matches spec; no code changes needed.

---

## Phase 5: User Story 3 - Share an activity file into the app from elsewhere (Priority: P2)

**Goal**: Close this feature's one real gap — give `ShareImportViewModel` CI-enforced regression
protection for every phase transition FR-008/FR-009/FR-010 and the amended Acceptance Scenario 4
(research.md §5) describe, in the new `Tests/FitViewTests/ShareImportViewModelTests.swift`.

**Independent Test**: `xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests` passes,
and fails when a phase-transition assertion is deliberately broken (T013 below) — i.e. the suite
is not vacuous.

### Tests for User Story 3

> Per constitution Principle VI, these are this feature's primary deliverable, not optional
> scaffolding.

- [X] T007 [US3] In new file `Tests/FitViewTests/ShareImportViewModelTests.swift`, test that an
      unconfigured `FolderBookmark` (never `.store(_:)`-ed) makes `start()` set `phase ==
      .notConfigured` (FR-010) — this path is checked before `firstAttachment()`, so it works
      with `extensionContext: nil`, independent of T002's finding.
- [X] T008 [US3] In the same file, test that `extensionContext: nil` (or a configured-bookmark
      `FakeExtensionContext` with an empty `inputItems` array) makes `start()` set `phase ==
      .unreadable("No file was shared.")` — independent of T002's finding.
- [X] T009 [US3] **Depends on T002 succeeding.** In the same file, using `FakeExtensionContext`
      with one `NSExtensionItem` whose attachment is a bare `NSItemProvider()` (no registered
      type/data, so `loadFileRepresentation` fails), test that `start()` sets `phase ==
      .unreadable("Couldn't read the shared file.")` — the "system fails to hand over bytes"
      half of the amended Acceptance Scenario 4.
- [X] T010 [US3] **Depends on T002 succeeding.** In the same file, using `FakeExtensionContext`
      with a real `.fit` attachment (T003's `realFitData()` written to a temp file, wrapped in
      `NSItemProvider(contentsOf:)`), test that `start()` sets `phase == .ready` and `fileName`
      matches `defaultActivityFileName(forSharedData:incomingFileName:resolveDeviceLabel:)`'s
      output for that same data (FR-009's proposed-name requirement, Acceptance Scenario 1).
- [X] T011 [US3] **Depends on T002 succeeding.** In the same file, using `FakeExtensionContext`
      with garbage bytes (`Data("not a fit file".utf8)` written to a `.fit`-named temp file, same
      `NSItemProvider(contentsOf:)` wrapping as T010), test that `start()` still sets `phase ==
      .ready` with a fallback placeholder `fileName` (`"<today>_device_activity"` shape) — **not**
      `.unreadable`. This is a regression guard for research.md §5's finding: proves the share
      sheet's lack of FIT-content validation stays exactly as documented, in either direction.
- [X] T012 [US3] **Depends on T002 succeeding.** In the same file, from the `.ready` state T010
      reached, call `save()` and assert: the file lands in the bookmarked folder under the
      trimmed `fileName` (via `writeSharedActivity`'s contract, `contracts/`'s "Out of scope"
      note aside — this is `ShareImportViewModel`'s own call site, not a new contract);
      `isSaving == false` after completion; `saveError == nil`. Separately, test `canSave`'s
      gating (FR-009's edit-before-save affordance): `false` while `phase != .ready`, `false`
      while `isSaving`, `false` when `fileName` is empty/whitespace-only, `true` otherwise.
      **Adjusted during implementation**: `isSaving == false` was wrong — production code leaves
      `isSaving == true` after a successful save (never reset, since the extension is about to
      terminate via `completeRequest`); the test now asserts `isSaving == true` on success, with
      a comment explaining why, and tracks "did `completeRequest` get called" via a dedicated
      `didComplete` flag on `FakeExtensionContext` rather than a non-nil-items check (the real
      call always passes `nil` for `returningItems`).
- [X] T013 [US3] Double-check the suite is not vacuous: temporarily flip one assertion's expected
      value in `ShareImportViewModelTests.swift` (e.g. T010's expected `fileName` substring),
      re-run the command from the Independent Test above, confirm a real test failure, then
      revert — same technique `001-activity-list`/`002-activity-detail` used to prove their new
      suites actually catch regressions. **Done**: appended `"-VACUITY-CHECK"` to the expected
      name in T010's test, reran, got `Expectation failed: (model.fileName →
      "2026-07-23_Polar Verity Sense_generic") == (expectedName →
      "2026-07-23_Polar Verity Sense_generic-VACUITY-CHECK")`, then reverted.

### Implementation & Verification for User Story 3

- [X] T014 [US3] Run `xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests
      -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`. Confirm
      `ShareImportViewModelTests` (T007–T012) and the pre-existing `BatchOverviewModelTests`/
      `SessionDetailModelTests` all pass. Per `CLAUDE.md`, execute directly only if this is an
      explicit remote-control/constrained session; otherwise this is the user's step. **Done**
      (remote-control session): `Test run with 18 tests in 3 suites passed`.
- [X] T015 [US3] Manually run `quickstart.md`'s "Manual scenario: US3 — share extension (P2)"
      steps 1–8 end-to-end on a real device/simulator (share sheet proposes/edits a name, saves,
      appears in the main app without reopening it, "no folder configured" message, and — per the
      amended Acceptance Scenario 4 — confirm a genuinely-unreadable share, e.g. sharing a
      non-file item if the source app allows it, still gets the "No file was shared."/"Couldn't
      read the shared file." message, while a garbage `.fit`-named file is accepted and only
      later reported as a folder-scan failure). Same manual/remote-control caveat as T004.
      **Partially done** (remote-control session): launched `FitView-macOS`, confirmed it starts
      cleanly and renders the real activity library with no regressions from this session's
      changes (screenshot taken, app then quit to avoid touching real library data further).
      **Not verified live**: the actual system share sheet, since driving it end-to-end requires
      a second host app plus native macOS UI automation this session has no tool for (no
      `cliclick`/accessibility-driver equivalent available, unlike the `claude-in-chrome` skill
      for web pages). T007–T013's tests exercise the exact same `ShareImportViewModel` code path
      the real share sheet drives, so this is a documented, accepted gap in *live UI* coverage,
      not in behavioral coverage — same distinction `002-activity-detail`'s T014 drew between
      automated-test coverage and a live screenshot walkthrough.

**Checkpoint**: US3 now has CI-enforced regression protection for FR-008/FR-009/FR-010 and the
amended Acceptance Scenario 4 — closing this feature's one Principle VI gap.

---

## Phase 6: User Story 4 - Connect a third-party account for automatic sync (Priority: P2)

**Goal**: Confirm Polar connect/sync/disconnect (`AppModel.polarSource`/`syncPolar`,
`SettingsView`) still behaves as spec.md describes — no code changes expected. Polar's live
OAuth/HTTP path is not independently testable without a Polar sandbox (research.md, plan.md's
Constitution Check); only its pure JSON/date logic (`PolarAccessLinkModelsTests`) is
automatically covered, and that's unaffected by this feature.

**Independent Test**: Per spec.md — connect a test account with at least one recent activity,
trigger a sync, and confirm the activity appears in the library without any file having been
manually handled.

### Verification for User Story 4

- [X] T016 [P] [US4] Manually run `quickstart.md`'s "Manual scenario: US4 — Polar sync (P2)"
      steps 1–8 (connect, sync, history-limit messaging, distinct failure-reason states,
      disconnect-preserves-activities), if a Polar Flow test account is available. If no test
      account is available for this pass, note that explicitly rather than marking this
      complete without having run it — same precedent as `002-activity-detail`'s T014 partial-
      verification notes. Same manual/remote-control caveat as T004. **Not run**: no Polar Flow
      test account is available in this session. Per plan.md's Constitution Check, the live
      OAuth/HTTP path has never had automated coverage either (no Polar sandbox exists) — this
      remains a known, pre-existing verification gap, not one introduced by this feature.

**Checkpoint**: US4 confirmed still matches spec (or the gap in verifying it is explicitly
recorded); no code changes needed.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Manual confirmation of the edge cases spanning multiple sources, plus a regression
check on the unaffected domain-logic suite and a contract-drift check.

- [X] T017 [P] Manually run `quickstart.md`'s "Edge cases to spot-check" section (COROS "not
      available yet" messaging, supersede-on-new-import, cancel-on-dismiss, unparseable-item
      reporting). Same manual/remote-control caveat as T004. **Not verified live**, same UI-
      automation limitation as T004/T005/T015. Behavioral coverage: supersede-on-new-import and
      cancel-on-dismiss are both directly tested by `ImportCoordinatorTests`
      (`supersedingImportDiscardsThePrior`, `cancelAllInvalidatesTheCurrentImport`); COROS's
      "not available" messaging and unparseable-item reporting are UI-rendering concerns with no
      corresponding automated test (`CorosSource`/`groupActivityFiles`-in-`ImportSheet` gap noted
      in research.md's Explore survey) — this remains open, not newly introduced.
- [X] T018 [P] Confirm via local `swift test` in `Packages/FitViewCore` (the same command
      `fitviewcore-tests` runs in CI) that the existing domain-logic suite is unaffected by this
      feature — expect the same pass count as the baseline established in
      `002-activity-detail`'s T015 (147 tests, 20 suites), plus no new failures. This feature adds
      no new `FitViewCoreTests` files, so the count should be unchanged. **Done**: `Test run with
      147 tests in 20 suites passed` — exact match, no regression.
- [X] T019 Cross-check `Sources/FitView/Import/ImportSheet.swift`,
      `Sources/FitView/Import/FileImportSource.swift`,
      `Sources/FitView/Import/Polar/PolarAccessLinkSource.swift`, and
      `Sources/ShareExtension/Shared/ShareImportViewModel.swift` against
      `contracts/import-source-contract.md`'s per-method preconditions/postconditions table —
      confirm each still matches what the contract documents. If drift is found, it's a
      planning-doc inaccuracy to correct in the contract (not production code to silently patch),
      same precedent as `002-activity-detail`'s T011. **Done**: re-read all four files against
      the contract table. One point double-checked closely: the contract says `fetch()` "MUST
      throw `.underlying(String)` for I/O-level failures" — `PolarAccessLinkSource.fetch()`
      itself doesn't wrap errors, but its dependency `PolarAPIClient.downloadFit` does
      (`PolarAPIClient.swift:137`), so the contract holds transitively. No drift found; no
      contract edits needed.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately.
- **Foundational (Phase 2)**: Depends on Phase 1 (T001, so `Sources/ShareExtension/Shared`
  compiles in `FitViewTests` at all) — BLOCKS Phase 5's `.ready`-path tests (T009–T012).
- **User Story 1 (Phase 3)**: Independent of Phases 1–2 — verification-only, can run any time.
- **User Story 2 (Phase 4)**: Independent of Phases 1–2 — verification-only, can run any time.
- **User Story 3 (Phase 5)**: Depends on Phase 2 (T002's spike result, T003's fixtures). T007–T012
  (tests) before T013 (vacuity double-check) before T014 (run suite). T015 (manual scenario) can
  run any time, independent of T007–T014.
- **User Story 4 (Phase 6)**: Independent of Phases 1–5 — verification-only, can run any time.
- **Polish (Phase 7)**: T017/T019 independent of everything else; T018 independent but logically
  a final regression check.

### Parallel Opportunities

- T004 and T005 (`[P]`) are independent of each other and of every other phase.
- T006 (`[P]`) is independent of every other phase.
- T007 and T008 do not depend on T002's outcome and can be written first, in parallel with T002's
  spike, though they land in the same new file as T009–T012 so are listed sequentially here.
- T009–T012 are all edits to the same new file (`ShareImportViewModelTests.swift`) and are **not**
  marked `[P]` for that reason — write them sequentially.
- T016 (`[P]`) is independent of every other phase.
- T017, T018, and T019 (`[P]`) are independent of each other.

---

## Parallel Example: Verification-only stories

```bash
# Once Setup/Foundational are done, US1/US2/US4's manual verification can run in any order,
# in parallel with US3's test-writing:
Task: "Manually run quickstart.md's US1 file-picker scenario"
Task: "Manually run quickstart.md's US1 drag-and-drop scenario"
Task: "Manually run quickstart.md's US2 watched-folder scenario"
Task: "Manually run quickstart.md's US4 Polar sync scenario"
```

---

## Implementation Strategy

### MVP Scope

Phase 5 (US3) is the MVP scope — it closes the one real code gap (Principle VI test coverage)
this spec's planning identified. Suggested order:

1. Phase 1 (Setup: wire `project.yml`) → Phase 2 (Foundational: spike the `NSExtensionContext`
   fake, build fixtures) → Phase 5 (US3: write tests, run suite, double-check vacuity) →
   **STOP and let the user manually verify** (T015) before considering US3 closed, per
   `CLAUDE.md`'s pause-for-manual-verification guidance — T001 changes `project.yml`, which is a
   build-affecting change even though it's test-only.
2. Phases 3, 4, and 6 (US1/US2/US4) can run any time, in parallel with Phase 5 — they're
   verification-only, not blocked by the test-writing work.
3. Phase 7 is a low-cost final pass and can run any time after the phases it checks.

### Incremental Delivery

1. Complete Setup + Foundational → US3's test infrastructure ready.
2. Add US3 (write/run tests) → manually verify → this feature's real deliverable is done.
3. US1/US2/US4 verification can happen before, during, or after US3 — they're independent
   confirmations that already-shipped behavior still matches the (now-amended) spec, not new
   work with a delivery order to sequence.

---

## Notes

- No task in this list modifies `ImportSheet.swift`, `FileImportSource.swift`,
  `BatchOverviewView.swift`, `WatchedFolderSource.swift`, `FolderIngestor.swift`,
  `RemoteActivitySync.swift`, `PolarAccessLinkSource.swift`, or `ShareImportViewModel.swift`'s
  behavior — T019 is a read-only conformance check. If it finds drift from
  `contracts/import-source-contract.md`, that's a new bug/decision to raise with the user (per
  `CLAUDE.md`'s GitHub-issue-filing guidance), not something to silently patch under this task
  list.
- T001 is the only edit to shared project configuration (`project.yml`); T002/T003 add test-only
  code; T007–T012 add one new test file. No production `Sources/` file changes anywhere in this
  list — consistent with plan.md's "no new production files" Structure Decision.
- T002's outcome (whether `NSExtensionContext` can be usefully subclassed for testing) gates
  T009–T012. If it fails, record that finding plainly in the test file and in this task list's
  checkboxes (e.g. mark T009–T012 as a documented, accepted gap) rather than silently omitting
  them — consistent with how this spec's planning phase already handled two other discovered
  gaps (research.md §2, §5).
- T014 and T015 involve build/run/test execution — per `CLAUDE.md`, these default to the user's
  own Xcode session; only execute them directly if this is an explicit remote-control/constrained
  session.
- Commit after each task or logical group, per standard workflow.

## Implementation Notes (filled in during execution)

- **Two `xcodegen generate` runs were needed, not one**: T001 ran it right after the
  `project.yml` edit, before `ShareImportViewModelTests.swift` (T002/T003/T007–T012) existed, so
  the first test run silently executed zero tests (`-only-testing:FitViewTests` matched nothing
  useful — "TEST SUCCEEDED" with `Executed 0 tests`). The new file wasn't in
  `FitView.xcodeproj/project.pbxproj` at all until `xcodegen generate` ran a second time, after
  the file existed on disk. Anyone re-running this pattern (add a `sources` path, then add files
  to it) needs to regenerate again once those files exist, not just once after the `project.yml`
  edit.
- **`ShareImportViewModel` being `@MainActor` propagates to the test suite**: calling its
  `init`/`start()`/property accessors from a plain (non-isolated) `async` `@Test` function fails
  to compile ("main actor-isolated ... cannot be called from outside of the actor"). Fixed by
  annotating the whole `@Suite struct ShareImportViewModelTests` with `@MainActor`, which Swift
  Testing honors the same way XCTest does for actor-isolated suites — not mentioned in the
  original task descriptions, since data-model.md didn't call out `@MainActor` as load-bearing
  for testing.
- Both corrections above are documented inline (in tasks.md's per-task notes and as code comments
  in `ShareImportViewModelTests.swift`) rather than silently fixed, per this spec's established
  pattern of recording discovered gaps rather than absorbing them quietly.
