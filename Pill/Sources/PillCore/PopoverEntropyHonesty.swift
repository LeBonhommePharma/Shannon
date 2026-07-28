import Foundation

// MARK: - Entropy strip presentation (fail-closed)

/// Pure policy for ENTROPY strip / fleet H chrome on the expanded pill and
/// menu-bar popover. Synthetic bridge backends (`demo`, `idle`, …) must never
/// paint a measured-looking H badge or full rail.
public enum EntropyStripPresentation: Sendable {

    /// Whether the strip may show a numeric H badge as **measured**.
    public static func showsMeasuredBadge(
        reading: EntropyReading,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> Bool {
        reading.display(at: now, policy: policy) != nil
    }

    /// H / ΔH / z summary for the strip header — **never** falls back to raw
    /// `ShannonStatus.entropy` when the reading is synthetic or absent.
    public static func summaryLabel(
        reading: EntropyReading,
        bridgeStatus: ShannonStatus?,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> String? {
        guard let display = reading.display(at: now, policy: policy) else {
            return nil
        }
        // z-score only when this reading is measured (not stale-observe alone).
        let z: Double? = {
            guard reading.isMeasured, let status = bridgeStatus, !status.isSynthetic else {
                return nil
            }
            return status.zScore
        }()
        return EntropyRailLogic.summaryLabel(
            h: display.bits,
            deltaH: reading.measurement?.deltaH,
            zScore: z
        )
    }

    /// Watermark when a synthetic bridge is connected (demo / idle).
    /// `nil` when there is no synthetic connection to disclose.
    public static func syntheticWatermark(
        bridgeConnected: Bool,
        bridgeStatus: ShannonStatus?
    ) -> String? {
        guard bridgeConnected, let status = bridgeStatus, status.isSynthetic else {
            return nil
        }
        let backend = status.backend.trimmingCharacters(in: .whitespacesAndNewlines)
        if backend.isEmpty { return "simulated" }
        return "simulated · \(backend)"
    }

    /// Whether to paint the fluid/sparkline rail under the badge.
    /// Measured (or displayable stale-in-observe) only; never for synthetic alone.
    public static func showsRail(
        reading: EntropyReading,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> Bool {
        showsMeasuredBadge(reading: reading, now: now, policy: policy)
    }

    /// Fill 0…1 for the rail — same path as the H badge bits.
    /// Returns `nil` when the rail must be hidden.
    public static func railFill(
        reading: EntropyReading,
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> Double? {
        guard let display = reading.display(at: now, policy: policy) else {
            return nil
        }
        return display.fillFraction()
    }
}

// MARK: - Battery chrome when hub is idle

/// Pure battery time-estimate labels for HUD chrome.
///
/// When no agent is busy, avoid stuck **"Calculating…"** language that reads as
/// hub/agent progress. Prefer calm battery wording when the OS estimate is nil.
public enum BatteryChromePolicy: Sendable {

    /// Display time estimate next to the battery ring.
    ///
    /// - Parameters:
    ///   - agentBusy: true when at least one agent is busy (hub not idle).
    ///   - Prefer shipped `BatterySnapshot` fields via this pure entry point so
    ///     tests do not re-implement `timeLabel`.
    public static func timeLabel(
        percentage: Int,
        isCharging: Bool,
        minutesToFull: Int?,
        minutesToEmpty: Int?,
        agentBusy: Bool
    ) -> String {
        if isCharging {
            if percentage >= 100 { return "Charged" }
            if let m = minutesToFull, m > 0 {
                return "\(BatterySnapshot.formatMinutes(m)) to full"
            }
            // Unknown estimate: calm when idle, honest when agents are working.
            return agentBusy ? "Calculating…" : "Charging"
        }
        if let m = minutesToEmpty, m > 0 {
            return "\(BatterySnapshot.formatMinutes(m)) left"
        }
        return agentBusy ? "Calculating…" : "On battery"
    }

    /// Convenience from a snapshot + busy count.
    public static func timeLabel(
        snapshot: BatterySnapshot,
        busyCount: Int
    ) -> String {
        timeLabel(
            percentage: snapshot.percentage,
            isCharging: snapshot.isCharging,
            minutesToFull: snapshot.minutesToFull,
            minutesToEmpty: snapshot.minutesToEmpty,
            agentBusy: busyCount > 0
        )
    }
}

// MARK: - Expanded board density (companions vs entropy strip)

/// When the companion board already lists agents, suppress the per-agent
/// entropy strip if it would only echo the same ids with "no H".
public enum ExpandedBoardDensity: Sendable {

    /// Show the detailed per-agent entropy strip under the companion board.
    ///
    /// - `companionBoardVisible`: macOS 14+ companion list is on screen.
    /// - `anyListedAgentHasMeasuredH`: at least one listed agent has displayable H.
    ///
    /// When companions are visible and no agent has measured H, hide the strip
    /// (fleet demo H is handled by `EntropyStripPresentation` separately).
    public static func showPerAgentEntropyStrip(
        companionBoardVisible: Bool,
        anyListedAgentHasMeasuredH: Bool
    ) -> Bool {
        if !companionBoardVisible { return true }
        return anyListedAgentHasMeasuredH
    }

    /// Whether any reading in the map is displayable as H at `now`.
    public static func anyDisplayableH(
        readings: [String: EntropyReading],
        now: Date = Date(),
        policy: EntropyPolicy = .current
    ) -> Bool {
        readings.values.contains { $0.display(at: now, policy: policy) != nil }
    }
}
