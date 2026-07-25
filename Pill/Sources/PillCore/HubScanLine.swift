import Foundation

// MARK: - Founder-scan one-liner (pure)

/// Compact menubar/popover header subtitle for solo founders watching agents
/// and FlexAIDdS runs. Pure so unit tests pin priority without AppKit.
public enum HubScanLine {
    /// Whether the founder scan may claim “Hub ready”.
    ///
    /// **Gate Unix socket only** — same signal as `GateHealth.socketUp` /
    /// `GateHealthResolver` offline path. The Shannon pill bridge being up does
    /// **not** make FlexAIDdS approvals or `benchmark_state` available; OR-ing
    /// `bridge.connected` produced "Hub ready" while the badge said "hub offline".
    public static func isHubReady(gateSocketUp: Bool, bridgeConnected: Bool = false) -> Bool {
        _ = bridgeConnected // deliberately ignored (call-site must not reintroduce OR)
        return gateSocketUp
    }

    /// Priority: measured collapse → busy agents → live benchmark title → hub state.
    /// Never invents entropy bits or success rates.
    public static func resolve(
        collapseBits: Double?,
        collapseDelta: Double? = nil,
        busyNames: [String],
        busyStatus: String? = nil,
        benchmarkTitle: String?,
        hubReady: Bool
    ) -> String {
        if let bits = collapseBits, bits.isFinite {
            let delta = collapseDelta.map { String(format: ", ΔH %+.1f", $0) } ?? ""
            return String(format: "Entropy collapse — H %.1f%@", bits, delta)
        }
        if busyNames.count == 1 {
            let name = busyNames[0]
            if let st = busyStatus, !st.isEmpty {
                return "\(name) · \(st)"
            }
            return name
        }
        if busyNames.count > 1 {
            return "\(busyNames.count) agents active"
        }
        if let bench = benchmarkTitle, !bench.isEmpty {
            return "FlexAIDdS · \(bench)"
        }
        if hubReady {
            return "Hub ready · no agents busy"
        }
        return "Hub offline · start gate for FlexAIDdS"
    }

    /// End-to-end pure path: gate-down + bridge-up must read offline (badge-aligned).
    public static func resolveAlignedWithGateBadge(
        collapseBits: Double? = nil,
        collapseDelta: Double? = nil,
        busyNames: [String] = [],
        busyStatus: String? = nil,
        benchmarkTitle: String? = nil,
        gateSocketUp: Bool,
        bridgeConnected: Bool,
        pendingAsks: Int = 0,
        hasMeasuredEntropy: Bool = false
    ) -> (scanLine: String, badgeLabel: String, consistentOffline: Bool) {
        let ready = isHubReady(gateSocketUp: gateSocketUp, bridgeConnected: bridgeConnected)
        let scan = resolve(
            collapseBits: collapseBits,
            collapseDelta: collapseDelta,
            busyNames: busyNames,
            busyStatus: busyStatus,
            benchmarkTitle: benchmarkTitle,
            hubReady: ready
        )
        let health = GateHealthResolver.resolve(
            socketUp: gateSocketUp,
            dbAvailable: false,
            pendingAsks: pendingAsks,
            hasMeasuredEntropy: hasMeasuredEntropy
        )
        // When idle (no collapse/busy/bench), scan "offline" must match badge.
        let idle = collapseBits == nil && busyNames.isEmpty
            && (benchmarkTitle == nil || benchmarkTitle?.isEmpty == true)
        let consistentOffline = !idle || (ready == health.socketUp)
            && (!ready ? scan.contains("offline") && health.label == "hub offline" : true)
        return (scan, health.label, consistentOffline)
    }
}
