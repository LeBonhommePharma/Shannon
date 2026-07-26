import XCTest
@testable import PillCore

/// Product-class parity: AgentNotch + AgentPeek defining session/status outcomes
/// against **shipped** presenters only (no reimplementation).
///
/// Scenarios match the goal verification plan:
/// (a) needs-you ask · (b) working tool line · (c) multi-agent fleet
/// (d) finished/done · (e) idle quiet — optional fields fail-closed.
final class AgentNotchAgentPeekParityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

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
        id: Int64 = 1,
        agent: String = "claude_code",
        type: String,
        label: String,
        age: TimeInterval = 2
    ) -> GateDBReader.ActivityEvent {
        GateDBReader.ActivityEvent(
            id: id,
            agentId: agent,
            at: now.addingTimeInterval(-age),
            type: type,
            label: label,
            output: ""
        )
    }

    private func ask(
        agent: String,
        prompt: String = "Run npm run db:migrate?"
    ) -> GateDBReader.PendingAsk {
        GateDBReader.PendingAsk(
            interactionId: "ask-\(agent)",
            agentId: agent,
            prompt: prompt,
            createdAt: now.addingTimeInterval(-10)
        )
    }

    // MARK: (a) Needs-you — AgentNotch “waiting for your approval”

    func testNeedsYouBeatsWorkingAndOwnsCollapsedFocus() {
        let busy = agent(id: "codex", name: "Codex", status: .midTask, task: "editing")
        let waiting = agent(id: "claude_code", name: "Claude Code", status: .blocked)
        let pending = [ask(agent: "claude_code")]
        let activity = [
            event(agent: "codex", type: "tool_call", label: "Edited store.ts"),
        ]

        let fleet = AgentLiveSurfaceLogic.fleet(
            agents: [busy, waiting],
            pendingAsks: pending,
            activity: activity,
            now: now
        )
        XCTAssertEqual(fleet.first?.agentId, "claude_code")
        XCTAssertEqual(fleet.first?.attention, AgentLiveAttention.needsYou)
        XCTAssertEqual(
            AgentLiveSurfaceLogic.badgeLabel(
                surface: fleet[0], fallbackStatusLine: "x"
            ),
            "needs you"
        )

        let focus = AgentLiveSurfaceLogic.primaryFocus(
            agents: [busy, waiting],
            pendingAsks: pending,
            activity: activity,
            now: now
        )
        XCTAssertEqual(focus, "Needs you · Claude Code")

        let card = SessionContentPresenter.card(
            session: AgentSession(
                id: "g:claude",
                agentId: "claude_code",
                displayName: "Claude Code",
                presence: .live,
                status: .blocked,
                sourceKind: .gate,
                updatedAt: now,
                lastTask: "waiting"
            ),
            pendingAsks: pending,
            activity: activity,
            now: now
        )
        XCTAssertTrue(card.needsYou)
        XCTAssertTrue(card.canAnswerInline)
        XCTAssertEqual(card.pendingPrompt, "Run npm run db:migrate?")
        XCTAssertEqual(card.badgeLabel, "needs you")
    }

    // MARK: (b) Working tool line — AgentNotch live tool / AgentPeek activity

    func testWorkingToolLineIsPresentTenseNotDoubleVerb() {
        let a = agent(id: "claude_code", name: "Claude Code")
        let surface = AgentLiveSurfaceLogic.resolve(
            agent: a,
            activity: [event(type: "tool_call", label: "Edited lib/license/store.ts")],
            now: now
        )
        XCTAssertEqual(surface.attention, AgentLiveAttention.working)
        XCTAssertEqual(surface.toolKind, AgentToolKind.edit)
        XCTAssertTrue(surface.activityLine.hasPrefix("Editing "), surface.activityLine)
        XCTAssertFalse(surface.activityLine.lowercased().contains("editing edited"))
        XCTAssertEqual(
            AgentLiveSurfaceLogic.badgeLabel(surface: surface, fallbackStatusLine: "x"),
            "edit"
        )
        let focus = AgentLiveSurfaceLogic.primaryFocus(
            agents: [a],
            activity: [event(type: "tool_call", label: "Edited lib/license/store.ts")],
            now: now
        )
        XCTAssertNotNil(focus)
        XCTAssertTrue(focus!.contains("Claude Code"), focus!)
        XCTAssertTrue(focus!.contains("Editing") || focus!.contains("store"), focus!)
    }

    // MARK: (c) Multi-agent fleet — both products’ multi-session glance

    func testMultiAgentFleetOrderAndCollapsedDensity() {
        let agents = [
            agent(id: "claude_code", name: "Claude Code", status: .midTask),
            agent(id: "codex", name: "Codex", status: .midTask),
            agent(id: "cursor", name: "Cursor", status: .midTask),
        ]
        let activity = [
            event(id: 1, agent: "claude_code", type: "tool_call", label: "Edited a.swift"),
            event(id: 2, agent: "codex", type: "tool_call", label: "Edited b.ts"),
            event(id: 3, agent: "cursor", type: "tool_call", label: "Edited c.py"),
        ]
        let count = SessionContentPresenter.collapsedActiveCount(
            agents: agents, activity: activity, now: now
        )
        XCTAssertEqual(count, 3)

        let line = SessionContentPresenter.collapsedStatusLine(
            agents: agents, activity: activity, now: now
        )
        // Multi-agent density: "N agents · <activity>" when primary is working.
        XCTAssertTrue(line.hasPrefix("3 agents · ") || line.contains(" · "), line)
        XCTAssertNotEqual(line, CompanionFocusCopy.quietFace)
        XCTAssertFalse(line.isEmpty)

        let cards = SessionContentPresenter.cardsFromAgents(
            agents: agents,
            activity: activity,
            now: now,
            limit: 4
        )
        XCTAssertEqual(cards.count, 3)
        XCTAssertTrue(cards.allSatisfy { $0.attention == AgentLiveAttention.working })
    }

    // MARK: (d) Finished / ready for review — AgentNotch completion

    func testFinishedReadyForReview() {
        let a = agent(
            id: "science", name: "Claude Science",
            status: .idle, presence: .live, task: ""
        )
        let surface = AgentLiveSurfaceLogic.resolve(
            agent: a,
            activity: [event(
                agent: "science",
                type: "task_complete",
                label: "13 passed — ready for review",
                age: 5
            )],
            now: now
        )
        XCTAssertEqual(surface.attention, AgentLiveAttention.finished)
        XCTAssertTrue(surface.isFinished)
        XCTAssertEqual(
            AgentLiveSurfaceLogic.badgeLabel(surface: surface, fallbackStatusLine: "x"),
            "done"
        )
        let focus = AgentLiveSurfaceLogic.primaryFocus(
            agents: [a],
            activity: [event(
                agent: "science",
                type: "task_complete",
                label: "13 passed — ready for review",
                age: 5
            )],
            now: now
        )
        XCTAssertEqual(focus, "Done · Claude Science")
    }

    // MARK: (e) Idle quiet — not a noisy empty dashboard

    func testIdleQuietCollapsedAndNoInventedUsage() {
        let a = agent(
            id: "codex", name: "Codex",
            status: .idle, presence: .live, task: "", age: 5
        )
        XCTAssertNil(
            AgentLiveSurfaceLogic.primaryFocus(agents: [a], activity: [], now: now)
        )
        XCTAssertEqual(
            SessionContentPresenter.collapsedStatusLine(agents: [a], now: now),
            CompanionFocusCopy.quietFace
        )
        XCTAssertNil(SessionContentPresenter.collapsedUsageChip(
            agents: [a],
            usageByAgent: ["codex": AgentUsageSnapshot(tokensUsed: 99)],
            now: now
        ))
        XCTAssertEqual(
            SessionContentPresenter.collapsedActiveCount(agents: [a], now: now),
            0
        )
    }

    // MARK: Optional fields fail-closed (AgentPeek session board density)

    func testOptionalSessionFieldsAppearOnlyWhenSourced() {
        let bare = AgentSession(
            id: "s0", agentId: "codex", displayName: "Codex",
            presence: .observed, status: .idle, sourceKind: .artifact,
            updatedAt: now
        )
        let bareCard = SessionContentPresenter.card(session: bare, now: now)
        XCTAssertNil(bareCard.project)
        XCTAssertNil(bareCard.branch)
        XCTAssertNil(bareCard.model)
        XCTAssertNil(bareCard.usage)
        XCTAssertNil(bareCard.metaLine)

        let rich = AgentSession(
            id: "s1", agentId: "claude_code", displayName: "Claude Code",
            presence: .live, status: .midTask, sourceKind: .artifact,
            updatedAt: now,
            project: "website",
            lastTask: "Wiring",
            model: "Opus",
            branch: "main",
            tokensIn: 1_200,
            tokensOut: 400
        )
        let richCard = SessionContentPresenter.card(
            session: rich,
            activity: [event(agent: "claude_code", type: "tool_call", label: "Edited a")],
            now: now
        )
        XCTAssertEqual(richCard.metaLine, "website · main · Opus")
        XCTAssertEqual(richCard.usage?.tokensUsed, 1_600)
        XCTAssertNotNil(richCard.usageLabel)
        XCTAssertNotNil(richCard.relativeAge)
    }

    // MARK: Dual-HUD badge wording single source

    func testBadgeLabelsUseAgentAttentionCopyTokens() {
        let needs = AgentLiveSurface(
            agentId: "c", displayName: "C", attention: .needsYou,
            activityLine: "x", needsYou: true
        )
        XCTAssertEqual(
            AgentLiveSurfaceLogic.badgeLabel(surface: needs, fallbackStatusLine: "f"),
            AgentAttentionCopy.needsYou
        )
        let working = AgentLiveSurface(
            agentId: "c", displayName: "C", attention: .working,
            toolKind: .none, activityLine: "x"
        )
        XCTAssertEqual(
            AgentLiveSurfaceLogic.badgeLabel(surface: working, fallbackStatusLine: "f"),
            AgentAttentionCopy.working
        )
        let done = AgentLiveSurface(
            agentId: "c", displayName: "C", attention: .finished,
            activityLine: "x", isFinished: true
        )
        XCTAssertEqual(
            AgentLiveSurfaceLogic.badgeLabel(surface: done, fallbackStatusLine: "f"),
            AgentAttentionCopy.done
        )
    }

    // MARK: Usage chip primary-only (never scavenge for density)

    func testUsageChipOnlyFromPrimarySurfaceWhenSourced() {
        let needs = agent(id: "claude_code", name: "Claude Code", status: .blocked)
        let working = agent(id: "codex", name: "Codex", status: .midTask)
        let pending = [ask(agent: "claude_code")]
        let activity = [event(agent: "codex", type: "tool_call", label: "Edited x")]
        // Primary is needs-you without usage → chip nil even if codex has usage.
        XCTAssertNil(SessionContentPresenter.collapsedUsageChip(
            agents: [needs, working],
            pendingAsks: pending,
            activity: activity,
            usageByAgent: ["codex": AgentUsageSnapshot(contextPercent: 42)],
            now: now
        ))
        // Working primary with usage → chip shows.
        let chip = SessionContentPresenter.collapsedUsageChip(
            agents: [working],
            activity: activity,
            usageByAgent: ["codex": AgentUsageSnapshot(contextPercent: 42)],
            now: now
        )
        XCTAssertEqual(chip, "ctx 42%")
    }
}
