---

description: "Task list for 002-activity-detail"
---

# Tasks: Activity Detail View (Data Point Cards & Agreement Plots)

**Input**: Design documents from `/specs/002-activity-detail/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md,
contracts/session-detail-fields.md, quickstart.md

**Tests**: Included and mandatory for this feature — not optional. `research.md` §1 identifies
that `SessionDetailModel` (the production-mapping layer `SessionDetailView` already depends on)
has zero automated coverage, the same class of gap `001-activity-list` found in
`BatchOverviewModel`, and constitution Principle VI (CI-Verified Testing) requires it be closed
and double-checked, not just written.

**Organization**: This spec has two user stories (US1 P1, US2 P2), since it formalizes
already-shipped, already-implemented UI. There is intentionally no new production code in this
task list — `SessionDetailView.swift`, `StatTile.swift`, `AgreementPlotsSection.swift`,
`BlandAltmanChart.swift`, `ConcordanceChart.swift`, `MetricExplainerView.swift`, and
`SessionDetailModel.swift` already implement everything FR-001–FR-012 require. The work here
closes the testing/CI gap research.md identified, extends the existing preview fixture to reach
one edge case none of its current sessions exercise, and records a conformance check against the
field-presence contract.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1)
- Include exact file paths in descriptions

## Path Conventions

Existing project layout (see plan.md's Project Structure): `Sources/FitView/SessionDetail/`
(this feature's shared app source), `Packages/FitViewCore/` (domain package, its own `swift
test` target, unaffected by this feature), `Tests/FitViewTests/` (the hosted unit-test target
`001-activity-list` created — reused here, not recreated), `project.yml` (XcodeGen manifest,
unchanged by this feature), `.github/workflows/tests.yml` (CI, unchanged — `FitViewTests`
already runs there).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Confirm the `FitViewTests` target `001-activity-list` created is ready to host this
feature's tests as-is. Unlike 001, this feature needs no new target, scheme, or `project.yml`
change.

- [X] T001 Confirm `FitViewTests` in `project.yml` already depends on `FitView-macOS` (for
      `@testable import FitView`, which exposes `SessionDetailModel` and its internal supporting
      types) and that its Debug-only build configuration satisfies
      `Sources/FitView/SessionDetail/SessionDetailPreviewFixture.swift`'s `#if DEBUG` guard, the
      same way it already does for `BatchOverviewModelTests`. No `project.yml` edit expected —
      if one turns out to be needed, note it here before starting Phase 3. Confirmed:
      `FitViewTests` depends on `target: FitView-macOS` and `package: FitViewCore`; the
      `FitView-macOS` scheme's `test:` action already specifies `config: Debug`, matching how
      `BatchOverviewModelTests` already reaches `#if DEBUG`-gated code. No change needed.

**Checkpoint**: `FitViewTests` confirmed ready to host `SessionDetailModelTests` with zero
infrastructure changes.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: `SessionDetailPreviewFixture.makeBatch()` already covers 4 of this feature's 5
test-relevant scenarios (normal, missing-device, no-overlap, too-few-points) by running the real
grouping/agreement pipeline — reused as-is per research.md §1, no new
`Tests/FitViewTests/Fixtures/` file needed (unlike 001, which had to build
`AgreementFixtures.swift` from scratch). It does **not** yet cover Edge Case 1 (concordance
un-computable because both devices read an identical constant value) at the `SessionDetailModel`
level: `makeBatch()`'s "Normal" session has a constant *difference* (−1 bpm) but non-constant
*values* on each device, which is Bland-Altman's degenerate case, not concordance's — CCC stays
computable there. Closing this gap needs one more synthetic session.

**⚠️ CRITICAL**: T003–T008 in Phase 3 depend on this.

- [X] T002 Add a sixth session to `SessionDetailPreviewFixture.makeBatch()`
      (`Sources/FitView/SessionDetail/SessionDetailPreviewFixture.swift`): both devices reading
      the identical constant heart rate (e.g. `heartRate: 140` for both, over a fully-overlapping
      window ≥ `minMatchedSeconds`), following the same `record`/`activity` helpers already in
      the file, added to `activitiesByFileName` under a new date key (e.g.
      `"2026-08-06_pace4_run"` / `"2026-08-06_polarSense_run"`). This is the one addition to
      DEBUG-only preview/test fixture code this feature needs; no `SessionDetailModel` or view
      code changes.

**Checkpoint**: Fixture now has a session for every case `SessionDetailModelTests` needs
(normal, missing-device, no-overlap, too-few-points, constant-value); test-writing can begin.

---

## Phase 3: User Story 1 - Drill into one activity's full comparison (Priority: P1) 🎯 MVP

**Goal**: Make everything `SessionDetailModel` computes — chart points, the stats grid, both
agreement plots, per-device coverage, per-device source facts, and all three distinct skip-reason
explanations (FR-007, this spec's clarification) — verifiably correct, closing the gap where this
logic has driven the shipped detail screen with zero regression protection.

**Independent Test**: `xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests` passes,
and fails when a mapping rule is deliberately broken (T009 below) — i.e. the suite is not
vacuous.

### Tests for User Story 1

> Per constitution Principle VI, these are not optional scaffolding — they are this feature's
> primary deliverable, verifying behavior `spec.md`'s Acceptance Scenarios and Edge Cases already
> claim is shipped.

- [X] T003 [US1] In new file `Tests/FitViewTests/SessionDetailModelTests.swift`, test the
      "Normal" fixture session (`sessionId` for the `2026-08-01` pace4/polarSense pair): `agreement`
      non-nil; `matchedSecondsText == "200"` (full 200-second overlap); `bias?.text == "-1.0 bpm"`
      and `loaText == "[-1.0, -1.0]"` (every paired reading differs by exactly 1, per the
      fixture's `130 + i%10` / `131 + i%10` construction); `meanAbsDiff.text == "1.0 bpm"`,
      `maxAbsDiffText == "1 bpm"`; `ccc` non-nil (values vary, so concordance is computable even
      though the *difference* is constant — this is what distinguishes this session from T007's);
      `blandAltmanPlot` non-nil; `concordancePlot` non-nil; `chartPoints` non-empty and contains
      both `deviceLabels`; `lapBoundaries.isEmpty` and `lapSourceLabel == nil` (every fixture
      session's `activity()` helper produces exactly one lap per device, so no device ever has >1
      lap to source dividers from); `formattedDate` and `session.activity` (FR-001 — title/date);
      and, per-device, `deviceFacts.count == 2` plus each device's `fileName`, `sport`,
      `recordCount`, `lapCount`, `avgHeartRate`, `maxHeartRate` against the fixture's known
      `130 + i%10` / `131 + i%10` construction (FR-006 — previously only `deviceFacts.count` was
      asserted; added per `/speckit-analyze` finding C1/C2).
- [X] T004 [US1] In the same file, test the missing-device-file skip (the fixture session with
      only a `pace4` file, no `polarSense` file for that date): `agreement == nil`;
      `skipBannerText` matches `"No {secondary device label} file for this date."` (FR-007);
      `coverageDetails.count == 1`; `deviceFacts.count == 1`; `startTimeDeltaText == nil` (only
      one device has records, so there's no second timestamp to diff against).
- [X] T005 [US1] In the same file, test the no-overlap skip (the fixture session with disjoint
      time ranges): `agreement == nil`; `skipBannerText` matches the no-overlapping-seconds
      wording and is textually distinct from T004's and T006's; `startTimeDeltaText` non-nil
      (both devices have records, just no shared seconds).
- [X] T006 [US1] In the same file, test the too-few-points skip (the fixture session with exactly
      one shared second, below `minMatchedSeconds`): `agreement == nil`; `skipBannerText`
      contains the matched-second count and is textually distinct from T004's and T005's;
      `startTimeDeltaText` non-nil.
- [X] T007 [US1] In the same file, test the new constant-value session from T002 (Edge Case 1):
      `agreement` non-nil (both devices' readings are matched — this is not a skip); `ccc == nil`
      and `concordancePlot == nil`, while `bias` and `blandAltmanPlot` remain non-nil — proving
      one statistic's absence doesn't blank the other (FR-004).
- [X] T008 [US1] In the same file, test `coverageDetails` formatting against the "Normal" fixture
      session: `percentText` for each device is a `"NNN%"`-shaped string (not `"—"`, since both
      devices have full coverage in that session) and `ownSpanText` matches the
      `"{ownSeconds}s recorded over a {spanSeconds}s span"` template from
      `data-model.md`/`001-activity-list/data-model.md`.

### Implementation & Verification for User Story 1

- [X] T009 [US1] Run `xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests
      -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`. Confirm
      `SessionDetailModelTests` (T003–T008) and the pre-existing `BatchOverviewModelTests` all
      pass. Per `CLAUDE.md`, this is a build/run step — execute directly only if this is an
      explicit remote-control/constrained session; otherwise this is the user's step.
- [X] T010 [US1] Double-check the suite is not vacuous: temporarily flip one assertion's expected
      value in `SessionDetailModelTests.swift` (e.g. T003's `bias?.text` to a wrong value),
      re-run T009's command, confirm a real test failure, then revert — same technique
      `001-activity-list` used (its T013) to prove `BatchOverviewModelTests` actually catches
      regressions. Same build/run caveat as T009.
- [X] T011 [US1] Cross-check `Sources/FitView/SessionDetail/SessionDetailView.swift`,
      `StatTile.swift`, and `AgreementPlotsSection.swift` against
      `contracts/session-detail-fields.md`'s "By session state" and "Per-stat-tile presence"
      tables — confirm each section/tile's presence rule as implemented still matches what the
      contract documents. If drift is found, it's a planning-doc inaccuracy to correct in the
      contract (not production code to silently patch), same precedent as
      `001-activity-list`'s T010.

**Checkpoint**: US1 is now both feature-complete (already was, pre-existing) and
verification-complete — `SessionDetailModel` has CI-enforced regression protection covering the
normal case, all three skip reasons, and the constant-value edge case.

---

## Phase 4: User Story 2 - Understand what a statistic means (Priority: P2)

**Goal**: Confirm the explainer-reachability contract (FR-009/FR-010) — every stat tile and plot
that has an explanation is identifiable as tappable and reveals it in place; anything without one
is inert — still matches what's shipped.

**Independent Test**: Manual walkthrough of `quickstart.md` Scenarios 4–5 (tap a stat tile, tap a
plot's info control) confirms an in-context explanation appears without navigating away.

### Verification for User Story 2

> No new automated tests: `explainer` wiring (which `MetricKind` case each tile/plot gets) lives
> in `SessionDetailView.statsGrid`/`AgreementPlotsSection` — SwiftUI view code, not
> `SessionDetailModel` — so it isn't reachable from `FitViewTests`' XCTest-without-a-UI approach
> without adding a UI-testing dependency, which research.md didn't find justified for a single
> conformance check. This is a read-only, manual/inspection task instead.

- [X] T012 [P] [US2] Cross-check `SessionDetailView.swift`'s `statsGrid` against
      `contracts/session-detail-fields.md`'s "Per-stat-tile presence" table: confirm all six
      tiles (`Matched Seconds`, `Bias`, `95% LoA`, `Mean |Diff|`, `Max |Diff|`, `CCC`) pass a
      non-nil `explainer: MetricKind.*.explainer`, so FR-010's "not presented as tappable" case
      does not silently regress into affecting a tile that should be explorable.
- [X] T013 [P] [US2] Manually run `quickstart.md` Scenarios 4–5 (tap a stat tile with an info
      glyph; tap an agreement plot's info button) on both a narrow (iPhone) and wide (Mac or iPad)
      target, confirming the explanation is in-context (popover on regular width, sheet on
      compact) and dismissible without navigating away from the detail view. Per `CLAUDE.md`,
      this is the user's step unless in a remote-control session. **Verified live**
      (remote-control session): built and launched `FitView-macOS`, opened a real comparable
      session (Jul 31, 2026), tapped the "Matched Seconds" stat tile — its explainer popover
      appeared in place with title/summary/detail/unscored-note, confirming FR-009's mechanism
      (same code path every tile and plot info-button uses). Wide-width (Mac) only; narrow-width
      (iPhone/compact-sheet) not covered by this pass — no iOS simulator run.

**Checkpoint**: US2's explainer contract confirmed still matches shipped behavior; no code
changes needed.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Manual confirmation of the scenarios automated tests can't reach (full-screen chart
presentation, layout across widths, delete entry point), per `quickstart.md`, plus a regression
check on the unaffected domain-logic suite.

- [X] T014 [P] Manually run `quickstart.md` Scenarios 1–3 and 6–8 (full breakdown on open, skip
      banners for all three reasons, expand-chart full-screen presentation on both platforms,
      constant-value session, HR-range-paired-with-CCC, delete entry point visible) per
      `CLAUDE.md`'s manual-verification workflow — this is the user's step unless in a
      remote-control session. **Partially verified live** (remote-control session): opened a real
      comparable session, confirmed the full breakdown (chart with tooltip, lap-divider caption,
      all 6 stat tiles, CCC's HR-range detail line, agreement plots) and the expand-chart
      full-screen (macOS: resizable sheet, dismissible) presentation. **Not verified live**: the
      three skip-reason banners and the constant-value session — the user's real imported library
      (12 sessions, Jul 23–Aug 4 2026) has no skipped or constant-value sessions to click into;
      that behavior is covered instead by T003–T007's passing automated tests against the exact
      same `SessionDetailModel` code path, not a live screenshot. iOS/iPadOS narrow-width was not
      exercised in this pass. **FR-012 (delete entry point) scope note** (per `/speckit-analyze`
      finding C3): this task's "delete entry point visible" item was not verified in this pass —
      confirming the "..." toolbar menu offers "Delete Activity" is deliberately left to
      `005-session-deletion`, which spec.md already names as this screen's sole entry point into
      deletion (spec.md:105-108) and which owns the full confirmation/error/recoverability
      contract; that spec has not yet been through `/speckit-plan`, so no `quickstart.md` exists
      there yet to point to. Until it does, FR-012 here has no independent verification beyond
      this note — treat as a known gap, not a completed check.
- [X] T015 [P] Confirm via local `swift test` in `Packages/FitViewCore` (the same command
      `fitviewcore-tests` runs in CI) that the existing domain-logic suite is unaffected by this
      feature's one fixture addition (T002) — expect the same pass count as before T002, plus no
      new failures. Confirmed: 147 tests, 20 suites, all passing — matches
      `001-activity-list`'s T015 baseline exactly.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately.
- **Foundational (Phase 2)**: Depends on Phase 1 (T001) — BLOCKS Phase 3's tests (T003–T008).
- **User Story 1 (Phase 3)**: Depends on Phase 2 (T002). T003–T008 (tests) before T009 (run
  tests) before T010 (vacuity double-check). T011 (contract cross-check) is independent of
  T003–T008 and can run any time after Phase 1.
- **User Story 2 (Phase 4)**: Independent of Phase 3 — depends only on Phase 1. Can run in
  parallel with Phase 3.
- **Polish (Phase 5)**: Depends on Phases 3 and 4 both being complete.

### Parallel Opportunities

- T003–T008 are all edits to the same new file (`SessionDetailModelTests.swift`) and are **not**
  marked `[P]` for that reason — write them sequentially, even though each test case is logically
  independent.
- T011 is `[P]`-eligible against T003–T008 (different files) but is listed after them here for
  narrative order only.
- T012 and T013 (`[P]`) are independent of each other and of Phase 3 entirely.
- T014 and T015 (`[P]`) are independent of each other.

---

## Implementation Strategy

### MVP Scope

Phase 3 (US1) is the MVP scope — it closes the one real gap (test coverage) this spec's Phase 0
research identified. Suggested order:

1. Phase 1 (Setup) → Phase 2 (Foundational: extend the fixture) → Phase 3 (US1: write tests,
   verify, double-check vacuity, cross-check the contract) → **STOP and let the user manually
   verify** (Phase 5, T014) before considering US1 closed, per `CLAUDE.md`'s
   pause-for-manual-verification guidance.
2. Phase 4 (US2) can run any time after Phase 1, in parallel with Phase 3 — it's a read-only
   conformance/manual check, not blocked by the test-writing work.
3. T015 is a low-cost regression check and can run any time after Phase 2.

---

## Notes

- No task in this list modifies `SessionDetailView.swift`, `StatTile.swift`,
  `AgreementPlotsSection.swift`, `BlandAltmanChart.swift`, `ConcordanceChart.swift`, or
  `MetricExplainerView.swift`'s behavior — T011 and T012 are read-only conformance checks. If
  either finds drift from `contracts/session-detail-fields.md`, that's a new bug/decision to
  raise with the user (per `CLAUDE.md`'s GitHub-issue-filing guidance), not something to silently
  patch under this task list.
- T002 is the only edit to non-test source, and it's `#if DEBUG` preview/fixture code, not
  production behavior — consistent with plan.md's "no new production files" claim.
- T009, T010, and T014 involve build/run/test execution — per `CLAUDE.md`, these default to the
  user's own Xcode session; only execute them directly if this is an explicit
  remote-control/constrained session.
- Commit after each task or logical group, per standard workflow.
