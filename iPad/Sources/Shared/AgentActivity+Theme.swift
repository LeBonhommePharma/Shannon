import SwiftUI
import ShannonCore
import ShannonTheme

/// Where the model layer meets the design system.
///
/// `ShannonCore` and `ShannonTheme` are deliberately independent — the model
/// package has no views to colour, and making it depend on a presentation
/// package would force headless consumers to link SwiftUI. The mapping between
/// them belongs in the app layer that already imports both, and must agree
/// with the Mac pill's copy of this file.
extension AgentActivity {

    /// The semantic colour that stands for this activity.
    var tint: Color {
        switch self {
        case .running:  return .shannonAccent
        case .idle:     return .shannonNeutral
        case .blocked:  return .shannonWarning
        case .errored:  return .shannonError
        case .finished: return .shannonSuccess
        }
    }

    var dotState: ShannonStatusDot.State {
        switch self {
        case .running:  return .active
        case .idle:     return .neutral
        case .blocked:  return .warning
        case .errored:  return .error
        case .finished: return .success
        }
    }

    /// SF Symbol used in the sidebar and on the card header.
    var symbolName: String {
        switch self {
        case .running:  return "play.circle.fill"
        case .idle:     return "pause.circle"
        case .blocked:  return "questionmark.circle.fill"
        case .errored:  return "exclamationmark.triangle.fill"
        case .finished: return "checkmark.circle.fill"
        }
    }

    /// Activity badge — same tokens as Mac notch (`AgentAttentionCopy` / UX-001).
    var label: String {
        AgentAttentionCopy.activityLabel(for: self)
    }
}
