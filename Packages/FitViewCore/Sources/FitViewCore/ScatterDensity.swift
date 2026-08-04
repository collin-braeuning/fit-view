import Foundation

/// Collapses a large paired-sample scatter onto an integer lattice so a chart
/// draws one mark per distinct value pair instead of one per second — a real
/// session has 3,300-4,700 matched seconds but bpm is an integer, so most
/// pairs land on a handful of shared cells (overview.md §8: 23,966 pooled
/// pairs reduce to 1,339 unique points).

public struct DensityPoint: Sendable, Equatable, Identifiable {
    public var id: Int
    public var x: Double
    public var y: Double
    public var count: Int
}

public struct DensityCloud: Sendable, Equatable {
    public var points: [DensityPoint]
    public var maxCount: Int
    public var totalCount: Int
}

/// A struct rather than packed arithmetic, so there's no overflow reasoning
/// to get wrong.
private struct LatticeKey: Hashable {
    var x: Int64
    var y: Int64
}

/// Buckets `(xs[i], ys[i])` onto a lattice of spacing `quantum` and counts
/// occupancy per cell. `quantum` must exactly divide the values it's applied
/// to (0.5 for a half-bpm mean, 1 for whole bpm) so the reconstructed
/// coordinate `Double(key) * quantum` lands exactly where the raw data does —
/// no epsilon, no `Double` hashing drift.
public func reduceScatterDensity(xs: [Double], ys: [Double], quantum: Double) -> DensityCloud {
    guard quantum > 0, xs.count == ys.count, !xs.isEmpty else {
        return DensityCloud(points: [], maxCount: 0, totalCount: 0)
    }

    var counts: [LatticeKey: Int] = [:]
    for i in 0..<xs.count {
        let key = LatticeKey(x: Int64((xs[i] / quantum).rounded()), y: Int64((ys[i] / quantum).rounded()))
        counts[key, default: 0] += 1
    }

    // Dictionary iteration order isn't stable across runs — sort before
    // assigning `id` so `Equatable` tests and `ForEach` ids don't flake.
    let sortedEntries = counts.sorted { lhs, rhs in
        let lx = Double(lhs.key.x) * quantum
        let rx = Double(rhs.key.x) * quantum
        if lx != rx { return lx < rx }
        return Double(lhs.key.y) * quantum < Double(rhs.key.y) * quantum
    }

    let points = sortedEntries.enumerated().map { index, entry in
        DensityPoint(id: index, x: Double(entry.key.x) * quantum, y: Double(entry.key.y) * quantum, count: entry.value)
    }

    return DensityCloud(points: points, maxCount: counts.values.max() ?? 0, totalCount: xs.count)
}

/// Log-scaled occupancy weight in `0...1`, for opacity/size encoding.
/// Occupancy is heavily skewed — a linear ramp makes everything but the mode
/// invisible.
public func densityWeight(count: Int, maxCount: Int) -> Double {
    guard count > 0 else { return 0 }
    // `maxCount <= 1` would otherwise divide by `log(1) == 0`; a fully
    // non-overlapping cloud (every cell count 1) is the realistic small-session
    // case, and every point there is equally "the mode", so it gets full weight.
    guard maxCount > 1 else { return 1 }
    return log(Double(count)) / log(Double(maxCount))
}

public func blandAltmanDensity(_ stats: BlandAltmanStats) -> DensityCloud {
    reduceScatterDensity(xs: stats.points.map(\.mean), ys: stats.points.map(\.diff), quantum: 0.5)
}

public func concordanceDensity(_ stats: ConcordanceStats) -> DensityCloud {
    reduceScatterDensity(xs: stats.points.map(\.x), ys: stats.points.map(\.y), quantum: 1)
}
