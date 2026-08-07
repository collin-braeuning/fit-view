# Phase 1 Data Model: Import Flow

This documents the existing production types behind the spec's Key Entities (`Import Source`,
`Import Candidate`, `Import Result`) and the one presenter (`ShareImportViewModel`) closing the
Principle VI gap (research.md §1). No new production types are introduced by this feature — this
is a description of what already exists, for traceability from FR-### to code.

## Import Source → `ActivitySource` protocol

`Packages/FitViewCore/Sources/FitViewCore/ActivitySource.swift`

| Member | Type | Notes |
|---|---|---|
| `id` | `String` | Stable identifier: `"bundled"`, `"files"`, `"polar"`, `"coros"`. Recorded on `ImportedActivity.source` → `LibraryItem` provenance. |
| `displayName` | `String` | User-facing label in `ImportSheet`'s source picker. |
| `requiresAuthorization` | `Bool` | Drives whether `ImportSheet.run(_:)` calls `authorize()` before `listAvailable()`. `true` only for `PolarAccessLinkSource`. |
| `authorize() async throws` | — | No-op for sources that need no login (bundled, files, COROS-placeholder). |
| `listAvailable() async throws -> [ImportCandidate]` | — | FR-001/FR-004/FR-011: everything currently importable. |
| `fetch(_:) async throws -> ImportedActivity` | — | Pulls one candidate's raw bytes. |

**Conforming types** (all `actor`, all satisfying FR-013's error taxonomy via `ActivitySourceError`):
`BundledSampleSource`, `FileImportSource` (FR-001/FR-002), `WatchedFolderSource` (FR-004/FR-007,
used by `FolderIngestor` rather than `ImportSheet` directly), `PolarAccessLinkSource`
(FR-011/FR-012/FR-013/FR-014, used by `AppModel`/`RemoteActivitySync`, not `ImportSheet` —
research.md §3), `CorosSource` (announced-but-unavailable placeholder — Edge Cases).

## Import Candidate → `ImportCandidate`

`ActivitySource.swift`. Fields: `sourceId` (stable within its source only — not a global key),
`suggestedName` (canonical `"2026-07-26_pace4_run"` shape so batch grouping can parse it),
`startTime`/`deviceLabel`/`sport` (all optional — `nil` until a file-based candidate is decoded).
Maps directly to the spec's Import Candidate entity ("enough information... to preview before
committing to import it").

## Import Result → `ImportResult` / `ImportFailure` / `FolderIngestReport` / `RemoteSyncReport`

Four related result shapes, one per layer, all following the same "successes and failures
reported together, never one hiding the other" rule (FR-017):

- **`ImportResult`** (`ImportCoordinator.swift`): `files: [LoadedFile]`, `failures:
  [ImportFailure]`. What `ImportSheet.startImport` turns into its `Summary` (`fileCount`,
  `failures`, `unparsedNames` via `groupActivityFiles`).
- **`ImportFailure`**: `candidate: ImportCandidate`, `message: String` — one per failed item,
  never a batch-level "some failed" without specifics.
- **`FolderIngestReport`** (`FolderIngestor.swift`): `discovered: Int`, plus an import count
  measured as the store's actual size delta (not decode count), so a duplicate that decodes
  fine but adds nothing to the library is correctly reported as zero growth (FR-005/FR-015).
- **`RemoteSyncReport`** (`RemoteActivitySync.swift`): `discovered: Int`, `downloaded: Int`
  (written into the watched folder, not yet necessarily ingested), plus failures — mirrors
  `FolderIngestReport`'s discovered/landed split, one layer up the pipeline (Polar → folder →
  library are two separate hops, each independently reported).

## Import errors → `ActivitySourceError`

`ActivitySource.swift`, four cases mapped to FR-013's "not configured / not authorized /
temporarily unavailable" distinction: `.notConfigured(reason:)`, `.notAvailable(reason:)`
(COROS), `.unauthorized`, `.candidateNotFound(sourceId:)` (stale candidate from a superseded
listing), `.underlying(String)` (catch-all, e.g. FR-007's iCloud-timeout message).
`ImportSheet.describe(_:)` renders each case to the user-facing string shown in `.failureView`.

## Share Extension presenter → `ShareImportViewModel`

`Sources/ShareExtension/Shared/ShareImportViewModel.swift` — already the SwiftUI-free type
Principle I/II require (see research.md §1); this feature adds test coverage for it, not a new
type.

| Member | Type | Notes |
|---|---|---|
| `Phase` | `enum` | `.loading`, `.ready`, `.notConfigured` (FR-010), `.unreadable(String)` (FR-010's "reports that plainly" edge case). |
| `fileName` | `String`, mutable | Bound to `ShareEditView`'s `TextField`; user-editable proposed name (FR-009). |
| `phase` | `Phase`, read-only externally | Drives which UI `ShareEditView` shows. |
| `isSaving` / `saveError` | `Bool` / `String?` | Save-in-flight and save-failure state. |
| `canSave` | computed `Bool` | `phase == .ready && !isSaving && !trimmedFileName.isEmpty`. |
| `start() async` | — | Reads the shared attachment, proposes a name via `defaultActivityFileName`, sets `phase`. |
| `save()` | — | Writes via `writeSharedActivity` into the shared `FolderBookmark`, completes the extension request. |
| `cancel()` | — | Cancels the extension request. |

**Test fixture shape** (Phase 2, `ShareImportViewModelTests.swift`): construct an
`NSExtensionItem` with one `NSItemProvider(contentsOf: tempFileURL, ...)` attachment referencing
a real or synthetic `.fit` file on disk (mirrors `ShareImportTests`' existing fixture data), wrap
it in a minimal `NSExtensionContext` subclass or pass `nil` where the class already tolerates it,
and inject fixture `FolderBookmark`/`DeviceNicknameStore` instances (as `WatchedFolderSourceTests`
already does) so App-Group `UserDefaults` state never leaks between tests. No production code
changes — only `project.yml` (add `Sources/ShareExtension/Shared` to `FitViewTests.sources`) and
the new test file.

## State transitions

**`ImportSheet.Phase`**: `.pickingSource → .working → .confirmingImport → .working →
{.summary | .failure}`. `.failure` can also be reached directly from `.pickingSource`/`.working`
(authorization or listing failure) or `.working` post-confirm never fails outright — a
zero-success import still resolves to `.summary` with `fileCount == 0` and populated `failures`.

**`ShareImportViewModel.Phase`**: `.loading → {.ready | .notConfigured | .unreadable}`. `.ready`
is the only phase `save()` acts from; all others are terminal for that share attempt.

**`ImportCoordinator` generation counter**: incremented on every `startImport`/`cancelAll` call;
a `startImport` whose generation is stale by the time its `Task` completes returns `nil` instead
of its `ImportResult`, which is how FR-016 (superseding discards the prior result) is enforced
independent of which caller (`ImportSheet`, `FolderIngestor`'s scan, `RemoteActivitySync`'s sync)
triggered it.
