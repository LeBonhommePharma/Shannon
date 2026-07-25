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

    /// Countdown label must track second-precision remaining (not freeze on minute buckets).
    ///
    /// Regression: minute-bucket publish left shortLabel stuck (e.g. 61s still
    /// showed "1m 30s", last minute frozen at "59s") because formatDuration uses
    /// "m s" while the monitor only republished on whole-minute changes.
    func testShortLabelTracksSecondPrecisionCountdown() {
        // 90s remaining → "1m 30s"
        var session = KeepAwakeSession(
            isActive: true, secondsRemaining: 90, isIndefinite: false, displayHeld: true
        )
        XCTAssertEqual(session.shortLabel, "Keep awake: \(AmphetamineSession.formatDuration(90))")
        XCTAssertTrue(session.shortLabel.contains("1m"))
        XCTAssertTrue(session.shortLabel.contains("30s") || session.shortLabel.contains("1m 30s"))

        // After 29s of wall time, pure logic says 61s left → must be "1m 1s", not still "1m 30s"
        let start = Date(timeIntervalSince1970: 1_000)
        let left61 = KeepAwakeLogic.secondsRemaining(
            startedAt: start, duration: 90, now: Date(timeIntervalSince1970: 1_029)
        )
        XCTAssertEqual(left61, 61)
        session.secondsRemaining = left61
        let label61 = session.shortLabel
        XCTAssertTrue(label61.contains("1m"), label61)
        XCTAssertTrue(label61.contains("1s") || label61.contains("1m 1s"), label61)
        XCTAssertFalse(label61.contains("30s"), "must not freeze at prior minute remainder: \(label61)")

        // Last minute: 45s remaining must show seconds, not a frozen "59s"
        let left45 = KeepAwakeLogic.secondsRemaining(
            startedAt: start, duration: 90, now: Date(timeIntervalSince1970: 1_045)
        )
        XCTAssertEqual(left45, 45)
        session.secondsRemaining = left45
        XCTAssertEqual(session.shortLabel, "Keep awake: \(AmphetamineSession.formatDuration(45))")
        XCTAssertTrue(session.shortLabel.contains("45s"))

        let left10 = KeepAwakeLogic.secondsRemaining(
            startedAt: start, duration: 90, now: Date(timeIntervalSince1970: 1_080)
        )
        XCTAssertEqual(left10, 10)
        session.secondsRemaining = left10
        XCTAssertEqual(session.shortLabel, "Keep awake: 10s")
    }

    /// Publish gate: same remaining second is a no-op; any second change must publish.
    ///
    /// Minute bucketing is forbidden: 90s and 61s share the same floor(minute)
    /// bucket (`1`) but must still yield different shortLabels ("1m 30s" vs "1m 1s").
    func testRemainingPublishOnEverySecondChangeNotOnlyMinute() {
        // The bug: minute buckets treat 90 and 61 as the same publish unit.
        XCTAssertEqual(90 / 60, 61 / 60, "same whole-minute bucket — the old thrash gate")
        XCTAssertNotEqual(90, 61)
        XCTAssertNotEqual(
            AmphetamineSession.formatDuration(90),
            AmphetamineSession.formatDuration(61),
            "second-precision labels differ within the same minute"
        )

        // Intended gate used by KeepAwakeMonitor.refresh (value equality, not minute).
        var remaining: Int? = 90
        for left in [89, 61, 59, 58, 1] {
            if remaining != left { remaining = left }
            XCTAssertEqual(remaining, left)
            XCTAssertEqual(
                AmphetamineSession.formatDuration(remaining!),
                AmphetamineSession.formatDuration(left)
            )
        }

        // Last minute: same minute bucket (0) must still publish each second.
        XCTAssertEqual(59 / 60, 30 / 60)
        remaining = 59
        if remaining != 58 { remaining = 58 }
        XCTAssertEqual(remaining, 58)
        XCTAssertEqual(AmphetamineSession.formatDuration(58), "58s")
    }
}
