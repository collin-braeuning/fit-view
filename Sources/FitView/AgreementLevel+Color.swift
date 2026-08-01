import FitViewCore
import SwiftUI

extension AgreementLevel {
    var color: Color {
        switch self {
        case .good: .green
        case .warn: .orange
        case .bad: .red
        }
    }

    /// A non-color signal for the same level — color alone doesn't work for
    /// color-vision deficiency, and this app already uses green/orange/red
    /// for exactly this scale, so a shape carries the distinction redundantly.
    var symbolName: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        }
    }

    /// Spoken word for VoiceOver, independent of `AgreementLevel`'s raw
    /// value (which is a lowercase API name, not prose).
    var spokenWord: String {
        switch self {
        case .good: "good"
        case .warn: "warning"
        case .bad: "bad"
        }
    }
}
