import SwiftUI

// MARK: - Motion
//
// A shared vocabulary of motion is what makes the Mac pill, the iPhone card
// and the Watch glance feel like one product even though they never appear on
// screen together.
//
// Tuned for macOS 27 Liquid Glass: slightly higher damping (less bounce),
// medium response so morphs feel continuous rather than snappy or floaty.
// The damping falls as the travelled distance grows: a tap barely overshoots,
// a pill unfurling from the notch is allowed a little bounce.

public extension Animation {

    /// Tap response, toggles, selection. Fast, essentially no overshoot.
    /// `spring(response: 0.25, dampingFraction: 0.82)`
    static let shannonSnap = Animation.spring(response: 0.25, dampingFraction: 0.82)

    /// Card expansion, sheet content, list reflow.
    /// `spring(response: 0.38, dampingFraction: 0.82)`
    static let shannonEase = Animation.spring(response: 0.38, dampingFraction: 0.82)

    /// Pill expand/collapse — signature notch morph (macOS 27 Liquid Glass).
    /// Slightly snappier + more damped than the original float so the island
    /// settles cleanly without a rubber-band aftertaste on 120 Hz panels.
    /// `spring(response: 0.48, dampingFraction: 0.86)`
    static let shannonFloat = Animation.spring(response: 0.48, dampingFraction: 0.86)

    /// Gauge fill / numeric tick / core bar — continuous, never bouncy.
    /// Snappier than earlier 0.32 so 0.35 s resource ticks still look wet.
    /// `spring(response: 0.26, dampingFraction: 0.93)`
    static let shannonLiquid = Animation.spring(response: 0.26, dampingFraction: 0.93)

    /// Chrome opacity, border glow, quiet↔active. Medium settle.
    /// `spring(response: 0.36, dampingFraction: 0.90)`
    static let shannonChrome = Animation.spring(response: 0.36, dampingFraction: 0.90)

    /// Prefer `preferred` unless Reduce Motion is on (then `nil` = instant).
    static func shannon(_ preferred: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : preferred
    }
}

public enum ShannonMotion {
    /// Period of the active-agent border pulse, in seconds.
    public static let pulsePeriod: Double = 1.6

    /// The pulse the pill border runs while an agent is working.
    public static let pillPulse = Animation
        .easeInOut(duration: pulsePeriod)
        .repeatForever(autoreverses: true)

    /// Panel frame morph duration when the NSWindow tracks content height.
    /// Matched to `shannonFloat` response so SwiftUI and AppKit stay in phase.
    public static let panelMorphDuration: TimeInterval = 0.36

    /// Popover open / section expand.
    public static let popoverMorphDuration: TimeInterval = 0.28
}
