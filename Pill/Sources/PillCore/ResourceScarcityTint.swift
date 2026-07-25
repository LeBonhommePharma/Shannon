import Foundation

// MARK: - Continuous resource scarcity tint (pure)

/// Host-load / scarcity ink that **scales intensity with percent**, and only
/// goes red at critical emergency levels.
///
/// Discrete band colours (full green / full gold / full red) made the HUD look
/// "100% color-coded." This mapping:
/// - mutes low load (desaturated, near-neutral)
/// - raises saturation/chroma as scarcity rises
/// - stays non-red through elevated/hot (teal → accent → gold)
/// - leans red only for critical (≥ `criticalThreshold`, default 92)
///
/// Never uses ask-amber as the load path — approvals keep a separate ink.
public enum ResourceScarcityTint: Sendable {
    /// Critical emergency threshold (matches `SystemResourceLogic.Band.critical`).
    public static let criticalThreshold: Double = 92
    /// Below this, chroma is near-zero (muted secondary text).
    public static let muteBelow: Double = 35
    /// Full gold (non-red stress) around this load.
    public static let hotPeak: Double = 88

    public struct SRGB: Sendable, Equatable {
        public var r: Double
        public var g: Double
        public var b: Double
        public var a: Double

        public init(r: Double, g: Double, b: Double, a: Double = 1) {
            self.r = clamp01(r)
            self.g = clamp01(g)
            self.b = clamp01(b)
            self.a = clamp01(a)
        }

        /// Relative luminance 0…1 (WCAG).
        public var relativeLuminance: Double {
            func lin(_ c: Double) -> Double {
                let x = clamp01(c)
                return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }

        /// Max channel minus min — crude chroma proxy for tests.
        public var chroma: Double {
            max(r, g, b) - min(r, g, b)
        }

        /// How red-dominant vs green/blue (positive = redward).
        public var redDominance: Double {
            r - max(g, b)
        }
    }

    /// Scarcity intensity 0…1 from a utilisation percent.
    /// Soft ramp: almost nothing until ~muteBelow, then rises to 1 at 100.
    public static func intensity(percent: Double) -> Double {
        let p = clampPct(percent)
        // Smoothstep from muteBelow → 100.
        let t = (p - muteBelow) / (100 - muteBelow)
        return smooth01(t)
    }

    /// Continuous sRGB for host-load text/bars from optional percent.
    /// `nil` → muted neutral (unknown / n/a).
    public static func sRGB(percent: Double?) -> SRGB {
        guard let raw = percent, raw.isFinite else {
            return mutedNeutral(intensity: 0)
        }
        return sRGB(percent: raw)
    }

    public static func sRGB(percent: Double) -> SRGB {
        let p = clampPct(percent)
        let I = intensity(percent: p)

        // Hue waypoints (sRGB): mute green → teal/accent → gold → red (critical only).
        let calm = (r: 0.28, g: 0.62, b: 0.42)      // soft green
        let elevated = (r: 0.30, g: 0.48, b: 0.92)  // accent-ish blue
        let hot = (r: 0.88, g: 0.62, b: 0.12)       // gold (not ask-amber wash)
        let critical = (r: 0.90, g: 0.18, b: 0.14)  // emergency red
        let neutral = (r: 0.55, g: 0.56, b: 0.58)   // muted secondary

        let hue: (r: Double, g: Double, b: Double)
        if p < 60 {
            // 0…60: neutral → calm green
            let u = smooth01(p / 60)
            hue = lerpRGB(neutral, calm, u)
        } else if p < 80 {
            // 60…80: green → accent blue
            let u = smooth01((p - 60) / 20)
            hue = lerpRGB(calm, elevated, u)
        } else if p < criticalThreshold {
            // 80…92: blue → gold (stress without red)
            let u = smooth01((p - 80) / (criticalThreshold - 80))
            hue = lerpRGB(elevated, hot, u)
        } else {
            // 92…100: gold → red (emergency only)
            let u = smooth01((p - criticalThreshold) / (100 - criticalThreshold))
            hue = lerpRGB(hot, critical, u)
        }

        // Mix toward neutral by inverse intensity so low load is desaturated.
        let sat = I  // 0 at low, 1 at max scarcity
        let mixed = lerpRGB(neutral, hue, sat)

        // Alpha: calm text slightly softer; critical fully opaque.
        let a = 0.72 + 0.28 * I
        return SRGB(r: mixed.r, g: mixed.g, b: mixed.b, a: a)
    }

    /// True when ink is in the critical-red emergency zone (for tests / policy).
    public static func isCriticalRed(_ ink: SRGB, percent: Double) -> Bool {
        percent >= criticalThreshold && ink.redDominance > 0.15 && ink.chroma > 0.25
    }

    /// True when ink is clearly non-red (no emergency).
    public static func isNonRed(_ ink: SRGB) -> Bool {
        ink.redDominance < 0.12
    }

    // MARK: - Math

    public static func clampPct(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(100, max(0, v))
    }

    private static func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(1, max(0, v))
    }

    private static func smooth01(_ t: Double) -> Double {
        let x = clamp01(t)
        return x * x * (3 - 2 * x)
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * clamp01(t)
    }

    private static func lerpRGB(
        _ a: (r: Double, g: Double, b: Double),
        _ b: (r: Double, g: Double, b: Double),
        _ t: Double
    ) -> (r: Double, g: Double, b: Double) {
        (lerp(a.r, b.r, t), lerp(a.g, b.g, t), lerp(a.b, b.b, t))
    }

    private static func mutedNeutral(intensity: Double) -> SRGB {
        let I = clamp01(intensity)
        return SRGB(r: 0.55, g: 0.56, b: 0.58, a: 0.65 + 0.2 * I)
    }
}
