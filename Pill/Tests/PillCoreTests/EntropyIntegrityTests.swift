import XCTest
@testable import PillCore

/// Agents must not be able to paint a self-report (or an untrusted source)
/// as the pill's measured Shannon entropy.
final class EntropyIntegrityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = EntropyPolicy(maxAge: 120, warnBits: 5, maxBits: 64, mode: .enforce)

    // MARK: Self-report never becomes a measurement

    func testSelfReportFactoryAlwaysReturnsNil() {
        for bits in [0.0, 1.0, 8.0, 12.0, 99.0] {
            XCTAssertNil(
                EntropyIntegrity.measurementFromSelfReport(
                    bits: bits, agentId: "claude_code",
                    measuredAt: now, now: now, policy: policy
                ),
                "self-report of \(bits) bits must never construct a measurement"
            )
        }
    }

    func testSelfReportKeysAreRecognised() {
        for key in ["shannon_H", "shannon_h", "self_H", "entropy_score", "gate_H", "claimed_h", "H_BITS"] {
            XCTAssertTrue(EntropySelfReportKey.matches(key), key)
        }
        XCTAssertFalse(EntropySelfReportKey.matches("task_summary"))
        XCTAssertFalse(EntropySelfReportKey.matches("text"))
    }

    func testScrubRemovesSelfReportFields() {
        let scrubbed = EntropyIntegrity.scrubSelfReportFields([
            "text": "hello",
            "shannon_H": 1.0,
            "entropy_score": 9.9,
            "task_id": "t1",
        ])
        XCTAssertEqual(scrubbed["text"] as? String, "hello")
        XCTAssertEqual(scrubbed["task_id"] as? String, "t1")
        XCTAssertNil(scrubbed["shannon_H"])
        XCTAssertNil(scrubbed["entropy_score"])
    }

    // MARK: Trusted sources only

    func testAcceptRejectsSyntheticBridge() {
        XCTAssertNil(EntropyIntegrity.accept(
            bits: 8.0, source: .bridge(backend: "demo"),
            measuredAt: now, now: now, policy: policy
        ))
        XCTAssertNil(EntropyIntegrity.accept(
            bits: 8.0, source: .bridge(backend: "idle"),
            measuredAt: now, now: now, policy: policy
        ))
    }

    func testAcceptAllowsGateComputed() {
        guard let m = EntropyIntegrity.accept(
            bits: 7.25,
            source: .gate(agentId: "science", presence: .live),
            measuredAt: now.addingTimeInterval(-5),
            now: now,
            policy: policy
        ) else {
            return XCTFail("gate-computed measurement must be accepted")
        }
        XCTAssertEqual(m.bits, 7.25, accuracy: 1e-9)
        XCTAssertEqual(m.source.agentId, "science")
    }

    func testAcceptAllowsRealBridgeBackend() {
        guard let m = EntropyIntegrity.accept(
            bits: 6.5, deltaH: -0.2, collapsed: false,
            source: .bridge(backend: "vllm"),
            measuredAt: now, now: now, policy: policy
        ) else {
            return XCTFail("real bridge backend must be accepted")
        }
        XCTAssertEqual(m.bits, 6.5, accuracy: 1e-9)
    }

    // MARK: Claim under-report detection

    func testHonestClaimDoesNotUnderReport() {
        XCTAssertFalse(EntropyIntegrity.claimUnderReports(
            claimBits: 3.0, measuredBits: 3.0
        ))
    }

    func testLyingClaimUnderReports() {
        // d = log2(3.0/1.0) ≈ 1.585 >= 1.5
        XCTAssertTrue(EntropyIntegrity.claimUnderReports(
            claimBits: 1.0, measuredBits: 3.0
        ))
    }

    func testMissingClaimIsNotALieAtThisLayer() {
        XCTAssertFalse(EntropyIntegrity.claimUnderReports(
            claimBits: nil, measuredBits: 8.0
        ))
        XCTAssertFalse(EntropyIntegrity.claimUnderReports(
            claimBits: 0, measuredBits: 8.0
        ))
    }

    // MARK: resolveHonest ignores self-report as measurement

    func testResolveHonestUsesGateNotClaim() {
        let gate = EntropyMeasurement(
            bits: 2.5,
            source: .gate(agentId: "codex", presence: .live),
            measuredAt: now.addingTimeInterval(-3),
            now: now,
            policy: policy
        )!
        let result = EntropyIntegrity.resolveHonest(
            agentId: "codex",
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate],
            selfReportClaim: 9.99, // agent tries to look healthy
            now: now,
            policy: policy
        )
        XCTAssertEqual(result.reading.currentBits ?? -1, 2.5, accuracy: 1e-9)
        // claim 9.99 vs measured 2.5 is over-claim, not under-report
        XCTAssertFalse(result.claimUnderReports)
    }

    func testResolveHonestFlagsUnderReportWithoutSubstituting() {
        let gate = EntropyMeasurement(
            bits: 4.0,
            source: .gate(agentId: "codex", presence: .live),
            measuredAt: now.addingTimeInterval(-3),
            now: now,
            policy: policy
        )!
        let result = EntropyIntegrity.resolveHonest(
            agentId: "codex",
            bridgeConnected: false,
            bridgeStatus: nil,
            gate: [gate],
            selfReportClaim: 1.0,
            now: now,
            policy: policy
        )
        XCTAssertEqual(result.reading.currentBits ?? -1, 4.0, accuracy: 1e-9)
        XCTAssertTrue(result.claimUnderReports)
        // Display still shows gate measurement, never the lie.
        XCTAssertEqual(
            result.reading.display(at: now, policy: policy)?.bits ?? -1,
            4.0, accuracy: 1e-9
        )
    }

    func testSyntheticBridgeCannotLaunderViaResolve() {
        let status = ShannonStatus(
            entropy: 8.0, deltaH: -2.0, collapsed: true,
            tokenCount: 10, backend: "demo", agent: "science"
        )
        let result = EntropyIntegrity.resolveHonest(
            agentId: "science",
            bridgeConnected: true,
            bridgeStatus: status,
            gate: [],
            selfReportClaim: 8.0,
            now: now,
            policy: policy
        )
        XCTAssertFalse(result.reading.isMeasured)
        XCTAssertNil(result.reading.currentBits)
        XCTAssertNil(result.reading.display(at: now, policy: policy))
    }

    /// Two agents: a liar's claim cannot change the other agent's reading.
    func testPerAgentIsolationAgainstForeignClaim() {
        let rows = [
            EntropyMeasurement(
                bits: 8.0, source: .gate(agentId: "honest", presence: .live),
                measuredAt: now.addingTimeInterval(-2), now: now, policy: policy
            )!,
            EntropyMeasurement(
                bits: 2.0, source: .gate(agentId: "liar", presence: .live),
                measuredAt: now.addingTimeInterval(-2), now: now, policy: policy
            )!,
        ]
        let honest = EntropyIntegrity.resolveHonest(
            agentId: "honest", bridgeConnected: false, bridgeStatus: nil,
            gate: rows, selfReportClaim: 1.0, now: now, policy: policy
        )
        let liar = EntropyIntegrity.resolveHonest(
            agentId: "liar", bridgeConnected: false, bridgeStatus: nil,
            gate: rows, selfReportClaim: 9.0, now: now, policy: policy
        )
        XCTAssertEqual(honest.reading.currentBits ?? -1, 8.0, accuracy: 1e-9)
        XCTAssertEqual(liar.reading.currentBits ?? -1, 2.0, accuracy: 1e-9)
        XCTAssertTrue(honest.claimUnderReports) // claim 1 vs measured 8
        XCTAssertFalse(liar.claimUnderReports)  // claim 9 vs measured 2 is over-claim
    }
}
