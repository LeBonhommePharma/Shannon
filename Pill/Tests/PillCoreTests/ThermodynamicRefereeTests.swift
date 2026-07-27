import XCTest
@testable import PillCore

final class ThermodynamicRefereeTests: XCTestCase {

    // MARK: - Handrail + collapse attention

    func testSyntheticCollapseNeverAlarmsOrHandrails() {
        let synthetic = ShannonStatus(
            entropy: 2.0, deltaH: -4.0, collapsed: true,
            tokenCount: 10, backend: "demo"
        )
        let reading = EntropyProvenance.resolve(
            bridgeConnected: true,
            bridgeStatus: synthetic,
            gate: [],
            gateDBAvailable: false
        )
        let d = CollapseAttentionLogic.decide(reading: reading, status: synthetic)
        XCTAssertEqual(d.state, CollapseAttention.idle)
        XCTAssertFalse(d.shouldAutoExpand)
        XCTAssertTrue(d.handrailActions.isEmpty)
        XCTAssertTrue(CollapseAttentionLogic.handrailActions(measuredCollapsed: false).isEmpty)
    }

    func testMeasuredCollapseAutoExpandsWithFullHandrailSet() {
        let status = ShannonStatus(
            entropy: 2.5, deltaH: -3.5, collapsed: true,
            tokenCount: 100, backend: "cpp", agent: "flexaid-runner",
            zScore: -3.4, tokenSnippet: "eval-aware reply…"
        )
        let reading = EntropyProvenance.resolve(
            bridgeConnected: true,
            bridgeStatus: status,
            gate: [],
            gateDBAvailable: false
        )
        XCTAssertTrue(reading.isMeasured, "cpp backend must be measured")
        XCTAssertEqual(reading.collapsed, true)

        let d = CollapseAttentionLogic.decide(
            reading: reading,
            status: status,
            tokenSnippet: status.tokenSnippet
        )
        XCTAssertEqual(d.state, CollapseAttention.alarm)
        XCTAssertTrue(d.shouldAutoExpand)
        XCTAssertEqual(
            d.handrailActions.map { $0.rawValue },
            ["LOG", "ALERT", "THROTTLE", "KILL", "WEBHOOK"]
        )
        XCTAssertEqual(d.agentLabel, "flexaid-runner")
        XCTAssertEqual(d.entropy ?? -1, 2.5, accuracy: 1e-9)
        XCTAssertEqual(d.deltaH ?? 0, -3.5, accuracy: 1e-9)
        XCTAssertEqual(d.zScore ?? 0, -3.4, accuracy: 1e-9)
        XCTAssertEqual(d.tokenSnippet, "eval-aware reply…")

        for action in HandrailAction.collapseSet {
            XCTAssertTrue(HandrailDispatch.isAllowed(action: action, decision: d))
            let cmd = HandrailDispatch.command(
                action: action, agentId: d.agentLabel, entropy: d.entropy, deltaH: d.deltaH
            )
            XCTAssertTrue(cmd.contains("handrail.\(action.rawValue.lowercased())"))
            XCTAssertTrue(cmd.contains("flexaid-runner"))
        }
    }

    func testMeasuredSignificantDeltaIsWatchNotAlarm() {
        let status = ShannonStatus(
            entropy: 7.0, deltaH: -2.0, collapsed: false,
            tokenCount: 50, backend: "cpp"
        )
        let reading = EntropyProvenance.resolve(
            bridgeConnected: true,
            bridgeStatus: status,
            gate: [],
            gateDBAvailable: false
        )
        let d = CollapseAttentionLogic.decide(reading: reading, status: status)
        XCTAssertEqual(d.state, CollapseAttention.watch)
        XCTAssertFalse(d.shouldAutoExpand)
        XCTAssertTrue(d.handrailActions.isEmpty)
    }

    // MARK: - Entropy rail

    func testRailPointsMapCoolToWarmThermodynamicColors() {
        let series: [Double] = [10.0, 8.0, 5.0, 2.0]
        let points = EntropyRailLogic.points(hSeries: series, isCurrent: true)
        XCTAssertEqual(points.count, 4)
        let high = points[0].color
        let low = points[3].color
        XCTAssertGreaterThan(
            high.g + high.b, low.g + low.b,
            "high entropy should be cooler/diffuse vs collapse red"
        )
        XCTAssertGreaterThan(low.r, high.r, "collapse end should be warmer/redder")
        let label = EntropyRailLogic.summaryLabel(h: 2.5, deltaH: -3.2, zScore: -3.5)
        XCTAssertEqual(label, "H 2.5 ▽3.2 z-3.5")
    }

    func testRailAppendBoundsAndRefusesNonFinite() {
        var h: [Double] = []
        for i in 0..<60 {
            h = EntropyRailLogic.append(history: h, entropy: Double(i), capacity: 8)
        }
        XCTAssertEqual(h.count, 8)
        XCTAssertEqual(h.first ?? -1, 52, accuracy: 1e-9)
        let same = EntropyRailLogic.append(history: h, entropy: .nan, capacity: 8)
        XCTAssertEqual(same, h)
    }

    // MARK: - Bridge push significance

    func testPushSignificantOnMeasuredCollapseAndDelta() {
        let prev = ShannonStatus(
            entropy: 9.0, deltaH: -0.1, collapsed: false,
            tokenCount: 1, backend: "cpp"
        )
        let collapsed = ShannonStatus(
            entropy: 2.0, deltaH: -4.0, collapsed: true,
            tokenCount: 2, backend: "cpp"
        )
        XCTAssertTrue(BridgePushLogic.isSignificantEvent(previous: prev, next: collapsed))

        let jump = ShannonStatus(
            entropy: 4.0, deltaH: -2.0, collapsed: false,
            tokenCount: 3, backend: "numba"
        )
        XCTAssertTrue(BridgePushLogic.isSignificantEvent(previous: prev, next: jump))

        let quiet = ShannonStatus(
            entropy: 9.05, deltaH: -0.05, collapsed: false,
            tokenCount: 4, backend: "cpp"
        )
        XCTAssertFalse(BridgePushLogic.isSignificantEvent(previous: prev, next: quiet))

        let demo = ShannonStatus(
            entropy: 1.0, deltaH: -5.0, collapsed: true,
            tokenCount: 1, backend: "demo"
        )
        XCTAssertFalse(BridgePushLogic.isSignificantEvent(previous: nil, next: demo))
    }

    // MARK: - Apply push → model (no 1 Hz wait)

    @MainActor
    func testApplyPushUpdatesStatusHistoryAndGenerationWithoutPoll() throws {
        let bridge = ShannonBridge(
            socketPath: "/tmp/shannon-nonexistent-push-test.sock",
            interval: 2.0
        )
        XCTAssertNil(bridge.status)
        XCTAssertEqual(bridge.pushGeneration, 0)

        let frame = """
        {"entropy":3.1,"delta_h":-3.8,"collapsed":true,"token_count":42,\
        "backend":"cpp","agent":"runner","z_score":-3.3,"kind":"event"}
        """.data(using: .utf8)!

        try bridge.applyPush(frame)

        guard let st = bridge.status else {
            return XCTFail("status should be set after push")
        }
        XCTAssertEqual(st.entropy, 3.1, accuracy: 1e-9)
        XCTAssertEqual(st.zScore ?? 0, -3.3, accuracy: 1e-9)
        XCTAssertEqual(st.agent, "runner")
        XCTAssertTrue(st.collapsed)
        XCTAssertEqual(bridge.hHistory.last ?? -1, 3.1, accuracy: 1e-9)
        XCTAssertTrue(bridge.lastUpdateWasPush)
        XCTAssertEqual(bridge.pushGeneration, 1)
        XCTAssertTrue(bridge.connected)

        let demo = """
        {"entropy":1.0,"delta_h":-5.0,"collapsed":true,"token_count":1,"backend":"demo"}
        """.data(using: .utf8)!
        let genBefore = bridge.pushGeneration
        try bridge.applyPush(demo)
        XCTAssertEqual(bridge.pushGeneration, genBefore)
    }

    func testDecodeStatusCarriesZScoreAndKind() throws {
        let json = """
        {"entropy":8.0,"delta_h":-0.2,"collapsed":false,"token_count":3,\
        "backend":"cpp","z_score":-1.1,"kind":"event","token_snippet":"hi"}
        """.data(using: .utf8)!
        let s = try BridgeCodec.decodeStatus(json)
        XCTAssertEqual(s.zScore ?? 0, -1.1, accuracy: 1e-9)
        XCTAssertEqual(s.kind, "event")
        XCTAssertEqual(s.tokenSnippet, "hi")
        XCTAssertEqual(s.refereeLabel, "H 8.0 ▽0.2 z-1.1")
    }
}
