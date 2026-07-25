import XCTest
@testable import PillCore

final class GateHealthTests: XCTestCase {

    func testHubOfflineWinsOverPendingAndMeasuring() {
        let h = GateHealthResolver.resolve(
            socketUp: false,
            dbAvailable: false,
            pendingAsks: 3,
            hasMeasuredEntropy: true
        )
        XCTAssertEqual(h.label, "hub offline")
        XCTAssertFalse(h.socketUp)
        XCTAssertEqual(h.pendingAskCount, 3)
        XCTAssertTrue(h.measuredEntropy)
    }

    func testPendingCountLabel() {
        let one = GateHealthResolver.resolve(
            socketUp: true, dbAvailable: true, pendingAsks: 1, hasMeasuredEntropy: false
        )
        XCTAssertEqual(one.label, "1 pending")
        XCTAssertEqual(one.pendingAskCount, 1)

        let many = GateHealthResolver.resolve(
            socketUp: true, dbAvailable: true, pendingAsks: 4, hasMeasuredEntropy: true
        )
        XCTAssertEqual(many.label, "4 pending")
    }

    func testMeasuringWhenSocketUpAndHasEntropy() {
        let h = GateHealthResolver.resolve(
            socketUp: true, dbAvailable: true, pendingAsks: 0, hasMeasuredEntropy: true
        )
        XCTAssertEqual(h.label, "measuring")
        XCTAssertTrue(h.measuredEntropy)
    }

    func testUnmeasuredWhenSocketUpQuiet() {
        let h = GateHealthResolver.resolve(
            socketUp: true, dbAvailable: true, pendingAsks: 0, hasMeasuredEntropy: false
        )
        // Never bare "ready" — that green-washed a dead detector.
        XCTAssertEqual(h.label, GateHealthResolver.unmeasuredLabel)
        XCTAssertTrue(h.label.contains("no detector"))
        XCTAssertFalse(h.label == "ready")
        XCTAssertTrue(h.socketUp)
        XCTAssertTrue(h.dbAvailable)
        XCTAssertFalse(h.measuredEntropy)
    }

    func testNegativePendingClampedToZero() {
        let h = GateHealthResolver.resolve(
            socketUp: true, dbAvailable: false, pendingAsks: -2, hasMeasuredEntropy: false
        )
        XCTAssertEqual(h.pendingAskCount, 0)
        XCTAssertEqual(h.label, GateHealthResolver.unmeasuredLabel)
    }

    func testDbDownDoesNotForceOfflineWhenSocketUp() {
        // Socket is the approval path; DB absence is telemetry-only.
        let h = GateHealthResolver.resolve(
            socketUp: true, dbAvailable: false, pendingAsks: 0, hasMeasuredEntropy: false
        )
        XCTAssertEqual(h.label, GateHealthResolver.unmeasuredLabel)
        XCTAssertFalse(h.dbAvailable)
    }

    func testEquality() {
        let a = GateHealthResolver.resolve(
            socketUp: true, dbAvailable: true, pendingAsks: 0, hasMeasuredEntropy: true
        )
        let b = GateHealthResolver.resolve(
            socketUp: true, dbAvailable: true, pendingAsks: 0, hasMeasuredEntropy: true
        )
        XCTAssertEqual(a, b)
    }
}
