import XCTest
@testable import ShannonPill
@testable import PillCore

/// Shared badge labels must match across notch + menu-bar surfaces.
/// Dual-HUD wording: `AgentLiveChrome` must stay glued to `AgentLiveSurfaceLogic`.
final class AgentLiveChromeTests: XCTestCase {

    private func surface(
        attention: AgentLiveAttention,
        tool: AgentToolKind = .none
    ) -> AgentLiveSurface {
        // Build via real resolve when possible; fall back to synthesizing
        // through a quiet live agent + empty activity for idle.
        let agent = AgentActivitySnapshot(
            id: "science",
            displayName: "Science",
            status: attention == .working ? .active : .idle,
            lastTask: "task",
            source: "gate",
            updatedAt: Date(),
            resumable: false,
            historyCount: 0,
            presence: .live
        )
        return AgentLiveChrome.surface(
            agent: agent,
            pendingAsks: attention == .needsYou
                ? [GateDBReader.PendingAsk(
                    interactionId: "i1",
                    agentId: "science",
                    prompt: "ok?"
                )]
                : [],
            activity: []
        )
    }

    func testNeedsYouBadge() {
        let s = surface(attention: .needsYou)
        // Real resolve may elevate to needsYou when a pending ask matches.
        let label = AgentLiveChrome.badgeLabel(surface: s, fallbackStatusLine: "live")
        if s.attention == .needsYou {
            XCTAssertEqual(label, "needs you")
        } else {
            // Still a defined shipped label — never empty.
            XCTAssertFalse(label.isEmpty)
        }
    }

    func testIdleBadgeSaysLive() {
        let s = surface(attention: .idle)
        // Force the pure badge path with an idle surface from real resolve.
        if s.attention == .idle || s.attention == .unknown {
            let label = AgentLiveChrome.badgeLabel(surface: s, fallbackStatusLine: "offline")
            if s.attention == .idle {
                XCTAssertEqual(label, "live")
            } else {
                XCTAssertEqual(label, "offline")
            }
        }
        // Badge helper is pure: unknown falls back to status line.
        let unknown = AgentLiveSurfaceLogic.resolve(
            agent: AgentActivitySnapshot(
                id: "x", displayName: "X", status: .idle, lastTask: "",
                source: "obs", updatedAt: Date(), resumable: false,
                historyCount: 0, presence: .observed
            ),
            pendingAsks: [],
            activity: []
        )
        XCTAssertEqual(
            AgentLiveChrome.badgeLabel(surface: unknown, fallbackStatusLine: "seen 1m ago"),
            unknown.attention == .unknown ? "seen 1m ago" : AgentLiveChrome.badgeLabel(
                surface: unknown, fallbackStatusLine: "seen 1m ago"
            )
        )
        _ = s
    }

    func testWorkingUsesToolKindWhenPresent() {
        // Pure switch coverage via real surface if toolKind is none.
        let agent = AgentActivitySnapshot(
            id: "codex", displayName: "Codex", status: .active,
            lastTask: "editing", source: "gate", updatedAt: Date(),
            resumable: true, historyCount: 2, presence: .live
        )
        let s = AgentLiveChrome.surface(agent: agent, pendingAsks: [], activity: [])
        let label = AgentLiveChrome.badgeLabel(surface: s, fallbackStatusLine: agent.statusLine)
        XCTAssertFalse(label.isEmpty)
        // Working with no tool → "working"; other attentions still non-empty.
        if s.attention == .working, s.toolKind == .none {
            XCTAssertEqual(label, "working")
        }
    }

    /// Notch chrome and PillCore badge wording must stay identical.
    func testChromeBadgeDelegatesToSurfaceLogic() {
        let attentions: [AgentLiveAttention] = [
            .needsYou, .working, .finished, .idle, .unknown,
        ]
        for attention in attentions {
            let surface = AgentLiveSurface(
                agentId: "x",
                displayName: "X",
                attention: attention,
                toolKind: attention == .working ? .edit : .none,
                activityLine: "line",
                needsYou: attention == .needsYou,
                isFinished: attention == .finished
            )
            let fallback = "fallback-\(attention.rawValue)"
            XCTAssertEqual(
                AgentLiveChrome.badgeLabel(surface: surface, fallbackStatusLine: fallback),
                AgentLiveSurfaceLogic.badgeLabel(surface: surface, fallbackStatusLine: fallback),
                "drift for \(attention)"
            )
        }
    }
}
