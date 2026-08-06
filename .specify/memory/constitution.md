<!--
Sync Impact Report
- Version change: 1.0.0 → 1.1.0
- Modified principles: n/a
- Added sections:
  - VI. CI-Verified Testing (new principle)
- Removed sections: none
- Templates checked for alignment:
  - .specify/templates/plan-template.md — Constitution Check gate now has six
    principles to evaluate against; no template edit needed, gate table is
    filled per-feature at plan time
  - .specify/templates/spec-template.md — no changes needed
  - .specify/templates/tasks-template.md — no changes needed
  - .specify/templates/checklist-template.md — no changes needed
- Follow-up TODOs: none

Prior report (1.0.0, retained for history):
- Version change: [TEMPLATE] → 1.0.0 (initial ratification)
- Modified principles: n/a (first fill of template placeholders)
- Added sections:
  - I. Separation of Concerns & Shared Code
  - II. Self-Contained, Reusable Components
  - III. Human-Readable, Comfortably Spaced UI
  - IV. Configurable, Not Hardcoded
  - V. Local Logging for Diagnosis
  - Platform & Architecture Constraints
  - Development Workflow
  - Governance
- Removed sections: none
- Follow-up TODOs: none
-->

# FitView Constitution

## Core Principles

### I. Separation of Concerns & Shared Code
Domain logic (FIT decoding, timeline alignment, statistics, filename parsing, batch
aggregation) MUST live in `FitViewCore`, independent of SwiftUI, and MUST be directly
unit-testable without a UI. Code shared across the macOS, iPhone, and iPadOS targets MUST
live in a shared location rather than being duplicated per platform. When a function, view,
or type is doing more than one job, the distinct responsibility MUST be extracted into its
own helper or type rather than left inline.

Rationale: `overview.md` documents that the entire domain layer of the app this project
ports from is pure, framework-free logic — this is the property that made the port
tractable in the first place, and it must not erode as platform-specific code accretes
around it.

### II. Self-Contained, Reusable Components
A UI component MUST own the state that is intrinsic to it (expansion, editing mode, local
validation, animation phase, etc.) rather than requiring a parent to lift and manage that
state on its behalf. A component MUST NOT be generalized speculatively into an
over-parameterized abstraction; generalize only once a second real call site needs it.

Rationale: state owned externally multiplies lifecycle bugs — stale state, double updates,
parent/child desync — and defeats the reuse it was meant to enable. Premature generic
abstraction is the same failure in the other direction: it adds indirection reuse doesn't
yet need.

### III. Human-Readable, Comfortably Spaced UI
Interfaces MUST use spacing and sizing that keep text, controls, and click/touch targets
comfortably legible and distinguishable. Elements MUST NOT be packed together to save space
at the expense of readability or usability.

Rationale: user-stated requirement. This is a real regression risk when porting
data-dense surfaces — batch mode's per-session tables in particular — from a desktop web
layout onto constrained form factors like iPhone.

### IV. Configurable, Not Hardcoded
User-facing behavior that could reasonably vary by preference (thresholds, default device
pairing, units, display options, and similar) MUST be exposed through a settings/storage
layer rather than embedded as fixed constants in view or logic code. That settings layer
MUST be extensible — adding a new setting must not require restructuring existing storage —
and a Settings surface MUST exist and stay current as new configurable behavior is added.

Rationale: user-stated requirement. `overview.md` §11 independently identifies persistence
and configuration as the natural first feature beyond the web port, not an afterthought, so
this principle also protects a piece of the roadmap.

### V. Local Logging for Diagnosis
Error paths, and complex decoding logic in particular (FIT file parsing and normalization,
per `overview.md` §4), MUST emit local, structured log output sufficient to diagnose a
failure after the fact without reproducing it under a debugger. Logging MUST NOT substitute
for correct error handling — it accompanies a handled error or a decision point, not a
silent failure.

Rationale: user-stated requirement. `overview.md` §4 identifies the FIT parse layer as the
app's sole trust boundary against malformed or unexpected input, which makes it the
highest-value place to leave a diagnostic trail.

### VI. CI-Verified Testing
GitHub Actions CI (currently `.github/workflows/tests.yml`) is the authoritative record of
whether unit tests pass — a local `swift test`/`xcodebuild test` run is a development
convenience, not a substitute for a green CI run, and MUST NOT be cited as verification in
place of one. Every unit test target MUST run in CI on pull requests, not just exist in a
package or project file. When a new test suite is created (a new test target, or the first
test file added to one), it MUST be double-checked before being considered done: confirm it is
actually wired into a CI workflow job (not merely present locally), and confirm it meaningfully
fails when the code it covers is broken — a suite that passes vacuously (e.g., against a stub,
or without exercising the failure path it claims to cover) does not satisfy this principle.

Rationale: user-stated requirement. A test that only ever runs on one contributor's machine, or
a suite added but never checked to see whether it actually catches anything, gives false
confidence indistinguishable from no test at all — worse, because it looks like coverage. This
principle also closes a concrete, already-identified gap: `Sources/FitView` currently has no
test target wired into `tests.yml` (only `Packages/FitViewCore` runs there today), so any new
test target added for it (e.g., per `specs/001-activity-list/research.md` §1) must extend the
CI workflow, not just exist locally, before its tests count as passing.

## Platform & Architecture Constraints

FitView targets macOS, iPhone, and iPadOS from a single SwiftUI codebase. Platform
divergence MUST be isolated to the smallest layer that actually needs it (e.g., file
access, navigation chrome) — not duplicated business logic.

Project structure is managed via `project.yml` (XcodeGen), not by hand-editing the
`.xcodeproj`. New source files go under `Sources/...`, or under
`Packages/FitViewCore/Sources` for domain logic, and `xcodegen generate` regenerates the
project after `project.yml` or the file set changes.

Domain logic changes MUST be validated against the acceptance numbers pinned in
`overview.md` §9 (exact record/lap counts, HR aggregates, batch statistics) before being
considered correct — these characterization values are the port's test oracle.

## Development Workflow

Building, running, or launching the app (including the simulator) is not performed by
default; verification is manual, by the user, in Xcode. The sole exception is an explicit
remote-control/constrained session, per `CLAUDE.md`.

A change with significant UI impact MUST land as a reviewable, self-contained step; further
UI-affecting changes MUST wait for user review rather than being chained together
unreviewed.

Bugs and feature requests surfaced in conversation MUST be filed as
GitHub issues on `collin-braeuning/fit-view` and added to the "Kanban" project board so they
are not lost once a session ends.

## Governance

This constitution supersedes ad hoc practice for anything it addresses. Where `CLAUDE.md`
and this document overlap, `CLAUDE.md` governs the assistant's day-to-day operational
specifics (exact commands, session modes); this document governs the durable engineering
principles behind them — the two MUST NOT be edited to contradict each other.

**Amendments**: propose the change (via `/speckit-constitution` or a direct edit), update
the Sync Impact Report at the top of this file, bump the version per the policy below, and
update Last Amended.

**Versioning policy** (semantic versioning):
- MAJOR: a principle is removed or redefined in a backward-incompatible way.
- MINOR: a new principle or section is added, or existing guidance is materially expanded.
- PATCH: wording, typo, or other non-semantic clarification.

**Compliance review**: outputs of `/speckit-plan` and `/speckit-tasks`, and PR review more
generally, MUST be checked against these principles. Unjustified complexity or a principle
violation MUST be called out explicitly rather than silently absorbed into the plan.

**Version**: 1.1.0 | **Ratified**: 2026-08-05 | **Last Amended**: 2026-08-05
