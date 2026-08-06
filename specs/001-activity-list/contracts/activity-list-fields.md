# UI Contract: Activity List Field Parity

This feature has no network/API surface; its "interface" is the field set both layouts
(`SessionCard` for narrow width, the `Table` in `BatchOverviewView` for wide width) must
present, since FR-005 requires the table to carry "the same summary fields as the card layout"
and SC-003 requires no summary field to be lost in either layout. This contract exists so a
future change to one layout can be checked against the other without re-reading both files.

Both layouts render from the same `SessionRow` / `SkippedRow` (see `data-model.md`) — this
contract is about which fields each layout surfaces *by default* vs. *behind disclosure*, not
about the underlying data (which is always fully present on the model regardless of layout).

## Comparable activities (`SessionRow`)

| Field | Cards (`SessionCard`) | Table, ≥900pt (`fullSessionsTable`) | Table, <900pt (`narrowSessionsTable`) |
|---|---|---|---|
| `formattedDate` | Always visible (header) | Always visible (Date column) | Always visible |
| `activity` | Always visible (header) | Always visible (Activity column) | Always visible |
| `ccc` + `cccWord` | Always visible (header chip + headline) | Always visible (CCC column, `.help()` tooltip for word) | Always visible |
| `hrRangeText` | Always visible (headline, paired with CCC) | Always visible (HR Range column) | Always visible |
| `meanAbsDiff` | Always visible (primary stat) | Always visible (Mean \|Diff\| column) | Always visible |
| `bias` | Always visible (primary stat) | Always visible (Bias column) | Always visible |
| `loaText` | Always visible (primary stat) | Always visible (95% LoA column) | Dropped — see note below |
| `maxAbsDiffText` | Always visible (primary stat) | Always visible (Max \|Diff\| column) | Dropped — see note below |
| `matchedSecondsText` | Behind "Details" disclosure | Always visible (Matched Seconds column, with `coverageSummary`) | Always visible |
| `coverageSummary` | Behind "Details" disclosure (as per-device rows) | Always visible (Matched Seconds column subtitle) | Always visible |
| `primaryCoverage` / `secondaryCoverage` (`ownSpanText`) | Behind "Details" disclosure | Not shown (no column) | Not shown |

**Note — narrow table (<900pt) drops `loaText` and `maxAbsDiffText` only** (verified directly
against `BatchOverviewView.narrowSessionsTable`'s column list — `hrRangeText` stays, via its
own "HR Range" column): this is an accepted, spec-acknowledged exception, not a parity bug.
Acceptance Scenario 5 requires the wide layout to carry "the same summary fields as the card
layout" at *sufficient* width; the sub-900pt table (iPad portrait) is a third, intermediate
case the spec doesn't separately name. The code comment at
`BatchOverviewView.narrowSessionsTable` documents the rationale: Bias and Mean |Diff| already
carry the headline signal, and the two fields it drops are exactly what the card's "Details"
disclosure holds on the narrow side — i.e., below 900pt, "wide" degrades toward "narrow"
behavior for the two least-headline fields, not a third field set. If a future change adds a
field to one layout's always-visible set, this row should be updated and the other layouts
checked for whether they need the same field.

## Skipped activities (`SkippedRow`)

| Field | Cards | Table |
|---|---|---|
| `formattedDate` | Always visible | Always visible |
| `activity` | Always visible | Not shown (rolled into `reasonText` line) |
| `reasonText` | Always visible | Always visible |

Both layouts keep skipped entries navigable (`NavigationLink(value: SessionRoute(...))`),
satisfying FR-003's "MUST remain reachable."

## Selection contract (FR-006)

Both layouts navigate to `SessionRoute(sessionId:)` on selection — the card via
`NavigationLink` wrapping the whole card, the table via `Table(selection:)` bound to
`selectedSessionId`, forwarded to the same `path.append(SessionRoute(...))`. One selection
action reaches detail in both layouts (SC-004).
