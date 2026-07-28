import XCTest
import SwiftUI
@testable import ShannonTheme

/// AgentNotch-class chrome contract: island fill, radii, springs, attention ink.
final class AgentNotchChromeTests: XCTestCase {

    func testIslandRadiiMatchAgentNotchClosedOpen() {
        let c = AgentNotchChrome.closedRadii
        XCTAssertEqual(c.top, 6, accuracy: 0.01)
        XCTAssertEqual(c.bottom, 14, accuracy: 0.01)
        let o = AgentNotchChrome.openRadii
        XCTAssertEqual(o.top, 19, accuracy: 0.01)
        XCTAssertEqual(o.bottom, 24, accuracy: 0.01)
        // Outward lip deeper than top wing.
        XCTAssertGreaterThan(c.bottom, c.top)
        XCTAssertGreaterThan(o.bottom, o.top)
    }

    func testIslandSpringSingleSourcesFloat() {
        XCTAssertEqual(AgentNotchChrome.islandSpring, ShannonSpring.float)
        XCTAssertEqual(AgentNotchChrome.islandSpring.response, 0.48, accuracy: 1e-12)
        XCTAssertEqual(AgentNotchChrome.islandSpring.dampingFraction, 0.86, accuracy: 1e-12)
        // AppKit panel morph duration == float response (in-phase with SwiftUI).
        XCTAssertEqual(
            AgentNotchChrome.panelMorphDuration,
            ShannonSpring.float.panelDuration,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            AgentNotchChrome.panelMorphDuration,
            ShannonMotion.panelMorphDuration,
            accuracy: 1e-12
        )
        XCTAssertEqual(ShannonMotion.islandSpring, ShannonSpring.float)
    }

    func testIslandFillIsPureBlackSemanticToken() {
        // Color.notchIslandFill aliases AgentNotchChrome.islandFill.
        XCTAssertEqual(
            String(describing: Color.notchIslandFill),
            String(describing: AgentNotchChrome.islandFill)
        )
        XCTAssertEqual(AgentNotchChrome.islandExpandedFillOpacity, 0.92, accuracy: 1e-9)
        XCTAssertLessThan(AgentNotchChrome.islandHairlineQuiet, AgentNotchChrome.islandHairlineRest)
    }

    func testAttentionInkRolesHighContrast() {
        let brand = Color.shannonAccent
        // Needs-you is warning, never brand blue alone.
        XCTAssertEqual(
            String(describing: AgentNotchChrome.ink(for: .needsYou, styleInk: brand)),
            String(describing: Color.shannonWarning)
        )
        XCTAssertEqual(
            String(describing: AgentNotchChrome.ink(for: .finished, styleInk: brand)),
            String(describing: Color.shannonSuccess)
        )
        XCTAssertEqual(
            String(describing: AgentNotchChrome.ink(for: .collapse, styleInk: brand)),
            String(describing: Color.shannonError)
        )
        XCTAssertEqual(
            String(describing: AgentNotchChrome.ink(for: .working, styleInk: brand)),
            String(describing: brand)
        )
    }

    func testAttentionRoleParserFailClosed() {
        XCTAssertEqual(AgentNotchChrome.role(attentionRaw: "needsYou"), .needsYou)
        XCTAssertEqual(AgentNotchChrome.role(attentionRaw: "needs-you"), .needsYou)
        XCTAssertEqual(AgentNotchChrome.role(attentionRaw: "working"), .working)
        XCTAssertEqual(AgentNotchChrome.role(attentionRaw: "finished"), .finished)
        XCTAssertEqual(AgentNotchChrome.role(attentionRaw: "collapse"), .collapse)
        XCTAssertEqual(AgentNotchChrome.role(attentionRaw: "not-a-role"), .unknown)
        XCTAssertEqual(AgentNotchChrome.role(attentionRaw: ""), .unknown)
    }

    func testWingPolicyStillAgentNotchClass() {
        XCTAssertTrue(DynamicIslandGeometry.shouldWing(liveWork: true))
        XCTAssertTrue(DynamicIslandGeometry.shouldWing(liveWork: false, hasPendingAsk: true))
        XCTAssertTrue(DynamicIslandGeometry.shouldWing(liveWork: false, collapseAlarm: true))
        XCTAssertFalse(DynamicIslandGeometry.shouldWing(liveWork: false))
        let snap = AgentNotchChrome.policySnapshot
        XCTAssertEqual(snap["closedTopRadius"], "6.0")
        XCTAssertEqual(snap["openBottomRadius"], "24.0")
        XCTAssertEqual(snap["islandFill"], "pureBlack")
    }

    func testSwiftUIAnimationMatchesIslandSpring() {
        // `.shannonFloat` must read the same response/damping as chrome contract.
        XCTAssertEqual(ShannonSpring.float.response, AgentNotchChrome.islandSpring.response)
        XCTAssertEqual(
            ShannonSpring.float.dampingFraction,
            AgentNotchChrome.islandSpring.dampingFraction
        )
    }
}
