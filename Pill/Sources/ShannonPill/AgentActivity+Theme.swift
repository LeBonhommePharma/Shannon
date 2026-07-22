import SwiftUI
import ShannonCore
import ShannonTheme

/// Where the model layer meets the design system.
///
/// `ShannonCore` and `ShannonTheme` are deliberately independent — the model
/// package has no views to colour, and making it depend on a presentation
/// package would force headless consumers to link SwiftUI. The mapping between
/// them belongs here, in the app layer that already imports both.
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

    /// The shared status-dot state, so the Mac pill and the companion apps
    /// signal the same activity with the same dot.
    var dotState: ShannonStatusDot.State {
        switch self {
        case .running:  return .active
        case .idle:     return .neutral
        case .blocked:  return .warning
        case .errored:  return .error
        case .finished: return .success
        }
    }

    /// Whether this activity should light the pill's accent border. Only live
    /// work earns the glow — a finished or idle agent leaves the pill at rest.
    var lightsPillBorder: Bool {
        self == .running
    }
}
