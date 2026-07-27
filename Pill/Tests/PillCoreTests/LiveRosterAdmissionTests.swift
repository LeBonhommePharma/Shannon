import XCTest
@testable import PillCore

/// Production roster admission + sole-live bridge H attribution (attach entropy).
final class LiveRosterAdmissionTests: XCTestCase {

    private func snap(
        id: String,
        presence: AgentPresence,
        status: AgentRunStatus = .idle,
        attachPid: Int32? = nil,
        attachBundle: String? = nil,
        source: String = "other",
        historyCount: Int = 0
    ) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            id: id,
            displayName: id,
            status: status,
            lastTask: "",
            source: source,
            updatedAt: Date(),
            resumable: false,
            historyCount: historyCount,
            presence: presence,
            attachPid: attachPid,
            attachBundle: attachBundle
        )
    }

    // MARK: - Admission

    func testRejectsOfflineWithoutAsk() {
        let a = snap(id: "claude_code", presence: .offline)
        XCTAssertFalse(LiveRosterAdmission.shouldList(agent: a))
    }

    func testRejectsBareObservedRegistrySpam() {
        let a = snap(id: "old_capture", presence: .observed)
        XCTAssertFalse(LiveRosterAdmission.shouldList(agent: a))
    }

    func testRejectsNonAgentHostBundleOnlyLive() {
        // Finder still running after a bad capture — not an agent host.
        let a = snap(
            id: "finder_oops",
            presence: .live,
            attachBundle: "com.apple.finder"
        )
        // ProcessAttach would now report .observed; even if .live sneaks in, admission rejects.
        XCTAssertFalse(LiveRosterAdmission.shouldList(agent: a))
    }

    func testRejectsGenericTerminalContainerWithoutBusy() {
        let a = snap(
            id: "terminal",
            presence: .live,
            attachPid: 1234,
            attachBundle: "com.mitchellh.ghostty"
        )
        // Generic container id + host only — not a classified CLI agent.
        XCTAssertFalse(LiveRosterAdmission.shouldList(agent: a))
    }

    func testAdmitsLiveAttachPidForNamedAgent() {
        let a = snap(
            id: "claude_code",
            presence: .live,
            attachPid: 42_001,
            attachBundle: "com.mitchellh.ghostty"
        )
        XCTAssertTrue(LiveRosterAdmission.shouldList(agent: a))
    }

    func testAdmitsCursorHostBundleOnlyLive() {
        let a = snap(
            id: "cursor",
            presence: .live,
            attachBundle: "com.todesktop.230313mzl4w4u92"
        )
        XCTAssertTrue(LiveRosterAdmission.shouldList(agent: a))
    }

    func testAdmitsNeedsYouEvenIfOffline() {
        let a = snap(id: "codex", presence: .offline, status: .blocked)
        XCTAssertTrue(
            LiveRosterAdmission.shouldList(
                agent: a,
                surface: nil,
                hasPendingAsk: true
            )
        )
    }

    func testProcessAttachBundleOnlyLiveOnlyForAgentHosts() {
        let running: Set<String> = ["com.apple.finder", "com.mitchellh.ghostty"]
        // Finder: not agent host → observed (or offline if pid dead)
        let finder = ProcessAttach.presence(
            attachPid: nil,
            attachBundle: "com.apple.finder",
            runningBundleIDs: running
        )
        XCTAssertNotEqual(finder, .live, "Finder must not stay live from bundle alone")

        let ghostty = ProcessAttach.presence(
            attachPid: nil,
            attachBundle: "com.mitchellh.ghostty",
            runningBundleIDs: running
        )
        XCTAssertEqual(ghostty, .live)
    }

    func testProcessAttachLivePidStillWins() {
        let p = ProcessAttach.presence(
            attachPid: 1,
            attachBundle: "com.apple.finder",
            runningBundleIDs: ["com.apple.finder"],
            pidAlive: { _ in true }
        )
        XCTAssertEqual(p, .live, "live CLI pid wins even if host is non-agent")
    }

    // MARK: - Entropy sole-live fleet bridge

    func testSoleLiveAgentGetsUnnamedMeasuredBridgeH() {
        let status = ShannonStatus(
            entropy: 7.5,
            deltaH: -0.4,
            collapsed: false,
            tokenCount: 10,
            backend: "cpp",
            agent: nil
        )
        let reading = EntropyProvenance.resolveForAgent(
            agentId: "claude_code",
            bridgeConnected: true,
            bridgeStatus: status,
            gate: [],
            applyUnnamedFleetBridge: true
        )
        XCTAssertTrue(reading.isMeasured)
        if case .measured(let m) = reading {
            XCTAssertEqual(m.bits, 7.5, accuracy: 1e-9)
        } else {
            XCTFail("expected measured")
        }
    }

    func testUnnamedBridgeNotAppliedWithoutSoleLiveFlag() {
        let status = ShannonStatus(
            entropy: 7.5,
            deltaH: 0,
            collapsed: false,
            tokenCount: 10,
            backend: "cpp",
            agent: nil
        )
        let reading = EntropyProvenance.resolveForAgent(
            agentId: "claude_code",
            bridgeConnected: true,
            bridgeStatus: status,
            gate: [],
            applyUnnamedFleetBridge: false
        )
        XCTAssertFalse(reading.isMeasured)
    }

    func testResolveAllAttributesUnnamedBridgeToSoleLive() {
        let status = ShannonStatus(
            entropy: 6.2,
            deltaH: -1.0,
            collapsed: false,
            tokenCount: 10,
            backend: "cpp",
            agent: ""
        )
        let map = EntropyProvenance.resolveAll(
            agentIds: ["claude_code", "stale_pet"],
            bridgeConnected: true,
            bridgeStatus: status,
            gate: [],
            liveAgentIds: ["claude_code"]
        )
        XCTAssertTrue(map["claude_code"]?.isMeasured == true)
        XCTAssertFalse(map["stale_pet"]?.isMeasured == true)
    }

    func testBridgeAgentAliasClaudeMatchesClaudeCode() {
        let status = ShannonStatus(
            entropy: 8.1,
            deltaH: 0,
            collapsed: false,
            tokenCount: 10,
            backend: "cpp",
            agent: "claude"
        )
        let reading = EntropyProvenance.resolveForAgent(
            agentId: "claude_code",
            bridgeConnected: true,
            bridgeStatus: status,
            gate: []
        )
        XCTAssertTrue(reading.isMeasured)
    }

    func testDemoBridgeNeverMeasuredForSoleLive() {
        let status = ShannonStatus(
            entropy: 9.0,
            deltaH: -3.0,
            collapsed: true,
            tokenCount: 10,
            backend: "demo",
            agent: nil
        )
        let reading = EntropyProvenance.resolveForAgent(
            agentId: "claude_code",
            bridgeConnected: true,
            bridgeStatus: status,
            applyUnnamedFleetBridge: true
        )
        XCTAssertFalse(reading.isMeasured)
    }

    func testRankedSurfacesDropNonAdmittedOfflineSpam() {
        let agents = [
            snap(id: "claude_code", presence: .live, attachPid: 99, attachBundle: "com.mitchellh.ghostty"),
            snap(id: "window_junk", presence: .observed),
            snap(id: "finder_junk", presence: .live, attachBundle: "com.apple.finder"),
        ]
        let ranked = AgentLiveSurfaceLogic.rankedAgentSurfaces(
            agents: agents,
            limit: 10
        )
        let ids = Set(ranked.map(\.agent.id))
        XCTAssertTrue(ids.contains("claude_code"))
        XCTAssertFalse(ids.contains("window_junk"))
        XCTAssertFalse(ids.contains("finder_junk"))
    }
}
