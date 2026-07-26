import XCTest
@testable import PillCore

final class SharedTelemetryBindingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func agent(
        id: String,
        status: AgentRunStatus = .midTask,
        presence: AgentPresence = .live,
        task: String = "work"
    ) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            id: id,
            displayName: id,
            status: status,
            lastTask: task,
            source: "gate",
            updatedAt: now.addingTimeInterval(-5),
            resumable: true,
            historyCount: 1,
            presence: presence
        )
    }

    private func gateH(agent: String, bits: Double, presence: AgentPresence = .live) -> EntropyMeasurement {
        EntropyMeasurement(
            bits: bits,
            source: .gate(agentId: agent, presence: presence),
            measuredAt: now.addingTimeInterval(-3),
            now: now
        )!
    }

    func testMultiConsumerAgreementOnSameSnapshot() {
        let snap = SharedTelemetrySnapshot.capture(
            agents: [
                agent(id: "claude_code"),
                agent(id: "codex", status: .idle, task: ""),
            ],
            pendingAsks: [
                GateDBReader.PendingAsk(
                    interactionId: "ask1",
                    agentId: "claude_code",
                    prompt: "Approve?",
                    createdAt: now.addingTimeInterval(-2)
                ),
            ],
            agentEntropy: [
                gateH(agent: "claude_code", bits: 8.1),
                gateH(agent: "codex", bits: 3.2),
            ],
            bridgeConnected: false,
            bridgeStatus: nil,
            gateAvailable: true,
            scannedAt: now
        )
        // Notch HUD + menu-bar popover: two consumers, identical freeze — must agree.
        let notch = snap
        let menuBar = snap
        XCTAssertTrue(SharedTelemetryBinding.consumersAgree([notch, menuBar], now: now))

        // Per-agent: busy / needs-you / H
        XCTAssertEqual(
            SharedTelemetryBinding.isBusy(agentId: "claude_code", in: notch),
            SharedTelemetryBinding.isBusy(agentId: "claude_code", in: menuBar)
        )
        XCTAssertTrue(SharedTelemetryBinding.isBusy(agentId: "claude_code", in: notch))
        XCTAssertFalse(SharedTelemetryBinding.isBusy(agentId: "codex", in: notch))

        XCTAssertEqual(
            SharedTelemetryBinding.needsYou(agentId: "claude_code", in: notch),
            SharedTelemetryBinding.needsYou(agentId: "claude_code", in: menuBar)
        )
        XCTAssertTrue(SharedTelemetryBinding.needsYou(agentId: "claude_code", in: notch))
        XCTAssertFalse(SharedTelemetryBinding.needsYou(agentId: "codex", in: notch))

        XCTAssertEqual(
            SharedTelemetryBinding.hBits(agentId: "claude_code", in: notch, now: now),
            SharedTelemetryBinding.hBits(agentId: "claude_code", in: menuBar, now: now)
        )

        let views = SharedTelemetryBinding.agentViews(in: snap, now: now)
        XCTAssertEqual(views["claude_code"]?.needsYou, true)
        XCTAssertEqual(views["claude_code"]?.isBusy, true)
        XCTAssertEqual(views["claude_code"]?.attention, .needsYou)
        XCTAssertEqual(views["claude_code"]?.entropyBits ?? -1, 8.1, accuracy: 1e-9)
        XCTAssertEqual(views["codex"]?.entropyBits ?? -1, 3.2, accuracy: 1e-9)
        XCTAssertNotEqual(views["claude_code"]?.entropyBits, views["codex"]?.entropyBits)
    }

    func testIdenticalSnapshotsDoNotForcePublish() {
        let a = SharedTelemetrySnapshot.capture(
            agents: [agent(id: "science")],
            pendingAsks: [],
            agentEntropy: [gateH(agent: "science", bits: 6.0)],
            bridgeConnected: true,
            bridgeStatus: ShannonStatus(
                entropy: 7.2, deltaH: 0, collapsed: false,
                tokenCount: 10, backend: "cpp", agent: "science"
            ),
            gateAvailable: true,
            scannedAt: now
        )
        var b = a
        b.scannedAt = now.addingTimeInterval(30) // pure clock advance
        XCTAssertTrue(SharedTelemetryBinding.displayEqual(a, b))
        XCTAssertFalse(SharedTelemetryBinding.shouldPublish(previous: a, next: b))
    }

    func testRealChangeForcesPublish() {
        let a = SharedTelemetrySnapshot(
            agents: [agent(id: "a", status: .idle)],
            scannedAt: now
        )
        let b = SharedTelemetrySnapshot(
            agents: [agent(id: "a", status: .midTask)],
            scannedAt: now
        )
        XCTAssertTrue(SharedTelemetryBinding.shouldPublish(previous: a, next: b))
    }

    func testSyntheticBridgeDoesNotInventMeasuredBridgeH() {
        let snap = SharedTelemetrySnapshot.capture(
            agents: [],
            pendingAsks: [],
            agentEntropy: [],
            bridgeConnected: true,
            bridgeStatus: ShannonStatus(
                entropy: 8.0, deltaH: 0, collapsed: false,
                tokenCount: 1, backend: "demo", agent: nil
            ),
            gateAvailable: false,
            scannedAt: now
        )
        XCTAssertNil(snap.bridgeEntropy, "demo bridge must not surface measured H")
        XCTAssertEqual(snap.bridgeBackend, "demo")
    }

    func testPrimaryFocusSharedAcrossConsumers() {
        let snap = SharedTelemetrySnapshot.capture(
            agents: [agent(id: "claude_code")],
            pendingAsks: [
                GateDBReader.PendingAsk(
                    interactionId: "x",
                    agentId: "claude_code",
                    prompt: "Run?",
                    createdAt: now
                ),
            ],
            agentEntropy: [],
            bridgeConnected: false,
            bridgeStatus: nil,
            gateAvailable: true,
            scannedAt: now
        )
        let f1 = SharedTelemetryBinding.primaryFocus(in: snap, now: now)
        let f2 = SharedTelemetryBinding.primaryFocus(in: snap, now: now)
        XCTAssertEqual(f1, f2)
        XCTAssertEqual(f1, "Needs you · claude_code")
    }

    func testMissingOptionalFieldsStayAbsent() {
        let snap = SharedTelemetrySnapshot()
        XCTAssertNil(snap.bridgeEntropy)
        XCTAssertNil(snap.bridgeBackend)
        XCTAssertTrue(snap.agentEntropy.isEmpty)
        XCTAssertTrue(snap.pendingAsks.isEmpty)
        let views = SharedTelemetryBinding.agentViews(in: snap, now: now)
        XCTAssertTrue(views.isEmpty)
        XCTAssertNil(SharedTelemetryBinding.hBits(agentId: "ghost", in: snap, now: now))
    }

    func testMultiAgentEntropyMemorySeriesCountsSurvivePartialUpdate() {
        var mem = AgentEntropyMemory()
        mem.ingest([
            gateH(agent: "claude_code", bits: 8.0),
            gateH(agent: "codex", bits: 4.0),
        ], now: now)
        // Only claude updates — codex series must remain (counts ≥ 1 each).
        let snap = SharedTelemetrySnapshot.capture(
            agents: [
                agent(id: "claude_code"),
                agent(id: "codex", status: .idle, task: ""),
            ],
            pendingAsks: [],
            agentEntropy: [gateH(agent: "claude_code", bits: 7.5)],
            bridgeConnected: false,
            bridgeStatus: nil,
            entropyMemory: mem,
            gateAvailable: true,
            scannedAt: now
        )
        XCTAssertGreaterThanOrEqual(snap.entropySeriesCounts["claude_code"] ?? 0, 1)
        XCTAssertGreaterThanOrEqual(snap.entropySeriesCounts["codex"] ?? 0, 1)
    }

    func testUICadenceEqualityGateMatchesBinding() {
        let a = SharedTelemetrySnapshot.capture(
            agents: [agent(id: "science")],
            pendingAsks: [],
            agentEntropy: [gateH(agent: "science", bits: 5.0)],
            bridgeConnected: false,
            bridgeStatus: nil,
            gateAvailable: true,
            scannedAt: now
        )
        var b = a
        b.scannedAt = now.addingTimeInterval(10)
        XCTAssertFalse(UICadence.shouldPublishSharedTelemetry(previous: a, next: b))
        XCTAssertFalse(UICadence.shouldAllowTimerChromePaint(contentChanged: false))
        XCTAssertTrue(UICadence.shouldAllowTimerChromePaint(contentChanged: true))
    }

    // MARK: - Gate activity on shared snapshot (ENH-001)

    func testSharedPathSurfacesToolCallActivityLine() {
        let edit = GateDBReader.ActivityEvent(
            id: 1,
            agentId: "claude_code",
            at: now.addingTimeInterval(-2),
            type: "tool_call",
            label: "Edited lib/license/store.ts",
            output: ""
        )
        let snap = SharedTelemetrySnapshot.capture(
            agents: [agent(id: "claude_code", task: "Wiring license claim")],
            pendingAsks: [],
            recentActivity: [edit],
            agentEntropy: [],
            bridgeConnected: false,
            bridgeStatus: nil,
            gateAvailable: true,
            scannedAt: now
        )

        let views = SharedTelemetryBinding.agentViews(in: snap, now: now)
        let line = views["claude_code"]?.activityLine ?? ""
        XCTAssertEqual(views["claude_code"]?.attention, .working)
        XCTAssertTrue(
            line.lowercased().contains("edit"),
            "shared path must pass gate activity so tool lines match live pill; got \(line)"
        )

        // Multi-consumer identity on the activity-derived line.
        let notch = SharedTelemetryBinding.agentViews(in: snap, now: now)
        let menuBar = SharedTelemetryBinding.agentViews(in: snap, now: now)
        XCTAssertEqual(notch["claude_code"]?.activityLine, menuBar["claude_code"]?.activityLine)
        XCTAssertTrue(SharedTelemetryBinding.consumersAgree([snap, snap], now: now))

        let focus = SharedTelemetryBinding.primaryFocus(in: snap, now: now) ?? ""
        XCTAssertTrue(
            focus.lowercased().contains("edit") || focus.contains("claude_code"),
            "primaryFocus should reflect working tool surface; got \(focus)"
        )
    }

    func testActivityChangeForcesPublish() {
        let base = SharedTelemetrySnapshot.capture(
            agents: [agent(id: "claude_code")],
            pendingAsks: [],
            recentActivity: [],
            agentEntropy: [],
            bridgeConnected: false,
            bridgeStatus: nil,
            gateAvailable: true,
            scannedAt: now
        )
        var withTool = base
        withTool.recentActivity = [
            GateDBReader.ActivityEvent(
                id: 2,
                agentId: "claude_code",
                at: now.addingTimeInterval(-1),
                type: "tool_call",
                label: "Edited store.ts",
                output: ""
            ),
        ]
        XCTAssertFalse(SharedTelemetryBinding.displayEqual(base, withTool))
        XCTAssertTrue(SharedTelemetryBinding.shouldPublish(previous: base, next: withTool))
    }
}
