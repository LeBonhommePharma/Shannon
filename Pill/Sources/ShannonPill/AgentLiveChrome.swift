import SwiftUI
import PillCore
import ShannonTheme

// MARK: - Shared agent live chrome (notch + menu-bar popover)

/// Pure helpers for the live attention capsule shared by `PillView` and
/// `MenuBarPopoverView`. One definition site — both surfaces must agree on
/// "needs you" / "working" / "live" wording so dual-HUD drift cannot reappear.
enum AgentLiveChrome {
    /// Capsule badge text from a resolved live surface.
    static func badgeLabel(
        surface: AgentLiveSurface,
        fallbackStatusLine: String
    ) -> String {
        switch surface.attention {
        case .needsYou: return "needs you"
        case .working: return surface.toolKind == .none ? "working" : surface.toolKind.rawValue
        case .finished: return "done"
        case .idle: return "live"
        case .unknown: return fallbackStatusLine
        }
    }

    /// Capsule ink color for the given attention state.
    static func attentionColor(
        surface: AgentLiveSurface,
        styleInk: Color
    ) -> Color {
        switch surface.attention {
        case .needsYou: return .shannonWarning
        case .working: return styleInk
        case .finished: return .shannonSuccess
        case .idle, .unknown: return styleInk
        }
    }

    /// Resolve the surface used by badge + detail lines (same inputs both HUDs use).
    static func surface(
        agent: AgentActivitySnapshot,
        pendingAsks: [GateDBReader.PendingAsk],
        activity: [GateDBReader.ActivityEvent]
    ) -> AgentLiveSurface {
        AgentLiveSurfaceLogic.resolve(
            agent: agent,
            pendingAsks: pendingAsks,
            activity: activity
        )
    }
}
