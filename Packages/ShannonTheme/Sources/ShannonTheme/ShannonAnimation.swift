import SwiftUI

// MARK: - Motion
//
// Three springs, and nothing else. A shared vocabulary of motion is what makes
// the Mac pill, the iPhone card and the Watch glance feel like one product even
// though they never appear on screen together.
//
// The damping falls as the travelled distance grows: a tap barely overshoots,
// a pill unfurling from the notch is allowed a little bounce.

public extension Animation {

    /// Tap response, toggles, selection. Fast, essentially no overshoot.
    /// `spring(response: 0.25, dampingFraction: 0.80)`
    static let shannonSnap = Animation.spring(response: 0.25, dampingFraction: 0.80)

    /// Card expansion, sheet content, list reflow.
    /// `spring(response: 0.40, dampingFraction: 0.75)`
    static let shannonEase = Animation.spring(response: 0.40, dampingFraction: 0.75)

    /// Pill expand/collapse — the signature motion of the Mac app.
    /// `spring(response: 0.60, dampingFraction: 0.65)`
    static let shannonFloat = Animation.spring(response: 0.60, dampingFraction: 0.65)
}

public enum ShannonMotion {
    /// Period of the active-agent border pulse, in seconds.
    public static let pulsePeriod: Double = 1.6

    /// The pulse the pill border runs while an agent is working.
    public static let pillPulse = Animation
        .easeInOut(duration: pulsePeriod)
        .repeatForever(autoreverses: true)
}
