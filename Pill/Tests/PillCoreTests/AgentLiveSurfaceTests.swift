import XCTest
@testable import PillCore

/// Clean-room AgentNotch-class live surface — pure classification only.
final class AgentLiveSurfaceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func agent(
        id: String = "claude_code",
        name: String = "Claude Code",
        status: AgentRunStatus = .midTask,
        presence: AgentPresence = .live,
        task: String = "Wiring license claim",
        secondsAgo: TimeInterval = 5
    ) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            id: id,
            displayName: name,
            status: status,
            lastTask: task,
            source: "gate",
            updatedAt: now.addingTimeInterval(-secondsAgo),
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
        secondsAgo: TimeInterval = 2
    ) -> GateDBReader.ActivityEvent {
        GateDBReader.ActivityEvent(
            id: id,
            agentId: agent,
            at: now.addingTimeInterval(-secondsAgo),
            type: type,
            label: label,
            output: ""
        )
    }

    // MARK: Needs you

    func testNeedsYouBeatsWorking() {
        let a = agent(status: .midTask)
        let ask = GateDBReader.PendingAsk(
            interactionId: "i1",
            agentId: "claude_code",
            prompt: "Run npm run db:migrate?",
            createdAt: now.addingTimeInterval(-10)
        )
        let surface = AgentLiveSurfaceLogic.resolve(
            agent: a,
            pendingAsks: [ask],
            activity: [event(type: "tool_call", label: "Edited store.ts")],
            now: now
        )
        XCTAssertEqual(surface.attention, AgentLiveAttention.needsYou)
        XCTAssertTrue(surface.needsYou)
        XCTAssertTrue(surface.activityLine.contains("migrate") || surface.activityLine.contains("Waiting"))
        XCTAssertTrue(surface.collapsedFocus.hasPrefix("Needs you"))
    }

    // MARK: Working / tools

    func testWorkingEditToolLine() {
        let a = agent()
        let surface = AgentLiveSurfaceLogic.resolve(
            agent: a,
            activity: [event(type: "tool_call", label: "Edited lib/license/store.ts")],
            now: now
        )
        XCTAssertEqual(surface.attention, .working)
        XCTAssertEqual(surface.toolKind, .edit)
        XCTAssertTrue(surface.activityLine.lowercased().contains("edit"), surface.activityLine)
    }

    func testWorkingReadAndShellClassification() {
        XCTAssertEqual(
            AgentLiveSurfaceLogic.toolKindFromBlob("read Package.swift"),
            .read
        )
        XCTAssertEqual(
            AgentLiveSurfaceLogic.toolKindFromBlob("Ran npm test (42 passed)"),
            .test
        )
        XCTAssertEqual(
            AgentLiveSurfaceLogic.toolKindFromBlob("bash cargo build"),
            .shell
        )
    }

    func testFailClosedWhenNoLiveSignal() {
        let a = agent(
            status: .idle,
            presence: .offline,
            task: "",
            secondsAgo: 3600
        )
        let surface = AgentLiveSurfaceLogic.resolve(agent: a, now: now)
        XCTAssertEqual(surface.attention, .unknown)
        XCTAssertEqual(surface.toolKind, .none)
        XCTAssertTrue(surface.activityLine.isEmpty)
        XCTAssertNil(surface.usage)
    }

    // MARK: Completion

    func testFinishedFromTaskCompleteEvent() {
        let a = agent(status: .idle, presence: .live, task: "", secondsAgo: 30)
        let surface = AgentLiveSurfaceLogic.resolve(
            agent: a,
            activity: [event(type: "task_complete", label: "13 passed — ready for review", secondsAgo: 10)],
            now: now
        )
        XCTAssertEqual(surface.attention, .finished)
        XCTAssertTrue(surface.isFinished)
    }

    // MARK: Fleet multi-agent identity

    func testFleetKeepsClaudeAndCodexDistinctAndOrdersNeedsYouFirst() {
        let claude = agent(id: "claude_code", name: "Claude Code", status: .midTask)
        let codex = agent(id: "codex", name: "Codex", status: .idle, presence: .live, task: "")
        let ask = GateDBReader.PendingAsk(
            interactionId: "ask1",
            agentId: "claude_code",
            prompt: "Approve deploy?",
            createdAt: now
        )
        let fleet = AgentLiveSurfaceLogic.fleet(
            agents: [codex, claude],
            pendingAsks: [ask],
            activity: [
                event(id: 2, agent: "codex", type: "task_complete", label: "ready for review", secondsAgo: 5),
            ],
            now: now,
            limit: 4
        )
        XCTAssertEqual(fleet.count, 2)
        XCTAssertEqual(fleet[0].agentId, "claude_code")
        XCTAssertEqual(fleet[0].attention, AgentLiveAttention.needsYou)
        XCTAssertEqual(fleet[1].agentId, "codex")
        XCTAssertNotEqual(fleet[0].agentId, fleet[1].agentId)
    }

    // MARK: Usage fail-closed

    func testUsageHiddenWhenEmpty() {
        let a = agent()
        let empty = AgentUsageSnapshot()
        let surface = AgentLiveSurfaceLogic.resolve(
            agent: a,
            usage: empty,
            now: now
        )
        XCTAssertNil(surface.usage)
        XCTAssertNil(AgentLiveSurfaceLogic.usageIfReal(empty))
    }

    func testUsageShownWhenReal() {
        let usage = AgentUsageSnapshot(tokensUsed: 1200, tokensLimit: 200_000, contextPercent: 22)
        XCTAssertTrue(usage.hasAny)
        XCTAssertEqual(usage.shortLabel, "ctx 22%")
        let a = agent()
        let surface = AgentLiveSurfaceLogic.resolve(agent: a, usage: usage, now: now)
        XCTAssertNotNil(surface.usage)
        XCTAssertEqual(surface.usage?.contextPercent, 22)
    }

    func testPrimaryFocusNeedsYou() {
        let a = agent()
        let ask = GateDBReader.PendingAsk(
            interactionId: "x",
            agentId: "claude_code",
            prompt: "Run migrate?",
            createdAt: now
        )
        let line = AgentLiveSurfaceLogic.primaryFocus(
            agents: [a],
            pendingAsks: [ask],
            now: now
        )
        XCTAssertEqual(line, "Needs you · Claude Code")
    }

    func testPrimaryFocusIdleDoesNotSuppressHubScanLine() {
        // Quiet live agents must not own the collapsed subtitle — HubScanLine
        // ("Hub ready · …") stays visible when nothing actionable is happening.
        let a = agent(status: .idle, presence: .live, task: "idle task", secondsAgo: 5)
        let line = AgentLiveSurfaceLogic.primaryFocus(
            agents: [a],
            activity: [],
            now: now
        )
        XCTAssertNil(line)
    }

    func testTaskCompleteBeatsStaleMidTaskBusy() {
        // Gate left status=midTask but latest event is task_complete → finished.
        let a = agent(status: .midTask, presence: .live, task: "still showing busy")
        let surface = AgentLiveSurfaceLogic.resolve(
            agent: a,
            activity: [event(type: "task_complete", label: "13 passed — ready for review", secondsAgo: 5)],
            now: now
        )
        XCTAssertEqual(surface.attention, .finished)
        XCTAssertTrue(surface.isFinished)
        XCTAssertFalse(surface.needsYou)
    }

    func testLiveWorkLineStripsDoubleVerbPrefix() {
        let a = agent()
        let surface = AgentLiveSurfaceLogic.resolve(
            agent: a,
            activity: [event(type: "tool_call", label: "Edited lib/license/store.ts")],
            now: now
        )
        XCTAssertEqual(surface.attention, .working)
        XCTAssertEqual(surface.toolKind, .edit)
        // Must be "Editing …store.ts", never "Editing Edited …".
        XCTAssertFalse(
            surface.activityLine.lowercased().contains("editing edited"),
            surface.activityLine
        )
        XCTAssertTrue(surface.activityLine.hasPrefix("Editing "), surface.activityLine)
        XCTAssertTrue(surface.activityLine.contains("store.ts"), surface.activityLine)
    }

    func testStripLeadingToolVerb() {
        XCTAssertEqual(
            AgentLiveSurfaceLogic.stripLeadingToolVerb("Edited store.ts"),
            "store.ts"
        )
        XCTAssertEqual(
            AgentLiveSurfaceLogic.stripLeadingToolVerb("Reading Package.swift"),
            "Package.swift"
        )
        XCTAssertEqual(
            AgentLiveSurfaceLogic.stripLeadingToolVerb("store.ts"),
            "store.ts"
        )
    }

    // MARK: Claude Design first-class identity

    func testClaudeDesignNeedsYouAndWorkingSurface() {
        let design = agent(
            id: "design",
            name: "Claude Design",
            status: .midTask,
            presence: .live,
            task: "Artboard polish"
        )
        let ask = GateDBReader.PendingAsk(
            interactionId: "d1",
            agentId: "design",
            prompt: "Export canvas as PDF?",
            createdAt: now.addingTimeInterval(-3)
        )
        let needs = AgentLiveSurfaceLogic.resolve(
            agent: design,
            pendingAsks: [ask],
            activity: [event(id: 9, agent: "design", type: "tool_call", label: "Edited poster.svg")],
            now: now
        )
        XCTAssertEqual(needs.agentId, "design")
        XCTAssertEqual(needs.displayName, "Claude Design")
        XCTAssertEqual(needs.attention, .needsYou)
        XCTAssertEqual(
            AgentLiveSurfaceLogic.primaryFocus(
                agents: [design],
                pendingAsks: [ask],
                activity: [event(id: 9, agent: "design", type: "tool_call", label: "Edited poster.svg")],
                now: now
            ),
            "Needs you · Claude Design"
        )

        let working = AgentLiveSurfaceLogic.resolve(
            agent: design,
            activity: [event(id: 10, agent: "design", type: "tool_call", label: "Edited poster.svg")],
            now: now
        )
        XCTAssertEqual(working.attention, .working)
        XCTAssertEqual(working.toolKind, .edit)
        XCTAssertTrue(working.activityLine.hasPrefix("Editing "), working.activityLine)
        XCTAssertFalse(working.activityLine.lowercased().contains("editing edited"))
    }

    func testFleetKeepsClaudeDesignDistinctFromClaudeCode() {
        let code = agent(id: "claude_code", name: "Claude Code", status: .midTask)
        let design = agent(
            id: "design", name: "Claude Design", status: .idle, presence: .live, task: ""
        )
        let fleet = AgentLiveSurfaceLogic.fleet(
            agents: [code, design],
            activity: [
                event(id: 1, agent: "design", type: "task_complete",
                      label: "mockups ready for review", secondsAgo: 4),
                event(id: 2, agent: "claude_code", type: "tool_call",
                      label: "Edited main.swift", secondsAgo: 2),
            ],
            now: now,
            limit: 4
        )
        XCTAssertEqual(fleet.count, 2)
        // Working Code ranks above finished Design.
        XCTAssertEqual(fleet[0].agentId, "claude_code")
        XCTAssertEqual(fleet[0].attention, .working)
        XCTAssertEqual(fleet[1].agentId, "design")
        XCTAssertEqual(fleet[1].attention, .finished)
        XCTAssertEqual(fleet[1].displayName, "Claude Design")
        XCTAssertNotEqual(fleet[0].agentId, fleet[1].agentId)
    }

    func testStaleActivityDoesNotForceWorkingWithoutBusy() {
        let a = agent(status: .idle, presence: .live, task: "old", secondsAgo: 5)
        let surface = AgentLiveSurfaceLogic.resolve(
            agent: a,
            activity: [event(type: "tool_call", label: "Edited foo", secondsAgo: 500)],
            now: now
        )
        // Live idle, not working on stale edit.
        XCTAssertEqual(surface.attention, .idle)
    }

    // MARK: Shared badge + ranked agents

    func testBadgeLabelSharedWording() {
        let needs = AgentLiveSurface(
            agentId: "c", displayName: "Claude", attention: .needsYou, activityLine: "x", needsYou: true
        )
        XCTAssertEqual(
            AgentLiveSurfaceLogic.badgeLabel(surface: needs, fallbackStatusLine: "f"),
            "needs you"
        )
        let working = AgentLiveSurface(
            agentId: "c", displayName: "Claude", attention: .working,
            toolKind: .edit, activityLine: "Editing a"
        )
        XCTAssertEqual(
            AgentLiveSurfaceLogic.badgeLabel(surface: working, fallbackStatusLine: "f"),
            "edit"
        )
        let done = AgentLiveSurface(
            agentId: "c", displayName: "Claude", attention: .finished,
            activityLine: "ready", isFinished: true
        )
        XCTAssertEqual(
            AgentLiveSurfaceLogic.badgeLabel(surface: done, fallbackStatusLine: "f"),
            "done"
        )
    }

    func testRankedAgentsNeedsYouFirst() {
        let working = agent(id: "codex", name: "Codex", status: .midTask)
        let needs = agent(id: "claude_code", name: "Claude Code", status: .idle, presence: .live, task: "")
        let ask = GateDBReader.PendingAsk(
            interactionId: "a", agentId: "claude_code", prompt: "?", createdAt: now
        )
        let ranked = AgentLiveSurfaceLogic.rankedAgents(
            agents: [working, needs],
            pendingAsks: [ask],
            activity: [event(id: 3, agent: "codex", type: "tool_call", label: "Edited x")],
            now: now,
            limit: 4
        )
        XCTAssertEqual(ranked.first?.id, "claude_code")
        XCTAssertEqual(ranked.map(\.id).contains("codex"), true)
    }

    /// ENH-007: paired API matches rankedAgents order and single-resolve attention.
    func testRankedAgentSurfacesMatchesRankedAgentsAndResolve() {
        let working = agent(id: "codex", name: "Codex", status: .midTask)
        let needs = agent(id: "claude_code", name: "Claude Code", status: .idle, presence: .live, task: "")
        let idle = agent(id: "design", name: "Design", status: .idle, presence: .live, task: "")
        let ask = GateDBReader.PendingAsk(
            interactionId: "a", agentId: "claude_code", prompt: "Approve?", createdAt: now
        )
        let activity = [event(id: 3, agent: "codex", type: "tool_call", label: "Edited x")]
        let agents = [working, needs, idle]
        let ranked = AgentLiveSurfaceLogic.rankedAgents(
            agents: agents,
            pendingAsks: [ask],
            activity: activity,
            now: now,
            limit: 4
        )
        let pairs = AgentLiveSurfaceLogic.rankedAgentSurfaces(
            agents: agents,
            pendingAsks: [ask],
            activity: activity,
            now: now,
            limit: 4
        )
        XCTAssertEqual(pairs.map(\.agent.id), ranked.map(\.id))
        XCTAssertEqual(pairs.first?.surface.attention, .needsYou)
        for (agent, surface) in pairs {
            let again = AgentLiveSurfaceLogic.resolve(
                agent: agent,
                pendingAsks: [ask],
                activity: activity,
                now: now
            )
            XCTAssertEqual(surface.attention, again.attention, agent.id)
            XCTAssertEqual(surface.needsYou, again.needsYou, agent.id)
            XCTAssertEqual(surface.activityLine, again.activityLine, agent.id)
        }
    }

    func testActiveFleetCountExcludesIdle() {
        let w = agent(id: "codex", name: "Codex", status: .midTask)
        let idle = agent(id: "design", name: "Design", status: .idle, presence: .live, task: "")
        let n = AgentLiveSurfaceLogic.activeFleetCount(
            agents: [w, idle],
            activity: [event(id: 4, agent: "codex", type: "tool_call", label: "Edited y")],
            now: now
        )
        XCTAssertEqual(n, 1)
    }
}
