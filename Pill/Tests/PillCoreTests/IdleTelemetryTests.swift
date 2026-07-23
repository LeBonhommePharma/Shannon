import XCTest
import Darwin
@testable import PillCore

final class IdleTelemetryTests: XCTestCase {

    func testEntropyStaysInCalmBand() {
        let t = IdleTelemetry(baseEntropy: 7.2, amplitude: 0.55, period: 6, phase: 0)
        for i in 0..<60 {
            let h = t.entropy(at: Double(i) * 0.5)
            XCTAssertGreaterThan(h, 6.5, "t=\(i)")
            XCTAssertLessThan(h, 8.0, "t=\(i)")
        }
    }

    func testStatusUsesIdleBackend() {
        let s = IdleTelemetry().status(at: 0)
        XCTAssertEqual(s.backend, "idle")
        XCTAssertEqual(s.agent, "local")
        XCTAssertFalse(s.collapsed)
        XCTAssertEqual(s.tokenCount, 0)
        XCTAssertFalse(s.pillLabel.isEmpty)
    }

    func testDeltaHIsFiniteDifference() {
        let t = IdleTelemetry(baseEntropy: 7.0, amplitude: 1.0, period: 4, phase: 0)
        let at = 1.0
        let expected = t.entropy(at: at) - t.entropy(at: at - 1.0)
        XCTAssertEqual(t.deltaH(at: at), expected, accuracy: 1e-12)
    }

    func testDefaultSeededIsDeterministic() {
        let a = IdleTelemetry.defaultSeeded()
        let b = IdleTelemetry.defaultSeeded()
        XCTAssertEqual(a.phase, b.phase, accuracy: 1e-12)
        XCTAssertEqual(a.entropy(at: 42), b.entropy(at: 42), accuracy: 1e-12)
    }

    func testPeriodFloorPreventsDivideByZero() {
        let t = IdleTelemetry(period: 0)
        XCTAssertGreaterThan(t.period, 0)
        XCTAssertTrue(t.entropy(at: 0).isFinite)
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
