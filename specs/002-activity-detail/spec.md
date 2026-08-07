# Feature Specification: Activity Detail View (Data Point Cards & Agreement Plots)

**Feature Branch**: `002-activity-detail`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description (from the combined "convert this existing project into speckit"
request): "(2) Activity detail view. This is what shows when an Activity Card (1) is tapped.
It shows a deeper dive of the stats from Activity Card (1) and a few extra graphs... (2a) Data
point card. This is what shows the small bits of data such as \"average heart rate\" and is
usually tappable to view more info. (2b) Bland-Altman Agreement Plot. This graph shows the
agreement and bias between 2 devices. (2c) Lin's Concordance Correlation Coefficient. This is
a graph that shows how much the devices correlate."

**Note on scope**: This specification documents functionality that already exists in the
codebase (`SessionDetailView`, `StatTile`, `AgreementPlotsSection`, `BlandAltmanChart`,
`ConcordanceChart`, `MetricExplainerView`). It formalizes the existing, shipped behavior as the
governing spec so that future changes go through the Spec Kit workflow instead of ad hoc edits.
Elements (2a) Data Point Card, (2b) Bland-Altman plot, and (2c) concordance plot are **not**
separate specs of their own — none has an independent user journey outside this view — but they
**are** kept as separate, independently reusable components within it (see Assumptions). This
spec is reached by selecting an entry in the Activity List, specified in `001-activity-list`.
Deleting the activity shown here is specified separately in `005-session-deletion`, since
deletion has its own contract (what "delete" actually removes, and whether it's recoverable)
independent of which screen triggers it.

## Clarifications

### Session 2026-08-06

- Q: Should a session where one device's file is entirely missing for that date be documented as its own distinct edge case in this spec, separate from "no overlapping seconds" and "too few matched seconds"? → A: Yes — add it as a third, distinct skip reason with its own plain-language explanation.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Drill into one activity's full comparison (Priority: P1)

From the activity list, a user opens one entry to see a complete breakdown of that single
activity's agreement data: the full statistics grid, both devices' heart-rate traces overlaid
on one timeline, and the two agreement plots (Bland-Altman and concordance).

**Why this priority**: This is where the user actually diagnoses a questionable session — the
list only tells them *that* something looks off; this view is where they see *why*. Without
it, the list's flagging is not actionable.

**Independent Test**: From an activity list containing a "bad" session, open it and confirm
the detail view renders the overlaid heart-rate chart, the full statistics grid, and both
agreement plots for that specific activity, matching the numbers shown for it in the list.

**Acceptance Scenarios**:

1. **Given** an activity has been selected from the activity list, **When** its detail view
   opens, **Then** it is titled with the activity's type and shows its date and the two
   devices being compared.
2. **Given** the detail view for an activity with valid comparison data, **When** it loads,
   **Then** it shows: an overlaid heart-rate-over-time chart for both devices (with lap
   markers when available), a grid of statistic tiles (matched seconds, bias, 95% limits of
   agreement, mean/max absolute difference, concordance), an agreement-plots section
   (Bland-Altman and concordance, when computable), a coverage breakdown per device, and
   per-device source facts (file name, sport, time range, record/lap counts,
   average/max heart rate).
3. **Given** an activity whose two devices had no usable overlapping seconds, **When** the
   user opens its detail view, **Then** the statistics grid and agreement plots are replaced
   by a clear explanation of why no comparison could be computed, rather than blank or
   zeroed-out values.
4. **Given** the detail view's heart-rate chart, **When** the user requests to expand it,
   **Then** it opens in a full-screen presentation for closer inspection, and can be dismissed
   back to the detail view.

Deleting the activity from this view is covered by `005-session-deletion`.

---

### User Story 2 - Understand what a statistic means (Priority: P2)

While viewing an activity's detail view, a user who doesn't recognize a statistic (e.g.,
"CCC", "95% LoA") can get an in-context, plain-language explanation without leaving the
screen.

**Why this priority**: The statistics involved (Bland-Altman limits of agreement, concordance
correlation) are specialist terms. Making them self-explanatory is what makes the rest of the
feature usable by someone without a statistics background, but the view is still meaningful
without it (User Story 1 delivers value on its own).

**Independent Test**: Tap a statistic tile or a plot's info control and confirm an explanation
of that specific metric appears, addressed to the metric shown, without navigating away.

**Acceptance Scenarios**:

1. **Given** a statistic tile (Data Point Card) that has an available explanation, **When**
   the user taps it, **Then** an in-context explanation of that specific metric appears (as a
   popover or sheet, appropriate to the platform), and the tile is identifiable as tappable
   before it's tapped.
2. **Given** an agreement plot (Bland-Altman or concordance), **When** the user taps its info
   control, **Then** an explanation of what that plot shows appears in place, without leaving
   the detail view.
3. **Given** a statistic tile with no associated explanation, **When** the user views it,
   **Then** it is not presented as tappable, avoiding a dead-end tap target.

### Edge Cases

- An activity has only one device's file present for that date (the other device recorded
  nothing) — the detail view shows a plain-language explanation naming which device's file is
  missing, distinct from a no-overlap or too-few-points skip (see FR-007).
- An activity's concordance coefficient cannot be computed (both devices' readings were a
  constant value) — the concordance statistic tile and its plot are omitted for that activity,
  not shown as an error or a zero.
- An activity has Bland-Altman data but not concordance data (or vice versa) — each agreement
  plot renders independently; a missing one does not block or blank the other.
- An activity has an unusually large or small heart-rate range — the concordance value is
  always shown paired with the range it was measured over, since the two are only meaningful
  together (per `overview.md` §7).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Selecting an activity from the activity list MUST open a detail view scoped to
  that single activity, titled with its activity type and showing its date and the two devices
  being compared.
- **FR-002**: The detail view MUST show an overlaid heart-rate-over-time chart for both
  compared devices, including lap boundary markers when lap data is available from either
  device.
- **FR-003**: The detail view MUST show a grid of individual statistic tiles (Data Point
  Cards) covering, at minimum: matched seconds, bias, 95% limits of agreement, mean absolute
  difference, max absolute difference, and concordance — each tile independently omitted when
  its underlying value is not computable, rather than shown as zero or blank.
- **FR-004**: The detail view MUST show the Bland-Altman agreement plot and the concordance
  plot as independent elements, each rendered only when its underlying data is computable, so
  that one being unavailable never blocks or blanks the other.
- **FR-005**: The detail view MUST show, per device, its coverage relative to the other device
  (percentage of its own usable readings that were matched) and its own recording span.
- **FR-006**: The detail view MUST show, per device, identifying source facts: file name,
  sport, recording time range, record and lap counts, and average/max heart rate.
- **FR-007**: When an activity has no usable overlapping data between its two devices, the
  detail view MUST replace the statistics grid and agreement plots with a plain-language
  explanation of why, rather than leaving those areas blank or showing fabricated values. This
  explanation MUST distinguish, by its wording, which of the three distinct skip reasons
  applies: one device's file is missing entirely for that date, the devices have no overlapping
  seconds at all, or they overlap but too few seconds were matched to compute agreement
  statistics.
- **FR-008**: The heart-rate comparison chart MUST support an on-demand full-screen
  presentation that the user can dismiss back to the detail view.
- **FR-009**: A statistic tile or agreement plot that has an associated explanation MUST be
  visually identifiable as tappable, and tapping it MUST show an in-context, plain-language
  explanation of that specific metric without navigating away from the detail view.
- **FR-010**: A statistic tile with no associated explanation MUST NOT be presented as
  tappable.
- **FR-011**: The Data Point Card (statistic tile), the Bland-Altman plot, and the concordance
  plot MUST each be implemented as independently reusable elements that own their own
  tap/reveal state, so they can be composed into the detail view (and reused elsewhere) without
  a parent view managing their internal state.
- **FR-012**: The detail view MUST provide an entry point for deleting the activity it shows
  (behavior specified in `005-session-deletion`).

### Key Entities

- **Statistic Tile (Data Point Card)**: A single labeled value (e.g., "Bias", "CCC") with an
  optional agreement level, an optional qualifying detail line, and an optional in-context
  explanation.
- **Agreement Plot**: A visual (Bland-Altman or concordance) built from one activity's matched
  reading pairs across its two devices; independently present or absent per activity depending
  on whether its underlying statistic is computable.
- **Device Coverage**: Per device, for one activity — the percentage of that device's own
  usable readings that were successfully matched to the other device, plus that device's own
  recording span.
- **Activity (Session) — detail**: The same entity introduced in `001-activity-list`, extended
  here with the fields only the detail view needs: chart points, lap boundaries, and per-device
  source facts.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Opening an activity's detail view immediately shows its full statistical and
  visual breakdown, with no further navigation required.
- **SC-002**: A user unfamiliar with Bland-Altman or concordance statistics can, without
  leaving the detail view, get a plain-language explanation of any statistic or plot shown.

## Assumptions

- Elements (2a) Data Point Card, (2b) Bland-Altman plot, and (2c) concordance plot are already
  implemented as separate, independently reusable SwiftUI components in the codebase
  (`StatTile`, `BlandAltmanChart`, `ConcordanceChart`) and are composed together inside this
  detail view. This spec keeps that separation: each is testable and reusable on its own,
  matching the project constitution's requirement that a component own its own state (e.g.,
  each tile independently owns whether its explanation popover is showing).
- This spec assumes an activity has already been selected via `001-activity-list`; it does not
  re-specify the list screen itself.
- Deleting the activity is out of scope here beyond providing the entry point; its full
  contract (what "delete" removes, recoverability, error handling) is specified in
  `005-session-deletion`.
- Only two devices are compared per activity, consistent with `overview.md` §1 and §10
  (Bland-Altman and concordance are inherently pairwise).
- "Tappable" is used platform-neutrally to mean the primary direct-interaction gesture (tap on
  iOS/iPadOS, click on macOS).
