import Foundation

// MARK: - Founder-scan one-liner (pure)

/// Compact menubar/popover header subtitle for solo founders watching agents
/// and FlexAIDdS runs. Pure so unit tests pin priority without AppKit.
public enum HubScanLine {
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
}
