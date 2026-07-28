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
    /// Delegates to ``CollapsedIslandPeek.chromeRole`` + ``AgentNotchChrome`` so
    /// notch + menu-bar attention ink cannot drift (AgentNotch-class dark HUD).
    static func attentionColor(
        surface: AgentLiveSurface,
        styleInk: Color
    ) -> Color {
        let role = CollapsedIslandPeek.chromeRole(for: surface.attention)
        return AgentNotchChrome.ink(for: role, styleInk: styleInk)
    }

    /// Shared dual-HUD badge role for a live surface (roster + island chips).
    static func badgeRole(for surface: AgentLiveSurface) -> AgentNotchChrome.AttentionRole {
        CollapsedIslandPeek.chromeRole(for: surface.attention)
    }

    /// Shared dual-HUD badge role for a session card attention value.
    static func badgeRole(for attention: AgentLiveAttention) -> AgentNotchChrome.AttentionRole {
        CollapsedIslandPeek.chromeRole(for: attention)
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
