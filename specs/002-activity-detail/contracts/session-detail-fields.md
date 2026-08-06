# UI Contract: Session Detail Field Presence

This feature has no network/API surface; its "interface" is which sections/fields render for a
given session state, since FR-003/FR-004/FR-007 require independent per-field omission rather
than blank or fabricated values. This contract exists so a future change to one section can be
checked against the others without re-reading all of `SessionDetailModel.swift`.

## By session state

| Section | Normal session (`agreement != nil`) | Skipped — missing device file | Skipped — no overlap | Skipped — too few points |
|---|---|---|---|---|
| Header (title, date, device labels) | Always shown | Always shown | Always shown | Always shown |
| HR chart | Always shown (both devices' points, if either has records) | Shown with only the present device's points | Shown with both devices' points (disjoint ranges) | Shown with both devices' points |
| Lap dividers | Shown when either device recorded >1 lap | Shown when the present device recorded >1 lap | Same rule | Same rule |
| Stats grid | Shown — one tile per computable stat (FR-003) | Replaced by skip banner (FR-007) | Replaced by skip banner (FR-007) | Replaced by skip banner (FR-007) |
| Agreement plots | Shown — Bland-Altman and/or concordance, independently (FR-004) | Not shown (no `agreement`) | Not shown | Not shown |
| Skip banner | Not shown | Shown: "No `{device}` file for this date." | Shown: "No overlapping seconds..." | Shown: "Only N matched second(s)... too few to compute agreement statistics." |
| Start-time delta | Not shown | Not shown (only one device has records) | Shown, when both devices have ≥1 record | Shown, when both devices have ≥1 record |
| Coverage section | Shown, per present device | Shown, per present device (only one entry) | Shown, per present device | Shown, per present device |
| Device facts section | Shown, per present device | Shown, per present device (only one entry) | Shown, per present device | Shown, per present device |

The three skip-banner wordings are mutually exclusive (see `data-model.md`'s "Validation /
derivation rules" and `research.md` §2) — exactly one applies per skipped session, satisfying
the Clarifications entry in spec.md and the updated FR-007.

## Per-stat-tile presence (`statsGrid`, normal session only)

| Tile | Present when | Absent when |
|---|---|---|
| Matched Seconds | Always (agreement implies `matchedSecondsText`) | Never, for a normal session |
| Bias / 95% LoA | `SessionAgreement.blandAltman != nil` | Bland-Altman not computable |
| Mean \|Diff\| / Max \|Diff\| | Always (agreement implies difference stats) | Never, for a normal session |
| CCC | `SessionAgreement.concordance != nil` | Both devices read a constant value over the window (Edge Case 1) |

A tile's `explainer` is non-`nil` for every tile currently shown (all six `MetricKind` cases
have explainer copy) — FR-010's "not presented as tappable" case does not currently occur for
any tile in this grid, but the contract (`StatTile`'s `explainer: MetricExplainer?`) supports it
for any future tile that doesn't have one.

## Agreement-plot independence (FR-004, Edge Case 2)

| Plot | Present when |
|---|---|
| Bland-Altman | `SessionAgreement.blandAltman != nil` |
| Concordance | `SessionAgreement.concordance != nil` |

`AgreementPlotsSection` renders `EmptyView()` only when *both* are `nil`; otherwise each
non-`nil` plot renders in its own block, independent of the other's presence.

## Explainer reachability (FR-009, FR-011)

| Element | Trigger | Presentation |
|---|---|---|
| Stat tile with `explainer != nil` | Tap the tile | Popover (macOS/iPad regular width) / sheet (`presentationCompactAdaptation(.sheet)`, iPhone) |
| Agreement plot's info button | Tap the `ExplainerButton` next to the plot title | Same popover/sheet mechanism |

Both reuse `MetricExplainerView` + `metricExplainerPopover(_:isPresented:)` — one explainer
presentation contract for both element kinds, so they can't drift (Principle II: each element
owns its own `isShowing`/`isPresenting` flag).

## Full-screen presentation (FR-008)

| Element | iOS/iPadOS | macOS |
|---|---|---|
| HR chart | `fullScreenCover` | `sheet`, `frame(minWidth: 700, minHeight: 420)` |
| Bland-Altman / concordance plot | `fullScreenCover` | `sheet`, `frame(minWidth: 560, minHeight: 480)` |

"Full-screen presentation" (spec.md's platform-neutral wording, per Assumptions) means the
platform's primary modal-takeover presentation — `fullScreenCover` on iOS/iPadOS, a large
resizable `sheet` on macOS (which has no `fullScreenCover` equivalent). Both are dismissible
back to the detail view.
