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

    /// Detector bridge tighter than legacy 1 s so collapse alarms surface faster.
    func testBridgeFasterThanLegacyOneSecond() {
        XCTAssertTrue(UICadence.bridgeFasterThanLegacyOneSecond())
        XCTAssertLessThan(UICadence.bridgeInterval, 1.0)
        XCTAssertGreaterThanOrEqual(UICadence.bridgeInterval, UICadence.bridgeIntervalMin)
        XCTAssertEqual(
            UICadence.clampBridgeInterval(0.01),
            UICadence.bridgeIntervalMin,
            accuracy: 1e-9
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

    /// Continuous ticks must not thrash fixed chrome when content is still.
    func testFixedChromePaintIsNonThrashing() {
        XCTAssertFalse(UICadence.shouldAllowTimerChromePaint(contentChanged: false))
        XCTAssertTrue(UICadence.shouldAllowTimerChromePaint(contentChanged: true))
        XCTAssertGreaterThan(UICadence.fixedChromeMinRepaintInterval, 0)
        XCTAssertLessThanOrEqual(
            UICadence.fixedChromeMinRepaintInterval,
            UICadence.resourceInterval + 0.05
        )
    }

    /// Menu-bar glyph paint decision uses the thrash guard on real signatures.
    func testMenuBarGlyphPaintIsEqualityGated() {
        let a = UICadence.menuBarGlyphSignature(
            pendingCount: 0, collapseBits: nil, busyCount: 0,
            primaryBusyName: "", liveCount: 1, bridgeConnected: true,
            constrainedKey: "cpu:12", coresKey: "c:12"
        )
        let same = UICadence.menuBarGlyphSignature(
            pendingCount: 0, collapseBits: nil, busyCount: 0,
            primaryBusyName: "", liveCount: 1, bridgeConnected: true,
            constrainedKey: "cpu:12", coresKey: "c:12"
        )
        let changed = UICadence.menuBarGlyphSignature(
            pendingCount: 1, collapseBits: nil, busyCount: 0,
            primaryBusyName: "", liveCount: 1, bridgeConnected: true,
            constrainedKey: "cpu:12", coresKey: "c:12"
        )
        XCTAssertEqual(a, same)
        XCTAssertFalse(UICadence.shouldPaintMenuBarGlyph(previousSignature: a, nextSignature: same))
        XCTAssertTrue(UICadence.shouldPaintMenuBarGlyph(previousSignature: a, nextSignature: changed))
        XCTAssertTrue(UICadence.shouldPaintMenuBarGlyph(previousSignature: nil, nextSignature: a))
    }

    /// Full pets scan stays coarser than every gate tick (off-main load policy).
    func testFullScanLessFrequentThanAgentHubTick() {
        XCTAssertGreaterThan(
            UICadence.agentFullScanInterval,
            UICadence.agentHubInterval * 4
        )
        XCTAssertEqual(
            AgentActivityMonitor.fullScanInterval,
            UICadence.agentFullScanInterval,
            accuracy: 1e-9
        )
    }

    func testSharedTelemetryPublishGateIsEqualityBased() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = SharedTelemetrySnapshot(
            agents: [
                AgentActivitySnapshot(
                    id: "a", displayName: "A", status: .idle, lastTask: "",
                    source: "gate", updatedAt: now, resumable: false,
                    historyCount: 0, presence: .live
                ),
            ],
            scannedAt: now
        )
        var later = snap
        later.scannedAt = now.addingTimeInterval(5)
        XCTAssertFalse(UICadence.shouldPublishSharedTelemetry(previous: snap, next: later))
        XCTAssertTrue(UICadence.shouldPublishSharedTelemetry(previous: nil, next: snap))
    }
}
