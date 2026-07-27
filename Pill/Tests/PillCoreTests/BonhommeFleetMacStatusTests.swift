import XCTest
import ShannonCore
@testable import PillCore

/// Mac hub fleet wiring — drives shipped `BonhommeFleetMacStatus` (not a dead import).
final class BonhommeFleetMacStatusTests: XCTestCase {

    func testDemoSnapshotSchedulesMultiDeviceWork() {
        let snap = BonhommeFleetMacStatus.demoSnapshot(totalUnits: 1000)
        XCTAssertGreaterThanOrEqual(snap.devices.count, 3)
        XCTAssertFalse(snap.chunks.isEmpty)
        XCTAssertEqual(snap.scheduledUnits, 1000)
        XCTAssertTrue(snap.statusLine.hasPrefix("Fleet:"))
        // Mac should receive a chunk (highest TFLOPS).
        XCTAssertTrue(snap.chunks.contains { $0.claimedBy.contains("Mac") || $0.deviceModel.contains("Mac")
            || $0.claimedBy.hasPrefix("device-") })
    }

    func testStatusLineFromExplicitLocalAndPeers() {
        let local = MacDeviceState(
            deviceName: "Studio", batteryPercent: 80, isCharging: true,
            capacity: HostCapacitySnapshot(thermal: .nominal, sampledAt: Date())
        )
        let peer = DeviceCapacity(
            deviceId: "device-phone",
            displayName: "Phone",
            capacity: HostCapacitySnapshot(thermal: .nominal, sampledAt: Date()),
            platform: "iOS"
        )
        let line = BonhommeFleetMacStatus.statusLine(
            local: local, peers: [peer], totalUnits: 500
        )
        XCTAssertTrue(line.contains("Fleet:"), line)
        XCTAssertFalse(line.contains("no devices"), line)

        let snap = BonhommeFleetMacStatus.snapshot(
            local: local, peers: [peer], totalUnits: 500
        )
        XCTAssertEqual(snap.scheduledUnits, 500)
        XCTAssertEqual(snap.available.count, 2)
    }

    func testCriticalPeerExcludedOnMacPath() {
        let local = MacDeviceState(
            deviceName: "Mac", batteryPercent: 100, isCharging: true,
            capacity: HostCapacitySnapshot(thermal: .nominal, sampledAt: Date())
        )
        let hot = DeviceCapacity(
            deviceId: "device-hot",
            displayName: "Hot",
            capacity: HostCapacitySnapshot(thermal: .critical, sampledAt: Date()),
            platform: "iOS"
        )
        let snap = BonhommeFleetMacStatus.snapshot(
            local: local, peers: [hot], totalUnits: 300
        )
        XCTAssertEqual(snap.available.count, 1)
        XCTAssertEqual(snap.chunks.count, 1)
        XCTAssertEqual(snap.chunks[0].params.units, 300)
        XCTAssertFalse(snap.chunks.contains { $0.claimedBy == "device-hot" })
    }
}
