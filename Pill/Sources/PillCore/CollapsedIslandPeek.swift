import Foundation
import ShannonTheme

// MARK: - Collapsed island peeks (AgentNotch-class density)

/// Pure policy for the **collapsed** notch island: quiet idle, ranked attention
/// peeks, dual-HUD chrome roles, and when trailing chips may appear.
///
/// Views bind this; they must not invent a second needs-you / working vocabulary
/// or a denser multi-metric stack on the closed island.
public enum CollapsedIslandPeek: Sendable {

    // MARK: Dual-HUD attention → chrome role (single map)

    /// Map live-surface attention to theme chrome roles so island + menu-bar
    /// badges cannot drift.
    public static func chromeRole(
        for attention: AgentLiveAttention
    ) -> AgentNotchChrome.AttentionRole {
        switch attention {
        case .needsYou: return .needsYou
        case .working: return .working
        case .finished: return .finished
        case .idle: return .idle
        case .unknown: return .unknown
        }
    }

    /// Collapse alarm always maps to Shannon’s entropy-collapse role.
    public static func chromeRole(
        collapseAlarm: Bool,
        attention: AgentLiveAttention
    ) -> AgentNotchChrome.AttentionRole {
        if collapseAlarm { return .collapse }
        return chromeRole(for: attention)
    }

    // MARK: Quiet vs attention peeks

    /// AgentNotch quiet idle: nothing needs the user and nothing is working.
    public static func isQuietIdle(
        collapseAlarm: Bool,
        pendingAsk: Bool,
        activeCount: Int
    ) -> Bool {
        !collapseAlarm && !pendingAsk && activeCount <= 0
    }

    /// Ranked peek kind for the closed island (AgentNotch peeks, not full board).
    public enum PeekKind: String, Sendable, Equatable, CaseIterable {
        /// Measured entropy collapse (Shannon differentiator).
        case collapse
        /// Human must approve / answer.
        case needsYou
        /// One or more agents working.
        case working
        /// Recent finished/done class (when not working/needs-you).
        case finished
        /// Minimal island — recessive quiet.
        case quiet
    }

    /// Priority: collapse → needs-you → working → finished → quiet.
    public static func primaryPeek(
        collapseAlarm: Bool,
        pendingAsk: Bool,
        workingCount: Int,
        finishedPrimary: Bool
    ) -> PeekKind {
        if collapseAlarm { return .collapse }
        if pendingAsk { return .needsYou }
        if workingCount > 0 { return .working }
        if finishedPrimary { return .finished }
        return .quiet
    }

    /// Chrome role for the primary peek (ink / badge wash).
    public static func chromeRole(for peek: PeekKind) -> AgentNotchChrome.AttentionRole {
        switch peek {
        case .collapse: return .collapse
        case .needsYou: return .needsYou
        case .working: return .working
        case .finished: return .finished
        case .quiet: return .idle
        }
    }

    // MARK: Trailing chip density (minimal closed island)

    /// Whether to show the multi-agent count capsule (AgentNotch “N agents”).
    /// Suppressed when quiet or when a higher-priority single peek owns the island.
    public static func showsMultiAgentCountChip(
        activeCount: Int,
        collapseAlarm: Bool,
        pendingAsk: Bool,
        hasUsageChip: Bool
    ) -> Bool {
        if hasUsageChip { return false }
        if collapseAlarm || pendingAsk { return false }
        return activeCount > 1
    }

    /// Measured entropy chip on the closed island — only when the glance
    /// presenter already produced a fail-closed label (never invent here).
    public static func showsMeasuredEntropyChip(label: String?) -> Bool {
        guard let label else { return false }
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.hasPrefix("H ")
    }

    /// Closed-island body should hide the primary label text (recessive quiet).
    public static func isRecessiveLabel(
        quietIdle: Bool,
        hasSomethingToSay: Bool
    ) -> Bool {
        quietIdle && !hasSomethingToSay
    }
}
