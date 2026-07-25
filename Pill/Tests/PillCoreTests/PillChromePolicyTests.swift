import XCTest
@testable import PillCore

final class PillChromePolicyTests: XCTestCase {

    func testMediaHiddenWithoutTrackOrWhenBusy() {
        XCTAssertFalse(PillChromePolicy.shouldShowMedia(hasTrack: false, busyCount: 0))
        XCTAssertFalse(PillChromePolicy.shouldShowMedia(hasTrack: true, busyCount: 1))
        XCTAssertFalse(PillChromePolicy.shouldShowMedia(hasTrack: true, busyCount: 3))
        XCTAssertTrue(PillChromePolicy.shouldShowMedia(hasTrack: true, busyCount: 0))
    }

    func testHoverExpandRequiresDwellAndNotAlreadyExpanded() {
        XCTAssertFalse(
            PillChromePolicy.shouldExpandOnHover(dwellSeconds: 0.1, alreadyExpanded: false)
        )
        XCTAssertTrue(
            PillChromePolicy.shouldExpandOnHover(dwellSeconds: 0.35, alreadyExpanded: false)
        )
        XCTAssertTrue(
            PillChromePolicy.shouldExpandOnHover(dwellSeconds: 1.0, alreadyExpanded: false)
        )
        // Sticky: once open, hover does not re-assert expand (click dismisses).
        XCTAssertFalse(
            PillChromePolicy.shouldExpandOnHover(dwellSeconds: 1.0, alreadyExpanded: true)
        )
    }

    func testHoverExpandRejectsNonFinite() {
        XCTAssertFalse(
            PillChromePolicy.shouldExpandOnHover(dwellSeconds: .nan, alreadyExpanded: false)
        )
        XCTAssertFalse(
            PillChromePolicy.shouldExpandOnHover(dwellSeconds: .infinity, alreadyExpanded: false)
        )
    }

    func testReduceMotionDisablesForeverPulse() {
        XCTAssertTrue(PillChromePolicy.allowsForeverPulse(reduceMotion: false))
        XCTAssertFalse(PillChromePolicy.allowsForeverPulse(reduceMotion: true))
    }

    func testStatusLegendTeachesAmberAndRed() {
        let s = PillChromePolicy.statusLegend.lowercased()
        XCTAssertTrue(s.contains("amber"), PillChromePolicy.statusLegend)
        XCTAssertTrue(s.contains("red"), PillChromePolicy.statusLegend)
        XCTAssertTrue(s.contains("approval") || s.contains("ask"), PillChromePolicy.statusLegend)
        XCTAssertTrue(s.contains("collapse"), PillChromePolicy.statusLegend)
    }

    func testHoverDwellIsPositiveAndStable() {
        XCTAssertGreaterThan(PillChromePolicy.hoverExpandDwell, 0.2)
        XCTAssertLessThan(PillChromePolicy.hoverExpandDwell, 1.0)
    }

    func testWaveformAnimationGated() {
        XCTAssertTrue(PillChromePolicy.shouldAnimateWaveform(reduceMotion: false, isRecessive: false))
        XCTAssertFalse(PillChromePolicy.shouldAnimateWaveform(reduceMotion: true, isRecessive: false))
        XCTAssertFalse(PillChromePolicy.shouldAnimateWaveform(reduceMotion: false, isRecessive: true))
    }

    func testLegendGraduatesAfterFirstRun() {
        XCTAssertTrue(PillChromePolicy.shouldShowStatusLegend(firstRunPending: true))
        XCTAssertFalse(PillChromePolicy.shouldShowStatusLegend(firstRunPending: false))
    }

    func testDualAlarmBadges() {
        XCTAssertTrue(PillChromePolicy.showDualAlarmBadges(collapseAlarm: true, pendingAsk: true))
        XCTAssertFalse(PillChromePolicy.showDualAlarmBadges(collapseAlarm: true, pendingAsk: false))
        XCTAssertFalse(PillChromePolicy.showDualAlarmBadges(collapseAlarm: false, pendingAsk: true))
    }

    func testEmptyRosterCopyIsConsumerFacing() {
        let s = PillChromePolicy.emptyRosterCopy
        XCTAssertTrue(s.contains("⌘D"), s)
        XCTAssertFalse(s.contains("~/.shannon"), s)
        XCTAssertFalse(s.contains("pets/"), s)
    }

    /// Collapse chrome is red (error); ask is amber (warning) — never swapped.
    func testStatusChromeCollapseIsRedAskIsAmber() {
        let collapse = PillChromePolicy.statusChromeRole(
            collapseAlarm: true, pendingAsk: true, busy: true
        )
        XCTAssertEqual(collapse, .collapse)
        XCTAssertEqual(PillChromePolicy.statusChromeToken(for: collapse), .error)

        let ask = PillChromePolicy.statusChromeRole(
            collapseAlarm: false, pendingAsk: true, busy: true
        )
        XCTAssertEqual(ask, .ask)
        XCTAssertEqual(PillChromePolicy.statusChromeToken(for: ask), .warning)

        let busy = PillChromePolicy.statusChromeRole(
            collapseAlarm: false, pendingAsk: false, busy: true
        )
        XCTAssertEqual(busy, .active)
        XCTAssertEqual(PillChromePolicy.statusChromeToken(for: busy), .accent)

        let idle = PillChromePolicy.statusChromeRole(
            collapseAlarm: false, pendingAsk: false, busy: false
        )
        XCTAssertEqual(idle, .idle)
        XCTAssertEqual(PillChromePolicy.statusChromeToken(for: idle), .tertiary)

        // Token names match legend language (error=red, warning=amber).
        XCTAssertEqual(PillChromePolicy.StatusChromeToken.error.rawValue, "error")
        XCTAssertEqual(PillChromePolicy.StatusChromeToken.warning.rawValue, "warning")
        XCTAssertNotEqual(
            PillChromePolicy.statusChromeToken(for: .collapse),
            PillChromePolicy.statusChromeToken(for: .ask)
        )
    }
}
