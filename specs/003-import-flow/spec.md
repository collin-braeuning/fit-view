# Feature Specification: Import Flow

**Feature Branch**: `003-import-flow`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description: "(3) Import flow (file picker, drag-and-drop, share extension,
Polar API import)"

**Note on scope**: This specification documents functionality that already exists in the
codebase (`ImportSheet`, `FileImportSource`, `WatchedFolderSource`/`FolderIngestor`,
`PolarAccessLinkSource`/`RemoteActivitySync`, the Share Extension target). It formalizes the
existing, shipped behavior as the governing spec so that future changes go through the Spec Kit
workflow instead of ad hoc edits. Where an import path depends on configuration owned by
Settings (choosing a watched folder, connecting a Polar account), that configuration itself is
specified in `004-settings-device-alias`; this spec covers what happens once it exists.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Import files by hand (Priority: P1)

A user selects one or more `.fit` files from their device (via a file picker, or by dragging
them onto the app on a Mac) and adds them to their activity library in one action, with no
prior setup required.

**Why this priority**: This is the zero-configuration baseline import path — it works the
first time the app is opened, before any folder or account has been set up, and is the
fallback every other import path can be explained in terms of.

**Independent Test**: With an empty library, pick two or three real `.fit` files through the
file picker and confirm they appear in the activity list afterward with correct dates and
device labels.

**Acceptance Scenarios**:

1. **Given** the user starts an import and chooses "Files", **When** they select one or more
   `.fit` files, **Then** the app lists what it found (one entry per file) before importing
   anything, and importing requires one further explicit confirmation.
2. **Given** the app is running on a Mac, **When** the user drags one or more `.fit` files onto
   the activity list, **Then** the same import happens as picking "Files" — the files are
   listed as found and added to the library, without opening a file picker.
3. **Given** an import batch has been confirmed, **When** it finishes, **Then** the app reports
   how many activities were added, and the activity list reflects them immediately.
4. **Given** some files in a batch fail to import (e.g., unreadable or corrupt) while others
   succeed, **When** the batch finishes, **Then** the app shows both the successful imports and
   the specific failures — a partial failure is never hidden by only reporting the successes.
5. **Given** the same recording is imported twice, whether via the same file picked again or a
   different file containing identical activity data, **When** the second import runs,
   **Then** it does not create a second entry in the activity library.

---

### User Story 2 - Automatically pick up new files from a designated folder (Priority: P1)

Once a user has designated a folder (in Settings, see `004-settings-device-alias`) as the
source of their activity files, any new `.fit` file placed into that folder — by the user, by a
sync service, or by another import path in this spec — is added to the library automatically,
without the user re-opening an import flow each time.

**Why this priority**: This is the primary bulk-import mechanism for anyone with a habitual
export/sync workflow (e.g., a cloud-synced folder from a watch's companion app) — it is what
makes repeat use of the app low-friction rather than a manual re-import every time.

**Independent Test**: With a folder already designated, add a new `.fit` file to it outside the
app, then return to the app and confirm the new activity appears without any manual import
action.

**Acceptance Scenarios**:

1. **Given** a folder has been designated as the activity source, **When** the app is opened or
   returns to the foreground, **Then** it checks the folder for files not already in the
   library and imports only those, leaving already-known files untouched (not re-read, not
   re-added).
2. **Given** the user wants to check for new files immediately, **When** they request an
   on-demand rescan, **Then** the app checks the folder right away rather than waiting for the
   next automatic check.
3. **Given** a file in the designated folder is stored in the cloud and not yet fully
   downloaded to the device, **When** the app tries to import it, **Then** it waits for the
   download up to a reasonable limit and reports a clear, specific message if that limit is
   reached, rather than failing silently or hanging indefinitely.
4. **Given** a rescan is already in progress, **When** another rescan is requested, **Then**
   the new request is honored after the current one finishes rather than being dropped.

---

### User Story 3 - Share an activity file into the app from elsewhere (Priority: P2)

From another app (e.g., a file browser or a device's companion app), a user shares a `.fit`
file directly into FitView without first switching to FitView.

**Why this priority**: This removes a context switch for the single-file case, which is common
when exporting one activity right after a workout. It is a convenience on top of User Story 1's
manual import and User Story 2's folder automation, not a replacement for either.

**Independent Test**: From another app's share sheet, share a `.fit` file to FitView, confirm
the app offers to name and save it, and confirm it later appears as an imported activity.

**Acceptance Scenarios**:

1. **Given** the user shares a `.fit` file (or a file containing FIT activity data) to FitView,
   **When** the share sheet opens, **Then** it shows a proposed name for the activity (derived
   from the file's own recorded date/device/activity where available) that the user can accept
   or edit before saving.
2. **Given** the user confirms the shared file, **When** it is saved, **Then** it becomes
   available to the app the same way a manually placed file would, without requiring the user
   to separately open FitView and re-import it.
3. **Given** no destination folder has been designated yet, **When** the user tries to share a
   file in, **Then** the share sheet tells them a folder needs to be set up first (in Settings)
   rather than accepting the file and losing it or failing without explanation.
4. **Given** the shared file can't be read as activity data, **When** the app inspects it,
   **Then** the share sheet reports that plainly instead of accepting a file it cannot use.

---

### User Story 4 - Connect a third-party account for automatic sync (Priority: P2)

A user connects a supported third-party fitness platform account (Polar Flow) once, and new
activities recorded on that platform are retrieved automatically from then on, without manual
file handling.

**Why this priority**: This removes the manual export/import step entirely for a supported
platform, but it's additive to the other import paths (a user with no such account still has
full use of the app via User Stories 1–3).

**Independent Test**: Connect a test account with at least one recent activity, trigger a sync,
and confirm the activity appears in the library without any file having been manually handled.

**Acceptance Scenarios**:

1. **Given** the user has not connected a third-party account, **When** they choose to connect
   one, **Then** the app takes them through that platform's sign-in and authorization, and
   confirms once the connection succeeds.
2. **Given** a connected account, **When** the app checks for new activity (automatically or
   on user request), **Then** it retrieves activities not already known to the app and adds
   them for import, skipping ones already retrieved.
3. **Given** the connected platform only exposes a limited recent history (e.g., the last 30
   days), **When** the user views the connection's status, **Then** the app states that
   limitation so the user knows older activities must be added another way.
4. **Given** the account connection fails or is not yet authorized, **When** the user attempts
   to sync, **Then** the app distinguishes, in plain language, between "not set up yet," "not
   authorized," and "temporarily unavailable," rather than showing one generic error.
5. **Given** the user disconnects the account, **When** disconnection completes, **Then**
   activities already retrieved remain in the library — only the connection itself is removed.

### Edge Cases

- A source that is announced but not yet available (e.g., a "coming soon" platform) is offered
  in the picker but tells the user plainly it isn't available yet when chosen, rather than being
  hidden or silently failing.
- A batch import is started, then a second import is started before the first finishes — the
  first is superseded (its partial results are discarded), not merged with the second.
- The import UI is dismissed while an import is still running — the in-progress import is
  cancelled.
- An activity's filename or metadata can't be parsed into a usable date/device/activity — it is
  still reported to the user as an unparseable item, not silently dropped from the results.
- The same underlying recording arrives through two different paths (e.g., manually imported,
  then later also delivered by account sync) — it is recognized as the same activity and not
  duplicated.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST let a user manually select one or more `.fit` files via a system
  file picker and import them into the activity library.
- **FR-002**: On macOS, the app MUST support importing `.fit` files by dragging them onto the
  activity list, producing the same result as picking them through the file picker.
- **FR-003**: Before committing an import, the app MUST show the user what was found and
  require one explicit confirmation before anything is added to the library.
- **FR-004**: The app MUST support designating a folder as an ongoing activity source, after
  which new files placed into it are imported automatically without a manual import action per
  file (folder designation itself specified in `004-settings-device-alias`).
- **FR-005**: Automatic folder import MUST only import files not already present in the
  library; already-known files MUST NOT be re-imported or re-read on every check.
- **FR-006**: The user MUST be able to trigger an immediate check of the designated folder for
  new files, on demand.
- **FR-007**: If a file in the designated folder is not yet fully available locally (e.g., an
  unfinished cloud download), the app MUST wait up to a reasonable limit and then report a
  specific, actionable message if it still isn't available, rather than failing silently or
  blocking indefinitely.
- **FR-008**: The app MUST let a user share a `.fit` file (or a file containing FIT activity
  data) from another app directly into the library, without first opening the app.
- **FR-009**: The share flow MUST let the user review and, if needed, edit the proposed name
  before the shared activity is saved.
- **FR-010**: If no destination folder has been designated when a user attempts to share a file
  in, the app MUST tell them to set one up rather than silently discarding the file or failing
  without explanation.
- **FR-011**: The app MUST let a user connect a supported third-party fitness platform account
  and, once connected, automatically retrieve new activities from it without further manual
  action.
- **FR-012**: The app MUST inform the user when a connected platform's available history is
  time-limited, so they know to import older activities another way.
- **FR-013**: Connection and sync failures MUST be reported with a specific reason (not
  configured, not authorized, temporarily unavailable, etc.), not a single generic error
  message.
- **FR-014**: Disconnecting a third-party account MUST remove only the connection; activities
  already retrieved through it MUST remain in the library.
- **FR-015**: Importing the same underlying recording more than once, through any combination
  of import paths, MUST NOT create duplicate entries in the library.
- **FR-016**: Starting a new import batch MUST supersede any import already in progress rather
  than merging their results; dismissing the import flow mid-import MUST cancel it.
- **FR-017**: When some items in an import batch fail while others succeed, the app MUST report
  both — a failure MUST NOT be hidden by presenting only the successful subset.
- **FR-018**: An item whose name or metadata can't be parsed into a usable date, device, and
  activity MUST still be reported to the user rather than silently dropped.

### Key Entities

- **Import Source**: One origin of activities (manual file selection, a designated folder, the
  share flow, or a connected third-party account), each with its own availability and
  authorization state.
- **Import Candidate**: A discovered, not-yet-imported activity with enough information
  (proposed name, and date/device/sport where known) to preview before committing to import it.
- **Import Result**: The outcome of one import batch — activities successfully added, activities
  skipped as already-known duplicates, and specific failures with reasons, all reported
  together.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user with a folder of exported `.fit` files can get all of them into the app in
  a single import action.
- **SC-002**: Once a folder is designated, a new file placed into it appears in the app without
  the user manually re-importing it.
- **SC-003**: A user can get a single activity from another app into FitView's library in two
  steps or fewer (share, then confirm) without switching to FitView first.
- **SC-004**: No import path can silently lose or duplicate an activity — every outcome
  (success, skipped duplicate, or failure) is visible to the user.
- **SC-005**: After connecting a supported third-party account once, new activities from it
  appear in the library with no further manual file handling.

## Assumptions

- The import sources covered here are: manual file selection (including drag-and-drop as its
  macOS-only variant), a user-designated watched folder, the share flow, and Polar Flow account
  sync. The bundled "Sample Data" source (used for trying the app without real files) follows
  the same contract as manual file selection and isn't treated as a separate story.
- A COROS import source is visible in the app today as an announced-but-not-yet-available
  option; per `overview.md`'s decisions record, COROS's API is partner-gated and unavailable, so
  this spec only requires that choosing it produces a clear "not available yet" message
  (covered under Edge Cases), not a working integration.
- Choosing and configuring a watched folder, and connecting/disconnecting a third-party account,
  are Settings actions specified in `004-settings-device-alias`; this spec covers the import
  behavior that follows from that configuration, not the configuration screens themselves.
- An import batch has no per-item selection step today — a source's results are found and
  imported as one all-or-nothing batch. This is treated as current, intended behavior, not a
  gap to fill.
- Deleting an already-imported activity is out of scope here and is specified in
  `005-session-deletion`.
