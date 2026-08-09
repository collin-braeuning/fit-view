# Feature Specification: Session Deletion

**Feature Branch**: `005-session-deletion`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description: "(5) Session deletion"

**Note on scope**: This specification started as documentation of functionality that already
exists in the codebase (`AppModel.deleteSession`, `LibraryStore.remove`), formalizing shipped
behavior as the governing spec so future changes go through the Spec Kit workflow instead of ad
hoc edits. Clarification (2026-08-08) established that the watched folder is the source of truth,
which makes part of this spec **new work rather than documentation**: folder reconciliation
(FR-009 through FR-012) does not exist today. User Story 1 remains a description of shipped
behavior; User Story 2 is to be built. This spec covers the deletion contract itself; the detail
view's entry point into it is specified in `002-activity-detail`.

## Clarifications

### Session 2026-08-08

- Q: When a user deletes an activity whose source file is still present in the watched folder,
  should the activity stay gone, or may it reappear on the next scan? → A: The watched folder is
  the source of truth — the activity is re-imported. Deleting an activity whose file is still in
  the folder is temporary by design.
- Q: When a file disappears from the watched folder, should the app remove the matching activity
  on its own during a scan, or flag it and wait for the user? → A: Automatically, with a safety
  guard — only a scan that successfully and completely reads the folder removes activities whose
  file is gone; a scan that fails or cannot confirm a complete read removes nothing.
- Q: When a scan removes activities because their files are gone from the folder, should the app
  tell the user that happened? → A: Yes, in the existing scan result — the scan reports how many
  activities it removed alongside what it imported, without interrupting the user.
- Q: If a scan removes the activity the user currently has open in the detail view, what should
  that open view do? → A: Nothing — it stays open showing the data already loaded, with no
  notice, and the user finds out when they return to the list. Chosen as the smallest-footprint
  option; it is the app's existing behavior and needs no new code.
- Q: When deleting a two-device activity and one device's side is removed but the other fails,
  should the app leave the half-removed state or restore the removed side? → A: Best-effort,
  reported truthfully — leave what was removed removed and tell the user the deletion was
  incomplete. FR-005 is a scope rule, not an atomicity guarantee.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Remove an unwanted activity from the library (Priority: P1)

A user who imported an activity they don't want to keep — a mistaken import, a test file, a
duplicate that wasn't caught automatically — removes it from their library, with a clear,
deliberate confirmation step so it can't happen by accident.

**Why this priority**: This is the only way to correct an unwanted import today. Without a
safe, working delete, a user's library can only grow, and a single accidental tap could
otherwise destroy data with no way back.

**Independent Test**: Import an activity from a file outside the watched folder, delete it, and
confirm it no longer appears anywhere in the app, while re-checking that its original source
file (if the user has one, outside the app) is untouched.

**Note**: For an activity whose source file is still in the watched folder, deletion clears it
from the library now but the next successful scan re-imports it — the folder is the source of
truth (see User Story 2 and FR-008). Removing the file from the folder is what makes the removal
stick.

**Acceptance Scenarios**:

1. **Given** the user is viewing an activity, **When** they choose to delete it, **Then** the
   app requires a separate, explicit confirmation step before anything is removed — the initial
   choice alone does not delete it.
2. **Given** the user confirms deletion, **When** it completes, **Then** the activity no longer
   appears in the activity list or anywhere else in the app, and the user is returned to the
   activity list.
3. **Given** the deletion confirmation is showing, **When** the user cancels it instead,
   **Then** nothing is removed and the activity remains exactly as it was.
4. **Given** an activity being deleted has data from both compared devices, **When** the user
   deletes it, **Then** the app removes both devices' data — the user is never offered a way to
   remove only one device's side of a two-device activity.
5. **Given** the user deletes an activity that was imported from a file they manage themselves
   outside the app (e.g., in a synced folder), **When** the deletion completes, **Then** that
   original file is left untouched — deletion only affects the app's own library.
6. **Given** a deletion attempt does not fully succeed (e.g., a storage error), **When** it
   fails, **Then** the app tells the user it did not succeed rather than proceeding as though it
   had.
7. **Given** the user deletes an activity whose source file is still present in the watched
   folder, **When** the next successful scan of that folder runs, **Then** the activity is
   imported again — the folder, not the in-app deletion, determines what the library holds.
8. **Given** one device's side of a two-device activity is removed but the other fails, **When**
   the attempt ends, **Then** the removed side stays removed, the app reports that the deletion
   was incomplete and part of the activity remains, and it does not claim success.

### User Story 2 - Keep the library matching the watched folder (Priority: P2)

A user who manages their activities as files — deleting one from the watched folder in Finder,
the Files app, or a synced folder — expects the app to follow along, rather than keeping an
activity whose file no longer exists.

**Why this priority**: This is what makes deletion durable at all. Given the folder is the
source of truth (FR-008), removing the file is the only way a user can permanently remove an
activity, so the app must honor it. It is P2 rather than P1 because the in-app delete in User
Story 1 still works on its own terms without it.

**Independent Test**: With a watched folder configured, delete a `.fit` file from the folder
outside the app, trigger a scan, and confirm the corresponding activity is gone from the
library — then repeat with the folder made unreadable and confirm nothing is removed.

**Acceptance Scenarios**:

1. **Given** an activity in the library came from the watched folder, **When** its file is
   removed from that folder and a scan successfully reads the folder, **Then** the activity is
   removed from the library without the user having to delete it in the app.
2. **Given** a scan fails or cannot confirm it read the folder completely (e.g., the folder is
   unreachable, permission was revoked, or synced files are not downloaded yet), **When** the
   scan ends, **Then** no activity is removed from the library.
3. **Given** an activity was not sourced from the watched folder (e.g., a bundled sample),
   **When** a folder scan reconciles the library, **Then** that activity is left alone.
4. **Given** a scan removed one or more activities, **When** it finishes, **Then** the scan
   result reports how many were removed alongside how many were imported, without interrupting
   whatever the user was doing.

### Edge Cases

- A deletion partially succeeds (e.g., one device's data for a two-device activity is removed
  before an error occurs on the other) — the app's state afterward reflects what actually
  happened, and the user is not told the deletion fully succeeded if it didn't.
- The user attempts to delete an activity that has already been removed (e.g., by a concurrent
  action) — this does not produce a confusing error or crash.
- Deletion is attempted while the library is otherwise busy (e.g., an import is in progress) —
  the deletion still either completes or reports a clear reason it didn't.
- The watched folder is momentarily empty or unreadable — a not-yet-downloaded synced folder, an
  unmounted volume, or a revoked folder permission — which must not be mistaken for the user
  having removed every file (FR-010).
- The user deletes an activity and a scan re-imports it before they notice, so the activity
  appears to have returned on its own (FR-008). The app should not present this as an error.
- The user deletes the last remaining activity in a library that seeds bundled samples when
  empty — the samples reappear rather than leaving an empty app. See Assumptions.
- A scan removes an activity the user is currently viewing — the open view keeps showing what it
  already loaded (FR-013). Acting on that stale view (e.g., deleting an activity already gone)
  must not produce an error or a crash.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The user MUST be able to delete an activity from the app.
- **FR-002**: The app MUST require an explicit confirmation step, separate from the initial
  choice to delete, before a deletion takes effect.
- **FR-003**: Deleting an activity MUST immediately remove it from the app's library so that it
  no longer appears in the activity list or any other in-app view. This removal is durable only
  for activities the watched folder does not still supply — see FR-008.
- **FR-004**: Deleting an activity MUST NOT delete, move, or modify its original source file
  outside the app's own library (e.g., a file in a user-managed synced folder).
- **FR-005**: Deletion MUST act on an activity as a whole — the user MUST NOT be offered a way
  to delete only one device's side of a two-device activity. This is a scope rule about what the
  user can ask for, not a guarantee that both removals succeed together; see FR-006.
- **FR-006**: A deletion MUST attempt every device's removal even if an earlier one fails, and
  MUST NOT undo removals that already succeeded. If any part fails, the app MUST tell the user
  the deletion was incomplete and that part of the activity remains, rather than silently
  treating it as successful.
- **FR-007**: After any deletion attempt, the app MUST reflect the library's actual resulting
  state (fully removed, partially removed, or unchanged) rather than an assumed one.
- **FR-008**: The watched folder MUST be treated as the source of truth for the activities it
  supplies. An activity whose source file is still present in the folder MUST be imported again
  by the next successful scan, even if the user deleted it in the app — in-app deletion does not
  suppress re-import.
- **FR-009**: When a scan successfully and completely reads the watched folder, the app MUST
  remove from the library any activity sourced from that folder whose file is no longer present,
  without requiring the user to delete it in the app.
- **FR-010**: A scan that fails, or that cannot confirm it read the watched folder completely
  (e.g., the folder is unreachable, access was revoked, or synced files have not been downloaded
  yet), MUST NOT remove any activity from the library.
- **FR-011**: Reconciliation under FR-009 MUST apply only to activities sourced from the watched
  folder; activities from other sources MUST be left untouched by it.
- **FR-012**: A scan that removes activities under FR-009 MUST report how many it removed, in
  the same place the scan already reports what it imported. It MUST NOT interrupt the user to do
  so.
- **FR-013**: An activity view already open when a scan removes that activity MAY continue to
  show the data it has already loaded, and is NOT required to close itself or announce the
  removal. Returning to the activity list MUST show the activity absent.
- **FR-014**: The app MUST record enough local diagnostic detail about deletion and
  reconciliation outcomes — including failures and partial failures — to determine afterward what
  was removed, what was not, and why, without reproducing the problem (Constitution V).

### Key Entities

- **Activity (Session)**: The same entity introduced in `001-activity-list`; deletion removes
  one activity's library record entirely, across both compared devices.
- **Deletion Outcome**: The result of one deletion attempt — success, partial failure (with
  which part failed), or failure — used to decide what the app reports to the user and what
  state it shows afterward.
- **Scan Outcome**: The result of one watched-folder scan — whether the folder was read
  completely, how many activities were imported, and how many were removed by reconciliation.
  Whether the read was complete is what gates removal (FR-010); the counts are what the scan
  reports back to the user (FR-012).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Deleting an activity always requires two distinct user actions (initiate, then
  confirm) — it is not possible to delete one with a single tap.
- **SC-002**: A deleted activity is confirmed absent from the activity list immediately, with
  no manual refresh required. (It may return on a later scan if its file is still in the watched
  folder — FR-008.)
- **SC-003**: A file the user manages outside the app is never affected by deleting the
  corresponding activity inside the app.
- **SC-004**: When a deletion does not fully succeed, the user is told so immediately, rather
  than having to discover the activity is still present some other way.
- **SC-005**: Removing a file from the watched folder removes the corresponding activity from
  the library on the next successful scan, with no in-app delete required.
- **SC-006**: A scan that cannot read the watched folder completely never removes an activity —
  a library with N activities still has N after such a scan.
- **SC-007**: A deletion or reconciliation failure can be diagnosed from the app's local logs
  alone, without reproducing it.

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
  explicitly out of scope here; none of them remove an already-imported activity. In particular,
  stopping folder watching MUST NOT be read as "every file disappeared" and trigger
  reconciliation — an unconfigured folder is a folder that cannot be read completely, which
  FR-010 already excludes from removing anything.
- There is no undo once a deletion is confirmed, which is the reason a confirmation step
  (FR-002) is required rather than optional. Re-import under FR-008 is not an undo — it is the
  folder reasserting itself, and it applies only while the file is still in the folder.
- A library that seeds bundled sample activities when it is empty will re-seed them if the user
  deletes the last remaining activity, so that state is deliberately unreachable. This is
  existing, intentional behavior and is not treated as a violation of FR-003.
- Reconciliation (FR-009) removes the library's record of an activity on the same terms as an
  in-app deletion; it is not a separate, gentler kind of removal, and it is equally
  unrecoverable from within the app.
