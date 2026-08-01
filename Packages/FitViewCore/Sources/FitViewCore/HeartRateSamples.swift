import Foundation

/// Shared timeline primitives for turning a device's records into a
/// second-indexed heart rate signal.
///
/// Both the pairwise comparison screen and the batch screen need to bucket
/// records to whole seconds and to know what counts as a usable heart-rate
/// reading, so those decisions live here once rather than being duplicated (or
/// drifting) between features.

/// Whole-second bucket for a record's timestamp, matching `round(epochMillis / 1000)`.
public func secondBucket(for timestamp: Date) -> Int {
    Int(timestamp.timeIntervalSince1970.rounded())
}

/// The reading, or nil on a dropout (absent, 0, negative).
///
/// Devices report 0 bpm (or, on some sensors, a negative value) when contact
/// is lost; that's a dropout, not a reading, so it must never be charted or
/// fed into statistics as if it were real data.
public func usableHeartRate(_ record: FitRecord) -> Int? {
    guard let heartRate = record.heartRate, heartRate > 0 else { return nil }
    return heartRate
}

/// second -> bpm for every usable reading. Dropouts are skipped, never stored.
///
/// A dropout must not erase an already-recorded good reading at the same
/// second — two records sharing a second is not expected on 1 Hz devices, but
/// skipping rather than unconditionally overwriting means a stray duplicate
/// can never silently blank out real data.
public func heartRateBySecond(_ records: [FitRecord]) -> [Int: Int] {
    var bySecond: [Int: Int] = [:]
    for record in records {
        guard let heartRate = usableHeartRate(record) else { continue }
        bySecond[secondBucket(for: record.timestamp)] = heartRate
    }
    return bySecond
}
