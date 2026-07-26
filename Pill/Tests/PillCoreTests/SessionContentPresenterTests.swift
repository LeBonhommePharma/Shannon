import XCTest
@testable import PillCore

/// AgentNotch-class session content + collapsed status — pure assembly only.
final class SessionContentPresenterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSession(
        id: String,
        agent: String,
        name: String? = nil,
        presence: AgentPresence = .live,
        status: AgentRunStatus = .idle,
        source: SessionSourceKind = .gate,
        task: String? = nil,
        project: String? = nil,
        branch: String? = nil,
        model: String? = nil,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        age: TimeInterval = 5
    ) -> AgentSession {
        AgentSession(
            id: id,
            agentId: agent,
            displayName: name ?? agent,
            presence: presence,
            status: status,
            sourceKind: source,
            updatedAt: now.addingTimeInterval(-age),
            project: project,
            lastTask: task,
            model: model,
            branch: branch,
            tokensIn: tokensIn,
            tokensOut: tokensOut
        )
    }

    private func agent(
        id: String,
        name: String,
        status: AgentRunStatus = .midTask,
        presence: AgentPresence = .live,
        task: String = "",
        age: TimeInterval = 5
    ) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            id: id,
            displayName: name,
            status: status,
            lastTask: task,
            source: "gate",
            updatedAt: now.addingTimeInterval(-age),
            resumable: true,
            historyCount: 1,
            presence: presence
        )
    }

    private func event(
        agent: String,
        type: String,
        label: String,
        age: TimeInterval = 2
    ) -> GateDBReader.ActivityEvent {
        GateDBReader.ActivityEvent(
            id: Int64(label.hashValue),
            agentId: agent,
            at: now.addingTimeInterval(-age),
            type: type,
            label: label,
            output: ""
        )
    }

    // MARK: - Prioritization (needs-you → working → done → idle)

    func testCardsOrderNeedsYouThenWorkingThenFinishedThenIdle() {
        let needs = makeSession(
            id: "g:claude", agent: "claude_code", name: "Claude Code",
            status: .blocked, task: "waiting"
        )
        let working = makeSession(
            id: "g:codex", agent: "codex", name: "Codex",
            status: .midTask, task: "editing"
        )
        let finished = makeSession(
            id: "g:science", agent: "science", name: "Claude Science",
            status: .idle, task: "done"
        )
        let idle = makeSession(
            id: "g:design", agent: "design", name: "Claude Design",
            presence: .live, status: .idle, task: "quiet"
        )
        let ask = GateDBReader.PendingAsk(
            interactionId: "ask-1",
            agentId: "claude_code",
            prompt: "Run npm run db:migrate?",
            createdAt: now.addingTimeInterval(-10)
        )
        let activity = [
            event(agent: "codex", type: "tool_call", label: "Edited store.ts"),
            event(agent: "science", type: "task_complete",
                  label: "13 passed — ready for review", age: 8),
        ]
        let cards: [SessionContentCard] = SessionContentPresenter.cards(
            sessions: [idle, finished, working, needs],
            pendingAsks: [ask],
            activity: activity,
            now: now,
            limit: 8
        )
        XCTAssertEqual(cards.map(\.agentId), [
            "claude_code", "codex", "science", "design",
        ])
        XCTAssertEqual(cards[0].attention, AgentLiveAttention.needsYou)
        XCTAssertEqual(cards[0].badgeLabel, "needs you")
        XCTAssertTrue(cards[0].needsYou)
        XCTAssertEqual(cards[0].canAnswerInline, true)
        XCTAssertEqual(cards[0].pendingPrompt, "Run npm run db:migrate?")
        XCTAssertEqual(cards[1].attention, AgentLiveAttention.working)
        XCTAssertEqual(cards[2].attention, AgentLiveAttention.finished)
        XCTAssertEqual(cards[2].badgeLabel, "done")
        XCTAssertEqual(cards[3].attention, AgentLiveAttention.idle)
    }

    // MARK: - Optional fields fail-closed

    func testOptionalFieldsAbsentWhenMissing() {
        let s = makeSession(id: "a", agent: "codex", name: "Codex", task: "hello")
        let card = SessionContentPresenter.card(session: s, now: now)
        XCTAssertNil(card.project)
        XCTAssertNil(card.branch)
        XCTAssertNil(card.model)
        XCTAssertNil(card.usage)
        XCTAssertNil(card.metaLine)
        XCTAssertNil(card.usageLabel)
        XCTAssertEqual(card.activityLine.isEmpty, false)
        XCTAssertNotNil(card.relativeAge)
    }

    func testOptionalFieldsAppearWhenSourced() {
        let s = makeSession(
            id: "s1",
            agent: "claude_code",
            name: "Claude Code",
            status: .midTask,
            task: "Wiring claim endpoint",
            project: "website",
            branch: "main",
            model: "Opus",
            tokensIn: 1_200,
            tokensOut: 400
        )
        let card = SessionContentPresenter.card(
            session: s,
            activity: [event(agent: "claude_code", type: "tool_call", label: "Edited store.ts")],
            now: now
        )
        XCTAssertEqual(card.project, "website")
        XCTAssertEqual(card.branch, "main")
        XCTAssertEqual(card.model, "Opus")
        XCTAssertEqual(card.metaLine, "website · main · Opus")
        XCTAssertEqual(card.metaChips, ["website", "main", "Opus"])
        XCTAssertNotNil(card.usage)
        XCTAssertEqual(card.usage?.tokensUsed, 1_600)
        XCTAssertEqual(card.usageLabel, "1600 tok")
        XCTAssertEqual(card.attention, AgentLiveAttention.working)
    }

    func testEmptyStringsDoNotBecomeChips() {
        let s = AgentSession(
            id: "e",
            agentId: "codex",
            displayName: "Codex",
            presence: .observed,
            status: .idle,
            sourceKind: .artifact,
            updatedAt: now,
            project: "  ",
            model: "",
            branch: nil
        )
        let card = SessionContentPresenter.card(session: s, now: now)
        XCTAssertNil(card.project)
        XCTAssertNil(card.branch)
        XCTAssertNil(card.model)
        XCTAssertNil(card.metaLine)
    }

    func testUsageFromSessionFailClosed() {
        XCTAssertNil(SessionContentPresenter.usageFromSession(
            makeSession(id: "x", agent: "codex")
        ))
        let withTokens = makeSession(id: "y", agent: "codex", tokensIn: 10, tokensOut: 5)
        XCTAssertEqual(
            SessionContentPresenter.usageFromSession(withTokens)?.tokensUsed,
            15
        )
    }

    // MARK: - Collapsed status / fleet density

    func testCollapsedStatusNeedsYou() {
        let a = agent(id: "claude_code", name: "Claude Code", status: .midTask)
        let ask = GateDBReader.PendingAsk(
            interactionId: "i",
            agentId: "claude_code",
            prompt: "Approve?",
            createdAt: now
        )
        let line = SessionContentPresenter.collapsedStatusLine(
            agents: [a],
            pendingAsks: [ask],
            now: now
        )
        XCTAssertEqual(line, "Needs you · Claude Code")
    }

    func testCollapsedStatusIdleIsQuiet() {
        let a = agent(id: "codex", name: "Codex", status: .idle, presence: .live, task: "")
        let line = SessionContentPresenter.collapsedStatusLine(agents: [a], now: now)
        XCTAssertEqual(line, "Shannon · idle")
    }

    func testCollapsedActiveCountAndUsageChip() {
        let claude = agent(id: "claude_code", name: "Claude Code", status: .midTask)
        let codex = agent(id: "codex", name: "Codex", status: .midTask, task: "tests")
        let idle = agent(id: "design", name: "Design", status: .idle, presence: .live)
        let activity = [
            event(agent: "claude_code", type: "tool_call", label: "Edited a.swift"),
            event(agent: "codex", type: "tool_call", label: "Ran npm test"),
        ]
        let count = SessionContentPresenter.collapsedActiveCount(
            agents: [claude, codex, idle],
            activity: activity,
            now: now
        )
        XCTAssertEqual(count, 2)

        let usageBy = [
            "claude_code": AgentUsageSnapshot(contextPercent: 22),
        ]
        let chip = SessionContentPresenter.collapsedUsageChip(
            agents: [claude, codex],
            activity: activity,
            usageByAgent: usageBy,
            now: now
        )
        XCTAssertEqual(chip, "ctx 22%")

        // No invented usage when map empty.
        XCTAssertNil(SessionContentPresenter.collapsedUsageChip(
            agents: [claude],
            activity: activity,
            now: now
        ))
    }

    func testCollapsedUsageHiddenWhenIdle() {
        let a = agent(id: "codex", name: "Codex", status: .idle, presence: .live)
        XCTAssertNil(SessionContentPresenter.collapsedUsageChip(
            agents: [a],
            usageByAgent: ["codex": AgentUsageSnapshot(tokensUsed: 99)],
            now: now
        ))
    }

    // MARK: - Badge wording shared with AgentLiveSurfaceLogic

    func testBadgeLabelMatchesSurfaceLogic() {
        let a = agent(id: "claude_code", name: "Claude Code")
        let ask = GateDBReader.PendingAsk(
            interactionId: "x", agentId: "claude_code",
            prompt: "Run?", createdAt: now
        )
        let surface = AgentLiveSurfaceLogic.resolve(
            agent: a, pendingAsks: [ask], now: now
        )
        let card = SessionContentPresenter.card(
            session: makeSession(
                id: "g:claude", agent: "claude_code", name: "Claude Code",
                status: .blocked
            ),
            pendingAsks: [ask],
            now: now
        )
        XCTAssertEqual(
            card.badgeLabel,
            AgentLiveSurfaceLogic.badgeLabel(surface: surface, fallbackStatusLine: "x")
        )
        XCTAssertEqual(card.badgeLabel, "needs you")
    }

    // MARK: - cardsFromAgents ranking

    func testCardsFromAgentsRanksNeedsYouFirst() {
        let working = agent(id: "codex", name: "Codex", status: .midTask, task: "build")
        let needs = agent(id: "claude_code", name: "Claude Code", status: .idle, presence: .live)
        let ask = GateDBReader.PendingAsk(
            interactionId: "a1", agentId: "claude_code",
            prompt: "Approve deploy?", createdAt: now
        )
        let cards = SessionContentPresenter.cardsFromAgents(
            agents: [working, needs],
            pendingAsks: [ask],
            activity: [event(agent: "codex", type: "tool_call", label: "Edited foo")],
            now: now,
            limit: 4
        )
        XCTAssertEqual(cards.first?.agentId, "claude_code")
        XCTAssertEqual(cards.first?.attention, .needsYou)
        XCTAssertTrue(cards.first?.canAnswerInline == true)
    }

    func testCardsFromAgentsAttachSessionMeta() {
        let a = agent(id: "claude_code", name: "Claude Code", status: .midTask)
        let sess = makeSession(
            id: "art:1", agent: "claude_code", name: "Claude Code",
            status: .midTask, source: .artifact,
            task: "from disk", project: "api", branch: "feat/hud", model: "Sonnet"
        )
        let cards = SessionContentPresenter.cardsFromAgents(
            agents: [a],
            activity: [event(agent: "claude_code", type: "tool_call", label: "Read Package.swift")],
            sessionsByAgent: ["claude_code": sess],
            now: now,
            limit: 2
        )
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].project, "api")
        XCTAssertEqual(cards[0].branch, "feat/hud")
        XCTAssertEqual(cards[0].model, "Sonnet")
        XCTAssertEqual(cards[0].metaLine, "api · feat/hud · Sonnet")
    }

    // MARK: - ENH-005: hide pulled rows for live roster agents

    func testSessionsExcludingLiveAgentsDropsMatchingIds() {
        let live = makeSession(
            id: "art:claude", agent: "claude_code", source: .artifact, task: "disk"
        )
        let other = makeSession(
            id: "art:codex", agent: "codex", source: .artifact, task: "other disk"
        )
        let filtered = SessionContentPresenter.sessionsExcludingLiveAgents(
            [live, other],
            liveAgentIds: ["claude_code"]
        )
        XCTAssertEqual(filtered.map(\.agentId), ["codex"])
    }

    func testSessionsExcludingLiveAgentsEmptySetKeepsAll() {
        let s = makeSession(id: "art:1", agent: "claude_code", source: .artifact)
        let filtered = SessionContentPresenter.sessionsExcludingLiveAgents(
            [s],
            liveAgentIds: []
        )
        XCTAssertEqual(filtered.count, 1)
    }

    func testCardsHidePulledWhenAgentOnLiveRoster() {
        let claudeArt = makeSession(
            id: "art:c", agent: "claude_code", name: "Claude Code",
            source: .artifact, task: "old transcript"
        )
        let codexArt = makeSession(
            id: "art:x", agent: "codex", name: "Codex",
            source: .artifact, task: "cold session"
        )
        let cards = SessionContentPresenter.cards(
            sessions: [claudeArt, codexArt],
            now: now,
            limit: 5,
            liveAgentIds: ["claude_code"]
        )
        XCTAssertEqual(cards.map(\.agentId), ["codex"])
        // All live → pulled section empty.
        let none = SessionContentPresenter.cards(
            sessions: [claudeArt],
            now: now,
            liveAgentIds: ["claude_code"]
        )
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - Working tool line scenario

    func testWorkingToolLineCard() {
        let s = makeSession(
            id: "g:c", agent: "claude_code", name: "Claude Code",
            status: .midTask, task: "Wiring"
        )
        let card = SessionContentPresenter.card(
            session: s,
            activity: [event(agent: "claude_code", type: "tool_call",
                             label: "Edited lib/license/store.ts")],
            now: now
        )
        XCTAssertEqual(card.attention, .working)
        XCTAssertTrue(card.activityLine.lowercased().contains("edit")
                      || card.activityLine.contains("store"), card.activityLine)
        XCTAssertTrue(card.collapsedFocus.contains("Claude Code"))
    }

    // MARK: - Multi-agent busy fleet

    func testMultiAgentFleetCollapsedCount() {
        let agents = [
            agent(id: "claude_code", name: "Claude Code", status: .midTask),
            agent(id: "codex", name: "Codex", status: .midTask),
            agent(id: "cursor", name: "Cursor", status: .midTask),
        ]
        let activity = [
            event(agent: "claude_code", type: "tool_call", label: "Edited a"),
            event(agent: "codex", type: "tool_call", label: "Edited b"),
            event(agent: "cursor", type: "tool_call", label: "Edited c"),
        ]
        XCTAssertEqual(
            SessionContentPresenter.collapsedActiveCount(
                agents: agents, activity: activity, now: now
            ),
            3
        )
        let focus = SessionContentPresenter.collapsedStatusLine(
            agents: agents, activity: activity, now: now
        )
        // Primary is one working agent line, not a noisy empty dashboard.
        XCTAssertFalse(focus.isEmpty)
        XCTAssertNotEqual(focus, "Shannon · idle")
        XCTAssertTrue(focus.contains("·"), focus)
    }

    // MARK: - Finished + idle fixtures from plan scenarios

    func testFinishedAndIdleFixtures() {
        let done = makeSession(
            id: "g:s", agent: "science", name: "Claude Science",
            status: .idle, task: "review"
        )
        let doneCard = SessionContentPresenter.card(
            session: done,
            activity: [event(agent: "science", type: "task_complete",
                             label: "ready for review", age: 5)],
            now: now
        )
        XCTAssertEqual(doneCard.attention, AgentLiveAttention.finished)
        XCTAssertEqual(doneCard.badgeLabel, "done")
        XCTAssertTrue(doneCard.isFinished)

        let quiet = makeSession(
            id: "g:d", agent: "design", name: "Claude Design",
            presence: .offline, status: .idle, task: "", age: 3600
        )
        let quietCard = SessionContentPresenter.card(session: quiet, now: now)
        XCTAssertTrue(
            quietCard.attention == AgentLiveAttention.unknown
                || quietCard.attention == AgentLiveAttention.idle,
            "\(quietCard.attention)"
        )
        XCTAssertNil(quietCard.usage)
        XCTAssertNil(quietCard.project)
    }

    // MARK: - Approval affordance honesty

    func testCanAnswerInlineOnlyWhenAskMatchesAgent() {
        let s = makeSession(
            id: "g:c", agent: "claude_code", name: "Claude Code",
            status: .midTask, task: "work"
        )
        let foreignAsk = GateDBReader.PendingAsk(
            interactionId: "other",
            agentId: "codex",
            prompt: "Approve codex?",
            createdAt: now
        )
        let noMatch = SessionContentPresenter.card(
            session: s, pendingAsks: [foreignAsk], now: now
        )
        // Working without a matching ask — never claim inline answer.
        XCTAssertFalse(noMatch.canAnswerInline)
        XCTAssertNil(noMatch.pendingPrompt)

        let ownAsk = GateDBReader.PendingAsk(
            interactionId: "own",
            agentId: "claude_code",
            prompt: "Run migrate?",
            createdAt: now
        )
        let matched = SessionContentPresenter.card(
            session: s, pendingAsks: [ownAsk], now: now
        )
        XCTAssertTrue(matched.needsYou)
        XCTAssertTrue(matched.canAnswerInline)
        XCTAssertEqual(matched.pendingPrompt, "Run migrate?")
    }

    func testPrimarySurfaceNilWhenOnlyIdle() {
        let a = agent(id: "codex", name: "Codex", status: .idle, presence: .live, task: "")
        XCTAssertNil(
            AgentLiveSurfaceLogic.primarySurface(agents: [a], now: now)
        )
        XCTAssertEqual(
            SessionContentPresenter.collapsedStatusLine(agents: [a], now: now),
            "Shannon · idle"
        )
    }

    func testUsageZeroTokensStayAbsent() {
        // tokensIn=0 alone must not invent a usage chip.
        let s = makeSession(id: "z", agent: "codex", tokensIn: 0, tokensOut: 0)
        XCTAssertNil(SessionContentPresenter.usageFromSession(s))
        let card = SessionContentPresenter.card(session: s, now: now)
        XCTAssertNil(card.usage)
        XCTAssertNil(card.usageLabel)
    }

    func testCardsLimitAndDropsNoise() {
        let many = (0..<6).map { i in
            makeSession(
                id: "g:\(i)", agent: "agent_\(i)", name: "A\(i)",
                presence: .observed, status: .idle, task: "", age: Double(i + 1)
            )
        }
        let limited = SessionContentPresenter.cards(sessions: many, now: now, limit: 2)
        XCTAssertEqual(limited.count, 2)
        XCTAssertEqual(
            SessionContentPresenter.cards(sessions: [], now: now, limit: 8).count,
            0
        )
    }
}
