import XCTest
@testable import ShannonCore

/// UX-007 — Reduce Motion gates for phone/pad card chrome.
final class MotionChromePolicyTests: XCTestCase {

    func testAllowsForeverPulseHonorsReduceMotion() {
        XCTAssertTrue(MotionChromePolicy.allowsForeverPulse(reduceMotion: false))
        XCTAssertFalse(MotionChromePolicy.allowsForeverPulse(reduceMotion: true))
    }

    func testShouldPulseRunningDotRequiresRunningAndMotion() {
        XCTAssertTrue(
            MotionChromePolicy.shouldPulseRunningDot(isRunning: true, reduceMotion: false)
        )
        XCTAssertFalse(
            MotionChromePolicy.shouldPulseRunningDot(isRunning: true, reduceMotion: true),
            "Reduce Motion must freeze the running-dot breath at full opacity"
        )
        XCTAssertFalse(
            MotionChromePolicy.shouldPulseRunningDot(isRunning: false, reduceMotion: false),
            "Idle / non-running dots must not pulse"
        )
        XCTAssertFalse(
            MotionChromePolicy.shouldPulseRunningDot(isRunning: false, reduceMotion: true)
        )
    }

    func testIdleCompanionMotionHonorsReduceMotion() {
        XCTAssertTrue(MotionChromePolicy.allowsIdleCompanionMotion(reduceMotion: false))
        XCTAssertFalse(MotionChromePolicy.allowsIdleCompanionMotion(reduceMotion: true))
    }

    func testRunningDotPolicyMatchesForeverPulse() {
        for reduce in [false, true] {
            XCTAssertEqual(
                MotionChromePolicy.shouldPulseRunningDot(isRunning: true, reduceMotion: reduce),
                MotionChromePolicy.allowsForeverPulse(reduceMotion: reduce)
            )
        }
    }

    /// Phone + pad must consult the shared policy (structural wiring).
    func testPhoneAndPadWireMotionChromePolicy() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let pad = (try? String(
            contentsOf: root.appendingPathComponent(
                "iPad/Sources/ShannonPad/Views/AgentCardView.swift"
            ),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            pad.contains("MotionChromePolicy"),
            "pad AgentCardView must gate PulseIfRunning via MotionChromePolicy"
        )
        XCTAssertTrue(
            pad.contains("accessibilityReduceMotion") || pad.contains("reduceMotion"),
            "pad PulseIfRunning must read Reduce Motion"
        )

        let phone = (try? String(
            contentsOf: root.appendingPathComponent("iOS/Sources/ShannonPhone/HomeView.swift"),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            phone.contains("MotionChromePolicy"),
            "phone AgentCard must gate running-dot pulse via MotionChromePolicy"
        )
        XCTAssertTrue(
            phone.contains("PulseIfRunning") || phone.contains("shouldPulseRunningDot"),
            "phone must wire a Reduce Motion–aware running pulse"
        )
    }
}
