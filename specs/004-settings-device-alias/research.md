# Phase 0 Research: Settings & Device Alias Management

No NEEDS CLARIFICATION markers remain in the Technical Context — the spec's own
Clarifications session (2026-08-08) already resolved the three open product questions
(share sheet vs. in-app browser, fixed 1000-entry cap, explicit connection-lost state).
This document resolves the remaining *implementation* decisions needed to close the three
gaps identified in the plan's Summary.

## 1. Diagnostic log: ring buffer + persistence format

**Decision**: Keep `Documents/debug.log` as a plain newline-delimited UTF-8 text file (no
format change), but cap it at 1000 lines using a read-trim-rewrite strategy: on each
append, if the file would exceed 1000 lines, read it, drop the oldest lines, and rewrite.
Extract the trim arithmetic (given existing lines + a new line, return the capped list)
into `FitViewCore.DiagnosticLogRingBuffer` as a pure function so it is unit-testable
without touching a real file.

**Rationale**: The existing in-memory `debugLog` array already does exactly this
trim-to-cap dance (`AppModel.swift`'s `log(_:)`, capped at 200) — reusing the same
approach for the file keeps one mental model instead of two, and a plain text file is
what the share sheet should hand off anyway (human-readable, no export-time conversion
step). A pure helper in `FitViewCore` satisfies Constitution Principle I (distinct
responsibility → own, directly-testable unit) instead of leaving array-trim logic
inline inside `AppModel`, which itself isn't unit-testable (it's `@MainActor`-bound with
Foundation.FileManager side effects).

**Alternatives considered**:
- *Rewrite on every single append via full read-modify-write, unbounded growth left to
  the OS.* Rejected — this is exactly the current uncapped behavior the spec's
  clarification says to fix (FR-013).
- *Structured format (JSON Lines) instead of plain text.* Rejected — no consumer needs
  structured parsing (a human reads the exported file in Mail/Files), and a text format
  keeps the diff with existing behavior minimal.
- *SQLite-backed ring buffer.* Rejected — massive overhead for a 1000-line cap; adds a
  dependency and migration surface for no benefit at this scale.

## 2. Log export mechanism

**Decision**: Add an "Export Log…" button to `SettingsView.swift`'s Debug Log section
(replacing the current inline `Text` block + "Clear Log" button) that presents the
platform system share sheet over the `debug.log` file URL — `UIActivityViewController`
on iOS/iPadOS, `NSSharingServicePicker` (or SwiftUI's `ShareLink`, which already wraps
both platforms) on macOS. Prefer SwiftUI's `ShareLink(item:)` pointing at the file URL if
it handles both platforms adequately during implementation; fall back to
platform-conditional `UIActivityViewController`/`NSSharingServicePicker` only if
`ShareLink` can't present a file (vs. a URL/text) cleanly on one platform.

**Rationale**: `ShareLink` is the native, no-dependency SwiftUI API for "hand a file to
the system share sheet," and the spec's clarification explicitly names AirDrop/Mail/
Messages/Save to Files — exactly `ShareLink`'s built-in destination set. This also
removes the manual "Clear Log" button per the clarification ("No manual 'Clear Log'
control is needed since growth is bounded automatically").

**Alternatives considered**:
- *Keep the in-app scrollable log list, add export as a second control.* Rejected — the
  clarification explicitly says export "replac[es] the in-app browsable log list," not
  supplements it.
- *`UIDocumentPickerViewController` for save-only, no share sheet.* Rejected — narrower
  than what the spec asks for (AirDrop/Mail/Messages, not just Save to Files).

## 3. "Connection lost, reconnect needed" state

**Decision**: Replace `AppModel.isPolarConnected: Bool` with a small enum (e.g.
`PolarConnectionState { case notConnected, connected, connectionLost }`) so the three
states are structurally distinct rather than inferred from a Bool plus a transient error
string. Detect the transition to `.connectionLost` at the one place a stale token would
actually surface: `PolarAPIClient`'s response-status handling — when a request that
requires the stored session gets back HTTP 401, propagate a distinguishable error (e.g.
`ActivitySourceError.unauthorized`, which already exists but is currently only thrown
for "no session in memory") up through `PolarAccessLinkSource` to `AppModel`, which then
sets the enum to `.connectionLost` instead of leaving `isPolarConnected` stuck `true`.
`SettingsView.swift` renders `.connectionLost` with its own label (e.g. "Connection
lost — reconnect needed") distinct from both "Connect Polar Flow…" (not connected) and
the normal connected controls.

**Rationale**: FR-015 requires a state a user can *see* is different from "never
connected"; a Bool cannot represent three states without a second flag, which is exactly
the kind of implicit-state smell Constitution Principle II's "own the state intrinsic to
it" guidance argues against introducing. Detecting 401 in `PolarAPIClient` (rather than
in every call site) is the single choke point all authenticated Polar requests already
pass through (`requireSuccess`), so it is the one place this needs to be added.

**Alternatives considered**:
- *Proactively validate the token on every app launch with a cheap "whoami"-style call.*
  Rejected — Polar's API has no dedicated lightweight validation endpoint documented in
  this codebase's existing `PolarAPIClient`/`PolarConfiguration`; reusing the 401 from a
  real sync/connect call the user already triggers is simpler and needs no new network
  call.
- *Keep `isPolarConnected: Bool` and add a second `connectionLost: Bool`.* Rejected — two
  independently-settable Booleans can represent an invalid combination (both true); a
  single enum can't.

## 4. Test coverage additions (Constitution Principle VI)

**Decision**:
- `DiagnosticLogRingBufferTests.swift` in `Packages/FitViewCore/Tests/FitViewCoreTests`
  (runs under the existing `fitviewcore-tests` CI job — no workflow change needed since
  that job already runs `swift test` for the whole package).
- A new `AppModel`-adjacent test (in `Tests/FitViewTests`, the existing hosted bundle) for
  the Polar connection-state transition (`.connected` → `.connectionLost` on a simulated
  401), which the `fitview-tests` CI job already runs via `-only-testing:FitViewTests` —
  no workflow change needed there either, since the job runs the whole target, not an
  enumerated file list.
- `TokenStore` (`KeychainTokenStore`/`InMemoryTokenStore`) test coverage is out of scope
  for this feature unless implementation work touches it — it's a pre-existing gap noted
  during research, not something FR-001–FR-015 requires changing. Filed as a follow-up
  observation, not a blocking task.

**Rationale**: Both target CI jobs already run their whole target/package rather than an
enumerated file list, so no `.github/workflows/tests.yml` edit is anticipated — but this
must be verified once the actual files are added (per Principle VI's "double-checked
before being considered done" requirement), not assumed from this research alone.

**Alternatives considered**: *Skip `FitViewTests` coverage since `AppModel` is
`@MainActor` and awkward to instantiate in tests.* Rejected — the connection-state
transition is exactly the kind of logic Principle VI exists to force coverage of; if
`AppModel` itself resists testing, the 401-to-connectionLost mapping should be extracted
into a small, directly-testable pure function (mirroring the ring-buffer approach above)
rather than left uncovered.
