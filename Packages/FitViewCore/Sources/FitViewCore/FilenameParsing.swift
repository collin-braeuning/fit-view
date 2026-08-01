import Foundation

/// Strip a trailing file extension: "2026-07-30_pace4_run.fit" -> "2026-07-30_pace4_run".
public func stripFileExtension(_ fileName: String) -> String {
    fileName.replacing(/\.[^\/.]+$/, with: "")
}

/// What a sample filename tells us about its recording, straight from the
/// name — no session grouping or policy decisions here (that's `groupActivityFiles`).
public struct ActivityFileName: Sendable, Equatable {
    /// "2026-07-30", exactly as written.
    public var date: String
    /// "polarSense" — original casing, for display.
    public var device: String
    /// Lower-cased, grouping only.
    public var deviceKey: String
    /// May contain underscores ("long_run").
    public var activity: String
    public var activityKey: String
}

/// True when `y-m-d` is a real calendar date, catching things like 2026-13-40.
private func isValidDate(year: Int, month: Int, day: Int) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    guard let date = calendar.date(from: components) else { return false }
    let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
    return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
}

/// Parse a sample filename into its date, device and activity, or nil if it doesn't match.
///
/// `[-_ ]` handles "2026-07-26-pace4_run.fit", where the device is separated
/// from the date by a hyphen instead of the usual underscore. `[^_]+` stops the
/// device at the first `_` (tolerating hyphens inside a device name), and the
/// trailing `(?:_(.+))?` is optional and greedy so a multi-word activity like
/// "long_run" survives intact and a missing activity still parses.
///
/// Documented ambiguity: the device is always the first `_`-delimited token,
/// so "2026-07-26_my_device_run" yields device "my" — unresolvable from the
/// name alone, which is why the UI renders the parse result rather than hiding
/// it.
public func parseActivityFileName(_ fileName: String) -> ActivityFileName? {
    let trimmed = stripFileExtension(fileName).trimmingCharacters(in: .whitespaces)
    guard let match = trimmed.wholeMatch(of: /^(\d{4}-\d{2}-\d{2})[-_ ]([^_]+)(?:_(.+))?$/) else { return nil }

    let (_, date, device, activityCapture) = match.output
    let activity = activityCapture.map(String.init) ?? "activity"

    let dateParts = date.split(separator: "-").compactMap { Int($0) }
    guard dateParts.count == 3, isValidDate(year: dateParts[0], month: dateParts[1], day: dateParts[2]) else {
        return nil
    }

    return ActivityFileName(
        date: String(date),
        device: String(device),
        deviceKey: device.lowercased(),
        activity: activity,
        activityKey: activity.lowercased()
    )
}
