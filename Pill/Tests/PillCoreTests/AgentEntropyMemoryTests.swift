import XCTest
@testable import PillCore

/// Simultaneous multi-agent entropy series + presence-gated tracking.
final class AgentEntropyMemoryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let policy = EntropyPolicy(maxAge: 120, warnBits: 5, maxBits: 64, mode: .enforce)

    private func gate(
        agent: String,
        bits: Double,
        presence: AgentPresence = .live,
        secondsAgo: TimeInterval = 5,
        at: Date? = nil
    ) -> EntropyMeasurement {
        let measured = (at ?? now).addingTimeInterval(-secondsAgo)
        let m = EntropyMeasurement(
            bits: bits,
            deltaH: nil,
            collapsed: nil,
            source: .gate(agentId: agent, presence: presence),
            measuredAt: measured,
            now: now,
            policy: policy
        )
        guard let m else {
            XCTFail("refused measurement agent=\(agent) bits=\(bits)")
            return EntropyMeasurement(
                bits: 1, source: .gate(agentId: agent, presence: .live),
                measuredAt: now, now: now
            )!
        }
        return m
    }

    // MARK: Independent series

    func testUpdatingADoesNotClearB() {
        var mem = AgentEntropyMemory(maxSamplesPerAgent: 8)
        mem.ingest([
            gate(agent: "claude_code", bits: 8.0, secondsAgo: 20),
            gate(agent: "codex", bits: 3.5, secondsAgo: 20),
        ], now: now.addingTimeInterval(-20))

        // Only A updates on the next poll.
        mem.ingest([
            gate(agent: "claude_code", bits: 7.2, secondsAgo: 2),
        ], now: now.addingTimeInterval(-2))

        let a = mem.series(for: "claude_code")
        let b = mem.series(for: "codex")
        XCTAssertEqual(a.samples.count, 2)
        XCTAssertEqual(b.samples.count, 1, "B series must survive A-only ingest")
        XCTAssertEqual(a.latest?.bits ?? -1, 7.2, accuracy: 1e-9)
        XCTAssertEqual(b.latest?.bits ?? -1, 3.5, accuracy: 1e-9)
        XCTAssertNotEqual(a.latest?.bits, b.latest?.bits)
    }

    func testIndependentHistoriesRetainPriorSamples() {
        var mem = AgentEntropyMemory()
        let t0 = now.addingTimeInterval(-60)
        let t1 = now.addingTimeInterval(-30)
        let t2 = now.addingTimeInterval(-5)
        mem.ingest([gate(agent: "science", bits: 6.0, secondsAgo: 0, at: t0)], now: t0)
        mem.ingest([gate(agent: "science", bits: 5.5, secondsAgo: 0, at: t1)], now: t1)
        mem.ingest([gate(agent: "science", bits: 4.1, secondsAgo: 0, at: t2)], now: t2)
        mem.ingest([gate(agent: "grok_build", bits: 9.0, secondsAgo: 0, at: t1)], now: t1)

        let sci = mem.series(for: "science").bitSeries
        XCTAssertEqual(sci.count, 3)
        XCTAssertEqual(sci[0], 6.0, accuracy: 1e-9)
        XCTAssertEqual(sci[2], 4.1, accuracy: 1e-9)
        XCTAssertEqual(mem.series(for: "grok_build").samples.count, 1)
    }

    func testOptionalFieldsStayNilWhenAbsent() {
        let m = gate(agent: "codex", bits: 4.0)
        XCTAssertNil(m.deltaH)
        XCTAssertNil(m.collapsed)
        var mem = AgentEntropyMemory()
        mem.ingest([m], now: now)
        XCTAssertNil(mem.latest(for: "codex")?.measurement.deltaH)
        XCTAssertNil(mem.latest(for: "missing"))
    }

    // MARK: Presence gating

    func testOfflineIsNotCurrentWithoutInventingH() {
        var mem = AgentEntropyMemory()
        mem.ingest([
            gate(agent: "claude_code", bits: 8.0, presence: .live, secondsAgo: 10),
        ], now: now.addingTimeInterval(-10))
        XCTAssertTrue(mem.isCurrent(agentId: "claude_code", now: now, policy: policy))

        // Offline update retains history but is not current.
        mem.ingest([
            gate(agent: "claude_code", bits: 7.5, presence: .offline, secondsAgo: 1),
        ], now: now.addingTimeInterval(-1))
        XCTAssertFalse(mem.isCurrent(agentId: "claude_code", now: now, policy: policy))
        let reading = mem.reading(for: "claude_code", now: now, policy: policy)
        XCTAssertTrue(reading.isStale || !reading.isMeasured)
        // Still has series — no fabricated second agent, no wipe.
        XCTAssertEqual(mem.series(for: "claude_code").samples.count, 2)
        XCTAssertNil(mem.latest(for: "ghost")?.bits)
    }

    func testShouldKeepTrackingLiveVsOffline() {
        let liveM = gate(agent: "a", bits: 5.0, presence: .live)
        XCTAssertTrue(AgentEntropyMemory.shouldKeepTracking(
            presence: .live, latest: liveM, now: now, policy: policy
        ))
        XCTAssertTrue(AgentEntropyMemory.shouldKeepTracking(
            presence: .live, latest: nil, now: now, policy: policy
        ), "live attach without H still tracks (no invented bits)")
        XCTAssertFalse(AgentEntropyMemory.shouldKeepTracking(
            presence: .offline, latest: liveM, now: now, policy: policy
        ))
        let offlineM = gate(agent: "a", bits: 5.0, presence: .offline)
        XCTAssertFalse(AgentEntropyMemory.shouldKeepTracking(
            presence: .offline, latest: offlineM, now: now, policy: policy
        ))
    }

    func testStaleAgeNotPaintedAsCurrent() {
        var mem = AgentEntropyMemory()
        mem.ingest([
            gate(agent: "codex", bits: 4.0, presence: .live, secondsAgo: 500),
        ], now: now)
        XCTAssertFalse(mem.isCurrent(agentId: "codex", now: now, policy: policy))
        XCTAssertTrue(mem.reading(for: "codex", now: now, policy: policy).isStale)
    }

    // MARK: Attention board / reply

    func testAttentionBoardNeedsYouBeatsWorkingAndIdleDoesNotOwnFocus() {
        let claude = AgentActivitySnapshot(
            id: "claude_code", displayName: "Claude Code",
            status: .midTask, lastTask: "editing", source: "gate",
            updatedAt: now.addingTimeInterval(-5), resumable: true,
            historyCount: 1, presence: .live
        )
        let codex = AgentActivitySnapshot(
            id: "codex", displayName: "Codex",
            status: .idle, lastTask: "", source: "gate",
            updatedAt: now.addingTimeInterval(-5), resumable: true,
            historyCount: 1, presence: .live
        )
        let ask = GateDBReader.PendingAsk(
            interactionId: "i1",
            agentId: "claude_code",
            prompt: "Run migrate?",
            createdAt: now.addingTimeInterval(-3)
        )
        let activity = [
            GateDBReader.ActivityEvent(
                id: 1, agentId: "codex", at: now.addingTimeInterval(-2),
                type: "tool_call", label: "Edited main.swift", output: ""
            ),
        ]
        var mem = AgentEntropyMemory()
        mem.ingest([
            gate(agent: "claude_code", bits: 6.0),
            gate(agent: "codex", bits: 4.0),
        ], now: now)

        let rows = MultiAgentAttentionBoard.rows(
            agents: [codex, claude],
            pendingAsks: [ask],
            activity: activity,
            memory: mem,
            now: now,
            policy: policy,
            limit: 4
        )
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        XCTAssertEqual(rows[0].agentId, "claude_code")
        XCTAssertTrue(rows[0].needsYou)
        XCTAssertTrue(rows[0].canApproveDeny)
        XCTAssertEqual(rows[0].pendingAsk?.prompt.contains("migrate") , true)

        let focus = MultiAgentAttentionBoard.primaryFocus(
            agents: [codex, claude],
            pendingAsks: [ask],
            activity: activity,
            now: now
        )
        XCTAssertEqual(focus, "Needs you · Claude Code")

        // Idle-only agents: primary focus nil so HubScanLine can own chrome.
        let idleOnly = MultiAgentAttentionBoard.primaryFocus(
            agents: [
                AgentActivitySnapshot(
                    id: "science", displayName: "Claude Science",
                    status: .idle, lastTask: "quiet", source: "gate",
                    updatedAt: now, resumable: false, historyCount: 0, presence: .live
                ),
            ],
            pendingAsks: [],
            activity: [],
            now: now
        )
        XCTAssertNil(idleOnly)
    }

    func testCurrentlyTrackedAgentIds() {
        var mem = AgentEntropyMemory()
        mem.ingest([
            gate(agent: "a", bits: 5.0, presence: .live, secondsAgo: 5),
            gate(agent: "b", bits: 5.0, presence: .offline, secondsAgo: 5),
        ], now: now)
        let tracked = mem.currentlyTrackedAgentIds(now: now, policy: policy)
        XCTAssertEqual(tracked, ["a"])
    }

    func testCapDoesNotDropOtherAgents() {
        var mem = AgentEntropyMemory(maxSamplesPerAgent: 3)
        for i in 0..<5 {
            let t = now.addingTimeInterval(TimeInterval(-50 + i * 10))
            mem.ingest([
                gate(agent: "a", bits: Double(i + 1), secondsAgo: 0, at: t),
                gate(agent: "b", bits: 8.0 + Double(i) * 0.1, secondsAgo: 0, at: t),
            ], now: t)
        }
        XCTAssertEqual(mem.series(for: "a").samples.count, 3)
        XCTAssertEqual(mem.series(for: "b").samples.count, 3)
        XCTAssertEqual(Set(mem.agentIds), Set(["a", "b"]))
    }
}
