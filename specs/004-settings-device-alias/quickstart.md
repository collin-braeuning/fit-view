# Quickstart: Validating Settings & Device Alias Management

This feature is a mix of already-shipped behavior (validate as regression checks) and
three real gaps this plan closes (validate as new-feature checks). Per `CLAUDE.md`,
building/running/screenshotting is the user's job unless a session is explicitly in
remote-control mode — this guide is what to run once implementation is ready for manual
verification in Xcode, plus the automated checks that can run standalone.

## Prerequisites

- Xcode project regenerated after any `project.yml`/source-file changes:
  `xcodegen generate`.
- `Packages/FitViewCore` tests runnable standalone: `cd Packages/FitViewCore && swift test`.
- `Sources/FitView`/`FitViewTests` runnable via
  `xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.
- A Polar Flow test account (or observe existing behavior without one — connect stays
  disabled/unconfigured if `Secrets.xcconfig` has no real client id/secret).

## Automated validation

1. **Ring buffer cap** (new): `DiagnosticLogRingBufferTests` — appending past 1000
   entries drops the oldest first, result length never exceeds 1000, retained order is
   preserved. Run via `swift test` in `Packages/FitViewCore`.
2. **Connection-state transition** (new): a `FitViewTests` case simulating an
   authenticated Polar call receiving HTTP 401 while `polarConnectionState == .connected`
   asserts it becomes `.connectionLost`, not `.notConnected` and not silently unchanged.
3. **Existing regression coverage, unaffected**: `DeviceNicknameStoreTests` (cycle
   rejection, chain resolution, normalization) — MUST still pass unmodified; this
   feature's changes MUST NOT touch `DeviceNicknameStore`.
4. **CI wiring check** (Constitution Principle VI): after adding the two new test files,
   confirm they run under the existing `fitviewcore-tests` / `fitview-tests` jobs in
   `.github/workflows/tests.yml` — both jobs currently run whole targets/packages, so no
   job change is expected, but this must be confirmed against the actual PR's CI run, not
   assumed.

## Manual validation (in Xcode, by the user)

### User Story 1 — Device rename (regression, already shipped)
1. Open Settings → Devices…
2. Confirm every known device is listed with its display label and file count (FR-001).
3. Rename one device to match another's label; save.
4. Confirm the new label appears immediately in the activity list, activity detail, and
   device management — without re-importing anything (FR-002).
5. Attempt a rename that would create a cycle; confirm it's rejected with a clear message
   (FR-003), not silently applied.
6. Confirm the activity list now groups the two previously-separate devices' sessions
   together (Acceptance Scenario 5).

### User Story 2 — Data source (regression, already shipped)
1. Start on Sample Data; confirm activities shown are the bundled corpus.
2. Switch to a designated folder; confirm the app now shows that folder's activities.
3. Switch back to Sample Data; confirm the samples are unchanged.
4. With no folder yet designated, confirm attempting to switch to the folder source is
   blocked/guided rather than landing in a broken state (FR-005 edge case).

### User Story 3 — Polar connection (regression + NEW gap: connection-lost state)
1. With a folder configured, connect a test Polar account; confirm it's shown as
   `.connected` (existing UI: Sync Now/Disconnect/Forget Downloaded Activities).
2. **NEW**: Revoke the connection from Polar Flow's own account settings (or otherwise
   invalidate the stored token), then trigger a sync from this app. Confirm Settings now
   shows an explicit "connection lost, reconnect needed" state — visually distinct from
   the pre-connection "Connect Polar Flow…" prompt (FR-015) — rather than a generic error
   string or a silent revert to "not connected."
3. Reconnect from the connection-lost state; confirm it returns to `.connected`.
4. Disconnect; confirm previously retrieved activities remain in the library (FR-010).
5. Reset sync history; confirm no library activity is deleted, and a subsequent sync is
   willing to re-check previously-seen activities (FR-011).

### User Story 4 — Diagnostic log export (NEW — this is the feature's main net-new UI)
1. Perform a few import/sync/connection actions so the log has entries.
2. Open Settings → Debug Log section. Confirm the in-app scrollable log list and "Clear
   Log" button are gone, replaced by an "Export Log…" (or equivalent) control (FR-012).
3. Trigger export; confirm the system share sheet opens (AirDrop/Mail/Messages/Save to
   Files on iOS/iPadOS; the macOS share picker on macOS) over a file containing the
   recent action history.
4. Generate more than 1000 log entries (e.g. by repeatedly forcing folder scans/syncs);
   confirm the exported file caps at 1000 entries with the oldest discarded, not growing
   unbounded (FR-013).
5. Confirm no manual "Clear Log" control exists anywhere in Settings.

## Success criteria mapping

| Success Criterion | Validated by |
|---|---|
| SC-001 (single rename merges two raw names) | User Story 1, steps 3–6 |
| SC-002 (switching source never deletes/hides the other) | User Story 2, steps 1–3 |
| SC-003 (disconnect/reset never removes a library activity) | User Story 3, steps 4–5 |
| SC-004 (export a complete log off-device without a cable/debugger) | User Story 4, steps 3–4 |
