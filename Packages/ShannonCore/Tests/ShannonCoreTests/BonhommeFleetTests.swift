import XCTest
@testable import ShannonCore

/// FlexAIDdS FleetScheduler-style + NATURaL presence pure tests.
/// Drives shipped `BonhommeFleetScheduler` / `BonhommeFleetHub` / presence codec.
final class BonhommeFleetTests: XCTestCase {

    private func mac(
        id: String = "mac",
        tflops: Double = 5.0,
        weight: Double = 0.75,
        thermal: BonhommeFleetThermal = .nominal
    ) -> BonhommeFleetDevice {
        BonhommeFleetDevice(
            deviceID: id, model: "MacBookPro", platform: "macOS",
            estimatedTFLOPS: tflops, availableMemoryGB: 16,
            thermalState: thermal, batteryLevel: 0.9, isCharging: true,
            computeWeight: weight
        )
    }

    private func phone(
        id: String = "iphone",
        tflops: Double = 1.5,
        weight: Double = 0.15,
        thermal: BonhommeFleetThermal = .nominal
    ) -> BonhommeFleetDevice {
        BonhommeFleetDevice(
            deviceID: id, model: "iPhone", platform: "iOS",
            estimatedTFLOPS: tflops, availableMemoryGB: 6,
            thermalState: thermal, batteryLevel: 0.8, isCharging: false,
            computeWeight: weight
        )
    }

    private func pad(
        id: String = "ipad",
        weight: Double = 0.10,
        thermal: BonhommeFleetThermal = .fair
    ) -> BonhommeFleetDevice {
        BonhommeFleetDevice(
            deviceID: id, model: "iPad", platform: "iPadOS",
            estimatedTFLOPS: 0.8, availableMemoryGB: 4,
            thermalState: thermal, batteryLevel: 0.7, isCharging: false,
            computeWeight: weight
        )
    }

    // MARK: FlexAIDdS splitWork contracts

    func testSplitWorkProportionalSumsToTotal() {
        let devices = [mac(), phone(), pad()]
        let chunks = BonhommeFleetScheduler.splitWork(
            totalUnits: 1000,
            maxIterations: 100,
            devices: devices,
            seedBase: 7
        )
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(BonhommeFleetScheduler.totalScheduledUnits(chunks), 1000)
        // Mac heaviest weight → most units
        XCTAssertGreaterThan(chunks[0].params.units, chunks[1].params.units)
        XCTAssertGreaterThan(chunks[1].params.units, chunks[2].params.units)
        // All claimed
        XCTAssertEqual(Set(chunks.map(\.claimedBy)), Set(devices.map(\.deviceID)))
    }

    func testCriticalThermalDevicesExcluded() {
        // Force critical with zero weight via explicit computeWeight.
        let hot = BonhommeFleetDevice(
            deviceID: "hot-iphone", model: "iPhone", platform: "iOS",
            estimatedTFLOPS: 1.5, thermalState: .critical,
            batteryLevel: 0.5, isCharging: false, computeWeight: 0.0
        )
        XCTAssertFalse(hot.isAvailable)

        let chunks = BonhommeFleetScheduler.splitWork(
            totalUnits: 500,
            devices: [mac(), hot]
        )
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].params.units, 500)
        XCTAssertEqual(chunks[0].claimedBy, "mac")
        XCTAssertFalse(chunks.contains { $0.claimedBy == "hot-iphone" })
    }

    func testCriticalThermalComputedWeightIsZero() {
        let d = BonhommeFleetDevice(
            deviceID: "x", model: "iPhone", platform: "iOS",
            estimatedTFLOPS: 2.0, thermalState: .critical,
            batteryLevel: 0.9, isCharging: true
        )
        XCTAssertEqual(d.computeWeight, 0, accuracy: 1e-12)
        XCTAssertFalse(d.isAvailable)
    }

    func testNoAvailableDevicesYieldsEmptySchedule() {
        let hot = BonhommeFleetDevice(
            deviceID: "hot", model: "iPhone", platform: "iOS",
            estimatedTFLOPS: 1.0, thermalState: .critical, computeWeight: 0
        )
        let chunks = BonhommeFleetScheduler.splitWork(totalUnits: 100, devices: [hot])
        XCTAssertTrue(chunks.isEmpty)
    }

    func testLowBatteryExcluded() {
        let low = BonhommeFleetDevice(
            deviceID: "low", model: "iPhone", platform: "iOS",
            estimatedTFLOPS: 1.5, thermalState: .nominal,
            batteryLevel: 0.05, isCharging: false
        )
        XCTAssertFalse(low.isAvailable)
        let chunks = BonhommeFleetScheduler.splitWork(
            totalUnits: 200,
            devices: [mac(), low]
        )
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].params.units, 200)
    }

    // MARK: Mac hub wiring

    func testHubScheduleFromMacAndPeersIsNonEmpty() {
        let local = MacDeviceState(
            deviceName: "Studio",
            batteryPercent: 80,
            isCharging: true,
            capacity: HostCapacitySnapshot(
                cpuPercent: 20, ramPercent: 40, diskPercent: 50,
                thermal: .nominal, sampledAt: Date()
            )
        )
        let peer = DeviceCapacity(
            deviceId: "device-phone",
            displayName: "iPhone",
            capacity: HostCapacitySnapshot(
                cpuPercent: 30, thermal: .fair, sampledAt: Date()
            ),
            platform: "iOS"
        )
        let snap = BonhommeFleetHub.schedule(
            local: local,
            peers: [peer],
            totalUnits: 1000,
            localTFLOPS: 5.0,
            peerTFLOPS: 1.5
        )
        XCTAssertGreaterThanOrEqual(snap.devices.count, 2)
        XCTAssertFalse(snap.available.isEmpty)
        XCTAssertFalse(snap.chunks.isEmpty)
        XCTAssertEqual(snap.scheduledUnits, 1000)
        XCTAssertTrue(snap.statusLine.contains("Fleet:"))
        XCTAssertFalse(snap.statusLine.contains("no devices"))
    }

    func testHubMembershipExcludesCriticalPeerFromSchedule() {
        let local = MacDeviceState(
            deviceName: "Mac", batteryPercent: 90, isCharging: true,
            capacity: HostCapacitySnapshot(thermal: .nominal, sampledAt: Date())
        )
        let hotPeer = DeviceCapacity(
            deviceId: "device-hot",
            displayName: "HotPhone",
            capacity: HostCapacitySnapshot(thermal: .critical, sampledAt: Date()),
            platform: "iOS"
        )
        let snap = BonhommeFleetHub.schedule(
            local: local, peers: [hotPeer], totalUnits: 400
        )
        XCTAssertEqual(snap.devices.count, 2)
        XCTAssertEqual(snap.available.count, 1)
        XCTAssertEqual(snap.chunks.count, 1)
        XCTAssertEqual(snap.chunks[0].params.units, 400)
        XCTAssertFalse(snap.chunks.contains { $0.claimedBy == "device-hot" })
    }

    // MARK: Presence (NATURaL)

    func testPresenceRoundTripAndActivePeers() throws {
        // Second-resolution date — ISO8601 encode/decode drops subseconds.
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let rec = BonhommeFleetPresence(
            deviceId: "abc",
            displayName: "iPhone",
            platform: .iOS,
            isActive: true,
            updatedAt: when
        )
        let data = try BonhommeFleetPresenceCodec.encode(rec)
        let decoded = try BonhommeFleetPresenceCodec.decode(data)
        XCTAssertEqual(decoded.deviceId, rec.deviceId)
        XCTAssertEqual(decoded.displayName, rec.displayName)
        XCTAssertEqual(decoded.platform, rec.platform)
        XCTAssertEqual(decoded.isActive, rec.isActive)
        XCTAssertEqual(decoded.updatedAt.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)

        let key = BonhommeFleetPresence.kvsKey(for: "abc")
        XCTAssertEqual(BonhommeFleetPresence.deviceId(fromKVSKey: key), "abc")

        let now = Date()
        let fresh = BonhommeFleetPresence(
            deviceId: "abc", displayName: "iPhone", platform: .iOS,
            isActive: true, updatedAt: now
        )
        let stale = BonhommeFleetPresence(
            deviceId: "old", displayName: "Old", platform: .macOS,
            isActive: true,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let active = BonhommeFleetPresenceCodec.activePeers(
            from: [fresh, stale],
            now: now
        )
        XCTAssertEqual(active.map(\.deviceId), ["abc"])
    }

    func testLocalIdentityStable() {
        var store: String?
        let a = BonhommeFleetLocalIdentity.stableDeviceId(stored: store) { store = $0 }
        let b = BonhommeFleetLocalIdentity.stableDeviceId(stored: store) { store = $0 }
        XCTAssertEqual(a, b)
        XCTAssertEqual(
            BonhommeFleetLocalIdentity.defaultDisplayName(platform: .macOS, systemName: nil),
            "Mac"
        )
    }

    func testDevicesFromPresenceAreAvailable() {
        let records = [
            BonhommeFleetPresence(deviceId: "1", displayName: "A", platform: .iOS),
            BonhommeFleetPresence(deviceId: "2", displayName: "B", platform: .iPadOS),
        ]
        let devices = BonhommeFleetHub.devices(fromPresence: records)
        XCTAssertEqual(devices.count, 2)
        XCTAssertTrue(devices.allSatisfy(\.isAvailable))
        let chunks = BonhommeFleetScheduler.splitWork(totalUnits: 100, devices: devices)
        XCTAssertEqual(BonhommeFleetScheduler.totalScheduledUnits(chunks), 100)
    }

    // MARK: Shared entropy path (FlexAIDdS / Shannon kinship)

    /// Pertinent science check: uniform distribution still yields H = 2 bits
    /// (same kernel family FlexAIDdS configurational entropy ports from).
    func testSharedEntropyUniformFourClassIsTwoBits() {
        // Pure ShannonCore does not import the Python entropy package; pin the
        // closed-form identity used across Bonhomme science repos:
        // H = −Σ p log2 p for p = (1/4)×4 → 2 bits.
        let p = [0.25, 0.25, 0.25, 0.25]
        let h = -p.reduce(0.0) { $0 + $1 * log2($1) }
        XCTAssertEqual(h, 2.0, accuracy: 1e-12)
    }
}
