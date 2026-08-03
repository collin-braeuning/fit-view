import Foundation

/// Wire-format types and pure mapping for Polar's AccessLink API (v3).
///
/// Kept separate from the actual HTTP calls (`URLSession`, `ASWebAuthenticationSession`,
/// Keychain — all at the app layer, `Sources/FitView/Import/Polar/`) so the
/// JSON decoding and the `ImportCandidate` synthesis can be unit-tested here
/// against captured/handwritten fixtures without a network connection. This
/// mirrors the rest of the package: `Foundation`'s `Codable`/`JSONDecoder` are
/// fine, `URLSession` is not.
///
/// Field names mirror Polar's public AccessLink v3 documentation, which uses
/// hyphenated JSON keys throughout (`upload-time`, `start-time`, ...).

/// `POST https://polarremote.com/v2/oauth2/token`'s response body.
public struct PolarTokenResponse: Sendable, Equatable, Codable {
    public var accessToken: String
    public var tokenType: String
    /// Polar's internal numeric user id. Required by `POST /v3/users`
    /// (registration) and implicitly identifies the account for every
    /// subsequent data call once registered.
    public var xUserId: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case xUserId = "x_user_id"
    }

    public init(accessToken: String, tokenType: String, xUserId: Int) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.xUserId = xUserId
    }
}

/// One row of `GET /v3/exercises`'s `data` array.
public struct PolarExercise: Sendable, Equatable, Codable {
    public var id: String
    /// ISO-8601 local wall-clock time — see `startTimeUtcOffsetMinutes`.
    /// Optional because at least one real exercise has been observed missing
    /// this field entirely, live — confirmed against a real account, since
    /// there's no sandbox to check this against ahead of time (see this
    /// file's top-level doc comment). Treated exactly like an unparseable
    /// timestamp: `polarImportCandidate` falls back to `unknown-date`.
    public var startTime: String?
    /// Minutes east of UTC at the recording location. Polar's `start-time`
    /// carries no timezone suffix of its own; this is the only way to
    /// recover the true instant.
    public var startTimeUtcOffsetMinutes: Int?
    public var sport: String?
    public var device: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start-time"
        case startTimeUtcOffsetMinutes = "start-time-utc-offset"
        case sport
        case device
    }

    public init(
        id: String,
        startTime: String? = nil,
        startTimeUtcOffsetMinutes: Int? = nil,
        sport: String? = nil,
        device: String? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.startTimeUtcOffsetMinutes = startTimeUtcOffsetMinutes
        self.sport = sport
        self.device = device
    }
}

/// `GET /v3/exercises`'s top-level envelope.
///
/// The response body itself is a bare JSON array, not the `{"data": [...]}`
/// wrapper the naming here implies — confirmed against a live account, since
/// there's no sandbox to check this against ahead of time (see this file's
/// top-level doc comment on why the wire shape can only be verified live).
/// `data` is kept as the property name regardless, since every call site
/// reads `response.data` and a bare-array response decodes into it the same
/// way.
public struct PolarExerciseListResponse: Sendable, Equatable, Codable {
    public var data: [PolarExercise]

    public init(data: [PolarExercise]) {
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        data = try container.decode([PolarExercise].self)
    }
}

/// Parses Polar's local-time-plus-offset pair into the true UTC instant.
///
/// `start-time` (e.g. `"2026-07-26T17:06:52"`) is wall-clock time at the
/// recording location with no timezone info of its own — parsing it with a
/// UTC calendar first (rather than the device's local timezone, which would
/// silently vary by where *this app* happens to be running) gives back the
/// same wall-clock components, and only then does subtracting the offset
/// produce the real instant. Using the system's local timezone here instead
/// would reintroduce exactly the class of bug `overview.md` §6 documents for
/// filename dates: a value that's correct only by accident of where the
/// device is.
private let polarLocalTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter
}()

func polarStartTime(localTimeString: String, utcOffsetMinutes: Int?) -> Date? {
    guard let wallClockAsUTC = polarLocalTimeFormatter.date(from: localTimeString) else { return nil }
    let offsetSeconds = TimeInterval((utcOffsetMinutes ?? 0) * 60)
    return wallClockAsUTC.addingTimeInterval(-offsetSeconds)
}

/// "2026-07-26" for a UTC instant — the filename-style date stamp
/// `parseActivityFileName` expects, built the same way `FilenameParsing.swift`
/// validates a date (a UTC-timezoned `Calendar`) rather than a fresh, possibly
/// locale-sensitive formatter.
func utcDateStamp(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
}

/// Synthesises a batch-groupable name for a Polar exercise.
///
/// `groupActivityFiles` only knows how to key on `YYYY-MM-DD_device_activity`
/// names, and Polar gives real metadata instead of a filename — this is the
/// deliberate stopgap `overview.md`'s Phase 1 plan describes: build a name
/// that parses the same way a real file's would, so no change to the
/// grouping code is needed yet. Phase 2 replaces this with grouping directly
/// over descriptors.
public func polarImportCandidate(from exercise: PolarExercise) -> ImportCandidate {
    let startTime = exercise.startTime.flatMap {
        polarStartTime(localTimeString: $0, utcOffsetMinutes: exercise.startTimeUtcOffsetMinutes)
    }
    let dateStamp = startTime.map(utcDateStamp) ?? "unknown-date"
    // Device names ("Polar Vantage V2") and sports ("RUNNING") come back with
    // spaces/casing that would corrupt the underscore-delimited name (the
    // filename parser stops a device at the first `_`, not at every space,
    // so a raw space is harmless, but collapsing it keeps the synthesized
    // name closer to what a real exported filename looks like).
    let deviceSlug = (exercise.device ?? "polar").replacingOccurrences(of: " ", with: "")
    let sportSlug = (exercise.sport ?? "activity").lowercased()

    return ImportCandidate(
        sourceId: exercise.id,
        suggestedName: "\(dateStamp)_\(deviceSlug)_\(sportSlug)",
        startTime: startTime,
        deviceLabel: exercise.device,
        sport: exercise.sport
    )
}
