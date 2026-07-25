import XCTest
@testable import PillCore

final class KeepAwakeTests: XCTestCase {

    func testAutoStartWhenAgentsBusy() {
        XCTAssertTrue(KeepAwakeLogic.shouldAutoStart(
            agentsBusy: true, sessionActive: false, autoEnabled: true
        ))
        XCTAssertFalse(KeepAwakeLogic.shouldAutoStart(
            agentsBusy: true, sessionActive: true, autoEnabled: true
        ))
        XCTAssertFalse(KeepAwakeLogic.shouldAutoStart(
            agentsBusy: true, sessionActive: false, autoEnabled: false
        ))
        XCTAssertFalse(KeepAwakeLogic.shouldAutoStart(
            agentsBusy: false, sessionActive: false, autoEnabled: true
        ))
    }

    func testAutoEndWhenAgentsIdle() {
        XCTAssertTrue(KeepAwakeLogic.shouldAutoEnd(
            agentsBusy: false, sessionActive: true, autoEnabled: true
        ))
        XCTAssertFalse(KeepAwakeLogic.shouldAutoEnd(
            agentsBusy: true, sessionActive: true, autoEnabled: true
        ))
        XCTAssertFalse(KeepAwakeLogic.shouldAutoEnd(
            agentsBusy: false, sessionActive: false, autoEnabled: true
        ))
    }

    func testSecondsRemainingCountdown() {
        let start = Date(timeIntervalSince1970: 1_000)
        let rem = KeepAwakeLogic.secondsRemaining(
            startedAt: start, duration: 120, now: Date(timeIntervalSince1970: 1_040)
        )
        XCTAssertEqual(rem, 80)
    }

    func testIndefiniteHasNoExpiry() {
        XCTAssertFalse(KeepAwakeLogic.isExpired(
            startedAt: Date(timeIntervalSince1970: 0),
            duration: nil,
            now: Date(timeIntervalSince1970: 9_999)
        ))
    }

    func testTimedSessionExpires() {
        XCTAssertTrue(KeepAwakeLogic.isExpired(
            startedAt: Date(timeIntervalSince1970: 0),
            duration: 60,
            now: Date(timeIntervalSince1970: 61)
        ))
    }

    func testShortLabelListsCaffeinateClassFeature() {
        let off = KeepAwakeSession(isActive: false)
        XCTAssertTrue(off.shortLabel.lowercased().contains("keep awake"))
        let on = KeepAwakeSession(isActive: true, isIndefinite: true, displayHeld: true)
        XCTAssertTrue(on.shortLabel.contains("∞") || on.shortLabel.lowercased().contains("sleep"))
    }
}
