# Phase 0 Research: Import Flow

## §1. Closing the Principle VI gap for the Share Extension

**Unknown**: `ShareImportViewModel` (FR-008/FR-009/FR-010) has no automated test coverage.
`002-activity-detail` closed an analogous gap (`SessionDetailModel`) by extracting a SwiftUI-free
presenter and adding it to the `FitViewTests` target. Does the same "extract a presenter" move
apply here, or is there a simpler fix?

**Decision**: No extraction needed. Add `Sources/ShareExtension/Shared` to `FitViewTests`'s
`sources` array in `project.yml`, then write `Tests/FitViewTests/ShareImportViewModelTests.swift`
against the existing `ShareImportViewModel` class directly.

**Rationale**:
- `ShareImportViewModel.swift` already `import`s only `FitViewCore`, `Foundation`,
  `Observation`, and `UniformTypeIdentifiers` — no `SwiftUI`. It is already the SwiftUI-free
  presenter `002-activity-detail`'s pattern calls for; nothing needs pulling out of it.
- Its two inputs — `NSExtensionContext?` and the `NSItemProvider`s inside its `inputItems` — are
  both plain `Foundation`/`Foundation`-extension types, not `UIKit`/`AppKit` extension-host
  machinery. A test can construct a real `NSExtensionItem` with an `NSItemProvider(contentsOf:
  tempFileURL, ...)` attachment and pass `nil` for `extensionContext` (the class already
  handles `extensionContext == nil` — `cancel()`/`save()`'s `completeRequest` calls are on an
  optional). `start()` and `save()` are then directly callable and their `phase`/`fileName`/
  `isSaving`/`saveError` outputs directly assertable — no fake or protocol-abstracted
  extension-context layer is needed.
- The only reason it has zero coverage today is that `Sources/ShareExtension/Shared` is a
  `sources` path on `FitViewShareExtension-iOS`/`-macOS` only (`project.yml`); `FitViewTests`
  (hosted by `FitView-macOS`) never compiles it, and `FitView-macOS` itself doesn't include that
  path either (confirmed: its `sources` are `Sources/FitView` and `Sources/FitView-macOS` only),
  so there's no duplicate-symbol risk from adding it to `FitViewTests`.
- `AppGroup` (used for `ShareImportViewModel`'s default `bookmark`/`nicknames` arguments) is
  defined in `FitViewCore`, already a `FitViewTests` dependency — no new package dependency
  needed. Tests can override `bookmark`/`nicknames` with fixture instances the same way
  `WatchedFolderSourceTests`/`ShareImportTests` already do, so App-Group `UserDefaults` state
  never leaks between tests.

**Alternatives considered**:
- *Extract a new `ShareImportModel` presenter type, mirroring `SessionDetailModel`.* Rejected —
  there's nothing to extract; `ShareImportViewModel` doesn't import SwiftUI today, unlike
  `SessionDetailView`/`SessionDetailModel` before their split. Extracting a second type here
  would just rename the existing one without removing any coupling, which Principle II's
  "generalize only once a second real call site needs it" argues against.
- *Stand up a new `FitViewShareExtensionTests` target hosted by an extension target, with a new
  `tests.yml` job.* Rejected — heavier than needed (a new CI job, a new hosted-test-bundle
  wiring) for one file, and `002-activity-detail`'s precedent is specifically "extend the
  existing wired target," not add new CI plumbing, when the existing one already covers the
  right kind of code (SwiftUI-free, `Sources/FitView`-and-friends unit logic).

## §2. Drag-and-drop's spec/code mismatch

**Unknown**: The original spec draft's FR-002 ("producing the same result as picking them
through the file picker") and Acceptance Scenario 2 don't match `BatchOverviewView.handleDrop`'s
actual behavior — it imports immediately with no preview/confirmation step and discards
`ImportCoordinator`'s per-item failure list, showing neither successes nor failures explicitly
(only an implicit activity-list refresh on success).

**Decision** (per explicit user direction during planning): amend spec.md to describe this as
drag-and-drop's intended, current exemption rather than changing `BatchOverviewView.handleDrop`
to route through `ImportSheet`'s confirm/summary UI. spec.md's FR-002, FR-003, FR-017, SC-004,
User Story 1's Acceptance Scenario 2/4, the Edge Cases list, and the Assumptions section were all
updated accordingly (see spec.md diff). No code change and no task in tasks.md follows from this
— it's a documentation-only resolution.

**Rationale**: the user was presented with three options (fix code, amend spec, defer) and chose
to amend the spec, so the plan proceeds without carrying an open code-vs-spec gap. Revisiting the
UX gap itself (routing drops through the same confirm/summary flow) is explicitly out of scope
per the new Assumptions entry, and would be a future feature/issue, not part of 003.

**Alternatives considered**:
- *Change `handleDrop` to build the same `.confirmingImport`/`.summary` flow `ImportSheet` uses.*
  Viable and arguably better UX, but rejected for this pass per user decision — it's a
  user-visible behavior change requiring manual verification per `CLAUDE.md`'s
  pause-for-UI-review workflow, not a "formalize what's already shipped" documentation change,
  and the user chose not to take it on here.
- *Leave the spec as originally drafted and flag the mismatch in Complexity Tracking as an
  accepted violation.* Rejected — Complexity Tracking is for constitution-principle violations
  needing justification, not spec-acceptance-criteria mismatches; amending the spec directly is
  the correct mechanism for "the spec described the wrong behavior."

## §3. Polar's UI entry point

**Unknown**: `ImportSheet`'s `sources` array is `[bundledSource, fileSource, corosSource]` —
`PolarAccessLinkSource` is never listed there. Is this a gap (Polar unreachable from the import
UI) or by design?

**Decision**: By design, not a gap. `AppModel.swift` holds `polarSource` directly and drives
`authorize()`/`disconnect()`/sync from `SettingsView.swift` (connect/disconnect UI) and
`AppModel.syncPolar` (automatic + on-demand sync, called on launch/foreground alongside
`rescanFolder`). This matches spec.md's "Note on scope": connecting/disconnecting a third-party
account is a Settings action specified in `004-settings-device-alias`; this spec (003) only
covers the import behavior that follows once a connection exists. `ImportSheet`'s source list is
correctly scoped to the sources a user picks per-import-action (bundled sample, files, COROS
placeholder) — Polar's sync is ambient/automatic once connected, not something re-selected from
this sheet each time, consistent with FR-011 ("automatically retrieve new activities from it
without further manual action").

**Rationale**: confirmed by reading `AppModel.swift` (`polarSource`, `syncPolar`,
`rescanFolder`) and `SettingsView.swift` (Polar connect/disconnect UI, gated behind
`!model.polarSource.isConfigured` and `model.isFolderConfigured`) directly — no code change or
spec amendment needed here.

**Alternatives considered**: None — this was a verification task, not a decision with real
alternatives.

## §4. On-demand rescan queuing (FR-006, Edge Case: "a rescan is already in progress")

**Unknown**: Where is "a rescan requested while one is running is honored after, not dropped"
actually implemented — `FolderIngestor` (actor-isolated `ingest`) or `AppModel`?

**Decision**: `AppModel.rescanFolder(force:)` implements this explicitly via an `isScanning`
guard plus a `rescanQueued` flag and a `repeat...while rescanQueued` loop around the
`ingestor.ingest(into:)` call — not implicit actor-isolation serialization on `FolderIngestor`
itself. No code change needed; this is already correct and matches the spec's edge case.
`AppModel.syncPolar` uses the same `lastPolarSyncFinishedAt`/debounce shape for Polar, though
Polar sync does not have an equivalent explicit `rescanQueued`-style queue (a concurrent Polar
sync request while one is in flight is not separately specified by this spec's edge cases, since
FR-006's "on-demand rescan" language is folder-specific).

**Rationale**: read directly from `AppModel.swift`'s `rescanFolder`/`syncPolar` implementations.

**Alternatives considered**: None — verification task.
