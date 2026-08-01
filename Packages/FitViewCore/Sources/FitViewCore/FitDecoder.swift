import FITSwiftSDK
import Foundation

/// Errors surfaced when turning raw `.fit` bytes into ``ParsedFitFile``/``LoadedFile``.
public enum FitDecodingError: Error, Sendable, Equatable {
    case unreadable(underlying: String)
    case noActivitySessions
}

/// Decode raw `.fit` bytes into the app's domain model.
///
/// FIT files stream flat messages in chronological order; this reconstructs the
/// cascade-mode nesting `fit-file-parser` used to provide on the web — every
/// `record` since the previous `lap` belongs to that lap, and every `lap` since
/// the previous `session` belongs to that session.
public func decodeFitFile(data: Data) throws -> ParsedFitFile {
    let stream = FITSwiftSDK.InputStream(data: data)
    let decoder = FITSwiftSDK.Decoder(stream: stream)
    let collector = FitMesgCollector()
    let broadcaster = MesgBroadcaster()
    broadcaster.addListener(collector as RecordMesgListener)
    broadcaster.addListener(collector as LapMesgListener)
    broadcaster.addListener(collector as SessionMesgListener)
    broadcaster.addListener(collector as UserProfileMesgListener)
    decoder.addMesgListener(broadcaster)

    do {
        try decoder.read()
    } catch {
        throw FitDecodingError.unreadable(underlying: String(describing: error))
    }

    guard !collector.activities.isEmpty else {
        throw FitDecodingError.noActivitySessions
    }

    return ParsedFitFile(userProfile: collector.userProfile ?? FitUserProfile(), activities: collector.activities)
}

/// Parse a `.fit` file's bytes into the app's usable shape.
///
/// A file can hold several sessions (e.g. a multisport workout); this app compares
/// single activities, so only the first is used.
public func loadFitFile(data: Data, fileName: String) throws -> LoadedFile {
    let parsed = try decodeFitFile(data: data)
    return LoadedFile(fileName: stripFileExtension(fileName), activity: parsed.activities[0])
}

/// Buffers `record`/`lap` messages as they stream in and folds them into their
/// enclosing `lap`/`session` the moment the enclosing message arrives.
private final class FitMesgCollector: RecordMesgListener, LapMesgListener, SessionMesgListener, UserProfileMesgListener {
    private(set) var activities: [FitActivity] = []
    private(set) var userProfile: FitUserProfile?

    private var pendingRecords: [FitRecord] = []
    private var pendingLaps: [FitLap] = []

    func onMesg(_ mesg: RecordMesg) throws {
        pendingRecords.append(makeFitRecord(from: mesg))
    }

    func onMesg(_ mesg: LapMesg) throws {
        var lap = makeFitLap(from: mesg)
        lap.records = pendingRecords
        pendingRecords = []
        pendingLaps.append(lap)
    }

    func onMesg(_ mesg: SessionMesg) throws {
        var activity = makeFitActivity(from: mesg)
        activity.laps = pendingLaps
        pendingLaps = []
        activities.append(activity)
    }

    func onMesg(_ mesg: UserProfileMesg) throws {
        userProfile = makeFitUserProfile(from: mesg)
    }
}

// --- SDK message -> domain model -----------------------------------------

private let metersPerKilometer = 1000.0
private let kmhPerMetersPerSecond = 3.6
private let epoch = Date(timeIntervalSince1970: 0)

private func semicirclesToDegrees(_ semicircles: Int32) -> Double {
    Double(semicircles) * (180.0 / 2_147_483_648.0)
}

private func sportName(_ sport: Sport?) -> String {
    sport.map { String(describing: $0) } ?? "unknown"
}

private func subSportName(_ subSport: SubSport?) -> String {
    subSport.map { String(describing: $0) } ?? "unknown"
}

private func makeFitRecord(from mesg: RecordMesg) -> FitRecord {
    FitRecord(
        timestamp: mesg.getTimestamp()?.date ?? epoch,
        heartRate: mesg.getHeartRate().map(Int.init),
        speed: mesg.getSpeed().map { $0 * kmhPerMetersPerSecond },
        cadence: mesg.getCadence().map(Int.init),
        altitude: mesg.getAltitude(),
        power: mesg.getPower().map(Int.init),
        distance: mesg.getDistance().map { $0 / metersPerKilometer },
        positionLat: mesg.getPositionLat().map(semicirclesToDegrees),
        positionLong: mesg.getPositionLong().map(semicirclesToDegrees)
    )
}

private func makeFitLap(from mesg: LapMesg) -> FitLap {
    FitLap(
        startTime: mesg.getStartTime()?.date ?? epoch,
        endTime: mesg.getTimestamp()?.date ?? epoch,
        elapsedSeconds: mesg.getTotalElapsedTime() ?? 0,
        distance: (mesg.getTotalDistance() ?? 0) / metersPerKilometer,
        avgHeartRate: Int(mesg.getAvgHeartRate() ?? 0),
        maxHeartRate: Int(mesg.getMaxHeartRate() ?? 0),
        minHeartRate: Int(mesg.getMinHeartRate() ?? 0),
        avgSpeed: (mesg.getAvgSpeed() ?? 0) * kmhPerMetersPerSecond,
        maxSpeed: (mesg.getMaxSpeed() ?? 0) * kmhPerMetersPerSecond,
        avgCadence: Int(mesg.getAvgCadence() ?? 0),
        maxCadence: Int(mesg.getMaxCadence() ?? 0),
        totalAscent: Double(mesg.getTotalAscent() ?? 0),
        totalDescent: Double(mesg.getTotalDescent() ?? 0),
        avgPower: mesg.getAvgPower().map(Int.init),
        maxPower: mesg.getMaxPower().map(Int.init),
        calories: Double(mesg.getTotalCalories() ?? 0)
    )
}

private func makeFitActivity(from mesg: SessionMesg) -> FitActivity {
    FitActivity(
        sport: sportName(mesg.getSport()),
        subSport: subSportName(mesg.getSubSport()),
        startTime: mesg.getStartTime()?.date ?? epoch,
        endTime: mesg.getTimestamp()?.date ?? epoch,
        avgHeartRate: Int(mesg.getAvgHeartRate() ?? 0),
        maxHeartRate: Int(mesg.getMaxHeartRate() ?? 0)
    )
}

private func makeFitUserProfile(from mesg: UserProfileMesg) -> FitUserProfile {
    FitUserProfile(
        friendlyName: mesg.getFriendlyName(),
        weight: mesg.getWeight(),
        gender: mesg.getGender().map { String(describing: $0) },
        restingHeartRate: mesg.getRestingHeartRate().map(Int.init)
    )
}
