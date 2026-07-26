import XCTest
@testable import ShannonPill
@testable import PillCore

/// Structural + pure-path checks that notch / menu-bar session UI stays
/// wired to shipped presenters (not a parallel attention system).
final class SessionUIWiringTests: XCTestCase {

    /// Source files that must call the shared presenter / chrome entry points.
    func testShippedUISourcesUseSharedPresenterAndBadge() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ShannonPillTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Pill
            .appendingPathComponent("Sources/ShannonPill", isDirectory: true)

        let files: [(String, [String])] = [
            ("AgentLiveChrome.swift", [
                "AgentLiveSurfaceLogic.badgeLabel",
            ]),
            ("MenuBarAgentRoster.swift", [
                "SessionContentPresenter.cardsFromAgents",
                "card.badgeLabel",
                "rosterDetailLine",
                "showsApproveHint",
                "CompanionEmptyStateCopy.idleTitle",
            ]),
            ("PanelSectionRegistry.swift", [
                "SessionContentPresenter.cards",
                "card.badgeLabel",
                "liveAgentIds",
            ]),
            ("PillView.swift", [
                "SessionContentPresenter.listedSurfaces",
                "SessionContentPresenter.collapsedActiveCount",
                "SessionContentPresenter.collapsedUsageChip",
                "SessionContentPresenter.companionBoardDensity",
                "densityByAgent",
                "usageByAgent",
                "sessionsByAgent",
                "parity.sessionsByAgent",
                "AgentLiveChrome.badgeLabel",
                "metaLine",
                "CompanionEmptyStateCopy.idleTitle",
            ]),
            ("MenuBarPopoverView.swift", [
                "AgentLiveSurfaceLogic.primaryFocus",
                "PulledSessionsSection",
                "liveAgentIds",
                "GateInlineCard",
            ]),
            ("GateAskCard.swift", [
                "GateAskActionCopy",
            ]),
            ("GateInlineCard.swift", [
                "GateAskActionCopy.approve",
                "GateAskActionCopy.deny",
            ]),
        ]

        for (name, needles) in files {
            let url = root.appendingPathComponent(name)
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in needles {
                XCTAssertTrue(
                    text.contains(needle),
                    "\(name) must reference `\(needle)` — dual-HUD / presenter drift risk"
                )
            }
        }
    }

    /// Badge wording for every attention state is identical Chrome ↔ SurfaceLogic.
    func testAllAttentionBadgesShareWordingSource() {
        let cases: [(AgentLiveAttention, AgentToolKind, String, String)] = [
            (.needsYou, .none, "fallback", "needs you"),
            (.working, .none, "fallback", "working"),
            (.working, .edit, "fallback", "edit"),
            (.working, .shell, "fallback", "shell"),
            (.finished, .none, "fallback", "done"),
            (.idle, .none, "fallback", "live"),
            (.unknown, .none, "seen 2m ago", "seen 2m ago"),
        ]
        for (attention, tool, fallback, expected) in cases {
            let surface = AgentLiveSurface(
                agentId: "x",
                displayName: "X",
                attention: attention,
                toolKind: tool,
                activityLine: "line",
                needsYou: attention == .needsYou,
                isFinished: attention == .finished
            )
            let chrome = AgentLiveChrome.badgeLabel(
                surface: surface, fallbackStatusLine: fallback
            )
            let core = AgentLiveSurfaceLogic.badgeLabel(
                surface: surface, fallbackStatusLine: fallback
            )
            XCTAssertEqual(chrome, core, "attention=\(attention)")
            XCTAssertEqual(chrome, expected, "attention=\(attention)")
        }
    }

    /// Collapsed quiet path is the same presenter the pill falls through to.
    func testCollapsedIdleCopyIsShannonIdle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let idle = AgentActivitySnapshot(
            id: "codex",
            displayName: "Codex",
            status: .idle,
            lastTask: "",
            source: "gate",
            updatedAt: now,
            resumable: false,
            historyCount: 0,
            presence: .live
        )
        XCTAssertEqual(
            SessionContentPresenter.collapsedStatusLine(agents: [idle], now: now),
            CompanionFocusCopy.quietFace
        )
    }

    /// UX-017: presenter must not hard-code dual quiet-face string.
    func testCollapsedStatusLineWiresCompanionFocusCopyQuietFace() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PillCore/SessionContentPresenter.swift")
        let text = try String(contentsOf: root, encoding: .utf8)
        XCTAssertTrue(
            text.contains("CompanionFocusCopy.quietFace"),
            "collapsedStatusLine must use CompanionFocusCopy.quietFace"
        )
        XCTAssertFalse(
            text.contains("return \"Shannon · idle\""),
            "presenter must not hard-code dual quiet-face literal"
        )
    }
}
