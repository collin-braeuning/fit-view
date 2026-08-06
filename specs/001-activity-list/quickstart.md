# Quickstart: Validating the Activity List

This feature documents already-shipped behavior; there is no new build step. Use this to
confirm the acceptance scenarios in `spec.md` still hold, and to run the new
`BatchOverviewModel` unit tests once they exist (see `research.md` §1, `tasks.md`).

## Prerequisites

- Xcode with the FitView project generated: `xcodegen generate` (only needed after
  `project.yml` or file-set changes — not needed just to open the project).
- Per `CLAUDE.md`, building/running/launching the simulator is the user's job unless this is an
  explicit remote-control session — this guide is written for manual verification in Xcode.
- A loaded batch: either the bundled reference dataset (`overview.md` §8 — 14 files, 7
  sessions, 2 devices, `run` activity only) imported via the app's Import sheet, or any folder
  containing paired FIT files from exactly two devices.

## Automated check (Phase 0 gap)

Once `FitViewTests` exists (research.md §1):

```bash
xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests
```

Expected: `BatchOverviewModelTests` passes, covering — a `SessionRow` built from a
`SessionAgreement` with both `blandAltman` and `concordance` present (bias/LoA/CCC all
non-nil, correct `AgreementLevel`); one with both `nil` (bias/LoA/CCC absent, fallback
`cccAccessibilityLabel` text used); a `SkippedRow` for each `SkippedSession.Reason` case
(`reasonText` matches the two documented strings in data-model.md).

## Manual scenarios (map to spec.md Acceptance Scenarios)

1. **Scan at a glance (Scenario 1)** — Import the reference dataset. Open the app. Confirm
   each of the 7 sessions appears as one entry with date, activity ("run"), CCC + HR range,
   bias, and mean |diff|, each colored/iconed by level. Cross-check against `overview.md` §8's
   stated range (CCC 0.797–0.996) — the 2026-07-30 session should read as `bad`/red.

2. **Skipped entries (Scenario 2)** — Import a folder containing a pair of files with no
   time overlap (or fewer than 2 matched seconds). Confirm they appear under "Skipped" with a
   reason, not silently dropped, and are still tappable.

3. **Empty state (Scenario 3)** — Point the app at an empty/no-match folder. Confirm
   "No sessions could be compared." is shown, not a blank screen.

4. **Narrow layout disclosure (Scenario 4)** — Run on iPhone (or resize a Mac window narrow /
   use the iOS simulator in portrait). Confirm cards show date/activity/CCC/bias/mean-diff by
   default, and tapping "Details" reveals matched-seconds and per-device coverage in place
   (no navigation).

5. **Wide layout table (Scenario 5)** — Run on Mac, or iPad landscape ≥900pt width. Confirm
   the table shows all 9 columns (Date, Activity, Matched Seconds, HR Range, Bias, 95% LoA,
   Mean |Diff|, Max |Diff|, CCC). Narrow the window below 900pt (iPad portrait) and confirm it
   switches to the reduced 7-column table (95% LoA and Max |Diff| dropped; HR Range stays) per
   `contracts/activity-list-fields.md`.

6. **Resize mid-session (Edge Case)** — With the app open on iPad, rotate portrait ↔ landscape
   (or resize a Mac/iPad-in-Stage-Manager window across the 900pt threshold). Confirm the same
   sessions and values appear before and after, just re-laid-out.

7. **Selection → detail (FR-006 / SC-004)** — In both layouts, select one entry. Confirm
   navigation reaches that session's detail view in exactly one action (detail view content
   itself is `002-activity-detail`'s concern, not verified here beyond "did navigation occur").

## Out of scope for this quickstart

- Import mechanics (file picker, drag-and-drop, share extension, Polar sync) — separate
  feature.
- Activity detail view content — `002-activity-detail`.
- Agreement-level threshold tuning — no settings surface exists yet (research.md §3).
