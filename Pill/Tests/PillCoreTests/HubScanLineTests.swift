import XCTest
@testable import PillCore

final class HubScanLineTests: XCTestCase {

    func testCollapseWins() {
        let s = HubScanLine.resolve(
            collapseBits: 2.4,
            collapseDelta: -3.5,
            busyNames: ["Claude"],
            busyStatus: "working",
            benchmarkTitle: "12/85 · 1hpv",
            hubReady: true
        )
        XCTAssertTrue(s.contains("Entropy collapse"))
        XCTAssertTrue(s.contains("2.4"))
        XCTAssertTrue(s.contains("ΔH"))
    }

    func testBusySingleAndMulti() {
        XCTAssertEqual(
            HubScanLine.resolve(
                collapseBits: nil,
                busyNames: ["Grok Build"],
                busyStatus: "working",
                benchmarkTitle: nil,
                hubReady: true
            ),
            "Grok Build · working"
        )
        XCTAssertEqual(
            HubScanLine.resolve(
                collapseBits: nil,
                busyNames: ["a", "b", "c"],
                busyStatus: nil,
                benchmarkTitle: "34/85",
                hubReady: true
            ),
            "3 agents active"
        )
    }

    func testBenchmarkWhenIdle() {
        let s = HubScanLine.resolve(
            collapseBits: nil,
            busyNames: [],
            busyStatus: nil,
            benchmarkTitle: "12/85 · 1hpv",
            hubReady: true
        )
        XCTAssertEqual(s, "FlexAIDdS · 12/85 · 1hpv")
    }

    func testHubStatesHonest() {
        XCTAssertEqual(
            HubScanLine.resolve(
                collapseBits: nil, busyNames: [], busyStatus: nil,
                benchmarkTitle: nil, hubReady: true
            ),
            "Hub ready · no agents busy"
        )
        XCTAssertEqual(
            HubScanLine.resolve(
                collapseBits: nil, busyNames: [], busyStatus: nil,
                benchmarkTitle: nil, hubReady: false
            ),
            "Hub offline · start gate for FlexAIDdS"
        )
    }

    func testNoInventedSuccessRate() {
        let s = HubScanLine.resolve(
            collapseBits: nil,
            busyNames: [],
            busyStatus: nil,
            benchmarkTitle: "34/85",
            hubReady: true
        )
        XCTAssertFalse(s.contains("%"))
        XCTAssertFalse(s.contains("success"))
    }

    /// Call-site policy: bridge up does not make hub ready when gate socket is down.
    /// Matches GateHealthResolver "hub offline" badge (socketUp only).
    func testIsHubReadyIgnoresBridgeAlone() {
        XCTAssertFalse(
            HubScanLine.isHubReady(gateSocketUp: false, bridgeConnected: true),
            "bridge-only must not claim hub ready (FlexAIDdS/approvals need gate)"
        )
        XCTAssertTrue(HubScanLine.isHubReady(gateSocketUp: true, bridgeConnected: false))
        XCTAssertTrue(HubScanLine.isHubReady(gateSocketUp: true, bridgeConnected: true))
        XCTAssertFalse(HubScanLine.isHubReady(gateSocketUp: false, bridgeConnected: false))
    }

    /// End-to-end pure path used by MenuBarPopoverView + PillView wiring.
    func testGateDownBridgeUpScanLineMatchesOfflineBadge() {
        let r = HubScanLine.resolveAlignedWithGateBadge(
            gateSocketUp: false,
            bridgeConnected: true
        )
        XCTAssertTrue(r.consistentOffline)
        XCTAssertEqual(r.badgeLabel, "hub offline")
        XCTAssertTrue(r.scanLine.contains("offline"), r.scanLine)
        XCTAssertFalse(r.scanLine.lowercased().contains("hub ready"), r.scanLine)

        // Gate up + bridge down still ready (approvals path is the socket).
        let up = HubScanLine.resolveAlignedWithGateBadge(
            gateSocketUp: true,
            bridgeConnected: false
        )
        XCTAssertTrue(up.scanLine.contains("Hub ready"), up.scanLine)
        XCTAssertNotEqual(up.badgeLabel, "hub offline")
    }

    /// Shipped call-site pattern: isHubReady → resolve (no bare OR of bridge).
    func testShippedCallSitePatternGateDownIsOffline() {
        let gateAvailable = false
        let bridgeConnected = true
        let hubReady = HubScanLine.isHubReady(
            gateSocketUp: gateAvailable,
            bridgeConnected: bridgeConnected
        )
        let line = HubScanLine.resolve(
            collapseBits: nil,
            busyNames: [],
            busyStatus: nil,
            benchmarkTitle: nil,
            hubReady: hubReady
        )
        XCTAssertEqual(line, "Hub offline · start gate for FlexAIDdS")
        // Old bug: gateAvailable || bridgeConnected → true → "Hub ready"
        let buggy = gateAvailable || bridgeConnected
        XCTAssertTrue(buggy, "precondition: OR would have been true")
        XCTAssertNotEqual(
            HubScanLine.resolve(
                collapseBits: nil, busyNames: [], busyStatus: nil,
                benchmarkTitle: nil, hubReady: buggy
            ),
            line,
            "OR of bridge must not equal gate-socket policy line"
        )
    }
}
