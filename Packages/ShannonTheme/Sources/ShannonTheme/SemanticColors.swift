import SwiftUI

// MARK: - Semantic colour tokens
//
// Feature code never names a hex value. It names a role — "this is a surface",
// "this is secondary text" — and the token resolves per colour scheme.
//
// Shannon always renders in dark mode (NSApp.appearance is locked to .darkAqua
// at launch). The day values are kept intact so the system does not break if
// that override is ever removed, but the night values are the only ones that
// matter at runtime.
//
// Night palette — deep indigo-black with electric-blue accent:
//   background #09091A · surface #121220 · sunken #07070F · elevated #1A1A2E
//   quaternary #1E2038 · tertiary #8F97BA · secondary #9AA2C5 · primary #F2F2FA
// Accent #4B8BFF (electric blue, 6.8:1 on surface).
// State colours match Apple's vibrant palette for high-contrast readability.
//
// Day ladder (warm paper, preserved for completeness):
//   background #FAF8F3 · surface #FFFFFF · sunken #F6F2EA · elevated #F2EEE5
//   quaternary #DED6C8 · tertiary #7D7365 · secondary #6B6257 · primary #1C1917

public extension Color {

    // MARK: Backgrounds

    /// Window / scene background. day #FAF8F3 · night #09091A (deep indigo-black)
    ///
    /// Night was #0D0D10 (near-neutral). Pushed to #09091A — a deep indigo with
    /// just enough blue chroma to read as a scientific dark theme rather than
    /// plain black. Still well under 0.005 relative luminance so OLED-safe.
    static let shannonBackground = ShannonAdaptive.color(day: 0xFAF8F3, night: 0x09091A)

    /// Cards, sheets, list rows. day #FFFFFF · night #121220
    static let shannonSurface = ShannonAdaptive.color(day: 0xFFFFFF, night: 0x121220)

    /// Surfaces stacked on top of `shannonSurface`. day #F2EEE5 · night #1A1A2E
    static let shannonSurfaceElevated = ShannonAdaptive.color(day: 0xF2EEE5, night: 0x1A1A2E)

    /// Recessed wells — code blocks, scroll containers, diff bodies.
    /// day #F6F2EA · night #07070F
    static let shannonSurfaceSunken = ShannonAdaptive.color(day: 0xF6F2EA, night: 0x07070F)

    /// Row hover / pressed state. day rgba(122,92,58,0.07) · night rgba(255,255,255,0.08)
    static let shannonSurfaceHover = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0x7A5C3A, alpha: 0.07),
        night: ShannonRGBA(hex: 0xFFFFFF, alpha: 0.08)
    )

    /// Dividers and card hairlines. Night uses a faint blue tint so separators
    /// feel like illuminated edges in the indigo darkness rather than grey cuts.
    /// day rgba(122,92,58,0.18) · night rgba(80,140,255,0.18)
    static let shannonSeparator = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0x7A5C3A, alpha: 0.18),
        night: ShannonRGBA(hex: 0x508CFF, alpha: 0.18)
    )

    /// Ambient drop shadow under floating chrome.
    /// day rgba(92,72,45,0.12) · night rgba(0,0,30,0.50)
    /// Night shadow carries a faint blue tint to match the indigo-black palette.
    static let shannonShadow = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0x5C482D, alpha: 0.12),
        night: ShannonRGBA(hex: 0x00001E, alpha: 0.50)
    )

    // MARK: Pill (macOS notch)
    //
    // These sit *on top of* an `NSVisualEffectView` using the `.hudWindow`
    // material in both schemes, so they are deliberately translucent — the
    // alpha is doing real work and must not be flattened to an opaque value.

    /// Pill fill over the vibrancy material.
    /// day rgba(253,251,247,0.40) · night rgba(9,9,26,0.42)
    ///
    /// At 0.90 the tint was doing *all* the work and the `NSVisualEffectView`
    /// underneath was decorative — the pill read as an opaque slab bolted to the
    /// notch. The fill is a tint again: `PillMaterial` (`.sheet`) supplies the
    /// blur and the darkening, this supplies the indigo hue. `PillStyle`
    /// modulates it further by state, so the composite runs 0.305 (quiet) to
    /// 0.478 (active) instead of a flat 0.902.
    static let pillBackground = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0xFDFBF7, alpha: 0.40),
        night: ShannonRGBA(hex: 0x09091A, alpha: 0.42)
    )

    /// Border at rest. Night is a blue-tinted line — more visible than a
    /// neutral white whisper and consistent with the indigo palette.
    /// day rgba(122,92,58,0.28) · night rgba(80,140,255,0.25)
    static let pillBorder = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0x7A5C3A, alpha: 0.28),
        night: ShannonRGBA(hex: 0x508CFF, alpha: 0.25)
    )

    /// Hairline while an agent is active — the accent glow.
    /// day #4F6EF7 · night #4D9EFF (electric blue, higher saturation)
    static let pillBorderActive = ShannonAdaptive.color(day: 0x4F6EF7, night: 0x4D9EFF)

    /// Opacity layer that stabilises the pill over an unknown wallpaper.
    /// day rgba(253,251,247,0.14) · night rgba(0,0,20,0.10)
    ///
    /// Cut from 0.28 to 0.10. Stacked on top of `pillBackground` the old scrim
    /// pushed the composite past 0.90 opaque, which is the opposite of what a
    /// vibrancy surface is for. What remains is just enough to stop a bright
    /// wallpaper punching through the blur.
    static let pillScrim = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0xFDFBF7, alpha: 0.14),
        night: ShannonRGBA(hex: 0x000014, alpha: 0.10)
    )

    // MARK: Accent

    /// Primary interactive accent.
    /// day #3A5CF5 · night #4B8BFF (electric blue — 6.8:1 on #121220 surface)
    static let shannonAccent = ShannonAdaptive.color(day: 0x3A5CF5, night: 0x4B8BFF)

    /// Accent-tinted fill for badges and selected rows. day #EEF1FE · night #0C1435
    static let shannonAccentSubtle = ShannonAdaptive.color(day: 0xEEF1FE, night: 0x0C1435)

    // MARK: Text

    /// Titles and body copy. day #1C1917 (17.5:1 on white) · night #F2F2FA
    static let shannonPrimary = ShannonAdaptive.color(day: 0x1C1917, night: 0xF2F2FA)

    /// Supporting copy, labels. day #6B6257 (6.0:1 on white) · night #9AA2C5
    /// Night was #8A8D9F (neutral grey). Shifted to blue-tinted so it feels
    /// at home in the indigo palette without losing legibility.
    static let shannonSecondary = ShannonAdaptive.color(day: 0x6B6257, night: 0x9AA2C5)

    /// Timestamps, units, metadata. day #7D7365 (4.7:1 on white) · night #8F97BA
    ///
    /// Night lifted from #7A80A0 to #8F97BA. The pill surface is now genuinely
    /// translucent (see `pillBackground`), so whatever is behind the notch
    /// raises the effective backdrop luminance and eats contrast that an opaque
    /// slab used to guarantee. #7A80A0 measured under 2:1 over a bright
    /// wallpaper; #8F97BA holds ~3:1 there and ~7:1 over a dark one, while
    /// staying visibly subordinate to `shannonSecondary` (#9AA2C5).
    static let shannonTertiary = ShannonAdaptive.color(day: 0x7D7365, night: 0x8F97BA)

    /// Non-textual: separators, disabled glyphs, empty tracks, progress rails.
    /// day #DED6C8 · night #1E2038 (deep indigo — used for progress-bar backgrounds)
    static let shannonQuaternary = ShannonAdaptive.color(day: 0xDED6C8, night: 0x1E2038)

    // MARK: Semantic states

    /// Run succeeded, agent idle-healthy. day #1A7F4B · night #30D158
    /// Night uses Apple's vibrant system green — maximum punch on dark.
    static let shannonSuccess = ShannonAdaptive.color(day: 0x1A7F4B, night: 0x30D158)

    /// Degraded, retrying, entropy drifting. day #C47A0A · night #FFB340
    /// Night is Apple's vibrant amber — clearly readable and distinctly "caution".
    static let shannonWarning = ShannonAdaptive.color(day: 0xC47A0A, night: 0xFFB340)

    /// Failure, collapse detected. day #C0392B · night #FF453A
    /// Night is Apple's vibrant red — higher chroma and contrast than the old
    /// #FF6B6B, which read as "light pink" against the dark background.
    static let shannonError = ShannonAdaptive.color(day: 0xC0392B, night: 0xFF453A)

    /// No signal / not applicable. day #857C6E (4.2:1) · night #9A9AA6
    ///
    /// Night lifted from #636680, which measured 2.5:1 on the translucent pill —
    /// unreadable at the 9–11 pt sizes that actually use it. #9A9AA6 holds
    /// 4.9:1 there. Deliberately *desaturated* rather than merely brighter: it
    /// now sits at roughly the same luminance as `shannonSecondary`/`Tertiary`
    /// but with almost no blue chroma, so "no signal" reads as grey next to the
    /// indigo-tinted live text instead of just reading as dimmer.
    static let shannonNeutral = ShannonAdaptive.color(day: 0x857C6E, night: 0x9A9AA6)
}

// MARK: - Token catalogue

/// Every semantic token paired with its name, for previews, design docs and
/// snapshot tests. Keep in sync when adding a token above.
public struct ShannonColorToken: Identifiable, Sendable {
    public let name: String
    public let color: Color
    public let group: String

    public var id: String { name }

    public init(_ name: String, _ color: Color, group: String) {
        self.name = name
        self.color = color
        self.group = group
    }
}

public enum ShannonColorCatalogue {
    public static let backgrounds: [ShannonColorToken] = [
        .init("shannonBackground", .shannonBackground, group: "Backgrounds"),
        .init("shannonSurface", .shannonSurface, group: "Backgrounds"),
        .init("shannonSurfaceElevated", .shannonSurfaceElevated, group: "Backgrounds"),
        .init("shannonSurfaceSunken", .shannonSurfaceSunken, group: "Backgrounds"),
        .init("shannonSurfaceHover", .shannonSurfaceHover, group: "Backgrounds"),
        .init("shannonSeparator", .shannonSeparator, group: "Backgrounds"),
        .init("shannonShadow", .shannonShadow, group: "Backgrounds"),
    ]

    public static let pill: [ShannonColorToken] = [
        .init("pillBackground", .pillBackground, group: "Pill"),
        .init("pillBorder", .pillBorder, group: "Pill"),
        .init("pillBorderActive", .pillBorderActive, group: "Pill"),
        .init("pillScrim", .pillScrim, group: "Pill"),
        .init("notchIslandFill", .notchIslandFill, group: "Pill"),
    ]

    public static let accent: [ShannonColorToken] = [
        .init("shannonAccent", .shannonAccent, group: "Accent"),
        .init("shannonAccentSubtle", .shannonAccentSubtle, group: "Accent"),
    ]

    public static let text: [ShannonColorToken] = [
        .init("shannonPrimary", .shannonPrimary, group: "Text"),
        .init("shannonSecondary", .shannonSecondary, group: "Text"),
        .init("shannonTertiary", .shannonTertiary, group: "Text"),
        .init("shannonQuaternary", .shannonQuaternary, group: "Text"),
    ]

    public static let states: [ShannonColorToken] = [
        .init("shannonSuccess", .shannonSuccess, group: "States"),
        .init("shannonWarning", .shannonWarning, group: "States"),
        .init("shannonError", .shannonError, group: "States"),
        .init("shannonNeutral", .shannonNeutral, group: "States"),
    ]

    public static let all: [ShannonColorToken] =
        backgrounds + pill + accent + text + states

    public static let groups: [(String, [ShannonColorToken])] = [
        ("Backgrounds", backgrounds),
        ("Pill", pill),
        ("Accent", accent),
        ("Text", text),
        ("States", states),
    ]
}
