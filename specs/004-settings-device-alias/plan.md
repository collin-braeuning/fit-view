# Implementation Plan: Settings & Device Alias Management

**Branch**: `004-settings-device-alias` | **Date**: 2026-08-08 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/004-settings-device-alias/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

Most of this spec (FR-001–FR-011, FR-014) formalizes Settings/device-alias behavior that
already ships: `SettingsContent`/`SettingsSheet`, `DeviceAliasSheet`,
`Packages/FitViewCore/Sources/FitViewCore/DeviceNicknameStore.swift`, and
`Sources/FitView/Import/Polar/TokenStore.swift` already implement device renaming
(with cycle rejection), data-source switching, folder management, and Polar
connect/disconnect/reset. Three gaps remain unbuilt against the (already-clarified) spec
and are this plan's actual scope:

1. **Diagnostic log export (FR-012, FR-013)** — replace the in-app browsable "Debug Log"
   section and its manual "Clear Log" button in `SettingsView.swift` with a share-sheet
   export of a persisted, capped (1000-entry ring buffer) `debug.log` file. Today
   `AppModel.debugLog` is an in-memory array (capped at 200, not persisted per its own
   stale doc comment) that separately, silently, also appends to an uncapped on-disk
   `Documents/debug.log` (`AppModel.swift:479-512`) retrievable only via
   `devicectl` over a cable.
2. **"Connection lost, reconnect needed" state (FR-015)** — `AppModel.isPolarConnected`
   is a plain `Bool`; there is no state distinct from "never connected." An HTTP 401 from
   a revoked/expired Polar token is not specifically detected anywhere in
   `PolarAPIClient`/`PolarAccessLinkSource` today — it falls through as a generic
   `ActivitySourceError.underlying` string, and `isPolarConnected` is not flipped back.
3. **Test coverage** — `TokenStore` (`KeychainTokenStore`/`InMemoryTokenStore`) and the
   debug-log ring buffer have zero existing tests; per Constitution Principle VI, new
   coverage must be wired into `.github/workflows/tests.yml`, not just exist locally.

## Technical Context

**Language/Version**: Swift 5.9 (SWIFT_VERSION 5.0 toolchain setting in `project.yml`)

**Primary Dependencies**: SwiftUI, `Observation` (`@Observable`), `Security` (Keychain,
already in use via `KeychainTokenStore`), `UniformTypeIdentifiers`; no new third-party
dependencies needed.

**Storage**: `UserDefaults` via `AppGroup.defaults` (device nicknames, already shipped);
Keychain via `KeychainTokenStore` (Polar session, already shipped); a local file,
`Documents/debug.log` inside the app's own container (diagnostic log — exists today,
uncapped; this plan caps it at 1000 entries and adds export).

**Testing**: XCTest — `swift test` for `Packages/FitViewCore` (pure logic, e.g.
`DeviceNicknameStoreTests.swift`), `xcodebuild test -scheme FitView-macOS
-only-testing:FitViewTests` for `Sources/FitView`'s SwiftUI-free helpers (`AppModel`
lives here). Both are wired into `.github/workflows/tests.yml` today and any new test
file added under either target must stay wired per Constitution Principle VI.

**Target Platform**: macOS 14+, iOS 17+ (also builds for iPadOS under the iOS target,
per `project.yml`'s `TARGETED_DEVICE_FAMILY: "1,2"`)

**Project Type**: Native Apple app — SwiftUI app targets (`FitView-macOS`, `FitView-iOS`)
plus a share extension, backed by the platform-independent `FitViewCore` Swift package.

**Performance Goals**: N/A — Settings is a low-frequency, user-driven screen; no
throughput/latency target beyond staying responsive to typing/taps.

**Constraints**: Diagnostic log file MUST stay bounded (1000-entry ring buffer, FR-013)
so it can't grow unbounded; log export MUST go through the system share sheet
(`UIActivityViewController` / `NSSharingServicePicker`, platform-appropriately) rather than
a custom transfer mechanism, per the spec's clarification.

**Scale/Scope**: One Settings screen (`SettingsContent`, shared across macOS `Settings`
scene and iOS `SettingsSheet`) plus `DeviceAliasSheet`; a small number of known devices —
a device appearing under an unexpected extra name is exactly the naming-mismatch case
device-alias merging (User Story 1) exists to fix, not evidence of new hardware.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment |
|---|---|
| I. Separation of Concerns & Shared Code | PASS. Device alias resolution already lives in `FitViewCore` (`DeviceNicknameStore`, `LibraryStore.updateDeviceAlias`), framework-free and unit-tested. The new ring-buffer cap and 401-detection logic are not FIT-domain logic (they're app-shell diagnostics/auth-state concerns tied to `AppModel`/`PolarAPIClient`, which already live in `Sources/FitView`, not `FitViewCore`) — no misplacement risk, but the log ring-buffer trim logic itself (pure array/string manipulation with no SwiftUI or Foundation-file dependency) should be extracted into a small, directly-testable helper rather than left inline in `AppModel`, consistent with this principle's "distinct responsibility → own helper" clause. |
| II. Self-Contained, Reusable Components | PASS. `DeviceAliasSheet` already owns its own edit/save/error state. The planned share-sheet export control and the "connection lost" indicator are additions to existing components (`SettingsContent`), not new cross-component state-lifting. |
| III. Human-Readable, Comfortably Spaced UI | PASS, watch on implementation. Replacing the scrollable log text block with a single export button actually reduces density. The "connection lost, reconnect needed" state needs its own clearly distinguishable label/styling from "not connected" in the Polar Flow section — flag for review during implementation, not a gate failure. |
| IV. Configurable, Not Hardcoded | PASS. The 1000-entry cap is a fixed, spec-mandated constant (not a user preference), consistent with how the existing 200-entry in-memory cap is already a named constant (`AppModel.debugLogCap`) rather than a magic number — same treatment applies to the new file-backed cap. |
| V. Local Logging for Diagnosis | DIRECTLY ADVANCED. This feature's diagnostic-log work (FR-012/013) is this principle in application — making the log actually exportable off-device is what closes the gap between "logging exists" and "logging is usable for diagnosis without a debugger." |
| VI. CI-Verified Testing | GATE — must add, not just assert. New/changed logic (log ring-buffer trimming, 401 → connection-lost detection, and ideally `TokenStore`) needs test coverage wired into the existing `fitviewcore-tests` or `fitview-tests` CI jobs, verified to actually fail against broken code, per the research/tasks phases below. |

No violations requiring the Complexity Tracking table.

## Project Structure

### Documentation (this feature)

```text
specs/004-settings-device-alias/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md         # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/            # Phase 1 output (/speckit-plan command)
└── tasks.md              # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
Packages/FitViewCore/
├── Sources/FitViewCore/
│   ├── DeviceNicknameStore.swift        # existing — device alias table, unchanged by this feature
│   └── DiagnosticLogRingBuffer.swift    # NEW — pure, testable cap/trim logic for the 1000-entry log
└── Tests/FitViewCoreTests/
    ├── DeviceNicknameStoreTests.swift        # existing, unaffected
    └── DiagnosticLogRingBufferTests.swift    # NEW

Sources/FitView/
├── AppModel.swift                # MODIFIED — debugLog persistence/cap, Polar connection-state enum,
│                                  #   401 detection plumbing, log export entry point
├── DeviceAliasSheet.swift        # existing, unaffected
├── Settings/
│   └── SettingsView.swift        # MODIFIED — replace browsable log + "Clear Log" with export button;
│                                  #   render "connection lost, reconnect needed" state
└── Import/Polar/
    ├── TokenStore.swift          # existing; may gain a first test target
    ├── PolarAPIClient.swift      # MODIFIED — detect HTTP 401 specifically
    └── PolarAccessLinkSource.swift  # MODIFIED — surface connection-lost distinctly from never-connected

Tests/FitViewTests/
└── (new file, e.g. AppModelDiagnosticsTests.swift or similar — connection-state transition coverage)

.github/workflows/tests.yml       # MODIFIED if a new test file needs wiring into an existing job
```

**Structure Decision**: Single native-app project (no web/API split applies). New pure
logic (the ring-buffer cap) goes in `FitViewCore` per Constitution Principle I so it's
directly unit-testable without SwiftUI; everything else is a targeted modification of the
existing `AppModel`/`SettingsView`/Polar-import files rather than new top-level structure.

## Post-Design Constitution Check

*Re-evaluated after Phase 1 (data-model.md, contracts/, quickstart.md).*

- **I. Separation of Concerns** — confirmed by design: `DiagnosticLogRingBuffer` landed
  in `FitViewCore` as a pure function (data-model.md, diagnostic-log-contract.md), not
  inline in `AppModel`. PASS.
- **II. Self-Contained Components** — `PolarConnectionState` replaces a Bool+string pair
  with one structurally-valid enum owned by `AppModel`, eliminating the
  invalid-combination risk flagged at the pre-design gate. PASS.
- **III. Human-Readable UI** — the diagnostic-log contract requires the export button to
  replace, not add to, the scrollable log block, net-reducing Settings' density. PASS.
- **IV. Configurable, Not Hardcoded** — the 1000-entry cap remains a named constant
  (successor to `AppModel.debugLogCap`), not a preference — correctly *not* exposed as a
  user setting, since the spec fixes this number rather than asking for it to vary. PASS.
- **V. Local Logging for Diagnosis** — directly satisfied by design: export path plus a
  guaranteed-bounded file closes the "usable without a debugger" gap. PASS.
- **VI. CI-Verified Testing** — research.md §4 identifies exactly two new test files and
  confirms (pending actual-PR verification) both existing CI jobs already run their whole
  target/package, so no workflow edit is anticipated — flagged as a check to re-confirm
  once the files exist, per the principle's "double-checked before done" requirement, not
  a gate failure now.

No new violations introduced by the finalized design; no Complexity Tracking entries
needed.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No violations — table intentionally empty.
