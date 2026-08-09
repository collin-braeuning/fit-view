import FitViewCore
import Testing
@testable import FitView

/// Covers `metricTileAccessibilityLabel`, the SwiftUI-free helper `MetricTile`
/// shares with every call site (detail-screen tiles and overview-card rows
/// alike) to build what VoiceOver speaks. It's the one part of the
/// `StatTile`/`statTile`/`detailTile` consolidation (#25) that could regress
/// silently, since the view itself isn't unit-testable — see
/// specs/001-activity-list/research.md §1.
@Suite("MetricTile accessibility label")
struct MetricTileTests {
    @Test("without a level, the label reads just the label and value")
    func withoutLevel() {
        #expect(metricTileAccessibilityLabel(label: "Max |Diff|", value: "8 bpm", level: nil) == "Max |Diff| 8 bpm")
    }

    @Test("a good level appends ', good agreement'")
    func goodLevel() {
        #expect(
            metricTileAccessibilityLabel(label: "Bias", value: "2.0 bpm", level: .good)
                == "Bias 2.0 bpm, good agreement"
        )
    }

    @Test("a warn level appends ', warning agreement' — spokenWord, not the raw case name")
    func warnLevel() {
        #expect(
            metricTileAccessibilityLabel(label: "Mean |Diff|", value: "5.0 bpm", level: .warn)
                == "Mean |Diff| 5.0 bpm, warning agreement"
        )
    }

    @Test("a bad level appends ', bad agreement'")
    func badLevel() {
        #expect(
            metricTileAccessibilityLabel(label: "CCC", value: "0.800", level: .bad)
                == "CCC 0.800, bad agreement"
        )
    }

    @Test("every AgreementLevel case is covered by this helper's spokenWord mapping")
    func allCasesProduceAWord() {
        for level in AgreementLevel.allCases {
            let label = metricTileAccessibilityLabel(label: "X", value: "1", level: level)
            #expect(label == "X 1, \(level.spokenWord) agreement")
        }
    }
}
