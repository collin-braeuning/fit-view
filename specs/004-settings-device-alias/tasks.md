---

description: "Task list for Settings & Device Alias Management"
---

# Tasks: Settings & Device Alias Management

**Input**: Design documents from `/specs/004-settings-device-alias/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included — the plan's Constitution Check (Principle VI) requires CI-wired test
coverage for the two new gaps (ring buffer, connection-state transition); this is not an
optional add-on for this feature.

**Organization**: User Stories 1–3 (device rename, data source, Polar connect/disconnect)
are **already shipped** per plan.md's Summary — spec.md formalizes existing behavior for
them, and quickstart.md validates them as regression checks with no code changes required.
Only User Story 3 gets one net-new implementation task (the `.connectionLost` state, FR-015,
layered onto its otherwise-shipped connect/disconnect/reset flow). User Story 4 (diagnostic
log export, FR-012/FR-013) is entirely net-new. Tasks below reflect this: US1 and US2 have
no tasks (nothing to build — verify via quickstart.md only), US3 has the connection-state
gap, US4 is the main body of work.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4, matching spec.md priorities)

## Path Conventions

Native Apple app, single project. Pure/testable logic goes in
`Packages/FitViewCore/Sources/FitViewCore/` (tested via `swift test`); app-shell code goes
in `Sources/FitView/` (tested via `xcodebuild test -only-testing:FitViewTests` where
SwiftUI-free). Per CLAUDE.md, do not build/run/launch the app while executing these tasks
unless the session is explicitly in remote-control mode — `xcodegen generate` is fine after
any `project.yml`/source-file change.

---

## Phase 1: Setup

**Purpose**: Confirm the baseline this plan modifies is what plan.md/research.md describe,
before changing it.

- [X] T001 Run `swift test` in `Packages/FitViewCore` and confirm
  `DeviceNicknameStoreTests` (and the rest of the existing suite) passes unmodified, as the
  pre-change baseline this feature's changes must not disturb (quickstart.md's regression
  check #3).

---

## Phase 2: Foundational

**Purpose**: No shared blocking infrastructure is needed — both gaps (diagnostic log,
Polar connection state) are independent of each other and of the already-shipped US1/US2
code they sit alongside. Skipping to user story phases.

**Checkpoint**: N/A — proceed directly to Phase 3.

---

## Phase 3: User Story 1 - Rename a device so its recordings group correctly (Priority: P1)

**Goal**: Already shipped (`DeviceNicknameStore`, `LibraryStore.updateDeviceAlias`,
`DeviceAliasSheet`) — this spec formalizes existing behavior; no code changes in this
plan's scope.

**Independent Test**: quickstart.md "User Story 1 — Device rename (regression, already
shipped)", steps 1–6.

- [ ] T002 [US1] Execute quickstart.md's User Story 1 manual validation steps 1–6 in Xcode
  (device list with file counts, rename applied immediately everywhere, cycle rejection
  with a clear message, grouping after rename) and confirm no regression — no code change
  expected; file a bug only if a step fails.

**Checkpoint**: User Story 1 confirmed unaffected by this plan's changes.

---

## Phase 4: User Story 2 - Choose where activities come from (Priority: P1)

**Goal**: Already shipped (`DataSourceMode`, `AppModel.setWatchedFolder`/
`clearWatchedFolder`) — this spec formalizes existing behavior; no code changes in this
plan's scope.

**Independent Test**: quickstart.md "User Story 2 — Data source (regression, already
shipped)", steps 1–4.

- [ ] T003 [P] [US2] Execute quickstart.md's User Story 2 manual validation steps 1–4 in
  Xcode (sample data ↔ folder switch loses nothing, switch blocked with no folder
  designated) and confirm no regression — no code change expected; file a bug only if a
  step fails.

**Checkpoint**: User Story 2 confirmed unaffected by this plan's changes.

---

## Phase 5: User Story 3 - Connect a third-party account for automatic sync (Priority: P2)

**Goal**: Connect/disconnect/reset-sync-history is already shipped. This phase's actual
scope is the one real gap: FR-015's `.connectionLost` state, per
`contracts/polar-connection-contract.md` and data-model.md's "Third-Party Connection"
section — replacing `AppModel.isPolarConnected: Bool` with a `PolarConnectionState` enum
and detecting HTTP 401 as the trigger.

**Independent Test**: quickstart.md "User Story 3 — Polar connection (regression + NEW
gap: connection-lost state)", steps 1–5; automated: quickstart.md's Automated Validation
#2 (401 → `.connectionLost` transition).

### Tests for User Story 3

> Write these first; they must fail against the current `Bool`-based state before the
> implementation tasks below make them pass.

- [X] T004 [P] [US3] Add `Tests/FitViewTests/PolarConnectionStateTests.swift`
  (`@testable import FitView`, `Testing` framework, matching the style of
  `Tests/FitViewTests/BatchOverviewModelTests.swift`) covering the pure transition
  function added in T007: `.connected` + a simulated `ActivitySourceError.unauthorized` →
  `.connectionLost`; `.connected` + any other error (e.g. `.underlying("500")`) → stays
  `.connected`; `.notConnected`/`.connectionLost` + `.unauthorized` → unchanged (per the
  contract, only a live `.connected` session can go stale). This must not require
  instantiating `AppModel` — test the extracted pure function directly, per research.md
  §4's fallback guidance ("if `AppModel` itself resists testing, extract the mapping into
  a small, directly-testable pure function").

### Implementation for User Story 3

- [X] T005 [US3] In `Sources/FitView/Import/Polar/PolarAPIClient.swift`, change the
  private `requireSuccess(_:data:)` (line 133) to special-case HTTP 401: throw
  `ActivitySourceError.unauthorized` instead of the generic
  `.underlying("Polar returned HTTP \(status): ...")` when `httpResponse.statusCode ==
  401`, leaving every other non-2xx status on the existing `.underlying` path unchanged.
  This is the "one choke point all authenticated Polar requests already pass through" that
  research.md §3 identifies.
- [X] T006 [P] [US3] Add `enum PolarConnectionState: Equatable { case notConnected,
  connected, connectionLost }` to `Sources/FitView/AppModel.swift` (near the existing
  `debugLog`/Polar state properties, ~line 43), per
  `contracts/polar-connection-contract.md`.
- [X] T007 [US3] Add a pure static helper next to `PolarConnectionState` (e.g.
  `PolarConnectionState.afterFailedRequest(current:error:) -> PolarConnectionState`) that
  returns `.connectionLost` when `current == .connected` and `error` is
  `ActivitySourceError.unauthorized`, and returns `current` unchanged otherwise. This is
  the function T004's tests exercise directly.
- [X] T008 [US3] In `Sources/FitView/AppModel.swift`, replace `private(set) var
  isPolarConnected = false` (line 47) with `private(set) var polarConnectionState:
  PolarConnectionState = .notConnected`, and update every read/write site in the same
  file:
  - `connectPolar()` (lines 365–380): on `authorize()` success, set
    `polarConnectionState = .connected`; on failure, per the contract's postcondition
    ("unchanged"), **do not** reset it to `.notConnected`/`.connectionLost` — only set
    `polarError`, correcting the current code's `isPolarConnected = false` on failure.
  - `disconnectPolar()` (lines 385–396): set `polarConnectionState = .notConnected`
    unconditionally (from any prior state), matching the contract.
  - `syncPolar(force:)` (lines 405–454): where `restoreSession()` returns `false`
    (line 425–429), set `polarConnectionState = .notConnected`; where it returns `true`
    (line 430), set `.connected` only if not already `.connected`/`.connectionLost` from
    a more specific transition below (avoid clobbering a same-call-cycle `.connectionLost`
    result computed later). In the `catch` block (lines 449–453), after computing
    `message`, call `polarConnectionState =
    PolarConnectionState.afterFailedRequest(current: polarConnectionState, error: error)`
    (T007) so a 401 surfaced through `RemoteActivitySync` flips the state to
    `.connectionLost`.
- [X] T009 [US3] In `Sources/FitView/Settings/SettingsView.swift`'s Polar Flow section
  (lines 105–129), replace the `!model.isPolarConnected` / `else` two-way branch with a
  three-way `switch model.polarConnectionState`: `.notConnected` keeps the existing
  "Connect Polar Flow…" button (disabled unless `isFolderConfigured`); `.connected` keeps
  the existing Sync Now/Disconnect/Forget Downloaded Activities controls; `.connectionLost`
  is new — show a distinct label (e.g. "Connection lost — reconnect needed", styled
  visibly differently from the plain "Connect Polar Flow…" prompt, e.g. with a warning
  tint) plus a reachable reconnect action (reuse `connectPolar()`), per
  `contracts/polar-connection-contract.md`'s consumer-contract table. Do not render
  `.connectionLost` identically to `.notConnected`.

**Checkpoint**: User Story 3's `.connectionLost` gap (FR-015) closed and covered by T004;
existing connect/disconnect/reset-sync-history behavior (FR-009–FR-011) unaffected —
validate with quickstart.md steps 1, 3–5 (regression) and step 2 (new).

---

## Phase 6: User Story 4 - Export a local diagnostic log (Priority: P3)

**Goal**: Replace the in-app browsable "Debug Log" section and its manual "Clear Log"
button with a share-sheet export of a persisted, capped (1000-entry ring buffer)
`debug.log` file, per `contracts/diagnostic-log-contract.md` and data-model.md's
"Diagnostic Log" section. This is the feature's main net-new work (FR-012, FR-013).

**Independent Test**: quickstart.md "User Story 4 — Diagnostic log export (NEW — this is
the feature's main net-new UI)", steps 1–5; automated: quickstart.md's Automated
Validation #1 (ring buffer cap).

### Tests for User Story 4

> Write this first; it must fail against the not-yet-created `DiagnosticLogRingBuffer`
> before T012 makes it pass.

- [X] T010 [P] [US4] Add
  `Packages/FitViewCore/Tests/FitViewCoreTests/DiagnosticLogRingBufferTests.swift`
  (`Testing` framework, matching `DeviceNicknameStoreTests.swift`'s style) covering
  `DiagnosticLogRingBuffer.appending(_:to:cap:)` per
  `contracts/diagnostic-log-contract.md`: appending under cap grows the array by one;
  appending at cap evicts exactly the oldest entry (FIFO) and the result's count never
  exceeds `cap`; retained entries keep their relative order; `cap: 0` returns an empty
  array. Confirm this test fails to compile/run before T012 exists.

### Implementation for User Story 4

- [X] T011 [P] [US4] Add
  `Packages/FitViewCore/Sources/FitViewCore/DeviceNicknameStore.swift`-adjacent new file
  `Packages/FitViewCore/Sources/FitViewCore/DiagnosticLogRingBuffer.swift` with:
  `public enum DiagnosticLogRingBuffer { public static func appending(_ newEntry: String,
  to existing: [String], cap: Int) -> [String] }` per
  `contracts/diagnostic-log-contract.md` — pure, no I/O, order-preserving FIFO eviction
  from the front when `existing.count + 1 > cap`.
- [X] T012 [US4] In `Sources/FitView/AppModel.swift`:
  - Change `private static let debugLogCap = 200` (line 60) to `1000`, matching the
    single cap the contract requires for both the in-memory array and the on-disk file.
  - Replace the in-memory trim in `log(_:)` (lines 492–494, `if debugLog.count >
    Self.debugLogCap { debugLog.removeFirst(...) }`) with `debugLog =
    DiagnosticLogRingBuffer.appending(line, to: debugLog, cap: Self.debugLogCap)` (drop
    the separate `debugLog.append(line)` above it).
  - Replace `appendToLogFile(_:)` (lines 502–512, currently an append-only
    `FileHandle`/`write(to:)` path) with a read-trim-rewrite: read the existing file's
    lines (empty array if the file doesn't exist yet), call
    `DiagnosticLogRingBuffer.appending(line, to: existingLines, cap: Self.debugLogCap)`,
    and rewrite the file from the result (join with `"\n"` + trailing newline), per
    research.md §1. Keep this best-effort (swallow write errors) as the existing comment
    on `appendToLogFile` specifies.
  - Expose the file's URL for the export button, e.g. `static let debugLogFileURL` (rename
    the existing `private static let debugLogFileURL`, line 485, to non-private, or add a
    computed `var debugLogFileURL: URL { Self.debugLogFileURL }`) so `SettingsView.swift`
    can pass it to `ShareLink`.
  - Remove `clearDebugLog()` (lines 466–471) — per the contract, "MUST NOT expose a manual
    'Clear Log' action once the cap is in place."
- [X] T013 [US4] In `Sources/FitView/Settings/SettingsView.swift`'s Debug Log section
  (lines 160–180), replace the scrollable `Text(model.debugLog.joined(...))` block and the
  "Clear Log" button with: a lightweight in-Settings state indicator (e.g. "No log entries
  yet." when `model.debugLog.isEmpty`, otherwise an entry count like "\(model.debugLog
  .count) entries recorded" — per the contract's "some lightweight in-Settings indication
  ... so a user isn't exporting blind") and a `ShareLink(item: model.debugLogFileURL)`
  ("Export Log…") that is disabled when `model.debugLog.isEmpty`. Update the section's
  footer text to describe export instead of "Not saved between launches" (the file now is
  saved, capped at 1000 entries).

**Checkpoint**: User Story 4 fully functional — log entries accumulate capped at 1000 in
both `debugLog` and the on-disk file, export presents the system share sheet over the file,
no manual clear control remains. Validate with quickstart.md steps 1–5.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Confirm the plan's CI-wiring assumption and close out full-suite validation
before considering the feature done.

- [X] T014 [P] Run `swift test` in `Packages/FitViewCore` and confirm
  `DiagnosticLogRingBufferTests` (T010) passes and the full package suite (including
  `DeviceNicknameStoreTests`, unaffected) is green.
- [X] T015 [P] Run `xcodegen generate`, then `xcodebuild test -scheme FitView-macOS
  -only-testing:FitViewTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO` and confirm `PolarConnectionStateTests` (T004) passes and the
  rest of `FitViewTests` (e.g. `BatchOverviewModelTests`) is unaffected.
- [X] T016 Open `.github/workflows/tests.yml` and confirm both new test files (T004, T010)
  are picked up by the existing `fitviewcore-tests` (`swift test`, whole package) and
  `fitview-tests` (`-only-testing:FitViewTests`, whole target) jobs with no edits needed —
  per research.md §4's "must be verified once the actual files are added, not assumed."
  Only edit the workflow if a job is scoped more narrowly than assumed.
- [ ] T017 Execute quickstart.md's remaining Automated Validation items (#3 regression
  check, #4 CI wiring check) and all four Manual Validation sections end-to-end in Xcode,
  confirming the Success Criteria mapping table (SC-001–SC-004) holds.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — run first.
- **Foundational (Phase 2)**: Empty — no blocking work.
- **User Story 1 (Phase 3)** / **User Story 2 (Phase 4)**: Verification-only, no
  dependency on Phases 5–6; can run any time after Phase 1.
- **User Story 3 (Phase 5)**: Independent of Phase 6 — touches `PolarAPIClient.swift`,
  `AppModel.swift`'s Polar-specific state, and `SettingsView.swift`'s Polar Flow section
  only.
- **User Story 4 (Phase 6)**: Independent of Phase 5 — touches `AppModel.swift`'s
  debug-log-specific state and `SettingsView.swift`'s Debug Log section only. Both phases
  edit `AppModel.swift` and `SettingsView.swift`, but disjoint regions within each file —
  safe to parallelize across two contributors, sequential if solo.
- **Polish (Phase 7)**: Depends on Phases 5 and 6 both being complete.

### Within Each User Story

- US3: T004 (test) before T005–T009 (implementation) — T004 must fail first.
- US4: T010 (test) before T011–T013 (implementation) — T010 must fail first.

### Parallel Opportunities

- T002 and T003 (US1/US2 regression checks) can run in parallel with each other and with
  Phase 5/6 work — they touch no files.
- T004 and T010 (the two new test files, different targets/packages) can be written in
  parallel.
- T006 (enum definition) can be written in parallel with T005 (`PolarAPIClient` 401
  handling) — different files.
- T011 (`DiagnosticLogRingBuffer` implementation) has no same-file conflict with anything
  in US3.
- Phase 5 (US3) and Phase 6 (US4) can be executed in parallel by two contributors, given
  the disjoint-region note above.

---

## Parallel Example: Phase 5 (User Story 3)

```bash
# Test first:
Task: "Add Tests/FitViewTests/PolarConnectionStateTests.swift"

# Then, in parallel:
Task: "Add PolarConnectionState enum to Sources/FitView/AppModel.swift"
Task: "Special-case HTTP 401 in PolarAPIClient.requireSuccess"

# Then sequentially (both touch AppModel.swift's Polar section):
Task: "Add PolarConnectionState.afterFailedRequest pure helper"
Task: "Wire polarConnectionState through connectPolar/disconnectPolar/syncPolar"

# Finally:
Task: "Render the three-way polarConnectionState switch in SettingsView.swift"
```

---

## Implementation Strategy

### MVP First

This feature has no single "MVP user story" in the usual sense — US1/US2 are already
shipped (verification only) and US3/US4 are two small, independent gaps, not a
build-up-from-nothing sequence. Recommended order:

1. Phase 1 (Setup): confirm baseline.
2. Phase 6 (US4, diagnostic log) — the larger, more self-contained gap; delivers FR-012/
   FR-013 and SC-004 end-to-end on its own.
3. Phase 5 (US3, connection-lost state) — smaller, delivers FR-015 and closes SC-003's
   "surfaced explicitly" requirement.
4. Phase 3/4 (US1/US2 regression) — can be run any time, even first, since they gate
   nothing else.
5. Phase 7 (Polish): CI-wiring confirmation and full quickstart.md pass.

### Incremental Delivery

- After Phase 6: diagnostic log export is fully usable and testable independently
  (SC-004).
- After Phase 5: connection-lost state is fully usable and testable independently
  (part of SC-003).
- Phases 3/4 add no code — they're confidence checks, safe to run whenever convenient.

---

## Notes

- [P] tasks touch different files (or disjoint regions) with no ordering dependency.
- US1 and US2 intentionally have implementation tasks numbering zero — per plan.md, this
  spec formalizes already-shipped behavior for them; do not add code "to be thorough."
  Resist the urge to refactor `DeviceNicknameStore`/`DataSourceMode` while touching
  adjacent code in this feature.
- Do not delete `AppModel.clearDebugLog()`'s on-disk counterpart behavior by accident —
  T012's read-trim-rewrite replaces the append-only file write, it does not add a new
  "clear" path; the removed `clearDebugLog()` only ever touched the in-memory array.
- Per CLAUDE.md, do not build/run/launch the app to validate these tasks unless the
  session is explicitly in remote-control mode — T015/T017's `xcodebuild test` and
  `swift test` invocations are test runs, not app launches, and are fine to run; Xcode
  manual verification (quickstart.md's "Manual Validation" section) is the user's own
  step.

---

## Phase 8: Convergence

- [X] T018 Make reconnecting from `.connectionLost` actually re-authorize: today
  `SettingsView.swift:121`'s "Reconnect Polar Flow…" calls `AppModel.connectPolar()`, whose
  `polarSource.authorize()` returns early whenever `restoreSession()` finds a cached token
  (`Sources/FitView/Import/Polar/PolarAccessLinkSource.swift:62`) — and a 401-revoked token
  is still in the keychain, so no OAuth sheet is ever presented and the state cycles
  `.connectionLost` → `.connected` → 401 → `.connectionLost` forever. Clear the stale
  session before re-authorizing (e.g. `AppModel.connectPolar(forcingFreshAuth: Bool = false)`
  that calls `polarSource.disconnect()` first, or an `authorize(ignoringCachedSession:)`
  parameter on `PolarAccessLinkSource`), and have the `.connectionLost` branch use it, so
  the reconnect action the contract requires to be "reachable" is also functional
  per FR-015 / `contracts/polar-connection-contract.md` (partial)
- [X] T019 In `Sources/FitView/Settings/SettingsView.swift`'s `.connectionLost` branch
  (lines 118–124), add a reachable "Disconnect" control alongside the reconnect button so a
  user with a permanently-dead token has an in-app escape that clears the session (today
  Disconnect only renders under `.connected`, leaving `.connectionLost` with no way to reset
  the connection) per FR-015 / FR-010 (partial). UI-affecting — land separately and pause
  for the user's manual review per CLAUDE.md.
- [X] T020 In `Sources/FitView/AppModel.swift`'s `syncPolar` (line 462), stop unconditionally
  setting `polarConnectionState = .connected` after `restoreSession()` returns true: a
  restored *cached* token is not evidence the session is still valid, so from
  `.connectionLost` a subsequent sync that fails for a non-auth reason (offline →
  `ActivitySourceError.underlying`) leaves the state stuck at `.connected` and hides
  "reconnect needed." Promote to `.connected` only from `.notConnected` (or only after a
  request actually succeeds), leaving `.connectionLost` intact — the clobber T008 explicitly
  warned against — and extend `Tests/FitViewTests/PolarConnectionStateTests.swift` to cover
  it per FR-015 (partial)
- [X] T021 Extract the diagnostic log's file ↔ entries codec (the
  `split(separator: "\n", omittingEmptySubsequences: true)` parse duplicated verbatim in
  `AppModel.init` line 163–164 and `appendToLogFile` line 532–533, plus the
  `joined(separator: "\n") + "\n"` serialize at line 535) into a pure helper in
  `Packages/FitViewCore/Sources/FitViewCore/DiagnosticLogRingBuffer.swift` (or an adjacent
  file), and add round-trip coverage to
  `Packages/FitViewCore/Tests/FitViewCoreTests/DiagnosticLogRingBufferTests.swift` asserting
  that entries written and re-read yield the same count — the behavior FR-016's "count read
  from the persisted log at launch must match what an export contains" depends on, currently
  duplicated inline and untested (FR-016 was added to spec.md after tasks.md was generated
  and has no earlier task) per FR-016 / Constitution I / Constitution VI (partial)
