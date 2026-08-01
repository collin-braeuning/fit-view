import Foundation

/// Agreement statistics for two paired sample series.
///
/// Pure maths. Every function takes two index-aligned arrays (`x[i]` and
/// `y[i]` are the two devices' readings at the same instant) and returns nil
/// when the input can't support a result.

public struct AbsoluteDifferenceStats: Sendable, Equatable {
    public var avgAbsDiff: Double
    public var maxAbsDiff: Double
}

public struct BlandAltmanPoint: Sendable, Equatable {
    public var mean: Double
    public var diff: Double
}

public struct BlandAltmanStats: Sendable, Equatable {
    public var points: [BlandAltmanPoint]
    public var meanDiff: Double
    public var sdDiff: Double
    public var upperLimit: Double
    public var lowerLimit: Double
}

public struct ConcordancePoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
}

public struct ConcordanceStats: Sendable, Equatable {
    public var points: [ConcordancePoint]
    public var ccc: Double
    public var min: Double
    public var max: Double
}

private func isPaired(_ x: [Double], _ y: [Double]) -> Bool {
    x.count == y.count && !x.isEmpty
}

func mean(_ values: [Double]) -> Double {
    values.reduce(0, +) / Double(values.count)
}

/// Min/max over two arrays in one pass — pooled arrays run into the tens of thousands.
func combinedRange(_ a: [Double], _ b: [Double]) -> (min: Double, max: Double) {
    var lo = Double.infinity
    var hi = -Double.infinity
    for value in a {
        if value < lo { lo = value }
        if value > hi { hi = value }
    }
    for value in b {
        if value < lo { lo = value }
        if value > hi { hi = value }
    }
    return (lo, hi)
}

/// Average and worst-case absolute difference — the headline "how far apart are
/// these two devices" number.
public func calculateAbsoluteDifferenceStats(_ x: [Double], _ y: [Double]) -> AbsoluteDifferenceStats {
    guard isPaired(x, y) else { return AbsoluteDifferenceStats(avgAbsDiff: 0, maxAbsDiff: 0) }

    var sum = 0.0
    var maxDiff = 0.0
    for i in 0..<x.count {
        let diff = abs(x[i] - y[i])
        sum += diff
        if diff > maxDiff { maxDiff = diff }
    }

    return AbsoluteDifferenceStats(avgAbsDiff: sum / Double(x.count), maxAbsDiff: maxDiff)
}

/// Bland-Altman agreement: each pair's mean (x) against its signed difference
/// (y), plus the bias (mean difference) and the 95% limits of agreement
/// (bias ± 1.96 SD). Answers "is one device biased, and how wide is the spread"
/// — which correlation alone can't tell you.
public func calculateBlandAltmanStats(_ x: [Double], _ y: [Double]) -> BlandAltmanStats? {
    guard isPaired(x, y) else { return nil }

    let points = zip(x, y).map { xi, yi in BlandAltmanPoint(mean: (xi + yi) / 2, diff: xi - yi) }
    let diffs = points.map(\.diff)
    let meanDiff = mean(diffs)
    let variance = mean(diffs.map { ($0 - meanDiff) * ($0 - meanDiff) })
    let sdDiff = variance.squareRoot()

    return BlandAltmanStats(
        points: points,
        meanDiff: meanDiff,
        sdDiff: sdDiff,
        upperLimit: meanDiff + 1.96 * sdDiff,
        lowerLimit: meanDiff - 1.96 * sdDiff
    )
}

/// Lin's Concordance Correlation Coefficient, plus the raw points for a
/// scatter against the line of equality.
///
/// CCC folds precision (correlation) and accuracy (distance from x = y) into
/// one score, so a device that tracks the reference perfectly but reads 10 bpm
/// high is penalised — unlike Pearson's r, which would report a perfect 1.0.
///
///   ρc = (2 · cov(x,y)) / (σx² + σy² + (μx − μy)²)
public func calculateConcordanceStats(_ x: [Double], _ y: [Double]) -> ConcordanceStats? {
    guard isPaired(x, y) else { return nil }

    let n = Double(x.count)
    let meanX = mean(x)
    let meanY = mean(y)

    var varX = 0.0
    var varY = 0.0
    var covXY = 0.0

    for i in 0..<x.count {
        let dx = x[i] - meanX
        let dy = y[i] - meanY
        varX += dx * dx
        varY += dy * dy
        covXY += dx * dy
    }

    varX /= n
    varY /= n
    covXY /= n

    let denominator = varX + varY + (meanX - meanY) * (meanX - meanY)
    // Zero only when both series are the same constant — no agreement to measure.
    guard denominator != 0 else { return nil }

    let range = combinedRange(x, y)
    return ConcordanceStats(
        points: zip(x, y).map { ConcordancePoint(x: $0, y: $1) },
        ccc: (2 * covXY) / denominator,
        min: range.min,
        max: range.max
    )
}
