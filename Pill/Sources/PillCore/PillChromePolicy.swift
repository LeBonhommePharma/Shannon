import Foundation

/// Pure, testable presentation policy for ShannonPill chrome.
///
/// Keeps “when to show / expand / teach” out of SwiftUI so unit tests can
/// assert aesthetics contracts without AppKit windows.
public enum PillChromePolicy {

    /// Dwell before hover expands the notch board (seconds).
    /// Instant hover-expand was twitchy (UX audit); a short dwell is intentional.
    public static let hoverExpandDwell: TimeInterval = 0.35

    /// Now Playing chrome only when a real track exists and no agent is busy.
    /// Empty / unavailable media must not paint a broken widget.
    public static func shouldShowMedia(hasTrack: Bool, busyCount: Int) -> Bool {
        hasTrack && busyCount <= 0
    }

    /// Whether a hover dwell should expand the board.
    public static func shouldExpandOnHover(
        dwellSeconds: TimeInterval,
        alreadyExpanded: Bool,
        delay: TimeInterval = hoverExpandDwell
    ) -> Bool {
        guard !alreadyExpanded else { return false }
        guard dwellSeconds.isFinite, delay.isFinite, delay >= 0 else { return false }
        return dwellSeconds >= delay
    }

    /// Forever-pulses (ask amber / collapse red borders) are suppressed under
    /// Reduce Motion; a solid attention border remains.
    public static func allowsForeverPulse(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// Idle waveform TimelineView motion — off under Reduce Motion or recessive quiet.
    public static func shouldAnimateWaveform(reduceMotion: Bool, isRecessive: Bool) -> Bool {
        !reduceMotion && !isRecessive
    }

    /// Operator legend: amber = human approval, red = measured entropy collapse.
    public static let statusLegend: String =
        "Amber = approval needed · Red = entropy collapse"

    /// Expanded board legend only while first-run coaching is still active.
    public static func shouldShowStatusLegend(firstRunPending: Bool) -> Bool {
        firstRunPending
    }

    /// Both affordances when ask + collapse fire together (dual badges).
    public static func showDualAlarmBadges(collapseAlarm: Bool, pendingAsk: Bool) -> Bool {
        collapseAlarm && pendingAsk
    }

    /// Consumer-facing empty roster line (no raw path dumps).
    public static let emptyRosterCopy: String =
        "⌘D attaches Terminal, Claude, Codex, Grok Build, or a browser. FlexAIDdS DatasetRunner progress appears when the hub records a benchmark_state row."

    /// Semantic chrome role for status glyphs (ask vs collapse).
    public enum StatusChromeRole: String, Sendable, Equatable {
        case idle
        case active
        case ask      // amber — human approval
        case collapse // red — measured entropy collapse
    }

    /// Token name (not Color) so tests assert legend mapping without SwiftUI.
    public enum StatusChromeToken: String, Sendable, Equatable {
        case tertiary
        case accent
        case warning  // amber — ask only
        case error    // red — collapse
        case success
    }

    /// Priority: collapse (red) beats ask (amber) beats active beats idle.
    public static func statusChromeRole(
        collapseAlarm: Bool,
        pendingAsk: Bool,
        busy: Bool
    ) -> StatusChromeRole {
        if collapseAlarm { return .collapse }
        if pendingAsk { return .ask }
        if busy { return .active }
        return .idle
    }

    /// Maps role → design token. Collapse must be `.error` (red), ask `.warning` (amber).
    public static func statusChromeToken(for role: StatusChromeRole) -> StatusChromeToken {
        switch role {
        case .collapse: return .error
        case .ask: return .warning
        case .active: return .accent
        case .idle: return .tertiary
        }
    }

    /// Short collapsed accessibility hint.
    public static let expandAccessibilityHint: String =
        "Click to expand or collapse agent status. Hover briefly to expand."
}
