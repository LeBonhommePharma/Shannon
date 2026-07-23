import SwiftUI

// MARK: - Agent identity colour roles
//
// Agent brand colours (Science amber, Cowork green, Codex blue …) were picked to
// glow on a near-black slab. Painted straight onto a white daylight surface the
// light ones — amber at 0.72 luminance, green at 0.60 — carry roughly 1.8:1
// against white and vanish in bright ambient light.
//
// So a brand colour is never used raw. It is resolved into four roles, and the
// role decides how far the hue is pushed toward legibility:
//
//   ink   — text and glyphs. Contrast-corrected until it clears ~4.5:1 against
//           the surface it sits on, in whichever scheme is active.
//   tint  — dots, arcs, progress fills. Shape carries the meaning here, not
//           letterforms, so the hue stays vivid and recognisable.
//   wash  — chip and card backgrounds. A whisper of hue; ink must stay readable
//           on top of it.
//   edge  — hairline borders, strong enough to define an edge in daylight.
//
// Identity therefore survives the scheme change: the same agent reads as "the
// amber one" in both, while the text is always actually readable.

/// The four daylight-corrected roles derived from one agent brand colour.
public struct AgentPalette: Equatable, Sendable {
    /// Text and glyphs — contrast-corrected for the active scheme.
    public let ink: Color
    /// Vivid brand hue for non-text marks: dots, arcs, fills.
    public let tint: Color
    /// Low-saturation background for chips and cards.
    public let wash: Color
    /// Hairline border.
    public let edge: Color

    public init(ink: Color, tint: Color, wash: Color, edge: Color) {
        self.ink = ink
        self.tint = tint
        self.wash = wash
        self.edge = edge
    }
}

public enum AgentColor {

    /// Relative luminance a colour must not exceed to clear ~4.5:1 against a
    /// white daylight surface. Solves (1.05)/(L + 0.05) >= 4.5.
    public static let dayInkMaxLuminance: Double = 0.183

    /// Relative luminance a colour must reach to clear ~4.5:1 against the night
    /// surface (#18181C, luminance ~0.011). Solves (L + 0.05)/0.0606 >= 4.5.
    public static let nightInkMinLuminance: Double = 0.223

    /// Resolve one brand colour into its four scheme-aware roles.
    public static func palette(red: Double, green: Double, blue: Double) -> AgentPalette {
        let base = ShannonRGBA(red: red, green: green, blue: blue)

        // Ink is darkened for day, brightened for night — each only as far as
        // the contrast target requires, so the hue is preserved where possible.
        let dayInk = darkened(base, toAtMost: dayInkMaxLuminance)
        let nightInk = brightened(base, toAtLeast: nightInkMinLuminance)

        // Tint keeps the brand hue. In daylight the very light brand colours
        // still need a nudge down or a 6 pt dot reads as a smudge.
        let dayTint = darkened(base, toAtMost: 0.42)
        let nightTint = brightened(base, toAtLeast: 0.20)

        return AgentPalette(
            ink: ShannonAdaptive.color(day: dayInk, night: nightInk),
            tint: ShannonAdaptive.color(day: dayTint, night: nightTint),
            wash: ShannonAdaptive.color(
                day: dayTint.withAlpha(0.10),
                night: nightTint.withAlpha(0.16)
            ),
            edge: ShannonAdaptive.color(
                day: dayTint.withAlpha(0.28),
                night: nightTint.withAlpha(0.34)
            )
        )
    }

    /// Convenience for the `AgentStyle` / `AgentIdentity` storage shape.
    public static func palette(_ rgb: (Double, Double, Double)) -> AgentPalette {
        palette(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    // MARK: Luminance maths

    /// WCAG relative luminance of an sRGB colour.
    public static func luminance(_ c: ShannonRGBA) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    /// Scale a colour toward black until its luminance is at or below `target`.
    /// Returns it untouched when it is already dark enough.
    static func darkened(_ c: ShannonRGBA, toAtMost target: Double) -> ShannonRGBA {
        guard luminance(c) > target else { return c }
        var lo = 0.0, hi = 1.0
        // 18 halvings resolves the factor far finer than an 8-bit channel.
        for _ in 0 ..< 18 {
            let mid = (lo + hi) / 2
            if luminance(c.scaled(by: mid)) > target { hi = mid } else { lo = mid }
        }
        return c.scaled(by: lo)
    }

    /// Blend a colour toward white until its luminance reaches `target`.
    static func brightened(_ c: ShannonRGBA, toAtLeast target: Double) -> ShannonRGBA {
        guard luminance(c) < target else { return c }
        var lo = 0.0, hi = 1.0
        for _ in 0 ..< 18 {
            let mid = (lo + hi) / 2
            if luminance(c.blendedTowardWhite(mid)) < target { lo = mid } else { hi = mid }
        }
        return c.blendedTowardWhite(hi)
    }
}

extension ShannonRGBA {
    /// Multiply toward black, preserving hue ratios and alpha.
    func scaled(by k: Double) -> ShannonRGBA {
        ShannonRGBA(red: red * k, green: green * k, blue: blue * k, alpha: alpha)
    }

    /// Linear blend toward white; `t = 0` is unchanged, `t = 1` is white.
    func blendedTowardWhite(_ t: Double) -> ShannonRGBA {
        ShannonRGBA(
            red: red + (1 - red) * t,
            green: green + (1 - green) * t,
            blue: blue + (1 - blue) * t,
            alpha: alpha
        )
    }

    public func withAlpha(_ a: Double) -> ShannonRGBA {
        ShannonRGBA(red: red, green: green, blue: blue, alpha: a)
    }
}
