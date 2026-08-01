import Foundation

/// Aggregates per-session and pooled agreement statistics across many
/// (date, activity) sessions for one chosen pair of devices.
///
/// Reuses `calculateAbsoluteDifferenceStats`, `calculateBlandAltmanStats` and
/// `calculateConcordanceStats` unchanged — the maths for "do two paired series
/// agree" doesn't change just because there are now several series to run it
/// over.
///
/// **Pooled Bland-Altman is fine to headline. Pooled CCC is not.** Measured on
/// this app's bundled sample data:
///
/// ```
/// naive pooled CCC (concat all sessions' pairs)   0.9533   <- range-inflated
/// mean of the per-session CCCs                    0.9320
/// Fisher/atanh-averaged CCC                        0.9714   <- worse, not better
/// ```
///
/// CCC's denominator is `σx² + σy² + (μx − μy)²`. Concatenating sessions with
/// different heart-rate profiles (e.g. an easy run around 100-110 bpm and a
/// hard interval session around 160-170 bpm) grows that denominator faster
/// than the difference variance, so the pooled coefficient rises even though
/// no session actually agreed any better. Fisher/`atanh` averaging looks like
/// a fix but is worse: the transform diverges as ρc -> 1, so it lets the single
/// best session dominate the average.
///
/// So: `spread` is the primary artefact for a headline CCC number — report the
/// distribution (median/min/max, McBride band counts), never `pooled.concordance.ccc`
/// labelled as if it were "CCC across activities". `pooled.concordance` exists
/// so the scatter has something to draw; it is deliberately excluded from
/// `AgreementSpread` and should never land in a headline stat.

/// Below this many matched seconds, a session's difference/CCC are noise, not signal.
private let minMatchedSeconds = 2

public struct HRRange: Sendable, Equatable {
    public var min: Double
    public var max: Double
}

public struct SessionAgreement: Sendable, Equatable, Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    public var date: String
    public var activity: String
    public var matchedSeconds: Int
    public var coverage: [DeviceCoverage]
    /// CCC is only interpretable against the HR range it was measured over.
    public var hrRange: HRRange
    public var difference: AbsoluteDifferenceStats
    public var blandAltman: BlandAltmanStats?
    public var concordance: ConcordanceStats?
}

public struct AgreementSpread: Sendable, Equatable {
    /// k — number of sessions contributing to this spread.
    public var sessions: Int
    /// sum(n_i) — context only.
    public var matchedSeconds: Int
    public var meanSessionBias: Double
    public var minSessionBias: Double
    public var maxSessionBias: Double
    public var meanSessionCcc: Double
    public var medianSessionCcc: Double
    public var minSessionCcc: Double
    public var maxSessionCcc: Double
    /// How many sessions per McBride band.
    public var cccBands: [AgreementLevel: Int]
}

public struct PooledAgreement: Sendable, Equatable {
    public var matchedSeconds: Int
    public var blandAltman: BlandAltmanStats?
    /// Range-inflated by construction — for the scatter, not for a headline.
    public var concordance: ConcordanceStats?
}

public struct SkippedSession: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case noOverlap
        case tooFewPoints
    }

    public var sessionId: String
    public var date: String
    public var reason: Reason
}

public struct BatchAgreementInput: Sendable {
    public struct SessionSamples: Sendable {
        public var session: ActivitySession
        public var samplesByDeviceKey: [String: [Int: Int]]

        public init(session: ActivitySession, samplesByDeviceKey: [String: [Int: Int]]) {
            self.session = session
            self.samplesByDeviceKey = samplesByDeviceKey
        }
    }

    public var sessions: [SessionSamples]
    public var primaryDeviceKey: String
    public var secondaryDeviceKey: String
    public var deviceLabels: [String: String]

    public init(
        sessions: [SessionSamples],
        primaryDeviceKey: String,
        secondaryDeviceKey: String,
        deviceLabels: [String: String]
    ) {
        self.sessions = sessions
        self.primaryDeviceKey = primaryDeviceKey
        self.secondaryDeviceKey = secondaryDeviceKey
        self.deviceLabels = deviceLabels
    }
}

public struct BatchAgreement: Sendable, Equatable {
    public var primaryName: String
    public var secondaryName: String
    public var sessions: [SessionAgreement]
    public var spread: AgreementSpread?
    public var pooled: PooledAgreement?
    public var skipped: [SkippedSession]

    public init(
        primaryName: String,
        secondaryName: String,
        sessions: [SessionAgreement],
        spread: AgreementSpread?,
        pooled: PooledAgreement?,
        skipped: [SkippedSession]
    ) {
        self.primaryName = primaryName
        self.secondaryName = secondaryName
        self.sessions = sessions
        self.spread = spread
        self.pooled = pooled
        self.skipped = skipped
    }
}

private func median(_ sortedValues: [Double]) -> Double {
    let mid = sortedValues.count / 2
    if sortedValues.count % 2 == 0 {
        return (sortedValues[mid - 1] + sortedValues[mid]) / 2
    }
    return sortedValues[mid]
}

/// Plain min/mean/median/max over the per-session results — no ANOVA, no CIs.
private func computeSpread(_ sessions: [SessionAgreement]) -> AgreementSpread? {
    let withStats = sessions.compactMap { session -> (bias: Double, ccc: Double)? in
        guard let blandAltman = session.blandAltman, let concordance = session.concordance else { return nil }
        return (blandAltman.meanDiff, concordance.ccc)
    }
    guard !withStats.isEmpty else { return nil }

    let biases = withStats.map(\.bias)
    let cccs = withStats.map(\.ccc)
    let sortedCccs = cccs.sorted()

    var cccBands: [AgreementLevel: Int] = [.good: 0, .warn: 0, .bad: 0]
    for ccc in cccs { cccBands[cccLevel(ccc), default: 0] += 1 }

    return AgreementSpread(
        sessions: withStats.count,
        matchedSeconds: sessions.reduce(0) { $0 + $1.matchedSeconds },
        meanSessionBias: mean(biases),
        minSessionBias: biases.min()!,
        maxSessionBias: biases.max()!,
        meanSessionCcc: mean(cccs),
        medianSessionCcc: median(sortedCccs),
        minSessionCcc: cccs.min()!,
        maxSessionCcc: cccs.max()!,
        cccBands: cccBands
    )
}

public func buildBatchAgreement(_ input: BatchAgreementInput) -> BatchAgreement {
    let primaryName = input.deviceLabels[input.primaryDeviceKey] ?? input.primaryDeviceKey
    let secondaryName = input.deviceLabels[input.secondaryDeviceKey] ?? input.secondaryDeviceKey

    var sessionAgreements: [SessionAgreement] = []
    var skipped: [SkippedSession] = []
    var pooledX: [Double] = []
    var pooledY: [Double] = []

    for entry in input.sessions {
        let primary = entry.samplesByDeviceKey[input.primaryDeviceKey] ?? [:]
        let secondary = entry.samplesByDeviceKey[input.secondaryDeviceKey] ?? [:]

        let aligned = intersectHeartRate([
            DeviceSamples(deviceKey: input.primaryDeviceKey, bySecond: primary),
            DeviceSamples(deviceKey: input.secondaryDeviceKey, bySecond: secondary),
        ])

        let matchedSeconds = aligned.seconds.count
        if matchedSeconds == 0 {
            skipped.append(SkippedSession(sessionId: entry.session.id, date: entry.session.date, reason: .noOverlap))
            continue
        }
        if matchedSeconds < minMatchedSeconds {
            skipped.append(SkippedSession(sessionId: entry.session.id, date: entry.session.date, reason: .tooFewPoints))
            continue
        }

        let x = (aligned.valuesByDeviceKey[input.primaryDeviceKey] ?? []).map(Double.init)
        let y = (aligned.valuesByDeviceKey[input.secondaryDeviceKey] ?? []).map(Double.init)

        pooledX.append(contentsOf: x)
        pooledY.append(contentsOf: y)

        let range = combinedRange(x, y)

        sessionAgreements.append(SessionAgreement(
            sessionId: entry.session.id,
            date: entry.session.date,
            activity: entry.session.activity,
            matchedSeconds: matchedSeconds,
            coverage: aligned.coverage,
            hrRange: HRRange(min: range.min, max: range.max),
            difference: calculateAbsoluteDifferenceStats(x, y),
            blandAltman: calculateBlandAltmanStats(x, y),
            concordance: calculateConcordanceStats(x, y)
        ))
    }

    let spread = computeSpread(sessionAgreements)
    let pooled: PooledAgreement? = pooledX.isEmpty ? nil : PooledAgreement(
        matchedSeconds: pooledX.count,
        blandAltman: calculateBlandAltmanStats(pooledX, pooledY),
        concordance: calculateConcordanceStats(pooledX, pooledY)
    )

    return BatchAgreement(
        primaryName: primaryName,
        secondaryName: secondaryName,
        sessions: sessionAgreements,
        spread: spread,
        pooled: pooled,
        skipped: skipped
    )
}
