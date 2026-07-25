import XCTest
@testable import PillCore

/// Live H must change when successive real measurements differ — never freeze
/// on a single value (e.g. 2.38 from repeated process-attach status).
final class EntropyLiveUpdateTests: XCTestCase {

    private let policy = EntropyPolicy(
        maxAge: 120,
        maxBits: 64,
        mode: .enforce
    )

    private func gate(
        agent: String,
        bits: Double,
        at: Date,
        presence: AgentPresence = .live
    ) -> EntropyMeasurement {
        EntropyMeasurement(
            bits: bits,
            deltaH: nil,
            collapsed: nil,
            source: .gate(agentId: agent, presence: presence),
            measuredAt: at,
            now: at,
            policy: policy
        )!
    }

    func testResolveSurfacesChangingGateH() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 1_010)
        let t2 = Date(timeIntervalSince1970: 1_020)

        let r0 = EntropyProvenance.resolve(
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate(agent: "science", bits: 2.38, at: t0)],
            now: t0,
            policy: policy
        )
        let r1 = EntropyProvenance.resolve(
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate(agent: "science", bits: 4.10, at: t1)],
            now: t1,
            policy: policy
        )
        let r2 = EntropyProvenance.resolve(
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate(agent: "science", bits: 1.90, at: t2)],
            now: t2,
            policy: policy
        )

        XCTAssertEqual(r0.currentBits!, 2.38, accuracy: 1e-9)
        XCTAssertEqual(r1.currentBits!, 4.10, accuracy: 1e-9)
        XCTAssertEqual(r2.currentBits!, 1.90, accuracy: 1e-9)
        // Display path must re-emit distinct bits for UI binding.
        XCTAssertNotEqual(r0.display(at: t0)?.bits, r1.display(at: t1)?.bits)
        XCTAssertNotEqual(r1.display(at: t1)?.bits, r2.display(at: t2)?.bits)
    }

    func testStaleFrozenScoreDoesNotStayCurrentWhenOnlyAgeAdvances() {
        // Heartbeats used to refresh last_seen while keeping H=2.38 — that
        // must age out once measuredAt is the real entropy_updated clock.
        let measured = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_000 + 200) // > maxAge 120
        let r = EntropyProvenance.resolve(
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate(agent: "grok_build", bits: 2.38, at: measured)],
            now: later,
            policy: policy
        )
        XCTAssertTrue(r.isStale || !r.isMeasured)
        XCTAssertNil(r.currentBits, "stale 2.38 must not present as currentBits")
    }

    func testZeroDefaultScoreNeverBecomesMeasured() {
        // agents.entropy_score DEFAULT 0.0 must never mint a measurement.
        XCTAssertNil(EntropyIntegrity.accept(
            bits: 0,
            deltaH: nil,
            collapsed: nil,
            source: .gate(agentId: "science", presence: .live),
            measuredAt: Date(),
            now: Date(),
            policy: policy
        ))
    }

    func testBridgeTokenHUpdatesLive() {
        let t0 = Date(timeIntervalSince1970: 5_000)
        let t1 = Date(timeIntervalSince1970: 5_001)
        let s0 = ShannonStatus(
            entropy: 8.2, deltaH: 0, collapsed: false,
            tokenCount: 10, backend: "numpy", agent: "science"
        )
        let s1 = ShannonStatus(
            entropy: 3.1, deltaH: -2.0, collapsed: false,
            tokenCount: 40, backend: "numpy", agent: "science"
        )
        let r0 = EntropyProvenance.resolve(
            bridgeConnected: true, bridgeStatus: s0, gate: [], now: t0, policy: policy
        )
        let r1 = EntropyProvenance.resolve(
            bridgeConnected: true, bridgeStatus: s1, gate: [], now: t1, policy: policy
        )
        XCTAssertEqual(r0.currentBits!, 8.2, accuracy: 1e-9)
        XCTAssertEqual(r1.currentBits!, 3.1, accuracy: 1e-9)
    }

    func testSyntheticBridgeDoesNotInventLiveH() {
        let status = ShannonStatus(
            entropy: 7.2, deltaH: 0, collapsed: false,
            tokenCount: 1, backend: "demo", agent: nil
        )
        let r = EntropyProvenance.resolve(
            bridgeConnected: true, bridgeStatus: status, gate: [],
            now: Date(), policy: policy
        )
        XCTAssertFalse(r.isMeasured)
        XCTAssertNil(r.currentBits)
    }
}
