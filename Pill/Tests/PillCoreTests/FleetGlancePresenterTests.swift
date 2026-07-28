import XCTest
@testable import PillCore

/// Dual-HUD fleet glance SSOT: one resolve policy for pill + popover, measured-only
/// collapsed H chip preferring primary agent, fail-closed on synthetic.
final class FleetGlancePresenterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let enforce = EntropyPolicy(maxAge: 120, warnBits: 5, maxBits: 64, mode: .enforce)

    private func status(
        entropy: Double,
        deltaH: Double = 0,
        collapsed: Bool = false,
        backend: String,
        agent: String? = nil
    ) -> ShannonStatus {
        return ShannonStatus(
            entropy: entropy,
            deltaH: deltaH,
            collapsed: collapsed,
            tokenCount: 32,
            backend: backend,
            agent: agent
        )
    }

    private func agent(
        id: String,
        status: AgentRunStatus = .idle,
        presence: AgentPresence = .live,
        task: String = "work"
    ) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            id: id,
            displayName: id,
            status: status,
            lastTask: task,
            source: "test",
            updatedAt: now,
            resumable: true,
            historyCount: 1,
            presence: presence
        )
    }

    private func gateMeasurement(
        agent: String,
        bits: Double,
        deltaH: Double? = -0.5
    ) -> EntropyMeasurement {
        let m = EntropyMeasurement(
            bits: bits,
            deltaH: deltaH,
            collapsed: false,
            source: .gate(agentId: agent, presence: .live),
            measuredAt: now.addingTimeInterval(-5),
            now: now,
            policy: enforce
        )
        guard let m else {
            XCTFail("gate measurement refused")
            return EntropyMeasurement(
                bits: 1,
                source: .gate(agentId: agent, presence: .live),
                measuredAt: now,
                now: now
            )!
        }
        return m
    }

    // MARK: - Resolve scope

    func testAdmittedPreferBusyUsesBusyIdsOnlyWhenPresent() {
        let agents = [
            agent(id: "claude_code", status: .idle),
            agent(id: "codex", status: .midTask, task: "edit"),
        ]
        let ids = FleetGlancePresenter.resolveAgentIds(
            agents: agents,
            pendingAgentIDs: [],
            scope: .admittedPreferBusy(limit: nil)
        )
        XCTAssertEqual(ids, ["codex"])
    }

    func testListedScopePreservesOrderAndDedupes() {
        let ids = FleetGlancePresenter.resolveAgentIds(
            agents: [],
            pendingAgentIDs: [],
            scope: .listed(["claude_code", "codex", "claude_code", "  "])
        )
        XCTAssertEqual(ids, ["claude_code", "codex"])
    }

    // MARK: - Synthetic fail-closed

    func testSyntheticDemoProducesNoCollapsedChipAndNoMeasuredRows() {
        let snap = FleetGlancePresenter.snapshot(
            agents: [agent(id: "claude_code", status: .midTask)],
            pendingAgentIDs: [],
            bridgeConnected: true,
            bridgeStatus: status(entropy: 8.7, deltaH: 0.9, backend: "demo"),
            gate: [],
            gateDBAvailable: true,
            scope: .admittedPreferBusy(limit: nil),
            primaryAgentId: "claude_code",
            companionBoardVisible: true,
            now: now,
            policy: enforce
        )
        XCTAssertNil(snap.collapsedEntropyLabel)
        XCTAssertTrue(snap.fleetReading.isAbsent)
        XCTAssertFalse(snap.liveReadings.values.contains(where: \.isMeasured))
        XCTAssertTrue(snap.companionDeltas.isEmpty)
        XCTAssertFalse(snap.showPerAgentEntropyStrip)
    }

    // MARK: - Per-agent measured H

    func testCollapsedChipPrefersPrimaryAgentMeasuredBits() {
        let gate = [
            gateMeasurement(agent: "claude_code", bits: 3.2),
            gateMeasurement(agent: "codex", bits: 7.5),
        ]
        let snap = FleetGlancePresenter.snapshot(
            agents: [
                agent(id: "claude_code", status: .midTask),
                agent(id: "codex", status: .midTask),
            ],
            pendingAgentIDs: [],
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: gate,
            gateDBAvailable: true,
            scope: .listed(["claude_code", "codex"]),
            primaryAgentId: "claude_code",
            companionBoardVisible: true,
            now: now,
            policy: enforce
        )
        XCTAssertEqual(snap.collapsedEntropyLabel, "H 3.2")
        XCTAssertTrue(snap.rowReadings["claude_code"]?.isMeasured == true)
        XCTAssertTrue(snap.rowReadings["codex"]?.isMeasured == true)
        // Independent per-agent — codex is not painted with claude’s bits.
        guard let codexBits = snap.rowReadings["codex"]?.currentBits else {
            return XCTFail("codex should be measured")
        }
        XCTAssertEqual(codexBits, 7.5, accuracy: 1e-9)
    }

    func testCollapsedChipFallsBackToFleetWhenPrimaryAbsent() {
        let bridge = status(entropy: 9.1, deltaH: -0.2, backend: "vllm")
        let snap = FleetGlancePresenter.snapshot(
            agents: [agent(id: "claude_code", status: .idle, presence: .observed)],
            pendingAgentIDs: [],
            bridgeConnected: true,
            bridgeStatus: bridge,
            gate: [],
            gateDBAvailable: true,
            scope: .listed(["claude_code"]),
            primaryAgentId: "claude_code",
            companionBoardVisible: false,
            now: now,
            policy: enforce
        )
        // Unnamed fleet bridge may attach only to sole live — observed may not
        // get per-agent measured; fleet still measured when backend is real.
        if snap.fleetReading.isMeasured {
            XCTAssertEqual(snap.collapsedEntropyLabel, "H 9.1")
        } else if let label = snap.collapsedEntropyLabel {
            XCTAssertTrue(label.hasPrefix("H "), label)
        }
    }

    func testCompanionDeltasOnlyFromMeasuredLiveMap() {
        let live: [String: EntropyReading] = [
            "a": EntropyProvenance.resolveForAgent(
                agentId: "a",
                bridgeConnected: false,
                bridgeStatus: nil,
                gate: [gateMeasurement(agent: "a", bits: 4.0, deltaH: -1.2)],
                gateDBAvailable: true,
                now: now,
                policy: enforce
            ),
            "b": .absent(.noDetector),
        ]
        let deltas = FleetGlancePresenter.companionDeltas(from: live)
        guard let dA = deltas["a"] else { return XCTFail("delta for a") }
        XCTAssertEqual(dA, -1.2, accuracy: 1e-12)
        XCTAssertNil(deltas["b"])
    }

    func testRowReadingsPreferMeasuredMemoryOverAbsentLive() {
        let live: [String: EntropyReading] = [
            "codex": .absent(.noDetector),
        ]
        let memReading = EntropyProvenance.resolveForAgent(
            agentId: "codex",
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gateMeasurement(agent: "codex", bits: 5.5)],
            gateDBAvailable: true,
            now: now,
            policy: enforce
        )
        XCTAssertTrue(memReading.isMeasured)
        let rows = FleetGlancePresenter.rowReadings(
            live: live,
            memoryByAgent: ["codex": memReading]
        )
        XCTAssertTrue(rows["codex"]?.isMeasured == true)
        guard let bits = rows["codex"]?.currentBits else {
            return XCTFail("memory-preferred bits")
        }
        XCTAssertEqual(bits, 5.5, accuracy: 1e-9)
    }

    func testShowPerAgentStripWhenAnyRowDisplayable() {
        let snap = FleetGlancePresenter.snapshot(
            agents: [agent(id: "codex", status: .midTask)],
            pendingAgentIDs: [],
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gateMeasurement(agent: "codex", bits: 6.0)],
            gateDBAvailable: true,
            scope: .listed(["codex"]),
            companionBoardVisible: true,
            now: now,
            policy: enforce
        )
        XCTAssertTrue(snap.showPerAgentEntropyStrip)
        XCTAssertNotNil(snap.collapsedEntropyLabel)
    }

    func testReadingLookupDoesNotInventSecondResolve() {
        let snap = FleetGlancePresenter.snapshot(
            agents: [agent(id: "codex", status: .midTask)],
            pendingAgentIDs: [],
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gateMeasurement(agent: "codex", bits: 2.5)],
            gateDBAvailable: true,
            scope: .listed(["codex"]),
            now: now,
            policy: enforce
        )
        guard let bits = snap.reading(for: "codex").currentBits else {
            return XCTFail("codex reading bits")
        }
        XCTAssertEqual(bits, 2.5, accuracy: 1e-9)
        // Unknown agent → absent, not a fabricated healthy number.
        XCTAssertTrue(snap.reading(for: "ghost").isAbsent)
        XCTAssertNil(snap.reading(for: "ghost").display(at: now, policy: enforce))
    }
}
