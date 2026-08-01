import Foundation

/// N-device intersection of second-indexed heart-rate samples.
///
/// The devices in this app aren't synchronised — they're started and stopped
/// by hand, and `pace4` auto-pauses — so a session's comparable samples are
/// only the whole seconds where *every* selected device produced a usable
/// reading. That's an intersection, not a union: unlike the pairwise
/// comparison screen (which draws a time series and so needs every second,
/// nil-filled, on a shared x-axis), the batch view draws no time series, so
/// building a union timeline with nil-filled arrays would be pure waste.

public struct DeviceSamples: Sendable {
    public var deviceKey: String
    public var bySecond: [Int: Int]

    public init(deviceKey: String, bySecond: [Int: Int]) {
        self.deviceKey = deviceKey
        self.bySecond = bySecond
    }
}

public struct DeviceCoverage: Sendable, Equatable {
    public var deviceKey: String
    /// Usable readings this device recorded.
    public var ownSeconds: Int
    /// last - first + 1: how long it was running.
    public var spanSeconds: Int
    /// matchedSeconds / ownSeconds, 0...1.
    public var coverage: Double
}

public struct AlignedSession: Sendable, Equatable {
    /// Present in EVERY device passed in.
    public var seconds: [Int]
    /// Index-aligned with `seconds`.
    public var valuesByDeviceKey: [String: [Int]]
    public var coverage: [DeviceCoverage]
}

private let emptyAlignedSession = AlignedSession(seconds: [], valuesByDeviceKey: [:], coverage: [])

private func spanOf(_ bySecond: [Int: Int]) -> Int {
    guard let min = bySecond.keys.min(), let max = bySecond.keys.max() else { return 0 }
    return max - min + 1
}

/// Intersect any number of devices' second-indexed samples.
///
/// Iterates the smallest map and probes the rest — O(min·N) rather than
/// building a union first. Two or more devices are required for an
/// intersection to mean anything; fewer returns an empty result rather than
/// throwing, since "not enough devices selected yet" is a normal transient UI
/// state, not an error.
public func intersectHeartRate(_ devices: [DeviceSamples]) -> AlignedSession {
    guard devices.count >= 2 else { return emptyAlignedSession }

    let smallest = devices.min { $0.bySecond.count < $1.bySecond.count }!

    var seconds: [Int] = []
    for second in smallest.bySecond.keys where devices.allSatisfy({ $0.bySecond[second] != nil }) {
        seconds.append(second)
    }
    seconds.sort()

    var valuesByDeviceKey: [String: [Int]] = [:]
    for device in devices {
        valuesByDeviceKey[device.deviceKey] = seconds.map { device.bySecond[$0]! }
    }

    let matchedSeconds = seconds.count
    let coverage = devices.map { device -> DeviceCoverage in
        let ownSeconds = device.bySecond.count
        return DeviceCoverage(
            deviceKey: device.deviceKey,
            ownSeconds: ownSeconds,
            spanSeconds: spanOf(device.bySecond),
            coverage: ownSeconds == 0 ? 0 : Double(matchedSeconds) / Double(ownSeconds)
        )
    }

    return AlignedSession(seconds: seconds, valuesByDeviceKey: valuesByDeviceKey, coverage: coverage)
}
