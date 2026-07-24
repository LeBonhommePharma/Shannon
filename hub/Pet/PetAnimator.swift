// PetAnimator.swift — turns (kind, state, wall-clock time) into a drawable frame.
//
// The continuous states (idle breathing, gear spin) are computed analytically
// from the TimelineView clock rather than held in @State. That keeps every pet
// on the card phase-locked to the same clock, costs no timers, and means a pet
// that scrolls out of view and back does not restart its cycle mid-breath.
//
// The one genuinely stateful thing is `happy`: it is a one-shot triggered by a
// human approving an ask, so it needs a start instant. `PetAnimator` owns that
// instant and drives a `withAnimation` pop alongside the analytic bounce.

import SwiftUI

// MARK: - Frame

/// One resolved animation frame. All offsets are in the pet's 32×32 design
/// space; `PetRenderer` scales them to the view's actual size.
struct PetFrame {
    /// Body scale, 0.95…1.02. Breathing.
    var breath: Double = 1
    /// Eyelid aperture. 0 = shut, 1 = resting, >1 = widened in alert.
    var eyeOpen: Double = 1
    /// Vertical offset, negative is up. Drives the happy bounce.
    var yOffset: Double = 0
    /// Horizontal drift in design units. A slow idle sway, per-kind personality.
    var sway: Double = 0
    /// Forward lean, 0…1. Shears the body toward the viewer's right.
    var lean: Double = 0
    /// How far the head hangs, in design units. Sleepy only.
    var headDroop: Double = 0
    /// Gear rotation in radians.
    var spin: Double = 0
    /// Sparkle burst envelope, 0…1. Gear's happy state.
    var sparkle: Double = 0
}

// MARK: - Animator

final class PetAnimator: ObservableObject {

    /// Set when the pet enters `happy`; cleared when the bounce is spent.
    @Published private(set) var happyStart: Date?

    /// A 0→1 pop driven through `withAnimation`, layered on top of the analytic
    /// bounce so the celebration also picks up SwiftUI's spring.
    @Published private(set) var celebration: Double = 0

    /// Call whenever the bound state changes. Idempotent for repeat values.
    func update(for state: PetAnimationState, now: Date = Date()) {
        guard state == .happy else {
            if happyStart != nil { happyStart = nil }
            if celebration != 0 {
                withAnimation(.easeOut(duration: 0.18)) { celebration = 0 }
            }
            return
        }
        // Re-approving retriggers the bounce from the top.
        happyStart = now
        celebration = 0
        withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) {
            celebration = 1
        }
        withAnimation(.easeOut(duration: 0.2).delay(PetAnimationState.happyDuration)) {
            celebration = 0
        }
    }

    /// Resolves the frame for `now`.
    func frame(kind: PetKind, state: PetAnimationState, now: Date) -> PetFrame {
        // A single monotonic seconds value shared by every pet on the card.
        let t = now.timeIntervalSinceReferenceDate
        let p = kind.personality
        var f = PetFrame()

        switch state {
        case .idle:
            // Breathing at the kind's own tempo and phase, so a card of pets
            // no longer rises and falls as one body.
            let bt = t / p.breathPeriod + p.breathPhase
            f.breath  = 0.975 + 0.025 * sin(2 * .pi * bt)
            f.eyeOpen = 1
            // Blink on the kind's own cadence, optionally a nervous double.
            f.eyeOpen *= Self.blink(t: t, period: p.blinkPeriod,
                                    phase: p.breathPhase, double: p.doubleBlink)
            // A slow lateral sway, roughly half the breathing rate and offset
            // from it, so idle reads as alive rather than mechanically pulsing.
            f.sway = p.swayAmp * sin(2 * .pi * (t / (p.breathPeriod * 2.3)
                                                 + p.breathPhase))

        case .alert:
            // Tighter, shallower breath — attention, not exertion.
            f.breath  = 0.99 + 0.01 * sin(2 * .pi * t / max(0.4, p.breathPeriod * 0.35))
            f.eyeOpen = p.alertEyeWiden
            f.lean    = 1
            f.yOffset = -0.5

        case .happy:
            let elapsed = happyStart.map { now.timeIntervalSince($0) } ?? 0
            let u = min(max(elapsed / PetAnimationState.happyDuration, 0), 1)
            // Up 4pt and back down, with a small overshoot on the settle.
            f.yOffset = -4 * sin(.pi * u) - 0.6 * celebration
            f.breath  = 1 + 0.02 * sin(.pi * u)
            f.eyeOpen = 1.15

        case .sleepy:
            // Slower, deeper breath; lids at a quarter; head hangs 3pt.
            f.breath    = 0.955 + 0.02 * sin(2 * .pi * t / 3.4)
            f.eyeOpen   = 0.22
            f.headDroop = 3
        }

        if kind == .gear {
            f.spin    = Self.gearSpin(state: state, t: t)
            f.sparkle = state == .happy ? Self.sparkleEnvelope(
                elapsed: happyStart.map { now.timeIntervalSince($0) } ?? 0) : 0
            // A gear has no lungs, no eyelids, and no reason to sway.
            f.breath    = state == .happy ? f.breath : 1
            f.eyeOpen   = 1
            f.headDroop = 0
            f.lean      = 0
            f.sway      = 0
        }
        return f
    }

    // MARK: Curves

    /// Eyelid multiplier for a blink on a per-kind cadence: 1 for most of the
    /// cycle, dipping to 0.1 across a 160 ms window once every `period` seconds.
    /// When `double` is set a second blink follows ~220 ms later — a nervous or
    /// busy tic rather than a single calm blink.
    private static func blink(t: Double, period: Double,
                              phase: Double, double: Bool) -> Double {
        let width = 0.16
        // Offset the blink within the cycle by the kind's phase so pets do not
        // all shut their eyes on the same frame.
        let local = (t / period + phase).truncatingRemainder(dividingBy: 1) * period
        func dip(at start: Double) -> Double {
            guard local >= start, local <= start + width else { return 1 }
            let u = (local - start) / width       // 0…1 through the blink
            return 0.1 + 0.9 * abs(cos(.pi * u))  // shut and reopen
        }
        // Blink near the end of the cycle. The second lid drop of a double
        // blink sits just after the first.
        let first = dip(at: period - 0.5)
        guard double else { return first }
        return min(first, dip(at: period - 0.5 + width + 0.06))
    }

    /// Gear rotation in radians at time `t`.
    private static func gearSpin(state: PetAnimationState, t: Double) -> Double {
        func radiansPerSecond(rpm: Double) -> Double { rpm * 2 * .pi / 60 }
        switch state {
        case .idle:  return t * radiansPerSecond(rpm: 1)
        case .alert: return t * radiansPerSecond(rpm: 4)
        case .happy: return t * radiansPerSecond(rpm: 12)
        case .sleepy:
            // Barely ticking: still for 80% of a 2.5 s cycle, then steps one
            // tooth (2π/8) across the remaining 20%.
            let period = 2.5, step = 2 * Double.pi / 8
            let cycles = (t / period).rounded(.down)
            let phase  = t / period - cycles
            let moving = max(0, (phase - 0.8) / 0.2)          // 0…1 in the last fifth
            let eased  = moving * moving * (3 - 2 * moving)   // smoothstep
            return (cycles + eased) * step
        }
    }

    /// Sparkle burst: snaps on, decays over the happy window.
    private static func sparkleEnvelope(elapsed: Double) -> Double {
        let u = elapsed / PetAnimationState.happyDuration
        guard u >= 0, u <= 1 else { return 0 }
        return pow(1 - u, 1.6)
    }
}
