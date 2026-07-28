import SwiftUI
#if canImport(QuartzCore)
import QuartzCore
#endif

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
//
// AppKit panel morphs MUST use the same response / damping as SwiftUI springs
// (`ShannonSpring.float`) — mismatched curves are the #1 source of ProMotion jank.

/// Pure spring parameters shared by SwiftUI `Animation.spring` and AppKit
/// `NSAnimationContext` / Core Animation timing. Unit-testable without a window.
public struct ShannonSpring: Sendable, Equatable {
    public var response: Double
    public var dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
    }

    /// Tap / toggle — `shannonSnap`.
    public static let snap = ShannonSpring(response: 0.25, dampingFraction: 0.82)
    /// Card / sheet — `shannonEase`.
    public static let ease = ShannonSpring(response: 0.38, dampingFraction: 0.82)
    /// Island expand/collapse — `shannonFloat` (signature Dynamic Island morph).
    /// Snappier than a generic sheet spring so ProMotion reads as DI, not a window resize.
    public static let float = ShannonSpring(response: 0.40, dampingFraction: 0.88)
    /// Gauge / numeric — `shannonLiquid`.
    public static let liquid = ShannonSpring(response: 0.26, dampingFraction: 0.93)
    /// Chrome glow — `shannonChrome`.
    public static let chrome = ShannonSpring(response: 0.36, dampingFraction: 0.90)

    /// Approximate settle duration for AppKit frame morphs (≈ response × settle factor).
    /// Kept in lockstep with SwiftUI's perceptual settle for `float`.
    public var panelDuration: TimeInterval {
        // Under-damped spring settles ~1.0–1.2× response; use 1.0 so content morph
        // and panel resize complete together on ProMotion.
        response
    }

    /// Scale spring for accessibility (Reduce Motion → near-instant; Animation Speed).
    public func scaled(reduceMotion: Bool, animationSpeed: Double = 1.0) -> ShannonSpring {
        if reduceMotion {
            return ShannonSpring(response: 0.001, dampingFraction: 1.0)
        }
        let speed = animationSpeed.isFinite && animationSpeed > 0 ? animationSpeed : 1.0
        // Faster system animation speed → shorter response (same feel, less time).
        return ShannonSpring(
            response: max(0.05, response / speed),
            dampingFraction: dampingFraction
        )
    }
}

public extension Animation {

    /// Tap response, toggles, selection. Fast, essentially no overshoot.
    /// `spring(response: 0.25, dampingFraction: 0.82)`
    static let shannonSnap = Animation.spring(
        response: ShannonSpring.snap.response,
        dampingFraction: ShannonSpring.snap.dampingFraction
    )

    /// Card expansion, sheet content, list reflow.
    /// `spring(response: 0.38, dampingFraction: 0.82)`
    static let shannonEase = Animation.spring(
        response: ShannonSpring.ease.response,
        dampingFraction: ShannonSpring.ease.dampingFraction
    )

    /// Pill expand/collapse — signature notch morph (macOS 27 Liquid Glass).
    /// Signature notch morph — response/damping from `ShannonSpring.float`.
    static let shannonFloat = Animation.spring(
        response: ShannonSpring.float.response,
        dampingFraction: ShannonSpring.float.dampingFraction
    )

    /// Gauge fill / numeric tick / core bar — continuous, never bouncy.
    /// Snappier than earlier 0.32 so 0.35 s resource ticks still look wet.
    /// `spring(response: 0.26, dampingFraction: 0.93)`
    static let shannonLiquid = Animation.spring(
        response: ShannonSpring.liquid.response,
        dampingFraction: ShannonSpring.liquid.dampingFraction
    )

    /// Chrome opacity, border glow, quiet↔active. Medium settle.
    /// `spring(response: 0.36, dampingFraction: 0.90)`
    static let shannonChrome = Animation.spring(
        response: ShannonSpring.chrome.response,
        dampingFraction: ShannonSpring.chrome.dampingFraction
    )

    /// Prefer `preferred` unless Reduce Motion is on (then `nil` = instant).
    static func shannon(_ preferred: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : preferred
    }

    /// Spring from pure parameters (after Reduce Motion / Animation Speed scale).
    static func shannonSpring(_ spring: ShannonSpring, reduceMotion: Bool = false) -> Animation? {
        if reduceMotion { return nil }
        return .spring(response: spring.response, dampingFraction: spring.dampingFraction)
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
    /// Exactly `ShannonSpring.float.response` so AppKit and SwiftUI stay in phase.
    public static let panelMorphDuration: TimeInterval = ShannonSpring.float.panelDuration

    /// Popover open / section expand.
    public static let popoverMorphDuration: TimeInterval = ShannonSpring.ease.response

    /// Island expand spring (canonical).
    public static let islandSpring = ShannonSpring.float

    /// Whether forever-pulses may run (Reduce Motion kills them).
    public static func allowsForeverPulse(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// Effective spring for panel + content morph under accessibility.
    public static func islandSpring(
        reduceMotion: Bool,
        animationSpeed: Double = 1.0
    ) -> ShannonSpring {
        ShannonSpring.float.scaled(reduceMotion: reduceMotion, animationSpeed: animationSpeed)
    }

    /// AppKit-facing duration for the current island spring.
    public static func panelMorphDuration(
        reduceMotion: Bool,
        animationSpeed: Double = 1.0
    ) -> TimeInterval {
        if reduceMotion { return 0 }
        return islandSpring(reduceMotion: reduceMotion, animationSpeed: animationSpeed).panelDuration
    }

    // CAMediaTimingFunction is macOS/iOS/tvOS only — unavailable on watchOS even
    // when QuartzCore imports. Keep AppKit panel morph helpers off the watch.
    #if canImport(QuartzCore) && (os(macOS) || os(iOS) || os(tvOS))
    /// Core Animation timing function matched to `ShannonSpring.float` damping.
    ///
    /// Approximate a critically-ish damped ease (control points tuned so the
    /// panel settle tracks SwiftUI spring settle length).
    public static var floatTimingFunction: CAMediaTimingFunction {
        // Damping ~0.88 → soft ease-in-out (not linear, not bouncy).
        CAMediaTimingFunction(controlPoints: 0.20, 0.92, 0.32, 1.0)
    }

    public static func timingFunction(for spring: ShannonSpring) -> CAMediaTimingFunction {
        if spring.dampingFraction >= 0.99 {
            return CAMediaTimingFunction(name: .linear)
        }
        if spring.response <= 0.01 {
            return CAMediaTimingFunction(name: .linear)
        }
        // Higher damping → less overshoot → later second control point.
        let d = min(max(spring.dampingFraction, 0.5), 1.0)
        let c1: Float = 0.18 + Float(1.0 - d) * 0.12
        let c2: Float = 0.85 + Float(d - 0.5) * 0.2
        return CAMediaTimingFunction(controlPoints: c1, 0.90, 0.32, c2)
    }
    #endif
}
