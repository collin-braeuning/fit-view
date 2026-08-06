# Feature Specification: Session Deletion

**Feature Branch**: `005-session-deletion`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description: "(5) Session deletion"

**Note on scope**: This specification documents functionality that already exists in the
codebase (`AppModel.deleteSession`, `LibraryStore.remove`). It formalizes the existing, shipped
behavior as the governing spec so that future changes go through the Spec Kit workflow instead
of ad hoc edits. This spec covers the deletion contract itself; the detail view's entry point
into it is specified in `002-activity-detail`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Remove an unwanted activity from the library (Priority: P1)

A user who imported an activity they don't want to keep — a mistaken import, a test file, a
duplicate that wasn't caught automatically — removes it from their library, with a clear,
deliberate confirmation step so it can't happen by accident.

**Why this priority**: This is the only way to correct an unwanted import today. Without a
safe, working delete, a user's library can only grow, and a single accidental tap could
otherwise destroy data with no way back.

**Independent Test**: Import an activity, delete it, and confirm it no longer appears anywhere
in the app, while re-checking that its original source file (if the user has one, outside the
app) is untouched.

**Acceptance Scenarios**:

1. **Given** the user is viewing an activity, **When** they choose to delete it, **Then** the
   app requires a separate, explicit confirmation step before anything is removed — the initial
   choice alone does not delete it.
2. **Given** the user confirms deletion, **When** it completes, **Then** the activity no longer
   appears in the activity list or anywhere else in the app, and the user is returned to the
   activity list.
3. **Given** the deletion confirmation is showing, **When** the user cancels it instead,
   **Then** nothing is removed and the activity remains exactly as it was.
4. **Given** an activity being deleted has data from both compared devices, **When** the
   deletion completes, **Then** both devices' data for that activity are removed together as
   one unit — there is no way to remove only one device's side of a two-device activity.
5. **Given** the user deletes an activity that was imported from a file they manage themselves
   outside the app (e.g., in a synced folder), **When** the deletion completes, **Then** that
   original file is left untouched — deletion only affects the app's own library.
6. **Given** a deletion attempt does not fully succeed (e.g., a storage error), **When** it
   fails, **Then** the app tells the user it did not succeed rather than proceeding as though it
   had.

### Edge Cases

- A deletion partially succeeds (e.g., one device's data for a two-device activity is removed
  before an error occurs on the other) — the app's state afterward reflects what actually
  happened, and the user is not told the deletion fully succeeded if it didn't.
- The user attempts to delete an activity that has already been removed (e.g., by a concurrent
  action) — this does not produce a confusing error or crash.
- Deletion is attempted while the library is otherwise busy (e.g., an import is in progress) —
  the deletion still either completes or reports a clear reason it didn't.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The user MUST be able to delete an activity from the app.
- **FR-002**: The app MUST require an explicit confirmation step, separate from the initial
  choice to delete, before a deletion takes effect.
- **FR-003**: Deleting an activity MUST remove it from the app's library so that it no longer
  appears in the activity list or any other in-app view.
- **FR-004**: Deleting an activity MUST NOT delete, move, or modify its original source file
  outside the app's own library (e.g., a file in a user-managed synced folder).
- **FR-005**: Deletion MUST act on an activity as a whole — both compared devices' data for
  that session are removed together; there is no partial, single-device deletion within a
  two-device activity.
- **FR-006**: If a deletion attempt does not fully succeed, the app MUST inform the user rather
  than silently treating it as successful.
- **FR-007**: After any deletion attempt, the app MUST reflect the library's actual resulting
  state (fully removed, partially removed, or unchanged) rather than an assumed one.

### Key Entities

- **Activity (Session)**: The same entity introduced in `001-activity-list`; deletion removes
  one activity's library record entirely, across both compared devices.
- **Deletion Outcome**: The result of one deletion attempt — success, partial failure (with
  which part failed), or failure — used to decide what the app reports to the user and what
  state it shows afterward.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Deleting an activity always requires two distinct user actions (initiate, then
  confirm) — it is not possible to delete one with a single tap.
- **SC-002**: A deleted activity is confirmed absent from the activity list immediately, with
  no manual refresh required.
- **SC-003**: A file the user manages outside the app is never affected by deleting the
  corresponding activity inside the app.
- **SC-004**: When a deletion does not fully succeed, the user is told so immediately, rather
  than having to discover the activity is still present some other way.

## Assumptions

- Today, the activity detail view is the only entry point for deletion — there is no
  multi-select or bulk delete, and no delete action directly from the activity list. This spec
  defines the deletion contract itself; `002-activity-detail` specifies that the detail view
  provides the entry point into it. Adding further entry points (e.g., from the list) would
  extend this spec's User Story 1 rather than requiring a new one.
- Deletion removes the library's record of an activity; it does not guarantee the underlying
  stored data is immediately reclaimed if other activities still reference identical recorded
  data. This has no user-visible effect and is out of scope for this spec's requirements.
- Actions elsewhere in the app that look similarly destructive but are not activity
  deletion — stopping folder watching, disconnecting a third-party account, resetting sync
  history, or clearing the diagnostic log (all specified in `004-settings-device-alias`) — are
  explicitly out of scope here; none of them remove an already-imported activity.
- There is no undo once a deletion is confirmed, which is the reason a confirmation step
  (FR-002) is required rather than optional.
