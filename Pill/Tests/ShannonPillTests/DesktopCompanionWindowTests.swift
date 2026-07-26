import XCTest
import AppKit
import PillCore
@testable import ShannonPill

/// Desktop companion panel applies always-on-top policy from the pure contract.
@MainActor
final class DesktopCompanionWindowTests: XCTestCase {

    func testPanelAppliesAlwaysOnTopPolicy() {
        let panel = DesktopCompanionPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 160)
        )
        defer { panel.orderOut(nil) }

        XCTAssertEqual(
            panel.level.rawValue,
            DesktopCompanionWindowPolicy.windowLevelRawValue
        )
        XCTAssertTrue(
            DesktopCompanionWindowPolicy.isAlwaysOnTopLevel(panel.level.rawValue)
        )
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(
            DesktopCompanionWindowPolicy.matchesAlwaysOnTop(
                levelRawValue: panel.level.rawValue,
                hidesOnDeactivate: panel.hidesOnDeactivate,
                canBecomeKey: panel.canBecomeKey,
                joinsAllSpaces: panel.collectionBehavior.contains(.canJoinAllSpaces)
            )
        )
    }

    func testReassertReappliesLevelAndOrder() {
        let panel = DesktopCompanionPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 160)
        )
        defer { panel.orderOut(nil) }

        // Simulate something demoting the level.
        panel.level = .normal
        XCTAssertFalse(
            DesktopCompanionWindowPolicy.isAlwaysOnTopLevel(panel.level.rawValue)
        )
        panel.applyAlwaysOnTopPolicy()
        XCTAssertTrue(
            DesktopCompanionWindowPolicy.isAlwaysOnTopLevel(panel.level.rawValue)
        )
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    }

    func testControllerShowAppliesPolicySnapshot() {
        let activity = AgentActivityMonitor()
        let bridge = ShannonBridge()
        let ctl = DesktopCompanionWindowController(activity: activity, bridge: bridge)
        ctl.show()
        defer { ctl.hide() }

        let snap = ctl.appliedPolicySnapshot
        XCTAssertEqual(snap["appliedHidesOnDeactivate"], "false")
        XCTAssertEqual(snap["appliedCanBecomeKey"], "false")
        XCTAssertEqual(snap["appliedJoinsAllSpaces"], "true")
        XCTAssertEqual(snap["appliedMatchesAlwaysOnTop"], "true")
        if let levelStr = snap["appliedLevel"], let level = Int(levelStr) {
            XCTAssertTrue(DesktopCompanionWindowPolicy.isAlwaysOnTopLevel(level))
        } else {
            XCTFail("missing appliedLevel")
        }

        // reassert path exists and keeps policy.
        ctl.reassertVisibility()
        XCTAssertEqual(ctl.appliedPolicySnapshot["appliedMatchesAlwaysOnTop"], "true")
    }

    func testDefaultFrameIsOnScreen() {
        let size = DesktopCompanionWindowController.defaultSize
        let frame = DesktopCompanionWindowController.defaultFrame(size: size)
        XCTAssertEqual(frame.width, size.width)
        XCTAssertEqual(frame.height, size.height)
        // Should land within some screen's coordinate space.
        let screens = NSScreen.screens
        if let first = screens.first {
            let union = screens.map(\.frame).reduce(first.frame) { $0.union($1) }
            XCTAssertTrue(union.intersects(frame) || union.contains(frame.origin),
                          "frame \(frame) should touch screen union \(union)")
        }
    }

    func testDesktopCompanionTypesAreShippedNotStubs() {
        // Structural: controller + panel + host exist on the ShannonPill product.
        XCTAssertTrue(DesktopCompanionWindowController.defaultSize.width > 0)
        XCTAssertNotNil(DesktopCompanionWindowPolicy.policySnapshot["windowLevelRawValue"])
        let activity = AgentActivityMonitor()
        let bridge = ShannonBridge()
        let model = DesktopCompanionModel(activity: activity, bridge: bridge)
        // Empty roster → watching bubble (honest, non-work).
        XCTAssertFalse(model.presentation.bubble.claimsWork)
        XCTAssertEqual(
            model.presentation.bubble.text,
            CompanionBubbleText.emptyRosterText
        )
    }
}
