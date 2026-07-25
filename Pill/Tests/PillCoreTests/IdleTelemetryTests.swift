import XCTest
import Darwin
@testable import PillCore

/// `IdleTelemetry` used to synthesise `7.2 + 0.55*sin(2πt/6)` — a number in the
/// 6.65–7.75 bit range tagged `collapsed: false` — whenever no detector was
/// attached, so a dead detector rendered as a permanently healthy one. These
/// tests keep the animation and forbid the number.
final class IdleTelemetryTests: XCTestCase {

    // MARK: - The fabricated reading is gone

    /// The exact defect: the placeholder must never emit a value that could pass
    /// for a plausible entropy. `breath` is unit-free and bounded to 0…1, so any
    /// consumer that mistook it for bits would show an obviously-wrong sub-1-bit
    /// figure rather than a convincing one.
    func testBreathIsUnitFreeAndNeverInThePlausibleEntropyBand() {
        let t = IdleTelemetry(period: 6, phase: 0)
        for i in 0..<600 {
            let v = t.breath(at: Double(i) * 0.05)
            XCTAssertGreaterThanOrEqual(v, 0, "t=\(i)")
            XCTAssertLessThanOrEqual(v, 1, "t=\(i)")
            XCTAssertLessThan(v, 6.5, "a decoration must never land in the entropy band")
        }
    }

    /// The animation is still useful — it must actually move, or the surface is
    /// static again and the pill reads as dead.
    func testBreathStillAnimates() {
        let t = IdleTelemetry(period: 6, phase: 0)
        let samples = stride(from: 0.0, to: 6.0, by: 0.25).map { t.breath(at: $0) }
        let spread = (samples.max() ?? 0) - (samples.min() ?? 0)
        XCTAssertGreaterThan(spread, 0.9, "the breath should still traverse its range")
    }

    /// The publisher exposes an explicit absence, not a number.
    func testPublisherReportsAbsentDetector() async {
        let pub = await IdleTelemetryPublisher(telemetry: IdleTelemetry(period: 6, phase: 0))
        let reading = await pub.reading
        XCTAssertTrue(reading.isAbsent)
        XCTAssertEqual(reading.absence, .noDetector)
        XCTAssertNil(reading.currentBits)
        XCTAssertNil(reading.collapsed, "unknown is not false")
        XCTAssertNotEqual(reading.verdict, .healthy)
    }

    /// The legacy `ShannonStatus` shim, for the view call site still typed on it.
    /// It must be an unmistakable sentinel: zero, synthetic, and unable to yield
    /// a collapse verdict.
    func testLegacyStatusShimIsAnAbsentSentinelNotAReading() async {
        let pub = await IdleTelemetryPublisher()
        let status = await pub.status
        XCTAssertEqual(status.entropy, 0,
                       "no detector attached must not produce a numeric H")
        XCTAssertEqual(status.deltaH, 0)
        XCTAssertEqual(status.backend, "absent")
        XCTAssertTrue(status.isSynthetic)
        XCTAssertNil(status.measuredCollapsed, "nothing measured it, so it is not 'false'")
        XCTAssertFalse(EntropyProvenance.isMeasured(connected: true, displayed: status))
        XCTAssertFalse(EntropyProvenance.isMeasured(connected: false, displayed: status))
        XCTAssertNil(EntropyProvenance.companionDelta(connected: true, status: status))

        // The existing renderer guards on `entropy > 0`, so a zero sentinel
        // draws nothing at all rather than a fake badge.
        XCTAssertFalse(status.entropy > 0)
    }

    /// Resolving the sentinel must land on absence, never on a value.
    func testSentinelResolvesToAbsentUnderEveryMode() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for mode in EntropyPolicy.Mode.allCases {
            let policy = EntropyPolicy(mode: mode)
            for connected in [true, false] {
                let reading = EntropyProvenance.resolve(
                    bridgeConnected: connected,
                    bridgeStatus: IdleTelemetry.absentStatus,
                    gate: [], gateDBAvailable: true, now: now, policy: policy
                )
                XCTAssertTrue(reading.isAbsent, "mode=\(mode) connected=\(connected)")
                XCTAssertNil(reading.currentBits)
                XCTAssertNil(reading.display(at: now, policy: policy))
                XCTAssertNotEqual(reading.verdict(policy: policy), .healthy)
            }
        }
    }

    // MARK: - Determinism

    func testDefaultSeededIsDeterministic() {
        let a = IdleTelemetry.defaultSeeded()
        let b = IdleTelemetry.defaultSeeded()
        XCTAssertEqual(a.phase, b.phase, accuracy: 1e-12)
        XCTAssertEqual(a.breath(at: 42), b.breath(at: 42), accuracy: 1e-12)
    }

    func testPeriodFloorPreventsDivideByZero() {
        let t = IdleTelemetry(period: 0)
        XCTAssertGreaterThan(t.period, 0)
        XCTAssertTrue(t.breath(at: 0).isFinite)
    }
}

final class ProcessGuardTests: XCTestCase {

    func testAcquireAndSecondInstanceSeesLock() throws {
        let path = NSTemporaryDirectory() + "shannon-pill-test-\(UUID().uuidString).lock"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let (first, handle) = ProcessGuard.acquire(path: path)
        guard case .acquired = first, let handle else {
            return XCTFail("first acquire failed: \(first)")
        }
        defer { _ = handle }

        let (second, handle2) = ProcessGuard.acquire(path: path)
        XCTAssertNil(handle2)
        guard case .alreadyRunning(let pid) = second else {
            return XCTFail("expected alreadyRunning, got \(second)")
        }
        XCTAssertEqual(pid, getpid())
    }
}
