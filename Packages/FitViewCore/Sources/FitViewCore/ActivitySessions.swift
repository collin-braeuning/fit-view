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

    public init(id: String, date: String, device: String, deviceKey: String, activity: String, activityKey: String) {
        self.id = id
        self.date = date
        self.device = device
        self.deviceKey = deviceKey
        self.activity = activity
        self.activityKey = activityKey
    }
}

/// Group activity descriptors into sessions.
///
/// This is the policy `groupActivityFiles` used to hardcode directly against
/// filenames — one row per (date, activity), holding at most one descriptor
/// per device, first-one-wins on a same-session device collision. Every
/// descriptor here is assumed already "parsed" (a caller with names to parse
/// first, like `groupActivityFiles`, reports its own unparsed names before
/// calling this); the only `unparsed` this function can itself produce is a
/// same-session device collision, never silently dropped — a broken join
/// should be visible, not quietly hidden by falling back to fewer rows.
public func groupActivities(_ descriptors: [ActivityDescriptor]) -> BatchGrouping {
    var sessionsById: [String: ActivitySession] = [:]
    // First-seen original casing per device, so "polarSense" displays correctly
    // while "polarsense"/"polarSense" still group together.
    var deviceLabels: [String: String] = [:]
    var deviceFileCounts: [String: Int] = [:]
    var unparsed: [UnparsedFile] = []

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

        if deviceLabels[descriptor.deviceKey] == nil {
            deviceLabels[descriptor.deviceKey] = descriptor.device
        }
        deviceFileCounts[descriptor.deviceKey, default: 0] += 1
    }

    let sessions = sessionsById.values.sorted { a, b in
        a.date == b.date ? a.activity < b.activity : a.date < b.date
    }

    let devices = deviceLabels
        .map { key, label in DeviceIdentity(key: key, label: label, fileCount: deviceFileCounts[key] ?? 0) }
        .sorted { $0.fileCount > $1.fileCount }

    return BatchGrouping(sessions: sessions, devices: devices, unparsed: unparsed)
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
