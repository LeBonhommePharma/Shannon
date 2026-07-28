import SwiftUI
import PillCore

// MARK: - Shared agent live chrome (notch + menu-bar popover)

/// Pure helpers for the live attention capsule shared by `PillView` and
/// `MenuBarPopoverView`. One definition site — both surfaces must agree on
/// "needs you" / "working" / "live" wording so dual-HUD drift cannot reappear.
enum AgentLiveChrome {
    /// Capsule badge text from a resolved live surface.
    ///
    /// Delegates to `AgentLiveSurfaceLogic.badgeLabel` so notch + menu-bar +
    /// session cards share one wording source (no dual-HUD drift).
    static func badgeLabel(
        surface: AgentLiveSurface,
        fallbackStatusLine: String
    ) -> String {
        AgentLiveSurfaceLogic.badgeLabel(
            surface: surface,
            fallbackStatusLine: fallbackStatusLine
        )
    }

    /// Capsule ink color for the given attention state.
    ///
    /// Delegates to ``AgentNotchChrome`` so notch + menu-bar attention ink
    /// cannot drift from theme roles (AgentNotch-class dark HUD).
    static func attentionColor(
        surface: AgentLiveSurface,
        styleInk: Color
    ) -> Color {
        let role: AgentNotchChrome.AttentionRole
        switch surface.attention {
        case .needsYou: role = .needsYou
        case .working: role = .working
        case .finished: role = .finished
        case .idle: role = .idle
        case .unknown: role = .unknown
        }
        return AgentNotchChrome.ink(for: role, styleInk: styleInk)
    }

    /// Collapse alarm ink (Shannon differentiator — only when measured).
    static var collapseInk: Color {
        AgentNotchChrome.ink(for: .collapse)
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
