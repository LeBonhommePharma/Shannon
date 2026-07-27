// DesktopCompanionRefreshCadence.swift — adaptive poll for desktop pet presentation.
//
// Activity + bridge `objectWillChange` already rebuild the companion on real
// state flips. A wall timer still runs so:
//   • busy / needs-you agents keep bubble ages + mood fluid (sub-second),
//   • quiet live agents can cross the idle→sleepy threshold honestly,
//   • fully quiet machines do not burn a 2 Hz recomposite forever.
//
// Precedence: active (busy/ask) → near-sleepy → quiet.

import Foundation

/// Pure interval selection for `DesktopCompanionModel` presentation refresh.
public enum DesktopCompanionRefreshCadence: Sendable {

    /// When any admitted agent is busy, blocked, or has a pending ask — keep
    /// bubble / mood in step with live work (aligned with agent hub cadence).
    public static let activePollInterval: TimeInterval = 0.55

    /// Coalesce poll when nothing is active and no agent is near sleepy.
    public static let quietPollInterval: TimeInterval = 12.0

    /// Poll while within `nearSleepyWindow` of the idle→sleepy flip.
    public static let nearSleepyPollInterval: TimeInterval = 1.0

    /// How close to `sleepyAfter` counts as "near" (must be ≥ quiet poll so a
    /// quiet tick cannot leap past the window without a near-window reschedule).
    public static let nearSleepyWindow: TimeInterval = 12.0

    /// Same threshold companions use for mood (single source of truth).
    public static var sleepyAfter: TimeInterval { CompanionMood.sleepyAfter }

    /// Hard floor / soft ceiling for injected intervals (tests / future prefs).
    public static let pollIntervalMin: TimeInterval = 0.35
    public static let pollIntervalMax: TimeInterval = 60.0

    public static func clampPollInterval(_ raw: TimeInterval) -> TimeInterval {
        min(max(raw, pollIntervalMin), pollIntervalMax)
    }

    /// True when presentation should track live work at active cadence.
    public static func hasActiveWork(_ agents: [AgentActivitySnapshot]) -> Bool {
        for a in agents {
            if a.status.isBusy, a.presence.canBeBusy { return true }
            if a.status == .blocked, a.presence.canBeBusy { return true }
        }
        return false
    }

    /// True when `secondsSinceSeen` is still below sleepy but within the
    /// fine-grained window (not already past the flip).
    public static func isNearSleepyThreshold(secondsSinceSeen: TimeInterval) -> Bool {
        let age = max(0, secondsSinceSeen)
        let remaining = sleepyAfter - age
        return remaining > 0 && remaining <= nearSleepyWindow
    }

    /// Seconds until the idle→sleepy flip, or `nil` when already past.
    public static func secondsUntilSleepy(secondsSinceSeen: TimeInterval) -> TimeInterval? {
        let remaining = sleepyAfter - max(0, secondsSinceSeen)
        return remaining > 0 ? remaining : nil
    }

    /// Select timer interval from raw ages (unit-test entry point).
    ///
    /// Any age still below `sleepyAfter` and within `nearSleepyWindow` of the
    /// flip → near-sleepy poll; otherwise → quiet. Empty input → quiet.
    /// Does **not** encode active work — use ``pollInterval(agents:now:hasPendingAsk:)``.
    public static func pollInterval(secondsSinceSeen ages: [TimeInterval]) -> TimeInterval {
        for age in ages where isNearSleepyThreshold(secondsSinceSeen: age) {
            return nearSleepyPollInterval
        }
        return quietPollInterval
    }

    /// Select timer interval from live agent snapshots.
    ///
    /// Precedence:
    /// 1. Pending ask or busy/blocked live agent → `activePollInterval`
    /// 2. Non-offline agent near sleepy threshold → `nearSleepyPollInterval`
    /// 3. Otherwise → `quietPollInterval`
    public static func pollInterval(
        agents: [AgentActivitySnapshot],
        now: Date = Date(),
        hasPendingAsk: Bool = false
    ) -> TimeInterval {
        if hasPendingAsk || hasActiveWork(agents) {
            return activePollInterval
        }
        let ages: [TimeInterval] = agents.compactMap { agent in
            if agent.presence == .offline { return nil }
            return max(0, now.timeIntervalSince(agent.updatedAt))
        }
        return pollInterval(secondsSinceSeen: ages)
    }

    /// Policy: active default is sub-second / responsive (not multi-second lag).
    public static func activeDefaultIsResponsive() -> Bool {
        activePollInterval >= pollIntervalMin
            && activePollInterval <= 1.0
    }

    /// Policy invariants for diagnostics / tests.
    public static var policySnapshot: [String: String] {
        [
            "activePollInterval": "\(activePollInterval)",
            "quietPollInterval": "\(quietPollInterval)",
            "nearSleepyPollInterval": "\(nearSleepyPollInterval)",
            "nearSleepyWindow": "\(nearSleepyWindow)",
            "sleepyAfter": "\(sleepyAfter)",
            "activeDefaultIsResponsive": "\(activeDefaultIsResponsive())",
        ]
    }
}
