# Phase 0 Research: Activity Detail View (Data Point Cards & Agreement Plots)

## 1. How should `SessionDetailModel` get unit-test coverage?

**Decision**: Add `Tests/FitViewTests/SessionDetailModelTests.swift` to the existing
`FitViewTests` target (created in `001-activity-list`, already wired into
`.github/workflows/tests.yml`). Build its fixtures on top of the existing
`SessionDetailPreviewFixture.makeBatch()` (`Sources/FitView/SessionDetail/
SessionDetailPreviewFixture.swift`, `#if DEBUG`) rather than hand-rolling a second `LoadedBatch`
builder. Cover: the normal-session mapping (chart points, stats grid values/levels, coverage
percentages, device facts) and all three skip-reason mappings (`missing device`, `no overlap`,
`too few points`), asserting `skipBannerText`'s wording is distinct per reason per the
clarification recorded in spec.md.

**Rationale**: `SessionDetailModel` (`Sources/FitView/SessionDetail/SessionDetailModel.swift`)
has no `import SwiftUI` and is, in its own doc comment, "a pure function of `(LoadedBatch,
sessionId)`" — the same shape of logic Principle I calls "directly unit-testable without a UI,"
and the same class of gap `001-activity-list/research.md` §1 found and fixed for
`BatchOverviewModel`. Unlike `BatchOverviewModel`, which only consumes a `BatchAgreement`,
`SessionDetailModel` also consumes raw per-device `FitRecord`s (for `chartPoints` and
`lapBoundaries`) and `FitActivity` metadata (for `deviceFacts`) — a `LoadedBatch` is required,
not just a `BatchAgreement`. Building one by hand for tests would duplicate
`SessionDetailPreviewFixture`, which already runs the real grouping/agreement pipeline over
made-up records and — at the time this research was written — had a dedicated session for 4 of
this spec's 5 test-relevant scenarios (`2026-08-01` normal, `2026-08-02` no-overlap, `2026-08-03`
too-few-points, `2026-08-04` missing device, plus `2026-08-05` scatter/ramp profile for visual
variety in previews). It did not yet cover Edge Case 1 (concordance un-computable because both
devices read an identical constant value) — that gap was found during task generation and closed
by adding a 6th session in Phase 2 (tasks.md T002). Reusing and extending this fixture is still
both less code and closer to the real pipeline than a fresh fixture would be. `#if DEBUG` does not
block reuse: XCTest/`FitViewTests`
builds in Debug configuration (same as SwiftUI previews), so the fixture is visible to
`@testable import FitView` there without any availability change.

**Alternatives considered**:
- *Hand-build a minimal `LoadedBatch` per test, independent of the preview fixture*: rejected —
  duplicates `SessionDetailPreviewFixture`'s grouping/agreement setup for no benefit, and two
  divergent "synthetic batch" builders is a maintenance trap (a future FitViewCore signature
  change would need updating in two places instead of one).
- *Move `SessionDetailModel` into `FitViewCore`*: rejected for the same reason
  `001-activity-list/research.md` §1 rejected it for `BatchOverviewModel` — it is
  presentation-mapping (display strings, chart point construction, lap-source selection), not
  domain logic (FIT decoding, alignment, statistics), so `FitViewCore`'s Principle-I scope
  doesn't claim it.
- *Leave it untested*: rejected — it is the layer that turns `SessionAgreement`/`FitActivity`
  into every number and every skip-reason sentence this spec's acceptance scenarios (User Story
  1, Edge Cases) depend on; an untested mapping bug here would silently misreport agreement data
  a user is specifically trying to diagnose.
- *Snapshot/UI tests of `SessionDetailView` itself*: out of scope for this pass, same reasoning
  as `001-activity-list/research.md` §1 — `SessionDetailModel` is the highest-leverage,
  cheapest-to-test layer; the view is a comparatively thin renderer of already-computed values.

## 2. Does the missing-device-file skip reason (this spec's clarification) need a `FitViewCore` change?

**Decision**: No. `SessionDetailModel` already derives it entirely client-side by checking
`session.filesByDeviceKey` against `orderedDeviceKeys` (`SessionDetailModel.swift:317-320`) —
`BatchAgreement`/`SkippedSession.Reason` in `FitViewCore` only has `.noOverlap`/`.tooFewPoints`
because a missing file is undetectable from the agreement layer alone (there's no
`SessionAgreement` *or* `SkippedSession` entry for a session where one device never recorded
anything that date — it simply doesn't reach the batch-agreement pipeline for that pairing).

**Rationale**: The three-way distinction the clarification requires (missing file / no overlap /
too few points) is already implemented exactly as spec.md's updated FR-007 describes; this
research item exists to record *why* it lives in `SessionDetailModel` rather than as a new
`SkippedSession.Reason` case, so a future contributor doesn't "fix" it by pushing the check into
`FitViewCore` unnecessarily. Moving it would also require `FitViewCore` to know about per-device
file presence, which `BatchAgreement`'s current input shape (`BatchAgreementInput.SessionSamples`,
already reduced to samples-by-device-key) doesn't carry.

**Alternatives considered**:
- *Add a `.missingDevice` case to `FitViewCore.SkippedSession.Reason`*: rejected — would require
  plumbing per-device file presence through `BatchAgreementInput`, a `FitViewCore` API change,
  for a distinction the presentation layer can already make from data it already has
  (`session.filesByDeviceKey`, from `001-activity-list`'s grouping output).

## 3. Are the agreement-level thresholds (Principle IV) in scope to fix here?

**Decision**: Out of scope, same as `001-activity-list/research.md` §3.

**Rationale**: `differenceLevel`/`cccLevel` in `FitViewCore/AgreementScale.swift` are consumed
identically by the list, this detail view, and the batch summary — a cross-cutting
settings-layer gap that no single feature's spec can close in isolation. Re-flagged here (not
re-solved) so the Constitution Check table above has a citation, per the constitution's
compliance-review requirement.

**Alternatives considered**: None new beyond what `001-activity-list/research.md` §3 already
considered and rejected.
