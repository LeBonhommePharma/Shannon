import XCTest
@testable import PillCore

/// Proves the **live data path** for notch density: sessions → usage/meta →
/// listed surfaces / collapsed chip. Fails if callers drop `sessionsByAgent`
/// (string-contains wiring tests alone would not catch that).
final class PillSessionDensityPathTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func agent(
        id: String = "claude_code",
        name: String = "Claude Code",
        status: AgentRunStatus = .midTask
    ) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            id: id,
            displayName: name,
            status: status,
            lastTask: "Wiring",
            source: "gate",
            updatedAt: now.addingTimeInterval(-5),
            resumable: true,
            historyCount: 1,
            presence: .live
        )
    }

    private func sessionWithTokens(
        agent: String = "claude_code",
        tokensIn: Int = 1200,
        tokensOut: Int = 400,
        project: String? = "website",
        branch: String? = "main",
        model: String? = "Opus"
    ) -> AgentSession {
        AgentSession(
            id: "art:\(agent)",
            agentId: agent,
            displayName: agent,
            presence: .observed,
            status: .midTask,
            sourceKind: .artifact,
            updatedAt: now,
            project: project,
            lastTask: "from disk",
            model: model,
            branch: branch,
            tokensIn: tokensIn,
            tokensOut: tokensOut
        )
    }

    func testUsageByAgentFromSessionsFailClosed() {
        let empty = SessionContentPresenter.usageByAgent(from: [:])
        XCTAssertTrue(empty.isEmpty)

        let noTokens = AgentSession(
            id: "a", agentId: "codex", displayName: "Codex",
            presence: .observed, status: .idle, sourceKind: .artifact,
            updatedAt: now
        )
        XCTAssertTrue(
            SessionContentPresenter.usageByAgent(from: ["codex": noTokens]).isEmpty
        )

        let with = sessionWithTokens()
        let map = SessionContentPresenter.usageByAgent(from: ["claude_code": with])
        XCTAssertEqual(map["claude_code"]?.tokensUsed, 1_600)
    }

    func testListedSurfacesCarryUsageAndMetaWhenSessionsPresent() {
        let a = agent()
        let sess = sessionWithTokens()
        let activity = [
            GateDBReader.ActivityEvent(
                id: 1, agentId: "claude_code",
                at: now.addingTimeInterval(-2),
                type: "tool_call", label: "Edited store.ts", output: ""
            ),
        ]
        let withSessions = SessionContentPresenter.listedSurfaces(
            agents: [a],
            activity: activity,
            sessionsByAgent: ["claude_code": sess],
            now: now,
            limit: 4
        )
        XCTAssertEqual(withSessions.count, 1)
        XCTAssertNotNil(withSessions[0].surface.usage)
        XCTAssertEqual(withSessions[0].surface.usage?.tokensUsed, 1_600)
        XCTAssertEqual(withSessions[0].metaLine, "website · main · Opus")

        // Drop sessions → usage and meta must vanish (the skeptic's dead path).
        let without = SessionContentPresenter.listedSurfaces(
            agents: [a],
            activity: activity,
            sessionsByAgent: [:],
            now: now,
            limit: 4
        )
        XCTAssertEqual(without.count, 1)
        XCTAssertNil(without[0].surface.usage)
        XCTAssertNil(without[0].metaLine)
    }

    func testCollapsedUsageChipUsesSessionMerge() {
        let a = agent(status: .midTask)
        let activity = [
            GateDBReader.ActivityEvent(
                id: 2, agentId: "claude_code",
                at: now.addingTimeInterval(-2),
                type: "tool_call", label: "Edited x", output: ""
            ),
        ]
        let sess = sessionWithTokens(tokensIn: 50, tokensOut: 10)
        let usage = SessionContentPresenter.usageByAgent(
            from: ["claude_code": sess]
        )

        let chip = SessionContentPresenter.collapsedUsageChip(
            agents: [a],
            activity: activity,
            usageByAgent: usage,
            now: now
        )
        XCTAssertEqual(chip, "60 tok")

        // Empty map → no chip (cannot invent).
        XCTAssertNil(SessionContentPresenter.collapsedUsageChip(
            agents: [a],
            activity: activity,
            usageByAgent: [:],
            now: now
        ))
    }

    func testListedSurfacesMatchesCardsFromAgentsUsage() {
        let a = agent()
        let sess = sessionWithTokens(project: "api", branch: "feat", model: "Sonnet")
        let activity = [
            GateDBReader.ActivityEvent(
                id: 3, agentId: "claude_code",
                at: now.addingTimeInterval(-1),
                type: "tool_call", label: "Read Package.swift", output: ""
            ),
        ]
        let sessions = ["claude_code": sess]
        let listed = SessionContentPresenter.listedSurfaces(
            agents: [a],
            activity: activity,
            sessionsByAgent: sessions,
            now: now
        )
        let cards = SessionContentPresenter.cardsFromAgents(
            agents: [a],
            activity: activity,
            sessionsByAgent: sessions,
            now: now
        )
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(listed[0].surface.usage?.tokensUsed, cards[0].usage?.tokensUsed)
        XCTAssertEqual(listed[0].metaLine, cards[0].metaLine)
        XCTAssertEqual(listed[0].metaLine, "api · feat · Sonnet")
    }

    func testMetaLineHelperIndependentOfAttention() {
        XCTAssertNil(SessionContentPresenter.metaLine(
            agentId: "missing", sessionsByAgent: [:]
        ))
        let s = sessionWithTokens(project: "web", branch: nil, model: "Opus")
        XCTAssertEqual(
            SessionContentPresenter.metaLine(
                agentId: "claude_code",
                sessionsByAgent: ["claude_code": s]
            ),
            "web · Opus"
        )
    }

    /// macOS 14+ CompanionBoardView density must consume the same meta/usage
    /// as listedSurfaces — pure map the board overlays on companion rows.
    func testCompanionBoardDensityFromSessionsMatchesListedSurfaces() {
        let a = agent()
        let sess = sessionWithTokens(
            project: "website", branch: "main", model: "Opus"
        )
        let activity = [
            GateDBReader.ActivityEvent(
                id: 10, agentId: "claude_code",
                at: now.addingTimeInterval(-2),
                type: "tool_call", label: "Edited store.ts", output: ""
            ),
        ]
        let sessions = ["claude_code": sess]
        let listed = SessionContentPresenter.listedSurfaces(
            agents: [a],
            activity: activity,
            sessionsByAgent: sessions,
            now: now
        )
        let fromListed = SessionContentPresenter.companionBoardDensity(from: listed)
        let fromSessions = SessionContentPresenter.companionBoardDensityByAgent(
            sessionsByAgent: sessions
        )

        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(fromListed["claude_code"]?.metaLine, "website · main · Opus")
        XCTAssertEqual(
            fromListed["claude_code"]?.usageLabel,
            listed[0].surface.usage?.shortLabel
        )
        XCTAssertEqual(fromSessions["claude_code"]?.metaLine, fromListed["claude_code"]?.metaLine)
        XCTAssertEqual(fromSessions["claude_code"]?.usageLabel, fromListed["claude_code"]?.usageLabel)
        XCTAssertFalse(fromListed["claude_code"]?.isEmpty ?? true)

        // Drop sessions → board density must vanish (fail-closed).
        let empty = SessionContentPresenter.companionBoardDensity(
            from: SessionContentPresenter.listedSurfaces(
                agents: [a],
                activity: activity,
                sessionsByAgent: [:],
                now: now
            )
        )
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(
            SessionContentPresenter.companionBoardDensityByAgent(sessionsByAgent: [:]).isEmpty
        )
    }

    /// Structural: CompanionBoardView + CompanionRow accept density; PillView
    /// passes companionBoardDensity from listedAgentSurfaces on the macOS 14 path.
    func testCompanionBoardUISourcesConsumeDensity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PillCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Pill

        let pet = try String(
            contentsOf: root
                .appendingPathComponent("Sources/PillCore/PetPillView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(pet.contains("density: CompanionBoardDensity"),
                      "CompanionRow must accept CompanionBoardDensity")
        XCTAssertTrue(pet.contains("densityByAgent"),
                      "CompanionBoardView must take densityByAgent")
        XCTAssertTrue(pet.contains("density.metaLine"),
                      "CompanionRow must render density.metaLine")
        XCTAssertTrue(pet.contains("density.usageLabel"),
                      "CompanionRow must render density.usageLabel")
        XCTAssertTrue(
            pet.contains("density: densityByAgent[state.id]"),
            "CompanionBoardView must pass densityByAgent into CompanionRow"
        )

        let pill = try String(
            contentsOf: root
                .appendingPathComponent("Sources/ShannonPill/PillView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            pill.contains("densityByAgent: SessionContentPresenter.companionBoardDensity"),
            "PillView macOS 14 path must pass companionBoardDensity into CompanionBoardView"
        )
        XCTAssertTrue(
            pill.contains("from: listedAgentSurfaces"),
            "Companion board density must come from listedAgentSurfaces (same as agentRow)"
        )
    }
}
