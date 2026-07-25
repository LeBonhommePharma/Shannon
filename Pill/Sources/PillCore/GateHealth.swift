import Foundation

/// Snapshot of whether the gate can deliver approvals and telemetry.
///
/// Drives the menu-bar status line so "hub offline" is never confused with
/// "nothing pending" or "detector measuring". Pure value — no I/O.
public struct GateHealth: Equatable, Sendable {
    public var socketUp: Bool
    public var dbAvailable: Bool
    public var pendingAskCount: Int
    /// Any current measured entropy reading (bridge or gate).
    public var measuredEntropy: Bool
    /// Short status line: `"hub offline"` / `"N pending"` / `"measuring"` /
    /// `"ready · no detector"` (never bare “ready” without measurement).
    public var label: String

    public init(
        socketUp: Bool,
        dbAvailable: Bool,
        pendingAskCount: Int,
        measuredEntropy: Bool,
        label: String
    ) {
        self.socketUp = socketUp
        self.dbAvailable = dbAvailable
        self.pendingAskCount = pendingAskCount
        self.measuredEntropy = measuredEntropy
        self.label = label
    }
}

/// Pure resolver for `GateHealth`. Priority: offline → pending → measuring → no detector.
public enum GateHealthResolver {
    /// Honest idle label when the socket is up but nothing is measuring.
    public static let unmeasuredLabel = "ready · no detector"

    /// Build a health snapshot from live monitor/bridge flags.
    ///
    /// - Parameters:
    ///   - socketUp: gate Unix socket present (approvals can be delivered).
    ///   - dbAvailable: hub DB readable (telemetry present).
    ///   - pendingAsks: open actionable approval count.
    ///   - hasMeasuredEntropy: any current measured entropy reading.
    public static func resolve(
        socketUp: Bool,
        dbAvailable: Bool,
        pendingAsks: Int,
        hasMeasuredEntropy: Bool
    ) -> GateHealth {
        let count = max(0, pendingAsks)
        let label: String
        if !socketUp {
            label = "hub offline"
        } else if count > 0 {
            label = "\(count) pending"
        } else if hasMeasuredEntropy {
            label = "measuring"
        } else {
            // Socket up ≠ collapse detection running — never green-wash.
            label = unmeasuredLabel
        }
        return GateHealth(
            socketUp: socketUp,
            dbAvailable: dbAvailable,
            pendingAskCount: count,
            measuredEntropy: hasMeasuredEntropy,
            label: label
        )
    }
}
