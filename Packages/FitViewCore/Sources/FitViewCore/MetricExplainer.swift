import Foundation

/// Copy for the "what does this number mean" explainer shown on a stat tile.
///
/// Lives next to `AgreementScale.swift` on purpose: its band copy (`Band.range`)
/// describes the same thresholds `differenceLevel`/`cccLevel` colour the tile
/// by, and `MetricExplainerTests` pins the two together directly so tuning a
/// threshold without updating this copy fails CI instead of drifting silently.
public struct MetricExplainer: Sendable, Equatable {
    public struct Band: Sendable, Equatable {
        public let level: AgreementLevel
        /// "within ±3 bpm"
        public let range: String
        /// "good"
        public let word: String

        public init(level: AgreementLevel, range: String, word: String) {
            self.level = level
            self.range = range
            self.word = word
        }
    }

    public let title: String
    public let subtitle: String?
    /// One sentence — also used as the macOS hover `.help()` text.
    public let summary: String
    /// 2–4 sentences: how to read it, what it misses.
    public let detail: String
    /// Empty when the metric has no good/fair/poor scale.
    public let bands: [Band]
    /// Shown instead of `bands` when `bands` is empty.
    public let unscoredNote: String?
    public let learnMoreURL: URL?

    public init(
        title: String,
        subtitle: String? = nil,
        summary: String,
        detail: String,
        bands: [Band] = [],
        unscoredNote: String? = nil,
        learnMoreURL: URL? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.detail = detail
        self.bands = bands
        self.unscoredNote = unscoredNote
        self.learnMoreURL = learnMoreURL
    }
}

private let blandAltmanURL = URL(string: "https://en.wikipedia.org/wiki/Bland%E2%80%93Altman_plot")!
private let meanAbsoluteErrorURL = URL(string: "https://en.wikipedia.org/wiki/Mean_absolute_error")!
private let concordanceURL = URL(string: "https://en.wikipedia.org/wiki/Concordance_correlation_coefficient")!

/// One entry per explainable element on the activity detail screen.
public enum MetricKind: String, CaseIterable, Sendable {
    case matchedSeconds, bias, limitsOfAgreement, meanAbsoluteDifference, maxAbsoluteDifference, concordance
    case blandAltmanPlot, concordancePlot

    public var explainer: MetricExplainer {
        switch self {
        case .matchedSeconds:
            MetricExplainer(
                title: "Matched Seconds",
                summary: "How many whole seconds both devices recorded a heart rate.",
                detail: """
                Every statistic here is computed over exactly these seconds. FitView only pairs \
                readings that share the same whole second — it never shifts or interpolates one \
                device onto the other — so a device that samples irregularly contributes fewer \
                matched seconds than it recorded. A low count means the numbers rest on thin evidence.
                """,
                unscoredNote: "No scale — judge it against how long the activity was."
            )
        case .bias:
            MetricExplainer(
                title: "Bias",
                subtitle: "Bland–Altman mean difference",
                summary: "The average signed gap between the two devices, in bpm.",
                detail: """
                Positive means the first device reads higher on average, negative means lower. \
                Bias catches a sensor that is consistently off — something a correlation score \
                alone would miss entirely. It says nothing about how much individual readings \
                scatter; that's what 95% LoA covers.
                """,
                bands: [
                    MetricExplainer.Band(level: .good, range: "within ±3 bpm", word: "good"),
                    MetricExplainer.Band(level: .warn, range: "within ±7 bpm", word: "fair"),
                    MetricExplainer.Band(level: .bad, range: "beyond ±7 bpm", word: "poor"),
                ],
                learnMoreURL: blandAltmanURL
            )
        case .limitsOfAgreement:
            MetricExplainer(
                title: "95% LoA",
                subtitle: "95% limits of agreement",
                summary: "The range that holds about 95% of the second-by-second differences.",
                detail: """
                Bias ± 1.96 × the standard deviation of the differences. Bias gives the average \
                offset; LoA gives how far a single reading can stray from it. Narrow limits \
                centred near zero are what you want — wide limits mean the devices disagree \
                unpredictably even when the average looks fine.
                """,
                unscoredNote: "No fixed threshold — read it against the heart-rate range for this activity.",
                learnMoreURL: blandAltmanURL
            )
        case .meanAbsoluteDifference:
            MetricExplainer(
                title: "Mean |Diff|",
                subtitle: "Mean absolute difference",
                summary: "The typical gap between the two readings at the same second, ignoring direction.",
                detail: """
                The headline "how far apart are these devices" number. Unlike Bias, over- and \
                under-readings don't cancel out, so a sensor that swings ±10 bpm shows up here \
                even when its average is spot on. Optical and chest-strap sensors routinely \
                disagree by a beat or two.
                """,
                bands: [
                    MetricExplainer.Band(level: .good, range: "≤3 bpm", word: "good"),
                    MetricExplainer.Band(level: .warn, range: "≤7 bpm", word: "fair"),
                    MetricExplainer.Band(level: .bad, range: ">7 bpm", word: "poor"),
                ],
                learnMoreURL: meanAbsoluteErrorURL
            )
        case .maxAbsoluteDifference:
            MetricExplainer(
                title: "Max |Diff|",
                summary: "The single largest gap between the two devices during this activity.",
                detail: """
                One bad second is enough to produce a big number, so treat this as a worst-case \
                marker rather than a verdict. A large max next to a small Mean |Diff| usually \
                points at a brief dropout or a cadence-lock artifact, not a device that's broadly wrong.
                """,
                unscoredNote: "No scale — compare it against Mean |Diff| rather than reading it alone."
            )
        case .concordance:
            MetricExplainer(
                title: "CCC",
                subtitle: "Lin's concordance correlation coefficient",
                summary: "A single 0-to-1 score for how closely the two devices agree.",
                detail: """
                It folds precision and accuracy into one number, so a device that tracks every \
                rise and fall perfectly but reads 10 bpm high is still penalised — plain \
                correlation would call that a perfect match. Only compare CCC between activities \
                with a similar heart-rate range: a wider range inflates the score, which is why \
                the range is printed under the number. That range — e.g. "86–174 bpm" — is just \
                the lowest and highest heart rate either device recorded during the activity; \
                it isn't a further scoring band, only context for how much the score above should \
                be trusted.
                """,
                bands: [
                    MetricExplainer.Band(level: .good, range: "≥0.95", word: "good"),
                    MetricExplainer.Band(level: .warn, range: "≥0.90", word: "fair"),
                    MetricExplainer.Band(level: .bad, range: "<0.90", word: "poor"),
                ]
            )
        case .blandAltmanPlot:
            MetricExplainer(
                title: "Bland-Altman Agreement",
                subtitle: "Mean vs difference",
                summary: "Every matched pair plotted as its average against the signed gap between the two devices.",
                detail: """
                Each point's x is the average of the two readings at that second; its y is the first \
                device's reading minus the second's. A flat, narrow band centred on zero is agreement. \
                A cloud that tilts as you move right means the disagreement itself depends on heart \
                rate — proportional bias, which the single Bias number above cannot show. The solid \
                line marks bias; the dashed lines mark the 95% limits of agreement.
                """,
                unscoredNote: "No score — read the shape: a flat, narrow band centred on zero is agreement.",
                learnMoreURL: blandAltmanURL
            )
        case .concordancePlot:
            MetricExplainer(
                title: "Lin's Concordance",
                subtitle: "Reading against reading",
                summary: "Every matched pair plotted as one device's reading against the other's.",
                detail: """
                Points on the dashed diagonal are identical readings from both devices. A cloud that \
                runs parallel to but offset from that line is constant bias — one device consistently \
                reading higher or lower. A cloud that fans out away from the line means the devices \
                diverge more at particular heart rates than others.
                """,
                unscoredNote: "No score of its own — the CCC tile above summarises this picture as one number.",
                learnMoreURL: concordanceURL
            )
        }
    }
}
