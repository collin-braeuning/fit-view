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
}
