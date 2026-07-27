import XCTest
import CoreGraphics
@testable import ShannonTheme

/// AgentNotch-style Dynamic Island geometry — pure radii / wing policy.
final class DynamicIslandGeometryTests: XCTestCase {

    func testClosedRadiiMatchAgentNotchClosedInsets() {
        // AgentNotch Models/NotchSizing.swift: closed (top: 6, bottom: 14)
        XCTAssertEqual(DynamicIslandGeometry.closedTopRadius, 6, accuracy: 0.01)
        XCTAssertEqual(DynamicIslandGeometry.closedBottomRadius, 14, accuracy: 0.01)
        let closed = DynamicIslandGeometry.radii(expanded: false)
        XCTAssertEqual(closed.top, 6, accuracy: 0.01)
        XCTAssertEqual(closed.bottom, 14, accuracy: 0.01)
    }

    func testOpenRadiiMatchAgentNotchOpenedInsets() {
        // AgentNotch: opened (top: 19, bottom: 24)
        XCTAssertEqual(DynamicIslandGeometry.openTopRadius, 19, accuracy: 0.01)
        XCTAssertEqual(DynamicIslandGeometry.openBottomRadius, 24, accuracy: 0.01)
        let open = DynamicIslandGeometry.radii(expanded: true)
        XCTAssertEqual(open.top, 19, accuracy: 0.01)
        XCTAssertEqual(open.bottom, 24, accuracy: 0.01)
    }

    func testBottomRadiusExceedsTopClosedAndOpen() {
        // Outward bottom lip is always larger than inward top wing.
        XCTAssertGreaterThan(
            DynamicIslandGeometry.closedBottomRadius,
            DynamicIslandGeometry.closedTopRadius
        )
        XCTAssertGreaterThan(
            DynamicIslandGeometry.openBottomRadius,
            DynamicIslandGeometry.openTopRadius
        )
    }

    func testInwardTopOutwardBottomKeyPoints() {
        let rect = CGRect(x: 0, y: 0, width: 220, height: 40)
        XCTAssertTrue(
            DynamicIslandGeometry.isInwardTopOutwardBottom(
                in: rect,
                topRadius: DynamicIslandGeometry.closedTopRadius,
                bottomRadius: DynamicIslandGeometry.closedBottomRadius
            )
        )
        let pts = DynamicIslandGeometry.outlineKeyPoints(
            in: rect,
            topRadius: 6,
            bottomRadius: 14
        )
        XCTAssertEqual(pts.topLeftInner.x, 6, accuracy: 0.01)
        XCTAssertEqual(pts.topLeftInner.y, 6, accuracy: 0.01)
        XCTAssertEqual(pts.bottomLeftOuter.x, 20, accuracy: 0.01) // 6+14
        XCTAssertEqual(pts.bottomLeftOuter.y, 40, accuracy: 0.01)
        XCTAssertEqual(pts.topRightInner.x, 214, accuracy: 0.01) // 220-6
        XCTAssertEqual(pts.bottomRightOuter.x, 200, accuracy: 0.01) // 220-6-14
    }

    func testShouldWingOnLiveWorkAskOrCollapse() {
        XCTAssertFalse(DynamicIslandGeometry.shouldWing(liveWork: false))
        XCTAssertTrue(DynamicIslandGeometry.shouldWing(liveWork: true))
        XCTAssertTrue(DynamicIslandGeometry.shouldWing(liveWork: false, hasPendingAsk: true))
        XCTAssertTrue(DynamicIslandGeometry.shouldWing(liveWork: false, collapseAlarm: true))
    }

    func testWingedWidthExtendsPastBaseAndClamps() {
        let base: CGFloat = 220
        let idle = DynamicIslandGeometry.closedWidth(
            baseWidth: base, winged: false, physicalNotch: true
        )
        XCTAssertEqual(idle, 220, accuracy: 0.01)

        let winged = DynamicIslandGeometry.closedWidth(
            baseWidth: base, winged: true, physicalNotch: true
        )
        XCTAssertEqual(
            winged,
            base + DynamicIslandGeometry.wingExtension * 2,
            accuracy: 0.01
        )
        XCTAssertGreaterThan(winged, base)
        XCTAssertLessThanOrEqual(winged, DynamicIslandGeometry.maxWingedWidth)

        // Non-physical: never wing.
        XCTAssertEqual(
            DynamicIslandGeometry.closedWidth(
                baseWidth: base, winged: true, physicalNotch: false
            ),
            base,
            accuracy: 0.01
        )

        // Clamp huge base.
        let huge = DynamicIslandGeometry.closedWidth(
            baseWidth: 400, winged: true, physicalNotch: true
        )
        XCTAssertEqual(huge, DynamicIslandGeometry.maxWingedWidth, accuracy: 0.01)
    }

    func testLayoutCollapsedWidthWingsOnPhysicalNotch() {
        let idle = ShannonLayout.Pill.collapsedWidth(
            notchWidth: 220, recessive: false, physicalNotch: true, winged: false
        )
        XCTAssertEqual(idle, 220, accuracy: 0.01)
        let live = ShannonLayout.Pill.collapsedWidth(
            notchWidth: 220, recessive: false, physicalNotch: true, winged: true
        )
        XCTAssertEqual(live, 220 + DynamicIslandGeometry.wingExtension * 2, accuracy: 0.01)
    }

    func testPolicySnapshotKeys() {
        let snap = DynamicIslandGeometry.policySnapshot
        for key in [
            "closedTopRadius", "closedBottomRadius",
            "openTopRadius", "openBottomRadius",
            "wingExtension", "maxWingedWidth",
        ] {
            XCTAssertNotNil(snap[key], "missing \(key)")
        }
    }

    func testNotchIslandShapePathIsNonEmpty() {
        let shape = NotchIslandShape(expanded: false)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 200, height: 32))
        XCTAssertFalse(path.isEmpty)
        let open = NotchIslandShape(expanded: true)
        XCTAssertFalse(open.path(in: CGRect(x: 0, y: 0, width: 400, height: 190)).isEmpty)
    }

    func testIslandRadiiHelperOnLayout() {
        let c = ShannonLayout.Pill.islandRadii(expanded: false)
        XCTAssertEqual(c.top, DynamicIslandGeometry.closedTopRadius, accuracy: 0.01)
        XCTAssertEqual(c.bottom, DynamicIslandGeometry.closedBottomRadius, accuracy: 0.01)
        let o = ShannonLayout.Pill.islandRadii(expanded: true)
        XCTAssertEqual(o.top, DynamicIslandGeometry.openTopRadius, accuracy: 0.01)
        XCTAssertEqual(o.bottom, DynamicIslandGeometry.openBottomRadius, accuracy: 0.01)
    }
}
