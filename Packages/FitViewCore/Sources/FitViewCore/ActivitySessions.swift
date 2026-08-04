import Foundation

/// Groups uploaded/loaded filenames into (date, activity) sessions.
///
/// `parseActivityFileName` only extracts what a name says; deciding how those
/// parsed facts turn into sessions — one row per (date, activity), which
/// device wins a collision, what counts as "most common" — is a policy
/// decision, so it lives here rather than in the filename parser.

public struct SessionFile: Sendable, Equatable {
    public var fileName: String
    public var device: String
    public var deviceKey: String
}

public struct ActivitySession: Sendable, Equatable {
    /// `"\(date)|\(activityKey)"` — stable identity and sort/grouping key.
    public var id: String
    public var date: String
    public var activity: String
    public var filesByDeviceKey: [String: SessionFile]
    public var deviceKeys: [String]
}

public struct DeviceIdentity: Sendable, Equatable {
    public var key: String
    public var label: String
    public var fileCount: Int
}

public struct UnparsedFile: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case namePattern
        case duplicateDevice
    }

    public var fileName: String
    public var reason: Reason
}

public struct BatchGrouping: Sendable, Equatable {
    /// Ascending by date, then activity.
    public var sessions: [ActivitySession]
    /// Most files first — drives the default pair selection.
    public var devices: [DeviceIdentity]
    public var unparsed: [UnparsedFile]
}

/// What a single recorded activity contributes to grouping, regardless of
/// where it came from — a parsed filename (`ActivityFileName`) and an
/// imported library item (`LibraryItem`) both reduce to exactly this shape.
///
/// Generalises the Phase 1 stopgap documented in `PolarAccessLinkModels.swift`:
/// an API-sourced activity used to have to synthesize a fake filename
/// (`"2026-07-26_polarvantagev2_running"`) just so `groupActivityFiles` could
/// parse it back out again. Building an `ActivityDescriptor` directly from
/// real metadata (a decoded start time, a device name the source reported)
/// skips that round-trip entirely.
public struct ActivityDescriptor: Sendable, Equatable {
    /// Stable within whatever produced this batch of descriptors — a
    /// filename for a file-backed grouping, a `LibraryItem.id` for a
    /// store-backed one. Carried through into `SessionFile.fileName` so
    /// downstream code can look the underlying data back up, whatever it's
    /// keyed by.
    public var id: String
    /// "2026-07-30", exactly as written — see `ActivityFileName.date`.
    public var date: String
    /// Original casing, for display.
    public var device: String
    /// Lower-cased, grouping only.
    public var deviceKey: String
    /// May contain underscores ("long_run").
    public var activity: String
    /// Lower-cased, grouping only.
    public var activityKey: String
    /// The recording's real start instant, when known — decoded from the
    /// file's own FIT data (`SharedActivityMetadata.startTime`), not derived
    /// from `date`. Drives time-window session matching (`groupActivities`);
    /// `nil` for a descriptor that only ever had a filename to go on (bytes
    /// that failed to decode, or the legacy `groupActivityFiles` path), which
    /// falls back to the old `date`/`activityKey` grouping instead.
    public var startTime: Date?
    /// The recording's real end instant, when known (`SharedActivityMetadata.endTime`).
    /// Lets `groupActivities` pair two devices whose recordings genuinely
    /// overlap even when their start times don't fall within
    /// `sessionMatchWindow` of each other. `nil` alongside `startTime` for the
    /// same reasons `startTime` is nil.
    public var endTime: Date?

    public init(
        id: String, date: String, device: String, deviceKey: String, activity: String, activityKey: String,
        startTime: Date? = nil, endTime: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.device = device
        self.deviceKey = deviceKey
        self.activity = activity
        self.activityKey = activityKey
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// How close two different devices' start times have to be to count as the
/// same real-world session (`groupActivities`'s time-window clustering).
/// Chosen because devices are started by hand, one after another, not on a
/// shared clock — see `overview.md` §5's "no clock-offset or drift
/// correction" for the analogous, much tighter (sub-second) constraint that
/// applies once two files *are* known to belong together.
let sessionMatchWindow: TimeInterval = 30 * 60

/// Tracks first-seen device label casing and per-device file counts across
/// however many grouping passes contribute to one `BatchGrouping` — split out
/// so the legacy `date`/`activityKey` path and the time-window clustering
/// path both feed the same device list.
private struct DeviceAccumulator {
    // First-seen original casing per device, so "polarSense" displays
    // correctly while "polarsense"/"polarSense" still group together.
    var labels: [String: String] = [:]
    var fileCounts: [String: Int] = [:]

    mutating func record(device: String, deviceKey: String) {
        if labels[deviceKey] == nil {
            labels[deviceKey] = device
        }
        fileCounts[deviceKey, default: 0] += 1
    }

    var devices: [DeviceIdentity] {
        // Most files first, then by key — the key tiebreak is what makes this
        // deterministic. `labels` is a Dictionary, so its iteration order
        // varies run to run, and `sorted(by:)` is not stable; ranking on
        // `fileCount` alone therefore returned an arbitrary order whenever two
        // devices had recorded the same number of files. The reference corpus is
        // exactly that case (pace4 and polarSense both have 8), so the default
        // pair selection could silently swap primary and secondary between
        // launches — flipping the sign of every reported bias.
        labels
            .map { key, label in DeviceIdentity(key: key, label: label, fileCount: fileCounts[key] ?? 0) }
            .sorted { lhs, rhs in
                if lhs.fileCount != rhs.fileCount { return lhs.fileCount > rhs.fileCount }
                return lhs.key < rhs.key
            }
    }
}

/// Group activity descriptors into sessions.
///
/// Descriptors with a real decoded `startTime` are clustered by cross-device
/// time proximity (`sessionMatchWindow`) instead of requiring an exact
/// `activityKey` match — different manufacturers name the same sport
/// differently (COROS "run" vs Polar "generic"), so two devices' recordings
/// only need to have started close together, not agree on what they call the
/// activity. Descriptors with no `startTime` (bytes that didn't decode, or a
/// caller with only a filename to go on, like `groupActivityFiles`) fall back
/// to the original policy: one row per (date, activityKey), holding at most
/// one descriptor per device, first-one-wins on a same-session device
/// collision — that collision is the only `unparsed` this function can itself
/// produce, never silently dropped, matching this package's "a broken join
/// should be visible" principle throughout.
public func groupActivities(_ descriptors: [ActivityDescriptor]) -> BatchGrouping {
    var accumulator = DeviceAccumulator()
    var unparsed: [UnparsedFile] = []

    let dated = descriptors.filter { $0.startTime == nil }
    let timed = descriptors.filter { $0.startTime != nil }

    let sessions = groupByDateAndActivityKey(dated, accumulator: &accumulator, unparsed: &unparsed)
        + groupByStartTimeProximity(timed, accumulator: &accumulator)

    let sorted = sessions.sorted { a, b in
        a.date == b.date ? a.activity < b.activity : a.date < b.date
    }

    return BatchGrouping(sessions: sorted, devices: accumulator.devices, unparsed: unparsed)
}

/// The original filename-shaped policy — one row per `"\(date)|\(activityKey)"`.
private func groupByDateAndActivityKey(
    _ descriptors: [ActivityDescriptor], accumulator: inout DeviceAccumulator, unparsed: inout [UnparsedFile]
) -> [ActivitySession] {
    var sessionsById: [String: ActivitySession] = [:]

    for descriptor in descriptors {
        let sessionId = "\(descriptor.date)|\(descriptor.activityKey)"

        if sessionsById[sessionId] == nil {
            sessionsById[sessionId] = ActivitySession(
                id: sessionId,
                date: descriptor.date,
                activity: descriptor.activity,
                filesByDeviceKey: [:],
                deviceKeys: []
            )
        }

        if sessionsById[sessionId]!.filesByDeviceKey[descriptor.deviceKey] != nil {
            // Same (date, activity, device) seen again — first one wins the slot.
            unparsed.append(UnparsedFile(fileName: descriptor.id, reason: .duplicateDevice))
            continue
        }

        sessionsById[sessionId]!.filesByDeviceKey[descriptor.deviceKey] = SessionFile(
            fileName: descriptor.id, device: descriptor.device, deviceKey: descriptor.deviceKey
        )
        sessionsById[sessionId]!.deviceKeys.append(descriptor.deviceKey)
        accumulator.record(device: descriptor.device, deviceKey: descriptor.deviceKey)
    }

    return Array(sessionsById.values)
}

/// Clusters descriptors that all carry a real `startTime` by cross-device
/// proximity: a descriptor joins the first existing cluster that (a) doesn't
/// already hold its `deviceKey` and (b) either has at least one member whose
/// recorded span genuinely overlaps its own, or has at least one member
/// within `sessionMatchWindow` of it — transitively, so a cluster's time span
/// can grow beyond the window one join at a time, the same way a slightly
/// staggered "start the watch, then start the chest strap a few minutes
/// later" real recording would.
///
/// The span-overlap test exists alongside the window test, not instead of
/// it, because a start-time gap alone is a bad proxy for "these belong
/// together": a device started 45 minutes after the other can still have
/// genuinely overlapping recorded seconds with it if the first device's
/// activity ran long enough (a forgotten chest strap started mid-run, not
/// the reference corpus's usual 6-12 minute stagger) — window-only matching
/// misses that pairing entirely and each recording ends up alone in its own
/// cluster, silently reported as zero overlap even though real matched
/// seconds exist. Falls back to the window test alone when either side is
/// missing an `endTime`.
///
/// Each device still contributes at most one file per cluster; a second
/// recording from a device already in a cluster starts its own new cluster
/// instead of being flagged — it's a genuine second activity, not a
/// collision on the same slot, so there is no `unparsed` case here (unlike
/// `groupByDateAndActivityKey`'s exact-slot collision).
private func groupByStartTimeProximity(
    _ descriptors: [ActivityDescriptor], accumulator: inout DeviceAccumulator
) -> [ActivitySession] {
    struct Timed {
        var descriptor: ActivityDescriptor
        var startTime: Date
        var endTime: Date?
    }

    struct Cluster {
        var members: [Timed] = []
        var deviceKeys: Set<String> = []
    }

    func belongsTogether(_ a: Timed, _ b: Timed) -> Bool {
        if let aEnd = a.endTime, let bEnd = b.endTime, a.startTime <= bEnd, b.startTime <= aEnd {
            return true
        }
        return abs(a.startTime.timeIntervalSince(b.startTime)) <= sessionMatchWindow
    }

    let sorted = descriptors
        .map { Timed(descriptor: $0, startTime: $0.startTime!, endTime: $0.endTime) }
        .sorted { $0.startTime < $1.startTime }

    var clusters: [Cluster] = []
    for timed in sorted {
        let deviceKey = timed.descriptor.deviceKey
        if let index = clusters.firstIndex(where: { cluster in
            !cluster.deviceKeys.contains(deviceKey)
                && cluster.members.contains { belongsTogether($0, timed) }
        }) {
            clusters[index].members.append(timed)
            clusters[index].deviceKeys.insert(deviceKey)
        } else {
            clusters.append(Cluster(members: [timed], deviceKeys: [deviceKey]))
        }
    }

    return clusters.map { cluster in
        // The earliest-starting member names and dates the session — whoever
        // started recording first.
        let anchor = cluster.members.min { $0.startTime < $1.startTime }!
        let sessionId = "\(anchor.descriptor.date)|\(Int(anchor.startTime.timeIntervalSince1970))"

        var filesByDeviceKey: [String: SessionFile] = [:]
        var deviceKeys: [String] = []
        for member in cluster.members {
            let descriptor = member.descriptor
            filesByDeviceKey[descriptor.deviceKey] = SessionFile(
                fileName: descriptor.id, device: descriptor.device, deviceKey: descriptor.deviceKey
            )
            deviceKeys.append(descriptor.deviceKey)
            accumulator.record(device: descriptor.device, deviceKey: descriptor.deviceKey)
        }

        return ActivitySession(
            id: sessionId, date: anchor.descriptor.date, activity: anchor.descriptor.activity,
            filesByDeviceKey: filesByDeviceKey, deviceKeys: deviceKeys
        )
    }
}

/// Group a set of filenames into sessions.
///
/// A thin adapter over `groupActivities`: every name is parsed through the
/// existing `parseActivityFileName`, names that don't parse are reported in
/// `unparsed` up front, and everything that does parse becomes an
/// `ActivityDescriptor`. Kept as its own entry point — rather than inlined at
/// every call site — because it's still the only grouping path filenames
/// need, and every existing caller (batch assembly, the import summary, the
/// preview fixture) keys its data by filename already.
public func groupActivityFiles(_ fileNames: [String]) -> BatchGrouping {
    var descriptors: [ActivityDescriptor] = []
    var unparsed: [UnparsedFile] = []

    for fileName in fileNames {
        guard let parsed = parseActivityFileName(fileName) else {
            unparsed.append(UnparsedFile(fileName: fileName, reason: .namePattern))
            continue
        }
        descriptors.append(ActivityDescriptor(
            id: fileName,
            date: parsed.date,
            device: parsed.device,
            deviceKey: parsed.deviceKey,
            activity: parsed.activity,
            activityKey: parsed.activityKey
        ))
    }

    var grouping = groupActivities(descriptors)
    grouping.unparsed = unparsed + grouping.unparsed
    return grouping
}

/// Sessions that have a file for every one of the given devices.
public func completeSessions(_ grouping: BatchGrouping, deviceKeys: [String]) -> [ActivitySession] {
    grouping.sessions.filter { session in
        deviceKeys.allSatisfy { session.filesByDeviceKey[$0] != nil }
    }
}
