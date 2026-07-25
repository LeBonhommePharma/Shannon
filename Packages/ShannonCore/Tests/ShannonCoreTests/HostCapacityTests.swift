import XCTest
@testable import ShannonCore

final class HostCapacityTests: XCTestCase {

    // MARK: Ranking — most constrained first

    func testRam95BeatsCpu40() {
        let c = HostCapacityLogic.mostConstrained(cpu: 40, gpu: nil, ram: 95)
        XCTAssertEqual(c?.kind, .ram)
        XCTAssertEqual(c?.percent ?? 0, 95, accuracy: 1e-9)
    }

    func testDiskFullBeatsMildCpu() {
        let ranked = HostCapacityLogic.constrainedRanked(
            cpu: 30, gpu: 20, ram: 40, disk: 98, thermalPressure: 8
        )
        XCTAssertEqual(ranked.first?.kind, .disk)
        XCTAssertEqual(ranked.map(\.kind), [.disk, .ram, .cpu, .gpu, .thermal])
    }

    func testThermalCriticalBeatsDiskWhenEqualPercent() {
        // Equal 97%: thermal severity > disk severity
        let ranked = HostCapacityLogic.constrainedRanked(
            cpu: 10, gpu: nil, ram: 10, disk: 97, thermalPressure: 97
        )
        XCTAssertEqual(ranked.first?.kind, .thermal)
        XCTAssertEqual(ranked[1].kind, .disk)
    }

    func testSnapshotConstrainedRankedOrder() {
        let snap = HostCapacitySnapshot(
            cpuPercent: 40,
            ramPercent: 95,
            diskPercent: 70,
            thermal: .fair
        )
        // fair pressure 45, disk 70, ram 95, cpu 40
        XCTAssertEqual(snap.mostConstrained?.kind, .ram)
        XCTAssertEqual(snap.constrainedRanked.map(\.kind), [.ram, .disk, .thermal, .cpu])
    }

    func testIgnoresNilGauges() {
        let c = HostCapacityLogic.mostConstrained(
            cpu: 70, gpu: nil, ram: nil, disk: nil, thermalPressure: nil
        )
        XCTAssertEqual(c?.kind, .cpu)
    }

    func testAllNil() {
        XCTAssertNil(HostCapacityLogic.mostConstrained(
            cpu: nil, gpu: nil, ram: nil, disk: nil, thermalPressure: nil
        ))
        XCTAssertTrue(HostCapacitySnapshot().constrainedRanked.isEmpty)
    }

    // MARK: Disk math

    func testDiskUsedPercent() {
        XCTAssertEqual(HostCapacityLogic.diskUsedPercent(used: 400, total: 500)!, 80, accuracy: 1e-9)
        XCTAssertEqual(HostCapacityLogic.diskUsedPercent(used: 0, total: 100)!, 0, accuracy: 1e-9)
        XCTAssertNil(HostCapacityLogic.diskUsedPercent(used: 1, total: 0))
        XCTAssertNil(HostCapacityLogic.diskUsedPercent(used: -1, total: 8))
    }

    func testDiskFreeGB() {
        XCTAssertEqual(HostCapacityLogic.diskFreeGB(used: 10, total: 50)!, 40, accuracy: 1e-9)
        XCTAssertNil(HostCapacityLogic.diskFreeGB(used: nil, total: 50))
    }

    func testClampAndThermalPressure() {
        XCTAssertEqual(HostThermalState.nominal.pressurePercent, 8, accuracy: 1e-9)
        XCTAssertEqual(HostThermalState.critical.pressurePercent, 97, accuracy: 1e-9)
        XCTAssertEqual(HostThermalState.from(raw: 2), .serious)
        XCTAssertNil(HostThermalState.from(raw: 99))
        XCTAssertEqual(HostCapacityLogic.clampPct(150)!, 100, accuracy: 1e-9)
        XCTAssertNil(HostCapacityLogic.clampPct(.nan))
    }

    // MARK: Load balance

    func testPreferredDevicePicksLeastConstrained() {
        let a = DeviceCapacity(
            deviceId: "mac-a",
            displayName: "Hot Mac",
            capacity: HostCapacitySnapshot(cpuPercent: 92, ramPercent: 40)
        )
        let b = DeviceCapacity(
            deviceId: "mac-b",
            displayName: "Cool Mac",
            capacity: HostCapacitySnapshot(cpuPercent: 25, ramPercent: 30)
        )
        let pick = LoadBalancePolicy.preferredDevice(among: [a, b])
        XCTAssertEqual(pick?.deviceId, "mac-b")
    }

    func testPreferredDeviceSkipsBusyWhenHealthyExists() {
        let busy = DeviceCapacity(
            deviceId: "busy",
            displayName: "Busy",
            capacity: HostCapacitySnapshot(cpuPercent: 88, diskPercent: 50)
        )
        let ok = DeviceCapacity(
            deviceId: "ok",
            displayName: "OK",
            capacity: HostCapacitySnapshot(cpuPercent: 40)
        )
        XCTAssertEqual(
            LoadBalancePolicy.preferredDevice(among: [busy, ok], busyThreshold: 85)?.deviceId,
            "ok"
        )
    }

    func testShouldDeferWhenCritical() {
        let d = DeviceCapacity(
            deviceId: "x",
            displayName: "X",
            capacity: HostCapacitySnapshot(cpuPercent: 95)
        )
        XCTAssertTrue(LoadBalancePolicy.shouldDeferWork(on: d, threshold: 90))
        XCTAssertFalse(LoadBalancePolicy.shouldDeferWork(
            on: DeviceCapacity(
                deviceId: "y",
                displayName: "Y",
                capacity: HostCapacitySnapshot(cpuPercent: 50)
            ),
            threshold: 90
        ))
    }

    func testShouldRunLocallyDefersWhenPeerIsHealthier() {
        let local = DeviceCapacity(
            deviceId: "local",
            displayName: "Local",
            capacity: HostCapacitySnapshot(cpuPercent: 91, ramPercent: 80)
        )
        let peer = DeviceCapacity(
            deviceId: "peer",
            displayName: "Peer",
            capacity: HostCapacitySnapshot(cpuPercent: 20)
        )
        XCTAssertFalse(LoadBalancePolicy.shouldRunLocally(local: local, peers: [peer]))
        XCTAssertTrue(LoadBalancePolicy.shouldRunLocally(local: peer, peers: [local]))
    }

    func testShouldRunLocallyWhenAlone() {
        let local = DeviceCapacity(
            deviceId: "only",
            displayName: "Only",
            capacity: HostCapacitySnapshot(cpuPercent: 50)
        )
        XCTAssertTrue(LoadBalancePolicy.shouldRunLocally(local: local, peers: []))
    }

    func testLoadScoreIsMaxGauge() {
        let score = HostCapacityLogic.loadScore(
            cpu: 40, gpu: 10, ram: 90, disk: 20, thermalPressure: 8
        )
        XCTAssertEqual(score, 90, accuracy: 1e-9)
    }
}
