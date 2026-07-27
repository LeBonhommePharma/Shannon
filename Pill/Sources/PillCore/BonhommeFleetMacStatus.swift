import Foundation
import ShannonCore

// MARK: - Mac hub fleet status (native Shannon path)

/// Pure Mac-facing Bonhomme Fleet + NATURaL SCI query used by Pill status / tests.
///
/// Builds membership from local Mac device + peers and returns a schedule
/// snapshot (FlexAIDdS split + NATURaL presence-ready). Exposes SCI demo line.
/// No CloudKit I/O / HealthKit.
public enum BonhommeFleetMacStatus: Sendable {

    /// NATURaL SCI demo (concentrated vs spread RR) for operator status.
    public static func naturalSCIStatusLine() -> String {
        NaturalSCIHub.demoStatusLine()
    }

    /// Schedule a representative fleet job across local + peers.
    public static func snapshot(
        local: MacDeviceState?,
        peers: [DeviceCapacity] = [],
        totalUnits: Int = 1000
    ) -> BonhommeFleetSnapshot {
        BonhommeFleetHub.schedule(
            local: local,
            peers: peers,
            totalUnits: totalUnits
        )
    }

    /// Operator line for multi-device footer / `./scripts/shannon fleet`.
    public static func statusLine(
        local: MacDeviceState?,
        peers: [DeviceCapacity] = [],
        totalUnits: Int = 1000
    ) -> String {
        snapshot(local: local, peers: peers, totalUnits: totalUnits).statusLine
    }

    /// Demo fixture: Mac + phone + pad (mirrors FlexAIDdS FleetSchedulerTests).
    public static func demoSnapshot(totalUnits: Int = 1000) -> BonhommeFleetSnapshot {
        let local = MacDeviceState(
            deviceName: "MacBookPro",
            batteryPercent: 90,
            isCharging: true,
            capacity: HostCapacitySnapshot(
                cpuPercent: 25,
                ramPercent: 40,
                diskPercent: 50,
                thermal: .nominal,
                sampledAt: Date()
            )
        )
        let peers: [DeviceCapacity] = [
            DeviceCapacity(
                deviceId: "device-iphone",
                displayName: "iPhone",
                capacity: HostCapacitySnapshot(
                    cpuPercent: 20, thermal: .nominal, sampledAt: Date()
                ),
                platform: "iOS"
            ),
            DeviceCapacity(
                deviceId: "device-ipad",
                displayName: "iPad",
                capacity: HostCapacitySnapshot(
                    cpuPercent: 15, thermal: .fair, sampledAt: Date()
                ),
                platform: "iPadOS"
            ),
        ]
        return snapshot(local: local, peers: peers, totalUnits: totalUnits)
    }
}
