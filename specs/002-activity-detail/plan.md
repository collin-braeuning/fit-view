# Implementation Plan: Activity Detail View (Data Point Cards & Agreement Plots)

**Branch**: `002-activity-detail` | **Date**: 2026-08-06 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-activity-detail/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

Formalize the existing, shipped activity-detail screen (`SessionDetailView`, `StatTile`,
`AgreementPlotsSection`, `BlandAltmanChart`, `ConcordanceChart`, `MetricExplainerView`,
`SessionDetailModel`) as the governing spec, and close the one real gap found while doing so:
`SessionDetailModel` — the SwiftUI-free presenter that maps a `LoadedBatch`/`sessionId` into
everything the view renders — has no XCTest coverage today, the same class of gap
`001-activity-list` found in `BatchOverviewModel` and fixed by adding the `FitViewTests` target.
That target already exists (added in 001), so closing this gap is "extend it," not "create it
again." No UI redesign is in scope; this also documents the clarification resolved in
spec.md (missing-device-file is a third, distinct skip reason).

## Technical Context

**Language/Version**: Swift 5 (`SWIFT_VERSION: "5.0"` in `project.yml`), Xcode toolchain implied
by iOS 17 / macOS 14 deployment targets.

**Primary Dependencies**: SwiftUI (views, Swift Charts for `BlandAltmanChart`/`ConcordanceChart`),
`FitViewCore` local Swift package — specifically `ComparisonTimeline.swift`
(`buildComparisonTimeline`), `AlignSamples.swift` (`intersectHeartRate`), `Statistics.swift`
(Bland-Altman/CCC/absolute-difference calculations), `ScatterDensity.swift`
(`blandAltmanDensity`/`concordanceDensity`/`DensityCloud`, the density-cloud reduction that keeps
the scatter plots legible at hundreds of points), `MetricExplainer.swift` (`MetricKind`,
explainer copy), and `AgreementScale.swift` (`AgreementLevel`, `differenceLevel`, `cccLevel`).

**Storage**: N/A for this feature — `SessionDetailView` reads an already-loaded `LoadedBatch`
(via `AppModel`/`SessionDetailModel(batch:sessionId:)`); how that batch was loaded (folder
import, share extension, Polar sync) is out of scope, same as `001-activity-list`.

**Testing**: XCTest (Swift Testing framework, per `BatchOverviewModelTests.swift`'s `@Suite`/
`@Test` style). The `FitViewTests` target (`Tests/FitViewTests/`, hosted by `FitView-macOS`,
created in `001-activity-list`) already runs in CI (`.github/workflows/tests.yml`) but currently
covers only `BatchOverviewModel`. `SessionDetailModel` is structurally identical in kind — plain
Swift/Foundation, no `import SwiftUI`, a pure function of `(LoadedBatch, sessionId)` — but has
**zero** automated coverage. Unlike `BatchOverviewModel` (which only needed a hand-built
`BatchAgreement`), `SessionDetailModel` needs a full `LoadedBatch` (raw per-device records, for
chart points, lap boundaries, and device facts). `SessionDetailPreviewFixture.swift`
(`#if DEBUG`) already builds exactly this — including dedicated sessions for the normal case and
all three skip reasons (no-overlap, too-few-points, missing-device) — through the real grouping/
agreement pipeline, not hand-rolled stand-ins. Resolved in Phase 0 research below.

**Target Platform**: iOS 17+ (iPhone + iPadOS), macOS 14+ — `FitView-iOS` and `FitView-macOS`,
both sharing `Sources/FitView`, per `project.yml`.

**Project Type**: Multiplatform SwiftUI app (mobile + desktop) from a single shared codebase.

**Performance Goals**: None explicitly stated in the spec. `overview.md` §8's reference dataset
(sessions up to ~600-2000 records) is already handled via `ScatterDensity`'s density-cloud
reduction (covered by `FitViewCoreTests/ScatterDensityTests.swift`) — not a design pressure for
this feature.

**Constraints**: Offline-capable (renders an already-loaded `LoadedBatch`, no network call);
explanations for any statistic or plot must be reachable without leaving the detail view
(FR-009); the Data Point Card, Bland-Altman plot, and concordance plot must each own their own
tap/reveal state independently (FR-011, Principle II) so they compose without a parent managing
child state.

**Scale/Scope**: One activity's comparison data at a time — chart points, one stats grid, up to
two agreement plots, coverage and device-facts sections for exactly two devices (Assumptions:
pairwise-only, consistent with `overview.md` §1/§10).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Separation of Concerns & Shared Code | ⚠ Pass with a gap to close | Domain logic (timeline alignment, Bland-Altman/CCC statistics, density reduction, metric explainer copy) already lives in `FitViewCore` and is tested there (`ComparisonTimelineTests`, `ScatterDensityTests`, `MetricExplainerTests`). `SessionDetailModel` is presentation-mapping, not domain logic — like `BatchOverviewModel` in `001-activity-list` — so it correctly stays in `Sources/FitView`, but it currently has no CI coverage. Addressed in Phase 0 (research.md) and carried into tasks.md as a setup/test task, not a spec/plan-blocking violation. |
| II. Self-Contained, Reusable Components | ✅ Pass | `StatTile` owns `isShowingExplainer`; `AgreementPlotsSection` owns `isPresentingBlandAltman`/`isPresentingConcordance` as two independent `@State` flags — a parent never manages either. This is exactly what FR-011 requires and matches the constitution's example in Principle II's rationale. |
| III. Human-Readable, Comfortably Spaced UI | ✅ Pass | Existing 12pt tile padding, 20pt inter-section spacing, adaptive stat grid (`GridItem(.adaptive(minimum: 160))`), and 64pt spacing between stacked agreement plots already meet this; no change needed. |
| IV. Configurable, Not Hardcoded | ⚠ Pre-existing, out of scope | Same gap `001-activity-list/research.md` §3 already flagged: `AgreementScale.swift`'s thresholds are hardcoded constants shared by the list, this detail view, and the batch summary. Cross-cutting, not this feature's to fix in isolation. |
| V. Local Logging for Diagnosis | ✅ N/A | This feature has no decoding path of its own. The one error path it owns (delete failure) already surfaces a user-facing `deleteErrorMessage` alert; deletion's own contract (including any logging) belongs to `005-session-deletion`, not here. |
| VI. CI-Verified Testing | ⚠ Pass with a gap to close | Same underlying gap as Principle I: `SessionDetailModel` is not yet exercised by `FitViewTests`/`tests.yml`. Closing it means extending an existing, already-CI-wired target — not standing up new CI plumbing. |

No unjustified violations. Principle IV's gap is pre-existing and cross-feature scoped, not
introduced or enlarged by this spec. Principle I/VI's gap is closed by this plan (see
research.md §1), not merely flagged.

**Post-Phase-1 re-check**: data-model.md and contracts/session-detail-fields.md introduce no new
production types, storage, or state beyond what's listed above — they document
`SessionDetailModel`'s existing output shape and the fixture used to test it. Gate re-passes with
the same one addressed gap (Principle I/VI, closed by tasks.md) and the same one pre-existing,
out-of-scope gap (Principle IV).

## Project Structure

### Documentation (this feature)

```text
specs/002-activity-detail/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md         # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   └── session-detail-fields.md
├── checklists/
│   └── requirements.md
└── tasks.md              # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
Sources/FitView/SessionDetail/          # Shared across FitView-iOS and FitView-macOS targets
├── SessionDetailView.swift             # Screen: header, chart, stats grid, agreement plots, coverage, device facts, delete
├── SessionDetailModel.swift            # SwiftUI-free mapping: (LoadedBatch, sessionId) -> display values (FR-001..FR-007)
├── StatTile.swift                      # Data Point Card: label/value/level/detail + optional tap-to-explain (FR-009..FR-011)
├── AgreementPlotsSection.swift         # Bland-Altman + concordance plots, each independently presentable full-screen (FR-004, FR-011)
├── BlandAltmanChart.swift              # Bland-Altman scatter (density cloud + bias/LoA lines)
├── ConcordanceChart.swift              # Concordance scatter (density cloud, square domain)
├── MetricExplainerView.swift           # Explainer popover/sheet body (FR-009)
└── SessionDetailPreviewFixture.swift   # #if DEBUG synthetic LoadedBatch covering normal + all 3 skip reasons — reused as the test fixture (see research.md §1)

Packages/FitViewCore/Sources/FitViewCore/
├── ComparisonTimeline.swift            # buildComparisonTimeline — feeds the overlaid HR chart
├── AlignSamples.swift                  # intersectHeartRate — same-second join, coverage diagnostics
├── Statistics.swift                    # Absolute difference, Bland-Altman, CCC
├── ScatterDensity.swift                # DensityCloud, blandAltmanDensity, concordanceDensity
├── MetricExplainer.swift               # MetricKind, explainer copy (FR-009)
└── AgreementScale.swift                # AgreementLevel, differenceLevel, cccLevel

Packages/FitViewCore/Tests/FitViewCoreTests/   # Existing domain-logic test suite (unaffected by this feature)

Tests/FitViewTests/
├── BatchOverviewModelTests.swift       # Existing (001-activity-list), unaffected
├── Fixtures/AgreementFixtures.swift    # Existing (001-activity-list), unaffected
└── (new, Phase 2) SessionDetailModelTests.swift — see research.md §1
```

**Structure Decision**: No new source directories and no new production files — this feature
lives entirely in the eight existing files under `Sources/FitView/SessionDetail/`, which already
implement everything the spec describes; `Packages/FitViewCore` supplies the domain types they
consume. The only structural change is closing the test-coverage gap (Phase 0/2): one new test
file, `Tests/FitViewTests/SessionDetailModelTests.swift`, added to the `FitViewTests` target that
already exists and already runs in CI — no `project.yml` or `tests.yml` changes needed.

## Complexity Tracking

*No entries — Constitution Check found no violation requiring a justified deviation.*
