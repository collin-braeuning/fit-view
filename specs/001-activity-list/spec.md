# Feature Specification: Activity List (Activity Card)

**Feature Branch**: `001-activity-list`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description (from the combined "convert this existing project into speckit"
request): "(1) Activity card. This is the main UI element, the first screen a user sees is a
list of these activity cards that give the most important data."

**Note on scope**: This specification documents functionality that already exists in the
codebase (`SessionCard`, `BatchOverviewCardList`, `BatchOverviewView`'s table layout). It
formalizes the existing, shipped behavior as the governing spec so that future changes go
through the Spec Kit workflow instead of ad hoc edits. Selecting an entry navigates into the
**Activity Detail** feature, specified separately in `002-activity-detail` — this spec covers
only the list screen and the summary each entry shows.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Scan all activities at a glance (Priority: P1)

A user who has imported multiple recorded activities opens the app and sees a list, one entry
per activity, showing enough agreement information (how closely two devices' heart-rate
readings matched) to spot which activities look fine and which look questionable without
opening any of them.

**Why this priority**: This is the app's home screen and the entry point to everything else.
If a user can't tell good sessions from bad ones at a glance, the app has failed its core
purpose (per `overview.md` §1, "do two heart-rate recording devices agree?").

**Independent Test**: Load a set of activities with a known mix of good/bad/incomplete
agreement data and confirm the list surfaces a distinguishable summary (concordance value,
agreement level, heart-rate range) for each one without further interaction.

**Acceptance Scenarios**:

1. **Given** several imported activities with valid comparison data, **When** the user opens
   the activity list, **Then** each activity appears as one entry showing its date, activity
   type, concordance value with the heart-rate range it was measured over, and headline
   difference statistics (bias, mean/max absolute difference), each visually flagged by
   agreement level (good/warn/bad).
2. **Given** an activity where the two devices' recordings did not sufficiently overlap in
   time, **When** the user opens the activity list, **Then** that activity appears in a
   distinctly separated "skipped" area with a stated reason, rather than being silently
   omitted or shown with fabricated numbers.
3. **Given** no activities have been imported yet, **When** the user opens the activity list,
   **Then** the app states plainly that there is nothing to show, rather than presenting an
   empty or broken-looking list.
4. **Given** the app window/screen is narrow (e.g., an iPhone in portrait), **When** the user
   views the list, **Then** entries are presented as cards with the same summary data as the
   wide-layout table, and each card offers an explicit control to disclose additional detail
   (matched-seconds count, per-device coverage) without navigating away from the list.
5. **Given** the app window/screen is wide (e.g., a Mac window or an iPad in landscape),
   **When** the user views the list, **Then** entries are presented as a table carrying the
   same summary fields as the card layout, with columns adapting to the available width.

---

### Edge Cases

- Two activities collide on the same grouping key on the same day — the later one is reported
  as skipped rather than silently overwriting the first (per `overview.md` §6).
- The window is resized across the narrow/wide layout threshold while the list is open — the
  same underlying activities and summary data are shown in both layouts.
- An activity has an unusually large or small heart-rate range — the concordance value is
  always shown paired with the range it was measured over, since the two are only meaningful
  together (per `overview.md` §7).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST present a list of all imported activities as the first screen, with
  one entry per activity.
- **FR-002**: Each activity list entry MUST show, without further interaction: the activity's
  date and type, its concordance value paired with the heart-rate range it was measured over,
  and its headline difference statistics (bias, mean absolute difference), each visually
  distinguished by agreement level (good/warn/bad) using both color and a non-color indicator.
- **FR-003**: Activities that could not be compared (insufficient overlap, missing device,
  etc.) MUST be listed separately from comparable activities, each with a stated reason, and
  MUST remain reachable (not hidden).
- **FR-004**: When the display area is narrow, the activity list MUST present entries as cards
  offering an explicit, user-triggered control to reveal additional per-entry detail (matched
  seconds, per-device coverage) in place, without navigating away from the list.
- **FR-005**: When the display area is wide enough, the activity list MUST present entries as a
  sortable, scannable table carrying the same summary fields as the card layout, adapting its
  column set to remaining available width.
- **FR-006**: Selecting an activity entry, in either layout, MUST navigate to that activity's
  detail view (specified in `002-activity-detail`).

### Key Entities

- **Activity (Session) — list summary**: One recorded activity compared between exactly two
  devices; identified by date and activity type. Carries the summary fields shown in the list
  (concordance, heart-rate range, bias, difference stats, agreement level, matched-seconds
  count, per-device coverage) and is either "comparable" or "skipped" with a reason.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From the activity list alone, a user can identify which activities have good vs.
  questionable device agreement without opening any of them.
- **SC-002**: Every activity that was imported is accounted for on the list screen — either
  shown with comparison data or listed as skipped with a reason; none are silently missing.
- **SC-003**: The same activity data is legible on both the narrowest supported phone width and
  the widest supported desktop window, with no summary field lost in either layout.
- **SC-004**: Reaching an activity's full detail from the list requires exactly one selection
  action.

## Assumptions

- "Activity Card" refers to the narrow-layout (phone-width) presentation of an activity list
  entry; the wide-layout (Mac / iPad-regular-width) presentation of the same entry is a table
  row carrying equivalent fields. Both are treated as one feature (the activity list) with two
  layouts, not two separate features, since they show the same data about the same entities.
- Only two devices are compared per activity, consistent with `overview.md` §1 and §10.
- This spec covers activities that have already been imported into the app. Import itself
  (file picker, drag-and-drop, share extension, Polar API) is a separate concern and is not
  covered here.
- What happens after an entry is selected — the full detail breakdown, its statistic tiles, and
  its agreement plots — is specified separately in `002-activity-detail`, which depends on this
  spec's entry point but is independently testable and deliverable on its own.
