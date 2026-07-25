import XCTest
@testable import PillCore

final class AmphetamineControlTests: XCTestCase {

    func testParseStatusActiveFinite() {
        let s = AmphetamineScript.parseStatusOutput("true|3600|false")
        XCTAssertEqual(s?.isActive, true)
        XCTAssertEqual(s?.secondsRemaining, 3600)
        XCTAssertFalse(s?.isIndefinite ?? true)
        XCTAssertEqual(s?.displaySleepAllowed, false)
        XCTAssertEqual(s?.availability, .available)
    }

    func testParseStatusInactive() {
        let s = AmphetamineScript.parseStatusOutput("false|0|true")
        XCTAssertEqual(s?.isActive, false)
        XCTAssertEqual(s?.availability, .available)
    }

    func testParseStatusIndefinite() {
        // sdef: 0 = infinite duration when active
        let s = AmphetamineScript.parseStatusOutput("true|0|false")
        XCTAssertEqual(s?.isActive, true)
        XCTAssertTrue(s?.isIndefinite ?? false)
        XCTAssertNil(s?.secondsRemaining)
        // Trigger-based (-1) also indefinite countdown
        let t = AmphetamineScript.parseStatusOutput("true|-1|false")
        XCTAssertTrue(t?.isIndefinite ?? false)
    }

    func testParseStatusNoSessionCode() {
        let s = AmphetamineScript.parseStatusOutput("false|-3|true")
        XCTAssertEqual(s?.isActive, false)
        XCTAssertNil(s?.secondsRemaining)
    }

    func testParseStatusGarbageFailClosed() {
        XCTAssertNil(AmphetamineScript.parseStatusOutput(""))
        XCTAssertNil(AmphetamineScript.parseStatusOutput("not a status line"))
    }

    func testParseStatusToleratesTrailingNoise() {
        let s = AmphetamineScript.parseStatusOutput("true|120|true\n")
        XCTAssertEqual(s?.secondsRemaining, 120)
    }

    func testStatusQueryScriptMentionsSuite() {
        let q = AmphetamineScript.statusQueryScript()
        XCTAssertTrue(q.contains("session is active"))
        XCTAssertTrue(q.contains("session time remaining"), q) // sdef command name
        XCTAssertTrue(q.contains("display sleep allowed"))
        XCTAssertTrue(q.contains("Amphetamine"))
    }

    func testStartScriptTimed() {
        let opts = AmphetamineStartOptions(duration: 45, interval: .minutes, displaySleepAllowed: false)
        let s = AmphetamineScript.startSessionScript(options: opts)
        XCTAssertTrue(s.contains("start new session"))
        XCTAssertTrue(s.contains("duration:45"))
        XCTAssertTrue(s.contains("interval:minutes"))
        XCTAssertTrue(s.contains("displaySleepAllowed:false"))
    }

    func testStartScriptIndefinite() {
        let opts = AmphetamineStartOptions(duration: nil, displaySleepAllowed: true)
        let s = AmphetamineScript.startSessionScript(options: opts)
        XCTAssertTrue(s.contains("start new session"))
        XCTAssertTrue(s.contains("duration:0"))
        XCTAssertTrue(s.contains("interval:0"))
        XCTAssertTrue(s.contains("displaySleepAllowed:true"))
    }

    func testEndScript() {
        let s = AmphetamineScript.endSessionScript()
        XCTAssertTrue(s.contains("end session"))
    }

    func testAutoStartEndPolicy() {
        XCTAssertTrue(AmphetamineScript.shouldAutoStartForAgents(
            agentsBusy: true, sessionActive: false, autoKeepAwakeEnabled: true
        ))
        XCTAssertFalse(AmphetamineScript.shouldAutoStartForAgents(
            agentsBusy: true, sessionActive: true, autoKeepAwakeEnabled: true
        ))
        XCTAssertFalse(AmphetamineScript.shouldAutoStartForAgents(
            agentsBusy: true, sessionActive: false, autoKeepAwakeEnabled: false
        ))
        XCTAssertTrue(AmphetamineScript.shouldAutoEndForAgents(
            agentsBusy: false, sessionActive: true, autoKeepAwakeEnabled: true
        ))
        XCTAssertFalse(AmphetamineScript.shouldAutoEndForAgents(
            agentsBusy: true, sessionActive: true, autoKeepAwakeEnabled: true
        ))
    }

    func testFormatDuration() {
        XCTAssertEqual(AmphetamineSession.formatDuration(45), "45s")
        XCTAssertEqual(AmphetamineSession.formatDuration(90), "1m 30s")
        XCTAssertEqual(AmphetamineSession.formatDuration(3600), "1h")
        XCTAssertEqual(AmphetamineSession.formatDuration(7200 + 120), "2h 2m")
    }

    func testShortLabelNotInstalled() {
        let s = AmphetamineSession(availability: .notInstalled)
        XCTAssertTrue(s.shortLabel.lowercased().contains("not installed"))
    }

    func testIsInstalledProbeDoesNotCrash() {
        // Real path check — true or false depending on machine; must not throw.
        _ = AmphetamineRunner.isInstalled()
    }

    func testAgentBusyDefaultOptions() {
        let o = AmphetamineStartOptions.agentBusyDefault
        XCTAssertEqual(o.duration, 2)
        XCTAssertEqual(o.interval, .hours)
        XCTAssertFalse(o.displaySleepAllowed)
    }
}
