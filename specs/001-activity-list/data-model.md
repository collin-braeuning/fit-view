# Phase 1 Data Model: Activity List (Activity Card)

All types below already exist in the codebase; this documents them as the spec's Key Entity
("Activity (Session) — list summary") and its supporting shapes. Source-of-truth domain types
(`BatchAgreement`, `SessionAgreement`, `SkippedSession`) live in
`Packages/FitViewCore/Sources/FitViewCore/BatchAgreement.swift`. The presentation-mapping types
(`SessionRow`, `SkippedRow`, `Metric`, `DeviceCoverageDetail`) live in
`Sources/FitView/BatchOverviewModel.swift` and are what both layouts (`SessionCard` and the
Mac/iPad `Table`) actually render — per FR-002/FR-005, there is exactly one mapping so the two
layouts cannot drift.

## BatchOverviewModel (screen-level)

The presentation model for the whole list screen, built once per loaded `BatchAgreement`.

| Field | Type | Notes |
|---|---|---|
| `title` | `String` | `"{primaryName} vs {secondaryName}"` |
| `rows` | `[SessionRow]` | Comparable activities, sorted by date descending. FR-001. |
| `skipped` | `[SkippedRow]` | Activities that could not be compared. FR-003. |

## SessionRow — one comparable activity list entry

Identifiable by `sessionId`. This is the spec's "comparable" Activity list-summary shape.

| Field | Type | Maps to requirement |
|---|---|---|
| `sessionId` / `id` | `String` | Row identity; navigation target for FR-006. |
| `date`, `formattedDate` | `String` | Raw + display date. FR-002. |
| `activity` | `String` | Activity type label. FR-002. |
| `matchedSecondsText` | `String` | Disclosed detail (cards) / column (table). FR-004. |
| `hrRangeText` | `String` | Always paired with `ccc`, never shown alone. FR-002, Edge Case 3. |
| `primaryCoverage`, `secondaryCoverage` | `DeviceCoverageDetail` | Per-device coverage detail. FR-004. |
| `coverageSummary` | `String` | One-line combined coverage, e.g. `"pace4 100% · polarSense 78%"`. |
| `bias` | `Metric?` | Headline difference stat. FR-002. `nil` when no Bland-Altman result. |
| `loaText` | `String?` | 95% limits of agreement; disclosed detail, not headline. |
| `meanAbsDiff` | `Metric` | Headline difference stat. FR-002. Always present. |
| `maxAbsDiffText` | `String` | Disclosed/secondary stat. |
| `ccc` | `Metric?` | Concordance value + level. `nil` when both devices read a constant value over the window (no variance to compute CCC from). |
| `cccWord` | `String?` | McBride wording — the non-color signal alongside `ccc.level`'s color, satisfying FR-002's "both color and a non-color indicator." |
| `cccAccessibilityLabel` | `String` | Full sentence pairing CCC + HR range (or the nil-CCC explanation) for VoiceOver — never a bare number, per Edge Case 3. |

**Validation / derivation rules** (already implemented, restated for the spec record):
- `bias`/`ccc` are `nil` exactly when the underlying `SessionAgreement.blandAltman` /
  `.concordance` are `nil` — never fabricated. Satisfies FR-002's "without further interaction"
  requirement without inventing data for edge cases the domain layer already declined to
  compute.
- Agreement level (`good`/`warn`/`bad`) for `bias`/`meanAbsDiff` comes from
  `differenceLevel(_:)`; for `ccc` from `cccLevel(_:)` — both in `FitViewCore/AgreementScale.swift`,
  reused unchanged (not re-derived per view).

## SkippedRow — one uncompared activity

Identifiable by `sessionId`. The spec's "skipped" Activity list-summary shape (FR-003).

| Field | Type | Notes |
|---|---|---|
| `sessionId` / `id` | `String` | Row identity; still navigable (FR-003: "MUST remain reachable"). |
| `formattedDate` | `String` | Display date. |
| `activity` | `String` | Activity type label. |
| `reasonText` | `String` | Human-readable reason, derived from `SkippedSession.Reason`: `.noOverlap` → "no overlapping seconds between the two devices"; `.tooFewPoints` → "too few matched seconds to compute agreement". |

## Metric — value + agreement level pairing

| Field | Type |
|---|---|
| `text` | `String` |
| `level` | `AgreementLevel` (`.good` / `.warn` / `.bad`, from `FitViewCore`) |

Used everywhere a number needs its color/non-color signal attached (FR-002) so no consuming
view re-derives the level from a raw double.

## DeviceCoverageDetail — one device's coverage for a session

| Field | Type | Notes |
|---|---|---|
| `label` | `String` | Device display name. |
| `percentText` | `String` | e.g. `"78%"`, or `"—"` if unavailable. |
| `ownSpanText` | `String` | e.g. `"1200s recorded over a 1500s span"` — the auto-pause diagnostic from `overview.md` §7, shown only in disclosed/expanded detail (FR-004). |

## Upstream domain types consumed (unchanged by this feature)

- `BatchAgreement` (`FitViewCore`): `primaryName`, `secondaryName`, `sessions: [SessionAgreement]`,
  `skipped: [SkippedSession]`, plus batch-level `spread`/`pooled` fields not used by the list
  screen (those belong to the batch-summary feature, out of scope here).
- `SessionAgreement`: `sessionId`, `date`, `activity`, `matchedSeconds`, `coverage: [DeviceCoverage]`,
  `hrRange: HRRange`, `difference: AbsoluteDifferenceStats`, `blandAltman: BlandAltmanStats?`,
  `concordance: ConcordanceStats?`.
- `SkippedSession`: `sessionId`, `date`, `activity`, `reason: Reason` (`.noOverlap` | `.tooFewPoints`).

## State (not persisted)

- `BatchOverviewCardList.expandedSessionIds: Set<String>` — which cards are disclosed, keyed by
  `sessionId`. View-local, not part of `BatchOverviewModel`; see research.md §2 for why this is
  owned by the list, not each card.
- `BatchOverviewView.layout: OverviewLayout` (`.table` | `.cards`) — derived per-render from
  platform + `horizontalSizeClass` (or `layoutOverride` for previews), never stored.

No new persisted state, no schema, and no state transitions beyond the disclosure toggle above
— this feature is a pure read/render of an already-built `BatchOverviewModel`.
