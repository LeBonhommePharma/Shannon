import Foundation

// MARK: - Companion card motion (phone · pad · Mac parity)

/// Pure, testable policy for nonessential chrome animation on companion surfaces.
///
/// Mirrors Mac `PillChromePolicy.allowsForeverPulse`: forever-pulses and idle
/// decorative loops are suppressed under Reduce Motion; solid attention chrome
/// (status dots, colors, labels) remains fully visible.
///
/// **UX-007:** phone agent cards and iPad hub cards / companion rail consult this
/// before running repeating opacity or wobble animations.
public enum MotionChromePolicy: Sendable {

    /// Forever-pulses (running status-dot breath, ask border, etc.) are off
    /// when the user has Reduce Motion enabled.
    public static func allowsForeverPulse(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// Whether a running-agent status dot should breathe on phone/pad cards.
    ///
    /// When false, keep full opacity — running is still encoded by color/label.
    public static func shouldPulseRunningDot(
        isRunning: Bool,
        reduceMotion: Bool
    ) -> Bool {
        isRunning && allowsForeverPulse(reduceMotion: reduceMotion)
    }

    /// Decorative idle companion loops (subtle wobble, idle sparkle).
    /// One-shot feedback (tap bounce) may still use `Animation.shannon(_:reduceMotion:)`.
    public static func allowsIdleCompanionMotion(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }
}
