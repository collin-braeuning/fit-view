# Feature Specification: Settings & Device Alias Management

**Feature Branch**: `004-settings-device-alias`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description: "(4) Settings & device alias management"

**Note on scope**: This specification documents functionality that already exists in the
codebase (`SettingsView`/`SettingsSheet`, `DeviceAliasSheet`, `DeviceNicknameStore`,
`TokenStore`). It formalizes the existing, shipped behavior as the governing spec so that
future changes go through the Spec Kit workflow instead of ad hoc edits. This spec covers
*configuring* import sources and devices; the resulting import behavior once configured is
specified in `003-import-flow`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Rename a device so its recordings group correctly (Priority: P1)

A user whose two devices are reported under inconsistent or unfriendly raw names (e.g., one
source calls a device `polarSense`, another calls the same physical device
`"Polar Vantage V2"`) gives it one consistent, human-readable name, so recordings from both
sources are recognized as the same device and grouped together for comparison.

**Why this priority**: Without this, the app's core comparison feature silently fails for
anyone whose device is named differently by different import sources — two recordings of the
same real workout never group into one comparable session. This is a correctness-critical
control, not a cosmetic one.

**Independent Test**: Import two activities that are the same real device under two different
raw names, confirm they appear as two separate, ungrouped devices, rename one to match the
other, and confirm they now group together.

**Acceptance Scenarios**:

1. **Given** the user opens device management, **When** the list loads, **Then** it shows
   every known device with its current display label and how many imported files are
   attributed to it.
2. **Given** a device's current label, **When** the user edits it and saves, **Then** the new
   label is used immediately for that device everywhere it's shown (activity list, activity
   detail, device management), without requiring any activity to be re-imported.
3. **Given** a device was previously renamed to match another device, **When** the user views
   its entry, **Then** they can see which original raw names now resolve to it.
4. **Given** a rename would create a naming loop (e.g., device A renamed to match device B,
   which was itself already renamed to match device A), **When** the user tries to save it,
   **Then** the app rejects the change with a clear explanation, rather than silently applying
   a broken mapping.
5. **Given** a device is renamed, **When** the user next views the activity list, **Then**
   sessions that previously failed to group solely because of the naming mismatch now group
   correctly.

---

### User Story 2 - Choose where activities come from (Priority: P1)

A user chooses whether the app is showing bundled sample data (to try the app out) or their own
activities from a real folder, and can pick or change which folder that is — all without
risking data loss in either mode.

**Why this priority**: This is the prerequisite configuration for real use of the app; without
it, a user can only ever see sample data or has no way to point the app at their own files.

**Independent Test**: Start on sample data, switch to a real folder, designate a folder
containing at least one activity, and confirm the app now shows that folder's activities
instead of the samples — then switch back and confirm the samples are unaffected.

**Acceptance Scenarios**:

1. **Given** the user is viewing sample data, **When** they switch to their own folder as the
   source, **Then** the app shows that folder's activities, and switching back later still
   shows the same sample data as before, unmodified.
2. **Given** no folder has been designated yet, **When** the user attempts to switch to it as a
   source, **Then** the app requires them to choose a folder first, rather than switching to an
   empty or broken state.
3. **Given** a folder is already designated, **When** the user picks a different one, **Then**
   the app begins treating the new folder as the source; activities already imported from the
   previous folder remain in the library.
4. **Given** a folder is designated, **When** the user chooses to stop watching it, **Then**
   the app forgets the folder, and any activities already imported from it remain in the
   library untouched.

---

### User Story 3 - Connect a third-party account for automatic sync (Priority: P2)

A user connects their Polar Flow account once, from Settings, so the app can retrieve new
activities from it automatically going forward (import behavior specified in
`003-import-flow`), and can disconnect or reset that connection later without losing anything
already retrieved.

**Why this priority**: This is additive convenience configuration — valuable, but the app is
fully usable via manual import and folder watching without it (User Stories 1–2 stand alone).

**Independent Test**: With a folder already designated, connect a test account, confirm the
connection is shown as active, then disconnect it and confirm previously retrieved activities
remain in the library.

**Acceptance Scenarios**:

1. **Given** a folder is already designated (a prerequisite), **When** the user chooses to
   connect their account, **Then** the app guides them through that platform's sign-in and
   shows the connection as active once it succeeds.
2. **Given** no folder is designated yet, **When** the user views the connect control,
   **Then** it is clearly unavailable, explaining that a folder is needed first, rather than
   allowing a connection attempt doomed to fail silently later.
3. **Given** an active connection, **When** the user disconnects it, **Then** the connection is
   removed but activities already retrieved through it remain in the library.
4. **Given** an active connection, **When** the user resets its sync history, **Then** the app
   is willing to re-check for activities it previously retrieved, without deleting any activity
   already in the library.

---

### User Story 4 - Review a local diagnostic log (Priority: P3)

A user (or a developer helping them) troubleshooting an import, sync, or connection problem can
view a running, in-app record of what the app has recently done, without needing to reproduce
the issue under a debugger.

**Why this priority**: This supports diagnosing the other three stories when something goes
wrong; it has no purpose on its own, so it's the lowest priority, but it materially shortens
troubleshooting for the features above it.

**Independent Test**: Trigger a failing sync or import, open the diagnostic log, and confirm
the failure and its context appear in it.

**Acceptance Scenarios**:

1. **Given** the user has performed import, sync, or connection actions, **When** they open the
   diagnostic log, **Then** they see a running record of those actions and their outcomes,
   most recent visible without extra navigation.
2. **Given** the diagnostic log has entries, **When** the user chooses to clear it, **Then** the
   visible log is emptied.

### Edge Cases

- Renaming a device to a label that causes it to merge with another already-named device —
  future recordings from both group under the merged name; already-imported activities are
  re-grouped by the rename, not re-imported.
- A rename attempt that would create a cycle is rejected outright, not partially applied.
- Renaming a device does not rename or move any file the user manages outside the app (e.g., in
  their watched folder) — only how the app labels and groups it.
- Switching data source modes, picking a new folder, disconnecting an account, or resetting
  sync history are all destructive-looking actions that must never delete an already-imported
  activity — only configuration/connection state changes.
- The third-party connect control depends on a folder already being configured; attempting to
  connect without one is prevented, not allowed to fail later during sync.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Settings MUST let a user view every known device along with a count of files
  attributed to it.
- **FR-002**: Settings MUST let a user rename any known device's display label, with the new
  label applied immediately everywhere that device is shown, without requiring any activity to
  be re-imported.
- **FR-003**: A rename that would create a naming cycle MUST be rejected with a clear
  explanation, not silently applied.
- **FR-004**: A device rename MUST NOT modify or move any file the user manages outside the
  app's own library — it changes labeling and grouping within the app only.
- **FR-005**: Settings MUST let a user choose which activity source is active (sample data for
  trying the app, or a real personal folder), and switching between them MUST NOT modify or
  remove data belonging to the source not currently active.
- **FR-006**: Settings MUST let a user pick or change the folder the app treats as its ongoing
  activity source.
- **FR-007**: Settings MUST let a user stop watching a folder without removing any activity
  already imported from it.
- **FR-008**: Settings MUST provide a control that triggers an immediate check of the watched
  folder for new files (import behavior specified in `003-import-flow`).
- **FR-009**: Settings MUST let a user connect a supported third-party account for automatic
  activity sync (import behavior specified in `003-import-flow`), and MUST prevent starting
  that connection until its prerequisite folder configuration exists, explaining why.
- **FR-010**: Settings MUST let a user disconnect a connected third-party account without
  removing activities already retrieved through it.
- **FR-011**: Settings MUST let a user reset a connected account's sync history, allowing
  previously retrieved activities to be re-checked, without deleting any activity already in
  the library.
- **FR-012**: Settings MUST present a rolling, in-app diagnostic log of import, sync, and
  connection activity, viewable without leaving the app.
- **FR-013**: The user MUST be able to clear the visible diagnostic log.
- **FR-014**: Settings MUST be reachable from the app's main screen on every supported
  platform.

### Key Entities

- **Device Alias**: A mapping from a device's raw, source-reported name to a user-chosen
  display label. Renames can chain (renaming an already-renamed device); a rename that would
  create a cycle is rejected.
- **Data Source**: Which activity source/library is currently active — sample data, for trying
  the app, or a real, user-designated folder. Each keeps its own set of imported activities.
- **Third-Party Connection**: A connected account's authorization state (not connected,
  connected, or connection failed) and its own sync-history tracking, independent of the
  library's contents.
- **Diagnostic Log**: A rolling, in-app record of import, sync, and connection events, kept for
  troubleshooting.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user whose device is reported under two different raw names can merge them into
  one group with a single rename, with no re-import required.
- **SC-002**: Switching the active data source never deletes or hides activities belonging to
  the source not currently selected.
- **SC-003**: Disconnecting or resetting a third-party connection never removes an activity
  already in the library.
- **SC-004**: A user troubleshooting an import or sync problem can review a record of recent
  activity without leaving the app or attaching a debugger.

## Assumptions

- Device-to-device library sync (a mechanism present in the codebase but not exposed by any
  current UI) is out of scope; this spec does not reintroduce it.
- What each import source does with the configuration set here (a designated folder, a
  connected account) is specified in `003-import-flow`; this spec covers configuring and
  managing those sources, not their import behavior.
- Session deletion is out of scope here and is specified in `005-session-deletion`.
- Only Polar Flow is treated as a working third-party connection today. Other announced sources
  are covered under `003-import-flow`'s "not yet available" handling, not here.
- "Rename" always means changing a device's display label within the app; it never renames or
  moves a file the user manages outside the app.
