# Quickstart: Import Flow

Validation guide for `003-import-flow`. Since this spec formalizes already-shipped behavior, most
of this is manual verification against the Acceptance Scenarios in spec.md; the one piece of new
work (Phase 2, per research.md §1) is automated and runs in CI.

## Prerequisites

- Xcode with the `FitView` project generated (`xcodegen generate` after any `project.yml`
  change).
- A few real `.fit` files on the test device/Mac for manual scenarios (per `overview.md`'s
  reference dataset, or any real recording).
- Per `CLAUDE.md`: building/running/launching is normally the user's own step in Xcode, not
  something this workflow does automatically — the scenarios below describe what to do once you
  (the user) have the app running, not commands this plan will execute.

## Automated validation (Phase 2 — after tasks.md lands)

```bash
# Domain-layer tests — already exist, unaffected by this feature
cd Packages/FitViewCore && swift test

# FitViewTests — after project.yml adds Sources/ShareExtension/Shared to its
# sources (research.md §1), this exercises ShareImportViewModelTests too
xcodegen generate
xcodebuild test \
  -scheme FitView-macOS \
  -only-testing:FitViewTests \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: both green. `FitViewCoreTests` already covers `ImportCoordinator`,
`WatchedFolderSource`, `FolderIngestor`, `RemoteActivitySync`, `PolarAccessLinkModels`, and the
pure Share Extension helpers. `FitViewTests` gains `ShareImportViewModelTests` (new) alongside
the existing `BatchOverviewModelTests`/`SessionDetailModelTests`.

## Manual scenario: US1 — file picker (P1)

1. Launch the app with an empty (or existing) library.
2. Tap the import toolbar action → "Files".
3. Select two or three real `.fit` files.
4. **Expect**: a "N activities found" screen appears before anything is imported (FR-003).
5. Tap "Import N".
6. **Expect**: a summary shows the imported count; tap "Use these N activities" and confirm the
   activity list now includes them (Acceptance Scenario 1/3).
7. Repeat with one file already-imported mixed in among new ones.
8. **Expect**: the already-imported one does not create a duplicate entry (Acceptance
   Scenario 5, FR-015).
9. Repeat with one corrupt/unreadable file mixed in.
10. **Expect**: the summary shows both the successful imports and the specific failure
    (Acceptance Scenario 4, FR-017).

## Manual scenario: US1 — macOS drag-and-drop (P1, amended contract)

1. On macOS, drag one or more `.fit` files onto the activity list.
2. **Expect**: no file picker opens, no preview/confirmation screen appears, and the files import
   immediately — the activity list updates once the drop finishes (spec.md's amended Acceptance
   Scenario 2; this is a deliberate exception to the file-picker path, not a bug).
3. Repeat with a file that will fail to import mixed into the drop.
4. **Expect**: per spec.md's amended FR-002/FR-017, no per-item failure is shown — only whichever
   files succeeded appear in the list.

## Manual scenario: US2 — watched folder (P1)

Requires a folder already designated in Settings (see `004-settings-device-alias`).

1. Add a new `.fit` file to the watched folder from outside the app (Finder, a sync client).
2. Return to / foreground the app.
3. **Expect**: the new activity appears without any manual import action (Acceptance
   Scenario 1, FR-004).
4. Trigger an on-demand rescan (per Settings/UI affordance) immediately after adding another
   file.
5. **Expect**: the app checks right away rather than waiting (Acceptance Scenario 2, FR-006).
6. If testing with an iCloud-synced folder, add a file that's not yet fully downloaded.
7. **Expect**: the app waits, then reports a clear message if the download doesn't finish in
   time (Acceptance Scenario 3, FR-007).

## Manual scenario: US3 — share extension (P2)

1. From another app (Files app, a companion app), share a `.fit` file to FitView.
2. **Expect**: the share sheet proposes a name derived from the file's own content where
   possible, editable before saving (Acceptance Scenario 1, FR-009).
3. Confirm the save.
4. **Expect**: the activity appears in the main app without needing to separately open/re-import
   it (Acceptance Scenario 2).
5. Repeat with no watched folder configured.
6. **Expect**: the share sheet states a folder needs to be set up first (Acceptance Scenario 3,
   FR-010).
7. Repeat sharing a file that isn't valid activity data.
8. **Expect**: the share sheet reports it can't be read, plainly (Acceptance Scenario 4).

## Manual scenario: US4 — Polar sync (P2)

Requires a Polar Flow test account with at least one recent activity, connected via Settings.

1. Connect the account (Settings, per `004-settings-device-alias`).
2. **Expect**: sign-in/authorization completes with a confirmation (Acceptance Scenario 1,
   FR-011).
3. Trigger a sync (automatic on foreground, or on-demand).
4. **Expect**: new activities appear without manual file handling (Acceptance Scenario 2,
   FR-011, SC-005).
5. Check the connection's status display.
6. **Expect**: the ~30-day history limitation is stated (Acceptance Scenario 3, FR-012).
7. Disconnect the account.
8. **Expect**: previously-retrieved activities remain in the library (Acceptance Scenario 5,
   FR-014).

## Edge cases to spot-check

- Choose the COROS source (or equivalent "coming soon" entry) → plain "not available yet"
  message, not hidden and not a silent failure.
- Start a second import while one is running → the first is superseded, not merged (FR-016).
- Dismiss the import sheet mid-import → the in-progress import is cancelled (FR-016).
- A file whose name/metadata can't be parsed → still listed as unparseable, not silently
  dropped (FR-018).
