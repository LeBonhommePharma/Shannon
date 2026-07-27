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
                "gateAvailable: activity.gateAvailable",
                "CompanionEmptyStateCopy.idleTitle",
                "HostTerminalJumpPolicy",
                "HostTerminalJumpExecutor",
                "OpenTerminalHerePolicy",
                "OpenTerminalHereExecutor",
            ]),
            ("PanelSectionRegistry.swift", [
                "SessionContentPresenter.cards",
                "card.badgeLabel",
                "liveAgentIds",
                "HostTerminalJumpInput",
                "onJumpToHost",
                "OpenTerminalHereInput",
                "onOpenTerminalHere",
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
                "HostTerminalJumpPolicy",
                "cwdByAgent",
                "OpenTerminalHerePolicy",
                "OpenTerminalHereExecutor",
            ]),
            ("MenuBarPopoverView.swift", [
                "AgentLiveSurfaceLogic.primaryFocus",
                "PulledSessionsSection",
                "liveAgentIds",
                "GateInlineCard",
                "gateAvailable: activity.gateAvailable",
                "HostTerminalJumpExecutor",
                "onJumpToHost",
                "OpenTerminalHereExecutor",
                "onOpenTerminalHere",
            ]),
            ("GateAskCard.swift", [
                "GateAskActionCopy",
                "macGateAffordance",
                "gateAvailable",
                "changePathsPresentation",
            ]),
            ("GateInlineCard.swift", [
                "GateAskActionCopy",
                "macGateAffordance",
                "gateAvailable",
                "a.canInteract",
                "changePathsPresentation",
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

    /// Spam-only roster must not re-paint raw agents; measured resolve preferred over stale memory.
    func testPillEntropyAttachWiringPrefersMeasuredResolveAndAdmission() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ShannonPillTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Pill
            .appendingPathComponent("Sources/ShannonPill", isDirectory: true)
        let pill = try String(contentsOf: root.appendingPathComponent("PillView.swift"), encoding: .utf8)
        let roster = try String(contentsOf: root.appendingPathComponent("MenuBarAgentRoster.swift"), encoding: .utf8)
        let pop = try String(contentsOf: root.appendingPathComponent("MenuBarPopoverView.swift"), encoding: .utf8)
        let desk = try String(contentsOf: root.appendingPathComponent("DesktopCompanionWindowController.swift"), encoding: .utf8)
        XCTAssertTrue(pill.contains("preferredRowReading"), "PillView strip must prefer measured resolve")
        XCTAssertTrue(pill.contains("LiveRosterAdmission.filterListed"), "PillView fallback must filter admission")
        XCTAssertTrue(
            pill.contains("guard !admitted.isEmpty else { return [] }"),
            "spam-only must empty board"
        )
        XCTAssertTrue(roster.contains("preferredRowReading"), "MenuBarAgentRoster must prefer measured resolve")
        XCTAssertTrue(pop.contains("LiveRosterAdmission.filterListed"), "popover liveAgentIds from admitted")
        XCTAssertTrue(desk.contains("LiveRosterAdmission.filterListed"), "desktop companion liveAgentIds from admitted")
    }

}
