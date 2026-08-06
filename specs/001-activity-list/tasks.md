---

description: "Task list for 001-activity-list"
---

# Tasks: Activity List (Activity Card)

**Input**: Design documents from `/specs/001-activity-list/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/activity-list-fields.md, quickstart.md

**Tests**: Included and mandatory for this feature — not optional. `research.md` §1 identifies
that `BatchOverviewModel` (the production-mapping layer the shipped UI already depends on) has
zero automated coverage, and the constitution's Principle VI (CI-Verified Testing, v1.1.0)
requires any new test suite to be wired into CI and double-checked, not just written.

**Organization**: This spec has a single user story (US1, P1 — spec.md has no US2/US3), since it
formalizes already-shipped, already-implemented UI. There is intentionally no new production
code in this task list — `SessionCard.swift`, `BatchOverviewCardList.swift`,
`BatchOverviewView.swift`, and `BatchOverviewModel.swift` already implement everything
FR-001–FR-006 require. The work here closes the testing/CI gap research.md identified and
records a conformance check against the field-parity contract.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1)
- Include exact file paths in descriptions

## Path Conventions

Existing project layout (see plan.md's Project Structure): `Sources/FitView/` (shared app
source), `Packages/FitViewCore/` (domain package, its own `swift test` target, unaffected by
this feature), `project.yml` (XcodeGen manifest), `.github/workflows/tests.yml` (CI). This
feature adds `Tests/FitViewTests/` as a new test location.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Stand up the missing test target research.md §1 calls for, so US1's tests have
somewhere to live and run.

- [X] T001 Add a `FitViewTests` unit-test target to `project.yml`: `type: bundle.unit-test`,
      `platform: macOS`, `sources: [Tests/FitViewTests]`, hosted by `FitView-macOS`
      (`dependencies: [{target: FitView-macOS}]`, with `TEST_HOST`/`BUNDLE_LOADER` settings
      pointing at the built `FitView.app` binary, the standard XcodeGen recipe for a
      hosted-unit-test bundle) so test files can `@testable import FitView` and reach
      `BatchOverviewModel`, `SessionRow`, `SkippedRow`, `Metric`, and `DeviceCoverageDetail`,
      all of which are internal, not public. Also required `GENERATE_INFOPLIST_FILE: YES`
      (the target has no Info.plist of its own) and an explicit `schemes:` entry for
      `FitView-macOS` with `FitViewTests` in its `test.targets` — XcodeGen's default
      per-target scheme autogeneration does not attach a hosted test target to its host's
      scheme on its own, discovered when `xcodebuild test -scheme FitView-macOS` initially
      failed with "Scheme FitView-macOS is not currently configured for the test action."
- [X] T002 Create the `Tests/FitViewTests/` directory. (Subsumed by T004 — the fixtures file
      was the first real source file, so no separate placeholder was needed.)
- [X] T003 Run `xcodegen generate` to regenerate `FitView.xcodeproj` with the new `FitViewTests`
      target (per `CLAUDE.md`: this is a manifest-driven regeneration, not a build/run step, and
      is always fine to run directly). Ran twice more after T001's scheme/Info.plist fixes.

**Checkpoint**: `FitViewTests` exists as a buildable, empty target; `swift`/Xcode should now
show it in the scheme list.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared fixtures every US1 test needs, so each test file isn't hand-rolling
`BatchAgreement`/`SessionAgreement` construction independently.

**⚠️ CRITICAL**: T005–T009 in Phase 3 depend on this.

- [X] T004 Create `Tests/FitViewTests/Fixtures/AgreementFixtures.swift`. **Revised from the
      original plan**: `SessionAgreement`/`SkippedSession`/`ActivitySession` have no `public
      init` in `FitViewCore` (confirmed by grep before writing), so they cannot be constructed
      directly from this target. Instead, `AgreementFixtures.batch(_:)` builds real
      `ActivityDescriptor`s (which do have public init), runs them through the actual
      `groupActivities` + `buildBatchAgreement` public pipeline, and returns a genuine
      `BatchAgreement` — exercising the same alignment/statistics code production does rather
      than hand-assembling internal structs. Also discovered while designing fixtures: the
      "constant value" nil case is CCC-only, not CCC-and-Bland-Altman as originally assumed —
      `calculateBlandAltmanStats` has no nil case for paired, non-empty input, so `bias` is
      never actually nil in production; `data-model.md`'s per-field description was already
      correct, only tasks.md's T006 wording (below) was too broad. Corrected there.

**Checkpoint**: Fixture builders compile and are importable from any file under
`Tests/FitViewTests/`; user story test-writing can begin.

---

## Phase 3: User Story 1 - Scan all activities at a glance (Priority: P1) 🎯 MVP

**Goal**: Make the summary data every activity-list entry shows (concordance + HR range, bias,
mean/max absolute difference, agreement level, skipped reason) verifiably correct — closing the
gap where this logic (in `BatchOverviewModel.swift`) has driven the shipped UI with zero
regression protection.

**Independent Test**: `xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests` passes,
and fails when a mapping rule is deliberately broken (T012 below) — i.e. the suite is not
vacuous.

### Tests for User Story 1

> Per constitution Principle VI, these are not optional scaffolding — they are this feature's
> primary deliverable, verifying behavior `spec.md`'s Acceptance Scenarios 1–3 already claim is
> shipped.

- [X] T005 [US1] In `Tests/FitViewTests/BatchOverviewModelTests.swift`, test that a `SessionRow`
      built from a "full" fixture (differing, non-constant HR values on both devices) produces
      non-nil `bias`, `loaText`, `ccc`, `cccWord`, with levels/text hand-computed and asserted
      as literal expected values (e.g. `bias?.level == .good`, `ccc?.text == "0.800"`,
      `ccc?.level == .bad`) rather than re-derived via `differenceLevel`/`cccLevel` at assert
      time — a stronger check, since it would catch e.g. a swapped `avgAbsDiff`/`maxAbsDiff` or
      signed-vs-`abs` bug that a re-derived assertion would not.
- [X] T006 [US1] **Revised** (see T004): tests the actually-reachable nil case — both devices
      reading the identical constant value — where `ccc`/`cccWord` are nil and
      `cccAccessibilityLabel` matches the documented fallback sentence, while `bias`/`loaText`
      are asserted **present** (`"0.0 bpm"`, `.good`), not nil, since that branch is unreachable
      through the real `buildBatchAgreement` pipeline.
- [X] T007 [US1] Tests `SkippedRow.reasonText` for both `SkippedSession.Reason` cases against
      the two exact strings documented in `data-model.md`'s SkippedRow table.
- [X] T008 [US1] Tests `BatchOverviewModel.init`: `title` formats as
      `"{primaryName} vs {secondaryName}"`, and `rows` is sorted by `date` descending given a
      two-session fixture with dates out of order.
- [X] T009 [US1] **Revised** (see T004): tests only the reachable `DeviceCoverageDetail`
      formatting (`"100%"`, `"5s recorded over a 5s span"`) — the `"—"`/nil-coverage fallback in
      `DeviceCoverageDetail.formatPercent`/`formatOwnSpan` turned out to be unreachable too:
      `intersectHeartRate` always returns exactly one `DeviceCoverage` per device passed in, and
      `buildBatchAgreement` always passes exactly two, so `primaryDeviceCoverage`/
      `secondaryDeviceCoverage` are never nil for an accepted session. Not asserted, since a
      fixture forcing that branch would test a state production can't produce.

### Implementation & Verification for User Story 1

- [X] T010 [US1] Cross-checked `Sources/FitView/SessionCard.swift`,
      `Sources/FitView/BatchOverviewCardList.swift`, and `Sources/FitView/BatchOverviewView.swift`
      against the field-parity table. **Found and fixed real drift — in the contract doc, not
      the code**: the table claimed the narrow (<900pt) table drops `hrRangeText`, `loaText`,
      and `maxAbsDiffText`. Re-reading `narrowSessionsTable`'s actual column list shows it keeps
      an "HR Range" column — only `loaText`/`maxAbsDiffText` are actually dropped. Corrected
      `contracts/activity-list-fields.md` and the matching "9 columns / reduced N-column"
      claim in `quickstart.md` (was "6-column", corrected to "7-column"). No production code
      changed — this was a planning-doc inaccuracy caught by checking it against source, exactly
      what this task exists for.
- [X] T011 [US1] Ran `xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests
      -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` (the
      `CODE_SIGNING_*=NO` overrides are CLI-only, not written into `project.yml` — they sidestep
      the app targets' provisioning-profile requirement for this unsigned local test run without
      touching the real signing config). All 5 tests in `BatchOverviewModelTests` passed.
      Executed directly in this session per the user's explicit "go ahead and run the tests for
      validation" request in this conversation, which is the documented exception to
      `CLAUDE.md`'s normal hands-off-the-build default.
- [X] T012 [US1] Added a `fitview-tests` job to `.github/workflows/tests.yml`, alongside the
      existing `fitviewcore-tests` job: installs XcodeGen via `brew`, runs `xcodegen generate`,
      then the same `xcodebuild test` invocation as T011. Satisfies constitution Principle VI's
      "MUST run in CI on pull requests, not just exist" requirement. **Not yet verified running
      on an actual GitHub Actions runner** — that requires pushing/opening a PR, which is a
      shared-remote action outside this task list's local scope; flagged to the user rather than
      done automatically.
- [X] T013 [US1] Double-checked locally rather than via a real push (pushing a deliberately
      broken commit to trigger CI, as originally planned, would affect the shared remote and
      wasn't authorized): flipped one assertion's expected `AgreementLevel` in
      `BatchOverviewModelTests.swift` from `.good` to `.bad`, re-ran the same `xcodebuild test`
      command, confirmed a real failure (`Expectation failed: (row.bias?.level → .good) ==
      .bad`, `** TEST FAILED **`), then reverted. Proves the suite is not vacuous. The CI job
      itself (T012) still needs a first real run on GitHub Actions to confirm the workflow YAML
      is correct end to end — recommend doing that via the next PR rather than a throwaway one.

**Checkpoint**: US1 is now both feature-complete (already was, pre-existing) and
verification-complete — the mapping layer it depends on has CI-enforced regression protection.

---

## Phase 4: Polish & Cross-Cutting Concerns

**Purpose**: Manual confirmation of the scenarios automated tests can't reach (visual layout,
navigation, cross-widths), per `quickstart.md`.

- [ ] T014 [P] Manually run `quickstart.md`'s Scenarios 1–7 (mirroring `spec.md`'s Acceptance
      Scenarios 1–5 plus the two Edge Cases) on both a narrow (iPhone) and wide (Mac or iPad
      landscape ≥900pt) target, per `CLAUDE.md`'s manual-verification workflow — this is the
      user's step unless in a remote-control session.
- [X] T015 [P] Confirmed via local `swift test` in `Packages/FitViewCore` (the same command
      `fitviewcore-tests` runs): 147 tests, 20 suites, all still passing, unaffected by this
      feature's changes.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately.
- **Foundational (Phase 2)**: Depends on Phase 1 (T001–T003) — BLOCKS Phase 3's tests.
- **User Story 1 (Phase 3)**: Depends on Phase 2 (T004). T005–T009 (tests) before T011
  (run tests) before T012–T013 (CI wiring + double-check). T010 (contract cross-check) is
  independent of T005–T009 and can run any time after Phase 1.
- **Polish (Phase 4)**: Depends on Phase 3 being complete.

### Parallel Opportunities

- T001–T002 can proceed together; T003 (`xcodegen generate`) must come after both.
- T005–T009 are all edits to the same new file (`BatchOverviewModelTests.swift`) and are
  **not** marked `[P]` for that reason — write them sequentially to avoid merge conflicts, even
  though each test case is logically independent.
- T010 is `[P]`-eligible against T005–T009 (different files) but is listed after them here for
  narrative order only.
- T014 and T015 are independent of each other and can run in parallel.

---

## Implementation Strategy

### MVP Scope

This entire feature *is* the MVP scope (single P1 user story). Suggested order:

1. Phase 1 (Setup) → Phase 2 (Foundational) → Phase 3 (US1: write tests, verify, wire into CI,
   double-check CI catches failures) → **STOP and let the user manually verify** (Phase 4, T014)
   before considering this feature closed, per `CLAUDE.md`'s pause-for-manual-verification
   guidance (this task list makes no UI changes, so the pause is about confirming the
   *documentation* — spec/contract — matches shipped behavior, not about reviewing a diff).
2. T015 is a low-cost regression check and can run any time after Phase 3.

---

## Notes

- No task in this list modifies `SessionCard.swift`, `BatchOverviewCardList.swift`, or
  `BatchOverviewView.swift`'s behavior — T010 is a read-only conformance check. If it finds
  drift from `contracts/activity-list-fields.md`, that drift is a new bug/decision to raise with
  the user (per `CLAUDE.md`'s GitHub-issue-filing guidance), not something to silently patch
  under this task list.
- T003, T011, and T014 involve build/run/test execution — per `CLAUDE.md`, these default to the
  user's own Xcode session; only execute them directly if this is an explicit
  remote-control/constrained session.
- Commit after each task or logical group, per standard workflow.
