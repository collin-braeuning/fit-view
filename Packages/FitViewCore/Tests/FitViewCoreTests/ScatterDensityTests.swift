import Foundation
import Testing
@testable import FitViewCore

@Suite("ScatterDensity")
struct ScatterDensityTests {
    @Test("duplicate integer pairs collapse, with correct counts")
    func duplicatesCollapse() {
        let cloud = reduceScatterDensity(xs: [1, 1, 2, 1], ys: [5, 5, 6, 5], quantum: 1)
        #expect(cloud.points.count == 2)
        let byX = Dictionary(uniqueKeysWithValues: cloud.points.map { ($0.x, $0.count) })
        #expect(byX[1] == 3)
        #expect(byX[2] == 1)
    }

    @Test("half-bpm lattice round-trips exactly")
    func halfBpmLatticeIsExact() {
        let cloud = reduceScatterDensity(xs: [132.5, 133.0, 132.5], ys: [0, 0, 0], quantum: 0.5)
        #expect(cloud.points.count == 2)
        let point132_5 = cloud.points.first { $0.x == 132.5 }
        let point133_0 = cloud.points.first { $0.x == 133.0 }
        #expect(point132_5?.count == 2)
        #expect(point133_0?.count == 1)
    }

    @Test("points are sorted by (x, then y), with ids 0..<count")
    func pointsAreSortedWithSequentialIds() {
        let cloud = reduceScatterDensity(xs: [2, 1, 1, 2], ys: [0, 1, 0, -1], quantum: 1)
        #expect(cloud.points.map(\.x) == [1, 1, 2, 2])
        #expect(cloud.points.map(\.y) == [0, 1, -1, 0])
        #expect(cloud.points.map(\.id) == Array(0..<cloud.points.count))
    }

    @Test("totalCount and per-cell counts sum to the input count")
    func countsSumToInput() {
        let xs: [Double] = [1, 1, 2, 3, 3, 3]
        let cloud = reduceScatterDensity(xs: xs, ys: xs, quantum: 1)
        #expect(cloud.totalCount == xs.count)
        #expect(cloud.points.map(\.count).reduce(0, +) == xs.count)
    }

    @Test("empty input yields an empty cloud")
    func emptyInput() {
        let cloud = reduceScatterDensity(xs: [], ys: [], quantum: 1)
        #expect(cloud.points.isEmpty)
        #expect(cloud.maxCount == 0)
        #expect(cloud.totalCount == 0)
        #expect(densityWeight(count: 0, maxCount: cloud.maxCount) == 0)
    }

    @Test("densityWeight is 0 for a singleton, 1 at the max, and monotonic between")
    func densityWeightMonotonic() {
        #expect(densityWeight(count: 1, maxCount: 100) == 0)
        #expect(densityWeight(count: 100, maxCount: 100) == 1)
        let low = densityWeight(count: 5, maxCount: 100)
        let high = densityWeight(count: 50, maxCount: 100)
        #expect(low > 0 && low < high && high < 1)
    }

    @Test("densityWeight avoids the 0/0 trap when maxCount is 1")
    func densityWeightMaxCountOne() {
        #expect(densityWeight(count: 1, maxCount: 1) == 1)
        #expect(densityWeight(count: 0, maxCount: 1) == 0)
    }

    @Test("blandAltmanDensity buckets mean/diff pairs onto the half-bpm lattice")
    func blandAltmanDensityBucketsCorrectly() {
        let stats = calculateBlandAltmanStats([100, 100, 102], [98, 98, 100])!
        let cloud = blandAltmanDensity(stats)
        #expect(cloud.totalCount == 3)
        #expect(cloud.points.count == 2)
        let byMean = Dictionary(uniqueKeysWithValues: cloud.points.map { ($0.x, $0) })
        #expect(byMean[99]?.y == 2)
        #expect(byMean[99]?.count == 2)
        #expect(byMean[101]?.y == 2)
        #expect(byMean[101]?.count == 1)
    }

    @Test("concordanceDensity buckets x/y pairs onto the unit lattice")
    func concordanceDensityBucketsCorrectly() {
        let stats = calculateConcordanceStats([100, 100, 100], [98, 98, 98])!
        let cloud = concordanceDensity(stats)
        #expect(cloud.points.count == 1)
        #expect(cloud.points.first?.count == 3)
        #expect(cloud.totalCount == 3)
    }

    @Test("a large synthetic corpus reduces to exactly its distinct-pair count")
    func scaleGuardAgainstHashingRegression() {
        // Mirrors overview.md §8's real-world reduction (tens of thousands of
        // pooled pairs collapsing onto a much smaller lattice) — catches a
        // key/hashing regression that would silently stop deduping.
        var xs: [Double] = []
        var ys: [Double] = []
        var distinctPairs = Set<LatticeCoordinate>()
        for i in 0..<24000 {
            let x = Double(60 + i % 140)
            let y = Double(60 + (i * 7) % 140)
            xs.append(x)
            ys.append(y)
            distinctPairs.insert(LatticeCoordinate(x: x, y: y))
        }

        let cloud = reduceScatterDensity(xs: xs, ys: ys, quantum: 1)
        #expect(cloud.totalCount == 24000)
        #expect(cloud.points.count == distinctPairs.count)
    }
}

private struct LatticeCoordinate: Hashable {
    var x: Double
    var y: Double
}
