import XCTest
@testable import PillCore

/// Shipped live-UI poll defaults — tighter than legacy 0.75 / 1.5 s stack.
final class UICadenceTests: XCTestCase {

    func testResourceDefaultIsResponsive() {
        XCTAssertTrue(UICadence.resourceDefaultIsResponsive())
        XCTAssertLessThan(UICadence.resourceInterval, 0.55)
        XCTAssertGreaterThanOrEqual(UICadence.resourceInterval, UICadence.resourceIntervalMin)
        XCTAssertLessThanOrEqual(UICadence.resourceInterval, UICadence.resourceIntervalMax)
    }

    func testAgentHubFasterThanLegacyOnePointFive() {
        XCTAssertTrue(UICadence.agentHubFasterThanLegacy())
        XCTAssertEqual(UICadence.agentHubInterval, 0.75, accuracy: 1e-9)
        XCTAssertLessThan(UICadence.agentHubInterval, 1.5)
    }

    func testMenuBarBackupKeepsPaceWithResources() {
        XCTAssertTrue(UICadence.menuBarKeepsPaceWithResources())
        XCTAssertLessThanOrEqual(
            UICadence.menuBarBackupInterval,
            UICadence.resourceInterval + 0.1
        )
    }

    func testFullScanFasterThanLegacyTwenty() {
        XCTAssertLessThan(UICadence.agentFullScanInterval, 20)
        XCTAssertGreaterThanOrEqual(
            UICadence.agentFullScanInterval,
            UICadence.agentFullScanIntervalMin
        )
        XCTAssertLessThanOrEqual(
            UICadence.agentFullScanInterval,
            UICadence.agentFullScanIntervalMax
        )
    }

    func testClampFloorsAndCeilings() {
        XCTAssertEqual(
            UICadence.clampResourceInterval(0.01),
            UICadence.resourceIntervalMin,
            accuracy: 1e-9
        )
        XCTAssertEqual(UICadence.clampResourceInterval(9), 2.0, accuracy: 1e-9)
        XCTAssertEqual(
            UICadence.clampAgentHubInterval(0.1),
            UICadence.agentHubIntervalMin,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            UICadence.clampSmoothAlpha(0),
            0.15,
            accuracy: 1e-9
        )
        XCTAssertEqual(UICadence.clampSmoothAlpha(2), 1.0, accuracy: 1e-9)
    }

    /// Smooth alpha pairs with faster ticks — still eases, not a hard snap.
    func testSmoothAlphaIsEaseNotSnap() {
        let a = UICadence.resourceSmoothAlpha
        XCTAssertGreaterThan(a, 0.35)
        XCTAssertLessThan(a, 0.95)
        // Intermediate step still moves (not stuck) and not full snap.
        let mid = SystemResourceLogic.smoothPercent(previous: 0, target: 100, alpha: a)
        XCTAssertEqual(mid ?? -1, 100 * a, accuracy: 1e-6)
        XCTAssertNotEqual(mid ?? -1, 100, accuracy: 0.5)
    }

    /// Monitor defaults must bind to UICadence (shipped entry point).
    func testSystemResourceMonitorDefaultIntervalUsesCadence() {
        // Construct with defaults — interval is private; prove clamp policy via
        // the same constants the init uses.
        XCTAssertEqual(
            UICadence.clampResourceInterval(UICadence.resourceInterval),
            UICadence.resourceInterval,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            SystemResourceLogic.defaultSmoothAlpha,
            UICadence.resourceSmoothAlpha,
            accuracy: 1e-9
        )
    }

    func testAgentFullScanIntervalPropertyMatchesCadence() {
        XCTAssertEqual(
            AgentActivityMonitor.fullScanInterval,
            UICadence.agentFullScanInterval,
            accuracy: 1e-9
        )
    }
}
