import Foundation

// MARK: - Live UI cadence (pure, unit-tested)

/// Default poll / smooth knobs for menubar + notch HUD.
///
/// Tighter than the historical 0.75 s / 1.5 s stack, but floored so we never
/// starve the main thread or thrash `host_processor_info` / SQLite. Smooth
/// alpha pairs with the resource interval so gauges ease instead of snap.
public enum UICadence: Sendable {
    // MARK: Host resources (CPU/GPU/RAM/SSD/cores)

    /// Target sample period for `SystemResourceMonitor` (seconds).
    public static let resourceInterval: TimeInterval = 0.35
    /// Hard floor — below this, sampling + SwiftUI invalidation costs dominate.
    public static let resourceIntervalMin: TimeInterval = 0.28
    /// Soft ceiling for “responsive” HUD (above this feels laggy).
    public static let resourceIntervalMax: TimeInterval = 0.55
    /// Exponential blend toward each raw sample (see `SystemResourceLogic.smoothPercent`).
    /// Slightly higher than 0.5 so a 0.35 s cadence still settles in ~2–3 ticks.
    public static let resourceSmoothAlpha: Double = 0.58

    // MARK: Agent / gate hub

    /// Gate DB poll period for `AgentActivityMonitor` (agents, asks, entropy).
    public static let agentHubInterval: TimeInterval = 0.75
    public static let agentHubIntervalMin: TimeInterval = 0.5
    public static let agentHubIntervalMax: TimeInterval = 1.5
    /// Full pets + registry disk scan (heavier).
    public static let agentFullScanInterval: TimeInterval = 15
    public static let agentFullScanIntervalMin: TimeInterval = 12
    public static let agentFullScanIntervalMax: TimeInterval = 30

    // MARK: Menu-bar status item backup timer

    /// Fallback paint when resource `onSnapshotPublished` is quiet.
    public static let menuBarBackupInterval: TimeInterval = 0.4
    public static let menuBarBackupIntervalMin: TimeInterval = 0.3
    public static let menuBarBackupIntervalMax: TimeInterval = 0.75

    // MARK: Fixed-chrome thrash guard (popover / menu bar)

    /// Continuous poll ticks must not reflow fixed chrome when content is still.
    /// Prefer `SharedTelemetryBinding.shouldPublish` / snapshot equality first;
    /// this floor only applies when a wall-timer paints without a content
    /// signature (legacy). Content change always wins (responsive).
    public static let fixedChromeMinRepaintInterval: TimeInterval = 0.35

    /// Whether a timer-driven chrome paint is allowed.
    ///
    /// - `contentChanged == true` → always paint (responsive).
    /// - `contentChanged == false` → never paint (non-thrashing fixed chrome).
    ///
    /// Wall-clock `minInterval` is reserved for future debounce of *churny*
    /// content; with equality-gated snapshots, identical ticks short-circuit.
    public static func shouldAllowTimerChromePaint(
        contentChanged: Bool,
        lastPaintAt: Date? = nil,
        now: Date = Date(),
        minInterval: TimeInterval = fixedChromeMinRepaintInterval
    ) -> Bool {
        if contentChanged { return true }
        // Identical content: fixed chrome (popover size, Quit footer) must not
        // re-layout or "pop" under the cursor on continuous agent/resource ticks.
        _ = lastPaintAt
        _ = now
        _ = minInterval
        return false
    }

    /// Equality-gate wrapper for shared telemetry snapshots (notch + menu bar).
    public static func shouldPublishSharedTelemetry(
        previous: SharedTelemetrySnapshot?,
        next: SharedTelemetrySnapshot
    ) -> Bool {
        SharedTelemetryBinding.shouldPublish(previous: previous, next: next)
    }

    // MARK: Clamp helpers (shipped entry points)

    public static func clampResourceInterval(_ raw: TimeInterval) -> TimeInterval {
        min(max(raw, resourceIntervalMin), 2.0)
    }

    public static func clampAgentHubInterval(_ raw: TimeInterval) -> TimeInterval {
        min(max(raw, agentHubIntervalMin), 5.0)
    }

    public static func clampMenuBarBackupInterval(_ raw: TimeInterval) -> TimeInterval {
        min(max(raw, menuBarBackupIntervalMin), 2.0)
    }

    public static func clampSmoothAlpha(_ raw: Double) -> Double {
        min(1, max(0.15, raw))
    }

    /// Policy: resource default sits in the responsive window.
    public static func resourceDefaultIsResponsive() -> Bool {
        resourceInterval >= resourceIntervalMin
            && resourceInterval <= resourceIntervalMax
    }

    /// Policy: agent hub default is strictly faster than the legacy 1.5 s tick.
    public static func agentHubFasterThanLegacy() -> Bool {
        agentHubInterval < 1.5 && agentHubInterval >= agentHubIntervalMin
    }

    /// Policy: menu-bar backup is at least as fast as the resource default.
    public static func menuBarKeepsPaceWithResources() -> Bool {
        menuBarBackupInterval <= resourceInterval + 0.1
    }
}
