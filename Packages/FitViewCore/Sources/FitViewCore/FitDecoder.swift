import FitFileParser
import Foundation

/// Errors surfaced when turning raw `.fit` bytes into ``ParsedFitFile``/``LoadedFile``.
public enum FitDecodingError: Error, Sendable, Equatable {
    case unreadable(underlying: String)
    case noActivitySessions
}

/// Decode raw `.fit` bytes into the app's domain model.
///
/// Backed by `FitFileParser`, which wraps Garmin's official C SDK. The previous
/// pure-Swift `FITSwiftSDK` decoded the same 16-file corpus in 5.9s (Debug) /
/// 671ms (Release) across a task group; this does it in 307ms / 98ms — the
/// difference being that the hot loop is optimised C regardless of the build
/// configuration Swift code is compiled with, which is what made a Debug build
/// (Xcode's default) an order of magnitude worse rather than the usual 2-3x.
///
/// `FitFileParser` hands back a flat, file-ordered message list rather than the
/// cascade nesting the web's `fit-file-parser` provided, so the `session` ->
/// `lap` -> `record` hierarchy is rebuilt here by timestamp window (see
/// ``distribute(records:into:)``).
public func decodeFitFile(data: Data) throws -> ParsedFitFile {
    // `.fast` explicitly, not just by default: `.generic` crashes outright
    // ("Not enough bits to represent the passed value") on this app's own
    // sample corpus, and nothing here needs the extra field coverage it buys.
    let fit = FitFile(data: data, parsingType: .fast)

    // A well-formed FIT file always carries at least a `file_id`. An empty
    // message list means the C SDK rejected the bytes outright — `FitFile`'s
    // initialiser isn't failable, so this is the only signal it gives.
    guard !fit.messages.isEmpty else {
        throw FitDecodingError.unreadable(underlying: "no FIT messages could be read from \(data.count) bytes")
    }

    var activities = messages(in: fit, ofType: "session")
        .map { makeFitActivity(from: $0.interpretedFields()) }
        .sorted { $0.startTime < $1.startTime }
    guard !activities.isEmpty else {
        throw FitDecodingError.noActivitySessions
    }

    var laps = messages(in: fit, ofType: "lap")
        .map { makeFitLap(from: $0.interpretedFields()) }
        .sorted { $0.startTime < $1.startTime }
    // Records stay in file order, which is chronological — both `distribute`
    // passes below are merge-joins that depend on it.
    let records = messages(in: fit, ofType: "record")
        .map { makeFitRecord(from: $0.interpretedFields()) }

    // Some devices write records without ever emitting a `lap`. `FitActivity`
    // stores its samples only inside laps, so without a stand-in every record
    // in such a file would be silently dropped.
    if laps.isEmpty, !records.isEmpty {
        laps = [syntheticLap(spanning: records)]
    }

    activities = distribute(laps: distribute(records: records, into: laps), into: activities)

    let userProfile = messages(in: fit, ofType: "user_profile")
        .first
        .map { makeFitUserProfile(from: $0.interpretedFields()) }

    return ParsedFitFile(userProfile: userProfile ?? FitUserProfile(), activities: activities)
}

/// Parse a `.fit` file's bytes into the app's usable shape.
///
/// A file can hold several sessions (e.g. a multisport workout); this app compares
/// single activities, so only the first is used.
public func loadFitFile(data: Data, fileName: String) throws -> LoadedFile {
    let parsed = try decodeFitFile(data: data)
    return LoadedFile(fileName: stripFileExtension(fileName), activity: parsed.activities[0])
}

// --- Message lookup -------------------------------------------------------

/// Every message of a named type, in file order. Returns empty rather than
/// trapping if the profile doesn't know the name — a missing message type is
/// "this file has none of those", not a programmer error worth crashing over.
private func messages(in fit: FitFile, ofType description: String) -> [FitMessage] {
    guard let type = FitFile.messageType(forDescription: description) else { return [] }
    return fit.messages(forMessageType: type)
}

// --- Hierarchy reconstruction ---------------------------------------------

/// Buckets chronological `records` into `laps` by timestamp window.
///
/// Replaces the previous arrival-order reconstruction, which assumed records
/// were interleaved between `lap` messages. These devices don't write that way
/// — every `record` arrives before the first `lap` — so the first lap used to
/// swallow the entire file and every later lap came back empty.
///
/// A merge-join rather than a per-record window search, so it stays O(records)
/// and, more importantly, is *lossless*: a record falling in a gap between two
/// laps (or before the first, or after the last) attaches to the nearest
/// preceding lap instead of being dropped. `FitActivity.records` therefore
/// still returns every sample, in order, exactly as before.
private func distribute(records: [FitRecord], into laps: [FitLap]) -> [FitLap] {
    guard !laps.isEmpty else { return laps }
    var laps = laps
    var index = 0
    for record in records {
        while index < laps.count - 1, record.timestamp > laps[index].endTime {
            index += 1
        }
        laps[index].records.append(record)
    }
    return laps
}

/// Buckets chronological `laps` into `activities` by the same merge-join, so a
/// multisport file's laps land in the session they belong to.
private func distribute(laps: [FitLap], into activities: [FitActivity]) -> [FitActivity] {
    guard !activities.isEmpty else { return activities }
    var activities = activities
    var index = 0
    for lap in laps {
        while index < activities.count - 1, lap.startTime > activities[index].endTime {
            index += 1
        }
        activities[index].laps.append(lap)
    }
    return activities
}

/// A stand-in lap spanning every record, for files that emit no `lap` message.
private func syntheticLap(spanning records: [FitRecord]) -> FitLap {
    FitLap(
        startTime: records.first?.timestamp ?? epoch,
        endTime: records.last?.timestamp ?? epoch,
        elapsedSeconds: 0, distance: 0,
        avgHeartRate: 0, maxHeartRate: 0, minHeartRate: 0,
        avgSpeed: 0, maxSpeed: 0, avgCadence: 0, maxCadence: 0,
        totalAscent: 0, totalDescent: 0, calories: 0
    )
}

// --- Field access ---------------------------------------------------------

/// `FitFileParser` exposes every field as a string-keyed `FitFieldValue`
/// rather than the generated typed accessors `FITSwiftSDK` had, so these
/// keep the unit-and-optionality handling in one place instead of at every
/// call site below.
private extension [FitFieldKey: FitFieldValue] {
    /// The numeric value, whether or not the profile attached a unit to it.
    func number(_ key: FitFieldKey) -> Double? {
        guard let field = self[key] else { return nil }
        return field.valueUnit?.value ?? field.value
    }

    func int(_ key: FitFieldKey) -> Int? {
        number(key).map(Int.init)
    }

    /// The first key that's present — for fields the profile names differently
    /// per sport (`avg_running_cadence` on a run, `avg_cadence` otherwise).
    func int(_ keys: FitFieldKey...) -> Int? {
        keys.lazy.compactMap { int($0) }.first
    }

    func date(_ key: FitFieldKey) -> Date? { self[key]?.time }

    func name(_ key: FitFieldKey) -> String? { self[key]?.name }
}

// --- Message -> domain model ----------------------------------------------

private let metersPerKilometer = 1000.0
private let kmhPerMetersPerSecond = 3.6
private let epoch = Date(timeIntervalSince1970: 0)

private func makeFitRecord(from fields: [FitFieldKey: FitFieldValue]) -> FitRecord {
    // Already degrees: `FitFileParser` folds `position_lat`/`position_long`
    // into one `position` coordinate and converts out of semicircles itself.
    let position = fields["position"]?.coordinate
    return FitRecord(
        timestamp: fields.date("timestamp") ?? epoch,
        heartRate: fields.int("heart_rate"),
        speed: fields.number("speed").map { $0 * kmhPerMetersPerSecond },
        cadence: fields.int("cadence"),
        altitude: fields.number("altitude"),
        power: fields.int("power"),
        distance: fields.number("distance").map { $0 / metersPerKilometer },
        positionLat: position?.latitude,
        positionLong: position?.longitude
    )
}

private func makeFitLap(from fields: [FitFieldKey: FitFieldValue]) -> FitLap {
    FitLap(
        startTime: fields.date("start_time") ?? epoch,
        endTime: fields.date("timestamp") ?? epoch,
        elapsedSeconds: fields.number("total_elapsed_time") ?? 0,
        distance: (fields.number("total_distance") ?? 0) / metersPerKilometer,
        avgHeartRate: fields.int("avg_heart_rate") ?? 0,
        maxHeartRate: fields.int("max_heart_rate") ?? 0,
        minHeartRate: fields.int("min_heart_rate") ?? 0,
        avgSpeed: (fields.number("avg_speed") ?? 0) * kmhPerMetersPerSecond,
        maxSpeed: (fields.number("max_speed") ?? 0) * kmhPerMetersPerSecond,
        avgCadence: fields.int("avg_running_cadence", "avg_cadence") ?? 0,
        maxCadence: fields.int("max_running_cadence", "max_cadence") ?? 0,
        totalAscent: fields.number("total_ascent") ?? 0,
        totalDescent: fields.number("total_descent") ?? 0,
        avgPower: fields.int("avg_power"),
        maxPower: fields.int("max_power"),
        calories: fields.number("total_calories") ?? 0
    )
}

private func makeFitActivity(from fields: [FitFieldKey: FitFieldValue]) -> FitActivity {
    FitActivity(
        sport: fields.name("sport") ?? "unknown",
        subSport: fields.name("sub_sport") ?? "unknown",
        startTime: fields.date("start_time") ?? epoch,
        endTime: fields.date("timestamp") ?? epoch,
        avgHeartRate: fields.int("avg_heart_rate") ?? 0,
        maxHeartRate: fields.int("max_heart_rate") ?? 0
    )
}

private func makeFitUserProfile(from fields: [FitFieldKey: FitFieldValue]) -> FitUserProfile {
    FitUserProfile(
        friendlyName: fields.name("friendly_name"),
        weight: fields.number("weight"),
        gender: fields.name("gender"),
        restingHeartRate: fields.int("resting_heart_rate")
    )
}
