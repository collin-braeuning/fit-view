# Contract: Diagnostic log ring buffer & export

Internal contract — no network surface. This documents the capped-log behavior FR-012/
FR-013 require and the pure helper this feature introduces to make it testable.

```swift
// Packages/FitViewCore/Sources/FitViewCore/DiagnosticLogRingBuffer.swift
public enum DiagnosticLogRingBuffer {
    /// Appends `newEntry` to `existing`, evicting the oldest entries first if the
    /// result would exceed `cap`. Pure — no I/O, no shared state.
    public static func appending(
        _ newEntry: String,
        to existing: [String],
        cap: Int
    ) -> [String]
}
```

## Preconditions / postconditions

**`appending(_:to:cap:)`**
- Precondition: `cap >= 0`.
- Postcondition: returns `existing + [newEntry]`, trimmed from the front if
  `count > cap`, so the result never exceeds `cap` entries and always contains the
  most-recently-appended entries (FIFO eviction of the oldest — FR-013).
- MUST be order-preserving for retained entries (no reordering beyond dropping the
  oldest).

## Consumer contract: `AppModel`

| Obligation | Rationale |
|---|---|
| MUST apply the same cap (1000) to both the in-memory `debugLog` array and the on-disk `debug.log` file — a single source of truth for "how many entries," not two independently-tuned caps. | Prevents the file and the in-memory view from drifting to different lengths, which would make "what's in the exported file" surprising relative to what Settings showed before export. |
| MUST NOT expose a manual "Clear Log" action once the cap is in place. | Spec clarification: "No manual 'Clear Log' control is needed since growth is bounded automatically." |
| MUST expose an export action that hands the *file* (not the in-memory array re-serialized) to the system share sheet. | The file is already the durable, complete record; re-serializing the in-memory copy risks a subtle divergence if the two ever aren't kept in lockstep. |

## Consumer contract: `SettingsView`

| Obligation |
|---|
| MUST replace the scrollable in-app log `Text` block with a single "Export Log…" control (or equivalent) that presents the system share sheet over the log file. |
| MUST still show *some* lightweight in-Settings indication of log state (e.g. "no entries yet" vs. a non-empty state) so a user isn't exporting blind — exact presentation is an implementation-phase UI decision, not fixed by this contract. |

## Out of scope for this contract

Log *content* (what gets logged, from which call sites) is unchanged by this feature —
only its cap and export path are new. Extending logging to cover the watched-folder scan
path (currently uncovered per research.md) is a separate, unrequested enhancement, not
required by FR-012/FR-013.
