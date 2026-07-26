// DesktopCompanionRefreshCadence.swift — adaptive poll for desktop pet presentation.
//
// Activity + bridge `objectWillChange` already rebuild the companion. A wall
// timer only exists so `CompanionMood.sleepy` can flip when ages cross
// `sleepyAfter` without gate traffic. The historical fixed 2 s tick woke quiet
// machines forever; this policy uses a 30 s sleepy poll, tightening to 2 s only
// when the idle→sleepy threshold is near.

import Foundation

/// Pure interval selection for `DesktopCompanionModel` presentation refresh.
public enum DesktopCompanionRefreshCadence: Sendable {

    /// Coalesce poll when no agent is near the sleepy threshold (seconds).
    public static let quietPollInterval: TimeInterval = 30.0

    /// Poll while within `nearSleepyWindow` of the idle→sleepy flip.
    public static let nearSleepyPollInterval: TimeInterval = 2.0

    /// How close to `sleepyAfter` counts as "near" (must be ≥ quiet poll so a
    /// quiet tick cannot leap past the window without a near-window reschedule).
    public static let nearSleepyWindow: TimeInterval = 30.0

    /// Same threshold companions use for mood (single source of truth).
    public static var sleepyAfter: TimeInterval { CompanionMood.sleepyAfter }

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
    /// flip → 2 s; otherwise → 30 s quiet poll. Empty input → quiet.
    public static func pollInterval(secondsSinceSeen ages: [TimeInterval]) -> TimeInterval {
        for age in ages where isNearSleepyThreshold(secondsSinceSeen: age) {
            return nearSleepyPollInterval
        }
        return quietPollInterval
    }

    /// Select timer interval from live agent snapshots.
    ///
    /// Offline agents are already on the sleepy mood path (no wall-clock flip
    /// left to catch). Busy live agents are driven by activity ticks; ages are
    /// still considered so a quiet live agent can nod off honestly.
    public static func pollInterval(
        agents: [AgentActivitySnapshot],
        now: Date = Date()
    ) -> TimeInterval {
        let ages: [TimeInterval] = agents.compactMap { agent in
            if agent.presence == .offline { return nil }
            return max(0, now.timeIntervalSince(agent.updatedAt))
        }
        return pollInterval(secondsSinceSeen: ages)
    }

    /// Policy invariants for diagnostics / tests.
    public static var policySnapshot: [String: String] {
        [
            "quietPollInterval": "\(quietPollInterval)",
            "nearSleepyPollInterval": "\(nearSleepyPollInterval)",
            "nearSleepyWindow": "\(nearSleepyWindow)",
            "sleepyAfter": "\(sleepyAfter)",
        ]
    }
}
