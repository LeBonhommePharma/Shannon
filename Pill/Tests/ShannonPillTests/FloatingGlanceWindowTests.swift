import XCTest
import AppKit
import PillCore
import ShannonCore
@testable import ShannonPill

/// UX-058 — floating glance panel applies always-on-top policy and ships.
@MainActor
final class FloatingGlanceWindowTests: XCTestCase {

    func testPanelAppliesAlwaysOnTopPolicy() {
        let panel = FloatingGlancePanel(
            contentRect: CGRect(x: 0, y: 0, width: 220, height: 88)
        )
        defer { panel.orderOut(nil) }

        XCTAssertEqual(
            panel.level.rawValue,
            FloatingGlanceWindowPolicy.windowLevelRawValue
        )
        XCTAssertTrue(
            FloatingGlanceWindowPolicy.isAlwaysOnTopLevel(panel.level.rawValue)
        )
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(
            FloatingGlanceWindowPolicy.matchesAlwaysOnTop(
                levelRawValue: panel.level.rawValue,
                hidesOnDeactivate: panel.hidesOnDeactivate,
                canBecomeKey: panel.canBecomeKey,
                joinsAllSpaces: panel.collectionBehavior.contains(.canJoinAllSpaces)
            )
        )
    }

    func testControllerShowAppliesPolicySnapshot() {
        let activity = AgentActivityMonitor()
        let ctl = FloatingGlanceWindowController(activity: activity)
        ctl.show()
        defer { ctl.hide() }

        let snap = ctl.appliedPolicySnapshot
        XCTAssertEqual(snap["appliedHidesOnDeactivate"], "false")
        XCTAssertEqual(snap["appliedCanBecomeKey"], "false")
        XCTAssertEqual(snap["appliedJoinsAllSpaces"], "true")
        XCTAssertEqual(snap["appliedMatchesAlwaysOnTop"], "true")
        XCTAssertTrue(ctl.wantsVisible)
        XCTAssertNotNil(ctl.modelForTesting)
    }

    func testDefaultFrameIsOnScreen() {
        let size = FloatingGlanceWindowController.defaultSize
        let frame = FloatingGlanceWindowController.defaultFrame(size: size)
        XCTAssertEqual(frame.width, size.width)
        XCTAssertEqual(frame.height, size.height)
        let screens = NSScreen.screens
        if let first = screens.first {
            let union = screens.map(\.frame).reduce(first.frame) { $0.union($1) }
            XCTAssertTrue(
                union.intersects(frame) || union.contains(frame.origin),
                "frame \(frame) should touch screen union \(union)"
            )
        }
    }

    func testHideClearsWantsVisible() {
        let activity = AgentActivityMonitor()
        let ctl = FloatingGlanceWindowController(activity: activity)
        ctl.show()
        XCTAssertTrue(ctl.wantsVisible)
        ctl.hide()
        XCTAssertFalse(ctl.wantsVisible)
    }

    func testEmptyPresentationOnFreshModel() {
        let activity = AgentActivityMonitor()
        let model = FloatingGlanceModel(activity: activity)
        XCTAssertTrue(model.presentation.isEmpty)
        XCTAssertEqual(model.presentation.emptyCaption, FloatingGlance.emptyCaption)
    }
}