import Foundation

/// One sample from a device, typically recorded once per second.
public struct FitRecord: Sendable, Equatable, Codable {
    public var timestamp: Date
    /// bpm. A reading of 0 is a sensor dropout, not a measurement — callers
    /// that need "usable reading" semantics must check for that themselves;
    /// this type only distinguishes present (however implausible) from absent.
    public var heartRate: Int?
    /// km/h.
    public var speed: Double?
    public var cadence: Int?
    public var altitude: Double?
    public var power: Int?
    /// km.
    public var distance: Double?
    public var positionLat: Double?
    public var positionLong: Double?

    public init(
        timestamp: Date,
        heartRate: Int? = nil,
        speed: Double? = nil,
        cadence: Int? = nil,
        altitude: Double? = nil,
        power: Int? = nil,
        distance: Double? = nil,
        positionLat: Double? = nil,
        positionLong: Double? = nil
    ) {
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.speed = speed
        self.cadence = cadence
        self.altitude = altitude
        self.power = power
        self.distance = distance
        self.positionLat = positionLat
        self.positionLong = positionLong
    }
}

/// A lap, with the device's own aggregates plus the samples it contains.
public struct FitLap: Sendable, Equatable, Codable {
    public var startTime: Date
    public var endTime: Date
    public var elapsedSeconds: TimeInterval
    /// km.
    public var distance: Double
    public var avgHeartRate: Int
    public var maxHeartRate: Int
    public var minHeartRate: Int
    /// km/h.
    public var avgSpeed: Double
    /// km/h.
    public var maxSpeed: Double
    public var avgCadence: Int
    public var maxCadence: Int
    public var totalAscent: Double
    public var totalDescent: Double
    public var avgPower: Int?
    public var maxPower: Int?
    public var calories: Double
    public var records: [FitRecord]

    public init(
        startTime: Date,
        endTime: Date,
        elapsedSeconds: TimeInterval,
        distance: Double,
        avgHeartRate: Int,
        maxHeartRate: Int,
        minHeartRate: Int,
        avgSpeed: Double,
        maxSpeed: Double,
        avgCadence: Int,
        maxCadence: Int,
        totalAscent: Double,
        totalDescent: Double,
        avgPower: Int? = nil,
        maxPower: Int? = nil,
        calories: Double,
        records: [FitRecord] = []
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.elapsedSeconds = elapsedSeconds
        self.distance = distance
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.minHeartRate = minHeartRate
        self.avgSpeed = avgSpeed
        self.maxSpeed = maxSpeed
        self.avgCadence = avgCadence
        self.maxCadence = maxCadence
        self.totalAscent = totalAscent
        self.totalDescent = totalDescent
        self.avgPower = avgPower
        self.maxPower = maxPower
        self.calories = calories
        self.records = records
    }
}

/// A single recorded workout (one "session" in FIT terminology).
public struct FitActivity: Sendable, Equatable, Codable {
    public var sport: String
    public var subSport: String
    public var startTime: Date
    public var endTime: Date
    public var avgHeartRate: Int
    public var maxHeartRate: Int
    public var laps: [FitLap]

    /// Every sample across every lap, flattened and in order.
    ///
    /// Cascade-mode FIT decoding nests samples inside laps, so this is always
    /// `laps.flatMap { $0.records }` rather than independently stored — there is
    /// exactly one source of truth for a session's samples.
    public var records: [FitRecord] {
        laps.flatMap { $0.records }
    }

    public var totalRecords: Int {
        records.count
    }

    public init(
        sport: String,
        subSport: String,
        startTime: Date,
        endTime: Date,
        avgHeartRate: Int,
        maxHeartRate: Int,
        laps: [FitLap] = []
    ) {
        self.sport = sport
        self.subSport = subSport
        self.startTime = startTime
        self.endTime = endTime
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.laps = laps
    }
}

public struct FitUserProfile: Sendable, Equatable, Codable {
    public var friendlyName: String?
    public var weight: Double?
    public var gender: String?
    public var restingHeartRate: Int?

    public init(
        friendlyName: String? = nil,
        weight: Double? = nil,
        gender: String? = nil,
        restingHeartRate: Int? = nil
    ) {
        self.friendlyName = friendlyName
        self.weight = weight
        self.gender = gender
        self.restingHeartRate = restingHeartRate
    }
}

/// Everything extracted from one `.fit` file.
public struct ParsedFitFile: Sendable, Equatable, Codable {
    public var userProfile: FitUserProfile
    public var activities: [FitActivity]

    public init(userProfile: FitUserProfile = FitUserProfile(), activities: [FitActivity]) {
        self.userProfile = userProfile
        self.activities = activities
    }
}

/// An activity paired with the name of the file it came from.
public struct LoadedFile: Sendable, Equatable, Codable {
    /// File name without its extension — used as the series label on charts
    /// and as the key batch mode groups by. `.fit` and `.FIT` collide by
    /// design because of this stripping.
    public var fileName: String
    public var activity: FitActivity

    public init(fileName: String, activity: FitActivity) {
        self.fileName = fileName
        self.activity = activity
    }
}
