import XCTest
@testable import PillCore

/// Provenance is one rule, and every consumer of an entropy number must apply
/// it. The regression these pin down: the companion board reacted to
/// `bridge.connected` alone while the header, border, `~H` badge and tooltip
/// all required `isMeasured`, so `--demo` (a REAL socket serving
/// `8.0 + 2.0*sin(n/12)`) drove the companions into the alarmed `.wary` pose
/// over a reading the same pill was labelling "simulated".
final class EntropyProvenanceTests: XCTestCase {

    private func status(backend: String, deltaH: Double = -6.0) -> ShannonStatus {
        ShannonStatus(
            entropy: 2.1,
            deltaH: deltaH,
            collapsed: true,
            tokenCount: 512,
            backend: backend
        )
    }

    // MARK: isMeasured — the rule the rest of the pill already used

    func testIsMeasuredRejectsSyntheticBackendsEvenWhenConnected() {
        for backend in ["demo", "idle", "unknown", "", "  DEMO  "] {
            XCTAssertFalse(
                EntropyProvenance.isMeasured(connected: true, displayed: status(backend: backend)),
                "backend \(backend.debugDescription) is synthetic and must not read as measured"
            )
        }
    }

    func testIsMeasuredAcceptsRealBackendOnlyWhileConnected() {
        let real = status(backend: "vllm")
        XCTAssertTrue(EntropyProvenance.isMeasured(connected: true, displayed: real))
        XCTAssertFalse(EntropyProvenance.isMeasured(connected: false, displayed: real))
        XCTAssertFalse(EntropyProvenance.isMeasured(connected: true, displayed: nil))
    }

    // MARK: companionDelta — the consumer that had drifted

    /// The defect, minimally: connected + synthetic must yield no delta.
    func testCompanionDeltaSuppressedForSyntheticBackend() {
        for backend in ["demo", "idle", "unknown", ""] {
            XCTAssertNil(
                EntropyProvenance.companionDelta(
                    connected: true, status: status(backend: backend)
                ),
                "a \(backend.debugDescription) reading must never reach the companions"
            )
        }
    }

    func testCompanionDeltaPassesMeasuredReadingThrough() {
        XCTAssertEqual(
            EntropyProvenance.companionDelta(connected: true, status: status(backend: "vllm")),
            -6.0
        )
    }

    func testCompanionDeltaNilWhenBridgeDownOrIdle() {
        XCTAssertNil(EntropyProvenance.companionDelta(connected: false, status: status(backend: "vllm")))
        XCTAssertNil(EntropyProvenance.companionDelta(connected: true, status: nil))
    }

    /// The invariant, stated directly: the companions get a number exactly when
    /// the header, border and `~H` badge say the number is real. If these two
    /// can disagree, the pill can alarm about a value it is marking fake.
    func testCompanionDeltaAgreesWithIsMeasuredForEveryBackend() {
        for backend in ["demo", "idle", "unknown", "", "vllm", "openai", "transformers"] {
            for connected in [true, false] {
                let s = status(backend: backend)
                let measured = EntropyProvenance.isMeasured(connected: connected, displayed: s)
                let delta = EntropyProvenance.companionDelta(connected: connected, status: s)
                XCTAssertEqual(
                    delta != nil, measured,
                    "backend \(backend.debugDescription) connected=\(connected): "
                        + "companion delta \(String(describing: delta)) disagrees with isMeasured=\(measured)"
                )
            }
        }
    }

    // MARK: End to end — the pose the user actually sees

    /// `--demo` asserts collapse for ~29% of ticks. Fed straight through, that
    /// is a companion cowering at a sine wave.
    func testDemoBackendDoesNotDriveLiveCompanionWary() {
        let now = Date()
        let summary = AgentActivitySummary(agents: [
            AgentActivitySnapshot(
                id: "science", displayName: "Science", status: .idle,
                lastTask: "docking 1ACJ", source: "test",
                updatedAt: now, resumable: false, historyCount: 1, presence: .live
            ),
        ], scannedAt: now)

        let demo = EntropyProvenance.companionDelta(
            connected: true, status: status(backend: "demo")
        )
        let roster = CompanionRoster.build(from: summary, now: now, entropyDelta: demo)
        XCTAssertNotEqual(roster.first?.mood, .wary,
                          "a synthetic reading must not alarm the companions")

        // …and a real collapse still must.
        let measured = EntropyProvenance.companionDelta(
            connected: true, status: status(backend: "vllm")
        )
        let alarmed = CompanionRoster.build(from: summary, now: now, entropyDelta: measured)
        XCTAssertEqual(alarmed.first?.mood, .wary,
                       "a measured collapse must still alarm the companions")
    }
}
