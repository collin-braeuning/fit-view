import Foundation

/// A batch/session date ("2026-07-26") names a calendar day parsed from a
/// filename, not an instant in time. Formatting it in the system's local time
/// zone can render the day *before* west of UTC, so this pins the format to
/// UTC to keep the displayed date equal to the input regardless of where the
/// device happens to be.

/// "2026-07-26" -> "Jul 26, 2026". Returns the raw input when unparseable.
func formatSessionDate(_ isoDate: String) -> String {
    guard let date = parseISODate(isoDate) else { return isoDate }
    return date.formatted(
        Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!)
            .month(.abbreviated)
            .day()
            .year()
    )
}

private func parseISODate(_ isoDate: String) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = isoDate.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
}
