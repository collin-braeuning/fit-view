import Foundation

/// Union alignment for the per-session HR comparison chart.
///
/// Unlike `intersectHeartRate` (see `AlignSamples.swift`), this builds its
/// x-axis from every device's record timestamps, not just their usable HR
/// buckets, and nil-fills each series rather than dropping unmatched seconds
/// — the chart needs every second on a shared axis, including the ones where
/// only one device produced a reading.

public struct DeviceRecords: Sendable {
    public var deviceKey: String
    public var records: [FitRecord]

    public init(deviceKey: String, records: [FitRecord]) {
        self.deviceKey = deviceKey
        self.records = records
    }
}

/// One chart line, index-aligned with `ComparisonTimeline.seconds`.
public struct HeartRateSeries: Sendable, Equatable {
    public var deviceKey: String
    /// nil where this device produced no usable reading for that second.
    public var values: [Int?]
}

public struct ComparisonTimeline: Sendable, Equatable {
    /// Union of every record's whole-second bucket across every device, ascending.
    public var seconds: [Int]
    /// Caller order preserved.
    public var heartRate: [HeartRateSeries]
}

/// Build a union timeline over any number of devices' records.
///
/// Deliberately does **not** bail out below two devices — a missing-device
/// session is precisely where drawing the one device you do have is the
/// diagnostic, so the timeline is built for however many devices are handed
/// in, including one.
public func buildComparisonTimeline(_ devices: [DeviceRecords]) -> ComparisonTimeline {
    var bucketSet = Set<Int>()
    for device in devices {
        for record in device.records {
            bucketSet.insert(secondBucket(for: record.timestamp))
        }
    }
    let seconds = bucketSet.sorted()

    var indexByBucket: [Int: Int] = [:]
    indexByBucket.reserveCapacity(seconds.count)
    for (index, bucket) in seconds.enumerated() {
        indexByBucket[bucket] = index
    }

    let heartRate = devices.map { device -> HeartRateSeries in
        var values = [Int?](repeating: nil, count: seconds.count)
        for record in device.records {
            guard let bpm = usableHeartRate(record) else { continue }
            let index = indexByBucket[secondBucket(for: record.timestamp)]!
            values[index] = bpm
        }
        return HeartRateSeries(deviceKey: device.deviceKey, values: values)
    }

    return ComparisonTimeline(seconds: seconds, heartRate: heartRate)
}
