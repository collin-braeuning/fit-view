# Quickstart: Validating the Activity Detail View

This feature documents already-shipped behavior; there is no new build step. Use this to
confirm the acceptance scenarios in `spec.md` still hold, and to run the new
`SessionDetailModel` unit tests once they exist (see `research.md` §1, `tasks.md`).

## Prerequisites

- Xcode with the FitView project generated: `xcodegen generate` (only needed after
  `project.yml` or file-set changes — not needed just to open the project).
- Per `CLAUDE.md`, building/running/launching the simulator is the user's job unless this is an
  explicit remote-control session — this guide is written for manual verification in Xcode.
- A loaded batch reaching this screen: import the bundled reference dataset (`overview.md` §8)
  via `001-activity-list`'s Import sheet, then select any entry (comparable or skipped) from the
  list.

## Automated check (Phase 0 gap)

Once `SessionDetailModelTests` exists (research.md §1):

```bash
xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests
```

Expected: `SessionDetailModelTests` passes, covering — a normal session (both Bland-Altman and
CCC present: all stat tiles non-nil, correct `AgreementLevel`, both plots non-nil); the
missing-device-file skip (`skipBannerText` names the missing device, `coverageDetails` has one
entry); the no-overlap skip; the too-few-points skip (`skipBannerText`'s wording distinct from
the other two, per FR-007); and the constant-value case (`concordancePlot`/`ccc` nil while
`blandAltmanPlot`/`bias` are not, per Edge Case 1) — see `SessionDetailPreviewFixture`'s five
sessions (`data-model.md`, `contracts/session-detail-fields.md`).

## Manual scenarios (map to spec.md Acceptance Scenarios)

1. **Full breakdown on open (User Story 1, Scenario 1-2)** — From the activity list, open the
   `2026-08-01`-equivalent "normal" session (or any comparable session in the reference
   dataset). Confirm the detail view shows: title/date/device labels, the overlaid HR chart, the
   stats grid (matched seconds, bias, 95% LoA, mean/max |diff|, CCC), both agreement plots,
   coverage percentages per device, and per-device source facts (file name, sport, time range,
   record/lap counts, avg/max HR) — matching the numbers shown for it in the activity list.

2. **No usable overlap (Scenario 3, Edge Case — missing device)** — Open a skipped session from
   the list. Confirm the stats grid and agreement plots are replaced by a plain-language skip
   banner, not blank or zeroed values, and that the wording correctly identifies *which* of the
   three skip reasons applies (missing file names the device; no-overlap and too-few-points read
   distinctly per `contracts/session-detail-fields.md`).

3. **Expand the chart (Scenario 4, FR-008)** — Tap the expand control on the HR chart. Confirm
   it opens full-screen (iOS/iPadOS) or as a large resizable sheet (macOS), and dismisses back to
   the detail view. Repeat for each agreement plot's expand control.

4. **Explain a statistic (User Story 2, Scenario 1)** — Tap a stat tile that shows an info glyph
   (e.g., CCC or Bias). Confirm an in-context explanation appears (popover on Mac/iPad, sheet on
   iPhone) without leaving the detail view, and that the tile was visually identifiable as
   tappable beforehand (info glyph present).

5. **Explain a plot (Scenario 2)** — Tap the info button next to "Bland-Altman Agreement" or
   "Lin's Concordance Correlation Coefficient". Confirm the explanation names the plot shown,
   in place.

6. **Constant-value session (Edge Case 1)** — Open a session where both devices' HR readings are
   effectively constant over the matched window, if the reference dataset has one (or the
   preview's "Normal" fixture, whose −1bpm-constant difference collapses CCC's denominator).
   Confirm the CCC tile and concordance plot are omitted (not shown as an error or zero) while
   bias/Bland-Altman remain.

7. **HR range paired with CCC (Edge Case 3)** — For any session with a CCC value, confirm its
   detail line always shows the HR range it was measured over alongside the McBride word (e.g.,
   "substantial · 90–173 bpm"), never the CCC number alone.

8. **Delete entry point (FR-012)** — Confirm the "..." toolbar menu offers "Delete Activity".
   Full delete behavior (confirmation, error handling, recoverability) is verified by
   `005-session-deletion`'s own quickstart, not here.

## Out of scope for this quickstart

- Activity list content and navigation into this screen — `001-activity-list`.
- Delete confirmation/error/recoverability behavior — `005-session-deletion`.
- Agreement-level threshold tuning — no settings surface exists yet
  (`001-activity-list/research.md` §3, reaffirmed in this feature's `research.md` §3).
