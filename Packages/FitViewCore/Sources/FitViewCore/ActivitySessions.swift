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

/// Group a set of filenames into sessions.
///
/// Unparsed names and same-session device collisions are reported in
/// `unparsed`, never silently dropped — a broken join should be visible, not
/// quietly hidden by falling back to fewer rows.
public func groupActivityFiles(_ fileNames: [String]) -> BatchGrouping {
    var sessionsById: [String: ActivitySession] = [:]
    // First-seen original casing per device, so "polarSense" displays correctly
    // while "polarsense"/"polarSense" still group together.
    var deviceLabels: [String: String] = [:]
    var deviceFileCounts: [String: Int] = [:]
    var unparsed: [UnparsedFile] = []

    for fileName in fileNames {
        guard let parsed = parseActivityFileName(fileName) else {
            unparsed.append(UnparsedFile(fileName: fileName, reason: .namePattern))
            continue
        }

        let sessionId = "\(parsed.date)|\(parsed.activityKey)"

        if sessionsById[sessionId] == nil {
            sessionsById[sessionId] = ActivitySession(
                id: sessionId,
                date: parsed.date,
                activity: parsed.activity,
                filesByDeviceKey: [:],
                deviceKeys: []
            )
        }

        if sessionsById[sessionId]!.filesByDeviceKey[parsed.deviceKey] != nil {
            // Same (date, activity, device) seen again — first one wins the slot.
            unparsed.append(UnparsedFile(fileName: fileName, reason: .duplicateDevice))
            continue
        }

        sessionsById[sessionId]!.filesByDeviceKey[parsed.deviceKey] = SessionFile(
            fileName: fileName, device: parsed.device, deviceKey: parsed.deviceKey
        )
        sessionsById[sessionId]!.deviceKeys.append(parsed.deviceKey)

        if deviceLabels[parsed.deviceKey] == nil {
            deviceLabels[parsed.deviceKey] = parsed.device
        }
        deviceFileCounts[parsed.deviceKey, default: 0] += 1
    }

    let sessions = sessionsById.values.sorted { a, b in
        a.date == b.date ? a.activity < b.activity : a.date < b.date
    }

    let devices = deviceLabels
        .map { key, label in DeviceIdentity(key: key, label: label, fileCount: deviceFileCounts[key] ?? 0) }
        .sorted { $0.fileCount > $1.fileCount }

    return BatchGrouping(sessions: sessions, devices: devices, unparsed: unparsed)
}

/// Sessions that have a file for every one of the given devices.
public func completeSessions(_ grouping: BatchGrouping, deviceKeys: [String]) -> [ActivitySession] {
    grouping.sessions.filter { session in
        deviceKeys.allSatisfy { session.filesByDeviceKey[$0] != nil }
    }
}
