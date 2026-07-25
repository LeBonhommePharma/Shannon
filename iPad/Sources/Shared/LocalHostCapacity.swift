import Foundation
import ShannonCore

/// Best-effort local capacity on iPhone / iPad (thermal + optional free disk).
/// Fail-closed for gauges the OS does not expose to third parties.
enum LocalHostCapacity {
    static func current(platform: String, now: Date = Date()) -> HostCapacitySnapshot {
        let thermal = HostThermalState.fromProcessInfoRawValue(
            ProcessInfo.processInfo.thermalState.rawValue
        )
        var diskPct: Double?
        var usedGB: Double?
        var totalGB: Double?
        var freeGB: Double?
        let path = NSHomeDirectory()
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let total = attrs[.systemSize] as? NSNumber,
           let free = attrs[.systemFreeSize] as? NSNumber {
            let t = total.doubleValue
            let f = free.doubleValue
            if t > 0 {
                let u = max(0, t - f)
                diskPct = HostCapacityLogic.diskUsedPercent(used: u, total: t)
                usedGB = u / 1e9
                totalGB = t / 1e9
                freeGB = f / 1e9
            }
        }
        return HostCapacitySnapshot(
            diskPercent: diskPct,
            diskUsedGB: usedGB,
            diskTotalGB: totalGB,
            diskFreeGB: freeGB,
            thermal: thermal,
            sampledAt: now
        )
    }
}
