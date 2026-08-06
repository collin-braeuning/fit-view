# Implementation Plan: Activity List (Activity Card)

**Branch**: `001-activity-list` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-activity-list/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

Formalize the existing, shipped activity-list screen (`BatchOverviewView`, its `.table` /
`.cards` layouts, `BatchOverviewCardList`, `SessionCard`, and the `BatchOverviewModel` mapping
layer) as the governing spec, and close the one real gap found while doing so: the
SwiftUI-free `BatchOverviewModel`/`SessionRow`/`SkippedRow` mapping layer has no XCTest
coverage today because no test target exists for `Sources/FitView`. The approach is
"document what exists, then make it verifiable" — no UI redesign is in scope.

## Technical Context

**Language/Version**: Swift 5 (`SWIFT_VERSION: "5.0"` in `project.yml`), Xcode toolchain
implied by iOS 17 / macOS 14 deployment targets.

**Primary Dependencies**: SwiftUI (views), `FitViewCore` local Swift package (domain types:
`BatchAgreement`, `SessionAgreement`, `SkippedSession`, `AgreementLevel`, `AgreementScale`
thresholds).

**Storage**: N/A for this feature — `BatchOverviewView` reads `AppModel.overview`
(a `BatchOverviewModel` already built from a `BatchAgreement`); how that batch got loaded
(folder import, share extension, Polar sync) is out of scope per spec's Assumptions.

**Testing**: XCTest. `FitViewCore` domain logic (statistics, alignment, agreement-level
thresholds) already has coverage in `Packages/FitViewCore/Tests/FitViewCoreTests`. The
presentation-mapping layer this feature is built on (`BatchOverviewModel.swift`,
`Sources/FitView/BatchOverviewModel.swift`) is plain Swift/Foundation with no `import SwiftUI`
— structurally unit-testable — but currently has **zero** automated coverage because no XCTest
target exists for `Sources/FitView` at all (confirmed: no `Test` entries in `project.yml`,
no `*Tests.swift` under `Sources/`). Resolved in Phase 0 research below.

**Target Platform**: iOS 17+ (iPhone + iPadOS), macOS 14+ — three app targets
(`FitView-iOS`, `FitView-macOS`, both sharing `Sources/FitView`) plus share extensions, per
`project.yml`.

**Project Type**: Multiplatform SwiftUI app (mobile + desktop) from a single shared codebase.

**Performance Goals**: None explicitly stated in the spec. `overview.md` §8's reference dataset
(14 files / 7 sessions) is the only scale reference and is already handled comfortably by the
current `LazyVStack` (cards) / `Table` (wide) implementations — not a design pressure for this
feature.

**Constraints**: Offline-capable (list renders from already-imported local data, no network
call); must remain legible from the narrowest supported phone width to the widest supported
desktop window (SC-003); every summary field must carry both a color and a non-color
(text/icon) agreement-level signal (FR-002, already implemented via `LevelChip` /
`metric.level.symbolName`).

**Scale/Scope**: Small — `overview.md` §8's reference dataset is 7 comparable sessions across
14 files; no stated upper bound on session count in the spec. Existing `LazyVStack`/`Table`
approach is not expected to need virtualization work beyond what SwiftUI already provides.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Separation of Concerns & Shared Code | ⚠ Pass with a gap to close | Domain logic (statistics, alignment, level thresholds) already lives in `FitViewCore` and is tested there. `BatchOverviewModel` is presentation-mapping, not domain logic (it turns `BatchAgreement` into display strings), so it correctly stays out of `FitViewCore` — but it is currently untestable in CI because no test target covers `Sources/FitView`. Addressed in Phase 0 (research.md) and carried into tasks.md as a setup task, not a spec/plan-blocking violation. |
| II. Self-Contained, Reusable Components | ✅ Pass | `SessionCard` already owns its expansion affordance's *trigger* via `onToggleExpanded`, but the expanded/collapsed `Set<String>` lives in the parent (`BatchOverviewCardList`) rather than the card itself — see research.md for why this is treated as an accepted deviation, not a violation to fix now. |
| III. Human-Readable, Comfortably Spaced UI | ✅ Pass | Existing card padding (14pt), stat-tile spacing (8-10pt), and `ViewThatFits`-based reflow already meet this; no change needed. |
| IV. Configurable, Not Hardcoded | ⚠ Pre-existing, out of scope | Agreement-level thresholds (`differenceLevel`, `cccLevel` in `AgreementScale.swift`) are hardcoded constants, not settings-backed. This predates this spec and is a cross-cutting concern touching every feature that shows agreement levels (list, detail, batch summary) — tracked as a separate backlog item, not this feature's job to fix (see research.md Decision). |
| V. Local Logging for Diagnosis | ✅ N/A | This feature has no error/decoding path of its own; it renders an already-built `BatchOverviewModel`. Load failures are surfaced via `model.loadError` (built and logged elsewhere, outside this spec's scope). |

No unjustified violations. Principle IV's gap is pre-existing and cross-feature scoped, not
introduced or enlarged by this spec; it is called out for visibility per the constitution's
compliance-review requirement, not tracked in Complexity Tracking below (nothing here proposes
a workaround for it).

**Post-Phase-1 re-check**: data-model.md and contracts/activity-list-fields.md introduce no
new types, storage, or state beyond what's listed above (`data-model.md`'s "State (not
persisted)" section is exhaustive). Principle I's gap and its resolution (a new `FitViewTests`
target, still exercising SwiftUI-free code only) are unchanged from the pre-design check.
Gate re-passes with the same one documented, non-blocking gap.

## Project Structure

### Documentation (this feature)

```text
specs/001-activity-list/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md         # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   └── activity-list-fields.md
└── tasks.md              # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
Sources/FitView/                       # Shared across FitView-iOS and FitView-macOS targets
├── BatchOverviewView.swift             # Screen: layout switch (table/cards), toolbar, import sheet, drag-and-drop
├── BatchOverviewCardList.swift         # Narrow-layout: ScrollView/LazyVStack of SessionCard + skipped section
├── SessionCard.swift                   # One card: header, CCC headline, primary stats, expandable detail
├── BatchOverviewModel.swift            # SwiftUI-free mapping: BatchAgreement -> SessionRow/SkippedRow display strings
└── (new, Phase 2) — no new production files expected; existing files are already the
    implementation this spec documents.

Packages/FitViewCore/Sources/FitViewCore/
├── BatchAgreement.swift                # SessionAgreement, SkippedSession, BatchAgreement (source of truth data)
└── AgreementScale.swift                # AgreementLevel, differenceLevel, cccLevel, cccLabel

Packages/FitViewCore/Tests/FitViewCoreTests/   # Existing domain-logic test suite (unaffected by this feature)

(new, Phase 0/2) A lightweight test target for Sources/FitView's SwiftUI-free helpers —
see research.md for the chosen approach (XCTest target vs. relocating BatchOverviewModel).
```

**Structure Decision**: No new source directories. This feature lives entirely in the four
existing files under `Sources/FitView/` listed above, which already implement everything the
spec describes; `Packages/FitViewCore` supplies the domain types they consume. The only
structural change under consideration is closing the test-coverage gap (Phase 0), which adds a
test target/location, not a new feature module.

## Complexity Tracking

*No entries — Constitution Check found no violation requiring a justified deviation.*
