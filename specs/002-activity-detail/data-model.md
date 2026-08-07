# Phase 1 Data Model: Activity Detail View (Data Point Cards & Agreement Plots)

All types below already exist in the codebase; this documents them as the spec's Key Entities
(Statistic Tile, Agreement Plot, Device Coverage, Activity — detail) and their supporting
shapes. The presenter, `SessionDetailModel`, lives in
`Sources/FitView/SessionDetail/SessionDetailModel.swift` and is what `SessionDetailView` (and
nothing else) renders — per FR-001..FR-007, it is the single mapping from domain data to
everything the detail screen shows.

## SessionDetailModel (screen-level)

Built once per `(LoadedBatch, sessionId)` via a failable initializer (`nil` if `sessionId` isn't
in `batch.grouping.sessions`).

| Field | Type | Notes |
|---|---|---|
| `session` | `ActivitySession` | Source-of-truth session identity/date/activity. |
| `formattedDate` | `String` | Display date. FR-001. |
| `deviceLabels` | `[String]` | Present devices only, `[primary, secondary]` order. FR-001. |
| `deviceFacts` | `[DeviceFacts]` | Per-device source facts. FR-006. |
| `chartPoints` | `[HeartRatePoint]` | Overlaid HR-over-time series, gap-segmented. FR-002. |
| `chartYDomain` | `ClosedRange<Double>` | Chart y-axis bounds, padded ±5bpm around observed range (or `0...200` when no points). |
| `lapBoundaries` | `[Date]` | Interior lap-divider positions, bucketed to whole seconds. FR-002. |
| `lapSourceLabel` | `String?` | Which device's laps are shown; `nil` when neither device recorded >1 lap. |
| `agreement` | `SessionAgreement?` | Non-`nil` for a normal session; `nil` for a skipped one — the switch FR-007 depends on. |
| `coverage` | `[DeviceCoverage]` | Raw per-device coverage (from `FitViewCore`, or locally computed when skipped but both files present). |
| `coverageDetails` | `[DeviceCoverageDetail]` | Display-ready per-device coverage. FR-005. |
| `matchedSecondsText`, `hrRangeText` | `String?` | `nil` exactly when `agreement` is `nil`. FR-003. |
| `bias`, `meanAbsDiff`, `ccc` | `Metric?` | Headline stats + level. FR-003. `bias`/`ccc` independently `nil` per Edge Cases. |
| `loaText`, `maxAbsDiffText` | `String?` | Non-headline stats. FR-003. |
| `cccDetailText` | `String?` | "substantial · 90–173 bpm" — CCC word + HR range kept adjacent, per `overview.md` §7 and Edge Case 3. |
| `blandAltmanPlot` | `BlandAltmanPlotData?` | `nil` when `agreement` is `nil` or `SessionAgreement.blandAltman` is `nil`. FR-004. |
| `concordancePlot` | `ConcordancePlotData?` | `nil` when `agreement` is `nil` or `SessionAgreement.concordance` is `nil` (both series constant). FR-004. |
| `skipBannerText` | `String?` | Non-`nil` only when `agreement` is `nil`; one of three distinct sentences per FR-007 (missing device / no overlap / too few points). |
| `startTimeDeltaText` | `String?` | "first sample 17:06:53 vs 17:00:41 — 6:12 apart" — shown alongside the skip banner when both devices have records. |

**Validation / derivation rules** (already implemented, restated for the spec record):
- `agreement == nil` is the single switch the view (`statsGrid`) uses to decide between the
  stats grid + plots vs. the skip banner (FR-007) — never a secondary nil-check on individual
  fields.
- `skipBannerText`'s three wordings are mutually exclusive and checked in priority order: a
  missing device file first (undetectable from `BatchAgreement` alone), then too-few-points
  (when a local re-alignment finds >0 but insufficient matched seconds), then no-overlap
  (default). See research.md §2 for why this branch lives here, not in `FitViewCore`.
- `bias`/`ccc`/`blandAltmanPlot`/`concordancePlot` are each independently `nil` exactly when the
  underlying `SessionAgreement.blandAltman`/`.concordance` are `nil` — one being absent never
  blocks or blanks the other (FR-004, Edge Case 2).
- Lap boundaries come from whichever device recorded more laps (`lapsByDevice`, strict
  comparison so ties keep the primary device) — the two devices lap independently, so overlaying
  both would draw a meaningless divider from whichever recorded only one lap for the whole run.

## Statistic Tile (Data Point Card) — `StatTile` view model

Not a separate presenter type — `SessionDetailView.statsGrid` constructs one `StatTile` per
computable stat directly from `SessionDetailModel`'s fields above.

| Field | Type | Notes |
|---|---|---|
| `label` | `String` | e.g. `"Bias"`, `"CCC"`. |
| `value` | `String` | Formatted stat text. |
| `level` | `AgreementLevel?` | Colors the value; `nil` for stats with no good/warn/bad scale (matched seconds, max \|diff\|). |
| `detail` | `String?` | Qualifying line — only `ccc` uses this (`cccDetailText`). |
| `explainer` | `MetricExplainer?` | When set, tile is tappable (FR-009); when `nil`, tile is inert (FR-010). |

**Derivation rule**: a tile is included in the grid at all only when its backing model field is
non-`nil` — FR-003's "each tile independently omitted... rather than shown as zero or blank" is
enforced by `SessionDetailView.statsGrid`'s `if let` per tile, not by `StatTile` itself (which
has no notion of "should I render").

## Agreement Plot — `BlandAltmanPlotData` / `ConcordancePlotData`

| Type | Field | Notes |
|---|---|---|
| Both | `cloud` | `DensityCloud` (`FitViewCore`/`ScatterDensity.swift`) — reduced point cloud, opacity = overlap density. |
| Both | `xDomain`/`yDomain` or `domain` | Padded axis bounds so edge points and (Bland-Altman) limit lines aren't clipped. |
| Both | `xAxisTitle`, `yAxisTitle`, `densityCaption` | Display strings; `densityCaption` is the plot's legend substitute ("N of M pairs · darker means more overlapping readings"). |
| `BlandAltmanPlotData` | `bias`, `upperLimit`, `lowerLimit` | The three reference lines drawn on the plot. |
| `ConcordancePlotData` | *(domain is square — identical range both axes)* | So the plot area renders as a literal square, matching CCC's x=y reference line. |

Each is constructed only when its `SessionAgreement` field is non-`nil` (see
`SessionDetailModel` rules above) — this is the mechanism behind FR-004's independence
guarantee.

## Device Coverage — `DeviceCoverageDetail`

Reused unchanged from `001-activity-list` (`Sources/FitView/BatchOverviewModel.swift`) — same
type, same fields (`label`, `percentText`, `ownSpanText`), applied here per-device for a single
session rather than per-row in a list. See `001-activity-list/data-model.md` for the full field
description.

## DeviceFacts — per-device source facts

| Field | Type | Notes |
|---|---|---|
| `label` | `String` | Device display name. |
| `fileName` | `String` | FR-006. |
| `sport` | `String` | FR-006. |
| `startTimeText`, `endTimeText` | `String` | Recording time range. FR-006. |
| `recordCount`, `lapCount` | `Int` | FR-006. |
| `avgHeartRate`, `maxHeartRate` | `Int` | FR-006. |

## Metric — value + agreement level pairing

Reused unchanged from `001-activity-list` (`Sources/FitView/BatchOverviewModel.swift`) —
identical `{ text: String, level: AgreementLevel }` shape, same reasoning (no consuming view
re-derives level from a raw double).

## Upstream domain types consumed (unchanged by this feature)

- `SessionAgreement`, `DeviceCoverage` (`FitViewCore`): as documented in
  `001-activity-list/data-model.md`.
- `FitActivity`, `FitRecord`, `FitLap` (`FitViewCore`): raw per-device decoded data —
  `SessionDetailModel` is the first feature to consume these directly (rather than only their
  `SessionAgreement`/`BatchAgreement` summaries), since it needs the raw HR series for the chart
  and lap timestamps for chart dividers.
- `MetricKind`, `MetricExplainer` (`FitViewCore`/`MetricExplainer.swift`): explainer copy shown
  by `MetricExplainerView` (FR-009); band thresholds pinned to `AgreementScale.swift`.

## State (not persisted)

- `SessionDetailView`: `isPresentingFullScreenChart` (FR-008), `isPresentingDeleteConfirmation`/
  `isDeleting`/`deleteErrorMessage` (delete entry point, FR-012 — full contract in
  `005-session-deletion`).
- `StatTile.isShowingExplainer` — owned per-tile (FR-011, Principle II).
- `AgreementPlotsSection.isPresentingBlandAltman` / `.isPresentingConcordance` — owned per-plot,
  independently (FR-011, Principle II).

No new persisted state, no schema, and no state transitions beyond the reveal/dismiss toggles
above — this feature is a pure read/render of an already-built `LoadedBatch`.
