/// Pure cap/trim logic for the diagnostic log, shared between `AppModel`'s
/// in-memory `debugLog` array and the on-disk `debug.log` file so both stay
/// bounded by the same rule instead of two independently-tuned caps.
public enum DiagnosticLogRingBuffer {
    /// Appends `newEntry` to `existing`, evicting the oldest entries first if
    /// the result would exceed `cap`. Order-preserving for retained entries —
    /// only the oldest are ever dropped, never reordered.
    public static func appending(
        _ newEntry: String,
        to existing: [String],
        cap: Int
    ) -> [String] {
        var result = existing
        result.append(newEntry)
        if result.count > cap {
            result.removeFirst(result.count - cap)
        }
        return result
    }

    /// Parses a persisted log file's contents into entries, one per line —
    /// the inverse of `serializing(_:)`. Empty lines are dropped so the
    /// trailing newline `serializing(_:)` always writes doesn't produce a
    /// spurious empty final entry.
    public static func parsing(_ fileContents: String) -> [String] {
        fileContents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Serializes entries back to the newline-delimited text format
    /// `debug.log` is persisted in — the inverse of `parsing(_:)`.
    public static func serializing(_ entries: [String]) -> String {
        entries.joined(separator: "\n") + "\n"
    }
}
