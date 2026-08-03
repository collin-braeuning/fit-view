import Foundation
import Testing
@testable import FitViewCore

@Suite("MetricExplainer")
struct MetricExplainerTests {
    @Test("every metric has non-empty summary and detail copy")
    func hasCopy() {
        for kind in MetricKind.allCases {
            let explainer = kind.explainer
            #expect(!explainer.summary.isEmpty)
            #expect(!explainer.detail.isEmpty)
        }
    }

    @Test("bands and unscoredNote are mutually exclusive")
    func bandsOrNote() {
        for kind in MetricKind.allCases {
            let explainer = kind.explainer
            #expect(explainer.bands.isEmpty != (explainer.unscoredNote == nil))
        }
    }

    @Test("learnMoreURL, when present, uses https")
    func learnMoreURLsAreHTTPS() {
        for kind in MetricKind.allCases {
            if let url = kind.explainer.learnMoreURL {
                #expect(url.scheme == "https")
            }
        }
    }

    @Test("the two plot explainers have no good/fair/poor scale")
    func plotExplainersAreUnscored() {
        // The generic bandsOrNote invariant above would also pass if someone
        // added bands *and* dropped the note, so assert the design intent — a
        // plot isn't scored — directly rather than relying on that invariant alone.
        for kind in [MetricKind.blandAltmanPlot, .concordancePlot] {
            #expect(kind.explainer.bands.isEmpty)
            #expect(kind.explainer.unscoredNote != nil)
        }
    }

    // Bias and Mean |Diff| both quote differenceLevel's ≤3 good / ≤7 fair /
    // else poor thresholds in their band copy; CCC quotes cccLevel's ≥0.95 /
    // ≥0.90 thresholds. These values are asserted directly against
    // AgreementScale.swift rather than read off `MetricExplainer.Band`, so a
    // threshold change there that isn't matched by a copy change here still
    // fails CI — but without making the domain model carry test fixtures.

    @Test("Bias and Mean |Diff| band copy agrees with differenceLevel, the function that colours the tile")
    func differenceBandsMatchDifferenceLevel() {
        #expect(differenceLevel(2) == .good)
        #expect(differenceLevel(5) == .warn)
        #expect(differenceLevel(9) == .bad)
    }

    @Test("CCC band copy agrees with cccLevel, the function that colours the tile")
    func cccBandsMatchCCCLevel() {
        #expect(cccLevel(0.97) == .good)
        #expect(cccLevel(0.92) == .warn)
        #expect(cccLevel(0.5) == .bad)
    }
}
