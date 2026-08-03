import Foundation

/// Support for the share extension: turning whatever name the source app
/// handed off into a sensible editable default, and writing the shared
/// bytes into the user's watched folder without clobbering an existing file.

/// The default name (no extension) to prefill the share extension's edit
/// screen with, following the `YYYY-MM-DD_device_activity` convention
/// documented in `overview.md` §6.
///
/// If the incoming filename already matches that convention (as most watch
/// exports do), its date/device/activity are reused verbatim — this
/// preserves the real recorded date rather than overwriting it with today's,
/// which matters because the app's date-based grouping treats that date as
/// the activity's own. Only a name that doesn't parse falls back to today's
/// date with literal `device`/`activity` placeholders for the user to edit.
public func defaultActivityFileName(
    forIncomingFileName incomingFileName: String?,
    today: Date = Date(),
    calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
) -> String {
    if let incomingFileName, let parsed = parseActivityFileName(incomingFileName) {
        return "\(parsed.date)_\(parsed.device)_\(parsed.activity)"
    }

    let components = calendar.dateComponents([.year, .month, .day], from: today)
    let date = String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    return "\(date)_device_activity"
}

/// The default name (no extension) to prefill the share extension's edit
/// screen with, preferring the shared `.fit` file's own recorded
/// date/device/activity (`extractSharedActivityMetadata`) over whatever name
/// the source app happened to hand off — the file's own content is the
/// truest source available, when it decodes at all. Falls back to
/// `defaultActivityFileName(forIncomingFileName:)` for a file that doesn't
/// decode (not a `.fit` file, or corrupted in transit).
public func defaultActivityFileName(
    forSharedData data: Data,
    incomingFileName: String?,
    today: Date = Date()
) -> String {
    if let metadata = extractSharedActivityMetadata(from: data) {
        let device = metadata.device ?? "device"
        return "\(metadata.date)_\(device)_\(metadata.activity)"
    }
    return defaultActivityFileName(forIncomingFileName: incomingFileName, today: today)
}

/// Writes `data` into the folder `bookmark` points at, as `<desiredBaseName>.fit`
/// — or, if that name is already taken, the first of `<desiredBaseName> 2.fit`,
/// `<desiredBaseName> 3.fit`, … that isn't (Finder's own convention for a
/// same-name copy). Returns the URL actually written.
///
/// Collision avoidance is needed here — and nowhere else in this codebase —
/// because this is the only code path that writes a human-chosen filename
/// into a folder the user manages directly; every other writer
/// (`FileSystemLibraryStore`, `FolderSyncStore`) is content-addressed and
/// never collides by construction.
public func writeSharedActivity(
    data: Data,
    desiredBaseName: String,
    into bookmark: FolderBookmark
) throws -> URL {
    try bookmark.withAccess { folderURL in
        let safeName = sanitizedForFilesystem(desiredBaseName)
        let destination = availableFileURL(forBaseName: safeName, extension: "fit", in: folderURL)
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

/// Replaces "/" — the one character a path component can't contain on
/// either platform, and the one that would otherwise let a user-typed name
/// like "../../elsewhere" escape the watched folder via
/// `appendingPathComponent`. Anything else is left alone; users may
/// legitimately want punctuation in an activity name.
private func sanitizedForFilesystem(_ name: String) -> String {
    name.replacingOccurrences(of: "/", with: "-")
}

/// The first `<directory>/<baseName>.<extension>`, `<baseName> 2.<extension>`,
/// … that doesn't already exist.
func availableFileURL(forBaseName baseName: String, extension fileExtension: String, in directory: URL) -> URL {
    var attempt = 1
    while true {
        let name = attempt == 1 ? baseName : "\(baseName) \(attempt)"
        let candidate = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        attempt += 1
    }
}
