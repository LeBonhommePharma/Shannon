import XCTest
@testable import ShannonPill

/// Pure throttle for parity panel artifact I/O (ENH-008) — no window server.
final class ParityRefreshPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Force

    func testForceAlwaysRefreshesWithArtifactsEvenWhenClosedAndFresh() {
        let d = ParityRefreshPolicy.decision(
            now: t0.addingTimeInterval(0.1),
            lastRefresh: t0,
            force: true,
            panelVisible: false
        )
        XCTAssertTrue(d.shouldRefresh)
        XCTAssertTrue(d.includeArtifacts)
    }

    func testForceAlwaysRefreshesWithArtifactsWhenOpen() {
        let d = ParityRefreshPolicy.decision(
            now: t0,
            lastRefresh: t0,
            force: true,
            panelVisible: true
        )
        XCTAssertTrue(d.shouldRefresh)
        XCTAssertTrue(d.includeArtifacts)
    }

    // MARK: - Open (visible)

    func testOpenSkipsInsideOpenMinInterval() {
        let d = ParityRefreshPolicy.decision(
            now: t0.addingTimeInterval(ParityRefreshPolicy.openMinInterval - 0.01),
            lastRefresh: t0,
            force: false,
            panelVisible: true
        )
        XCTAssertFalse(d.shouldRefresh)
    }

    func testOpenRefreshesWithArtifactsAfterOpenMinInterval() {
        let d = ParityRefreshPolicy.decision(
            now: t0.addingTimeInterval(ParityRefreshPolicy.openMinInterval),
            lastRefresh: t0,
            force: false,
            panelVisible: true
        )
        XCTAssertTrue(d.shouldRefresh)
        XCTAssertTrue(d.includeArtifacts)
    }

    // MARK: - Closed (hidden)

    func testClosedSkipsInsideClosedMinInterval() {
        // Even past open interval (2s), closed path uses 15s.
        let d = ParityRefreshPolicy.decision(
            now: t0.addingTimeInterval(3.0),
            lastRefresh: t0,
            force: false,
            panelVisible: false
        )
        XCTAssertFalse(d.shouldRefresh)
        XCTAssertFalse(d.includeArtifacts)
    }

    func testClosedGateOnlyAfterClosedMinInterval() {
        let d = ParityRefreshPolicy.decision(
            now: t0.addingTimeInterval(ParityRefreshPolicy.closedMinInterval),
            lastRefresh: t0,
            force: false,
            panelVisible: false
        )
        XCTAssertTrue(d.shouldRefresh)
        XCTAssertFalse(
            d.includeArtifacts,
            "closed refresh must skip Claude/Codex tree walks"
        )
    }

    func testClosedSkipsJustUnderClosedMinInterval() {
        let d = ParityRefreshPolicy.decision(
            now: t0.addingTimeInterval(ParityRefreshPolicy.closedMinInterval - 0.01),
            lastRefresh: t0,
            force: false,
            panelVisible: false
        )
        XCTAssertFalse(d.shouldRefresh)
    }

    // MARK: - Interval constants + structural wire-up

    func testIntervalConstantsMatchContract() {
        XCTAssertEqual(ParityRefreshPolicy.openMinInterval, 2.0)
        XCTAssertEqual(ParityRefreshPolicy.closedMinInterval, 15.0)
    }

    func testSourceWiresPolicyAndPanelVisible() throws {
        let src = try String(
            contentsOf: URL(fileURLWithPath: #file)
                .deletingLastPathComponent() // ShannonPillTests
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // Pill
                .appendingPathComponent("Sources/ShannonPill/PanelSectionRegistry.swift")
        )
        XCTAssertTrue(src.contains("ParityRefreshPolicy"), "policy enum must live in registry")
        XCTAssertTrue(src.contains("includeArtifactReaders: includeArtifacts"))
        XCTAssertTrue(src.contains("panelVisible"))
        XCTAssertTrue(src.contains("closedMinInterval"))

        let popoverSrc = try String(
            contentsOf: URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/ShannonPill/MenuBarPopoverView.swift")
        )
        XCTAssertTrue(
            popoverSrc.contains("panelVisible = true"),
            "popover appear must mark panel visible"
        )
        XCTAssertTrue(
            popoverSrc.contains("panelVisible = false"),
            "popover disappear must mark panel hidden"
        )
        XCTAssertTrue(
            popoverSrc.contains("onDisappear"),
            "visibility must clear on disappear"
        )
    }
}
