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
}
