import Foundation
import Testing
@testable import FitViewCore

private func date(_ epochSeconds: Int) -> Date {
    Date(timeIntervalSince1970: Double(epochSeconds))
}

private func record(_ epochSeconds: Int, heartRate: Int?) -> FitRecord {
    FitRecord(timestamp: date(epochSeconds), heartRate: heartRate)
}

@Suite("buildComparisonTimeline")
struct ComparisonTimelineTests {
    @Test("merges partially-overlapping recordings onto one timeline")
    func mergesPartiallyOverlapping() {
        let a = DeviceRecords(deviceKey: "a", records: [
            record(0, heartRate: 100),
            record(1, heartRate: 101),
            record(2, heartRate: 102),
        ])
        let b = DeviceRecords(deviceKey: "b", records: [
            record(2, heartRate: 200),
            record(3, heartRate: 201),
            record(4, heartRate: 202),
        ])

        let timeline = buildComparisonTimeline([a, b])

        #expect(timeline.seconds == [0, 1, 2, 3, 4])
        let aSeries = timeline.heartRate.first { $0.deviceKey == "a" }!
        let bSeries = timeline.heartRate.first { $0.deviceKey == "b" }!
        #expect(aSeries.values == [100, 101, 102, nil, nil])
        #expect(bSeries.values == [nil, nil, 200, 201, 202])
    }

    @Test("a 0 bpm reading is a dropout, not a value")
    func zeroIsDropout() {
        let a = DeviceRecords(deviceKey: "a", records: [
            record(0, heartRate: 100),
            record(1, heartRate: 0),
            record(2, heartRate: 102),
        ])

        let timeline = buildComparisonTimeline([a])

        #expect(timeline.heartRate[0].values == [100, nil, 102])
    }

    @Test("a dropout on a duplicated second must not erase an already-recorded good reading")
    func dropoutDoesNotEraseGoodReading() {
        let a = DeviceRecords(deviceKey: "a", records: [
            record(0, heartRate: 100),
            record(0, heartRate: 0),
        ])

        let timeline = buildComparisonTimeline([a])

        #expect(timeline.seconds == [0])
        #expect(timeline.heartRate[0].values == [100])
    }

    @Test("a single device yields a full timeline rather than an empty one")
    func singleDeviceYieldsFullTimeline() {
        let a = DeviceRecords(deviceKey: "a", records: [
            record(0, heartRate: 100),
            record(1, heartRate: 101),
        ])

        let timeline = buildComparisonTimeline([a])

        #expect(timeline.seconds == [0, 1])
        #expect(timeline.heartRate.count == 1)
        #expect(timeline.heartRate[0].values == [100, 101])
    }

    @Test("zero devices yields an empty timeline")
    func zeroDevicesYieldsEmptyTimeline() {
        let timeline = buildComparisonTimeline([])

        #expect(timeline.seconds.isEmpty)
        #expect(timeline.heartRate.isEmpty)
    }

    @Test("seconds are strictly ascending and each values array is seconds.count long")
    func secondsAscendingAndValuesLengthMatches() {
        let a = DeviceRecords(deviceKey: "a", records: [
            record(5, heartRate: 100),
            record(1, heartRate: 101),
            record(3, heartRate: 102),
        ])
        let b = DeviceRecords(deviceKey: "b", records: [
            record(9, heartRate: 200),
            record(0, heartRate: 201),
        ])

        let timeline = buildComparisonTimeline([a, b])

        #expect(timeline.seconds == timeline.seconds.sorted())
        #expect(Set(timeline.seconds).count == timeline.seconds.count)
        for series in timeline.heartRate {
            #expect(series.values.count == timeline.seconds.count)
        }
    }

    @Test("caller device order is preserved in the output series")
    func callerOrderPreserved() {
        let a = DeviceRecords(deviceKey: "secondary", records: [record(0, heartRate: 100)])
        let b = DeviceRecords(deviceKey: "primary", records: [record(0, heartRate: 200)])

        let timeline = buildComparisonTimeline([a, b])

        #expect(timeline.heartRate.map(\.deviceKey) == ["secondary", "primary"])
    }
}
