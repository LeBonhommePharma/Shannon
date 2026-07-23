import SwiftUI

// MARK: - Semantic colour tokens
//
// Feature code never names a hex value. It names a role — "this is a surface",
// "this is secondary text" — and the token resolves per colour scheme.
//
// Day  is warm paper, not clinical white: every day surface and grey keeps red
//      above blue, so it reads as cream under both daylight and warm indoor
//      light instead of turning grey. Deep indigo accent.
// Night is deep and low-emission: near-black with warm undertones (#0D0D10,
//      never pure black), electric blue accent legible at low brightness.
//
// The day ladder, lightest to darkest:
//   background #FAF8F3 · surface #FFFFFF · sunken #F6F2EA · elevated #F2EEE5
//   quaternary #DED6C8 · tertiary #7D7365 · secondary #6B6257 · primary #1C1917
// Hairlines and shadows are warm brown at low alpha (#7A5C3A / #5C482D), never
// neutral black — a black hairline over cream desaturates the edge to grey.

public extension Color {

    // MARK: Backgrounds

    /// Window / scene background. day #FAF8F3 · night #0D0D10
    ///
    /// Day was #F5F6FA — a cool blue-grey (B > R) that reads as clinical, and
    /// under warm indoor or afternoon light reads as dirty. The day ladder is
    /// now warm paper: red always exceeds blue, so it stays cream rather than
    /// turning grey as ambient light shifts.
    static let shannonBackground = ShannonAdaptive.color(day: 0xFAF8F3, night: 0x0D0D10)

    /// Cards, sheets, list rows. day #FFFFFF · night #18181C
    static let shannonSurface = ShannonAdaptive.color(day: 0xFFFFFF, night: 0x18181C)

    /// Surfaces stacked on top of `shannonSurface`. day #F2EEE5 · night #222228
    static let shannonSurfaceElevated = ShannonAdaptive.color(day: 0xF2EEE5, night: 0x222228)

    /// Recessed wells — code blocks, scroll containers, diff bodies. In daylight
    /// this reads as a shallow dent in paper rather than a dark cut-out.
    /// day #F6F2EA · night #101014
    static let shannonSurfaceSunken = ShannonAdaptive.color(day: 0xF6F2EA, night: 0x101014)

    /// Row hover / pressed state. day rgba(0,0,0,0.04) · night rgba(255,255,255,0.06)
    /// Warm brown rather than neutral black, so hover does not grey the surface.
    static let shannonSurfaceHover = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0x7A5C3A, alpha: 0.07),
        night: ShannonRGBA(hex: 0xFFFFFF, alpha: 0.06)
    )

    /// Dividers and card hairlines. Deliberately darker in day than the usual
    /// 8%-white seam, which disappears entirely against a bright desk.
    /// Warm ultra-light tint, not neutral grey: a black hairline over cream
    /// desaturates the whole card edge and is what made the light theme read
    /// grey even where the fills were warm.
    /// day rgba(122,92,58,0.18) · night rgba(255,255,255,0.10)
    static let shannonSeparator = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0x7A5C3A, alpha: 0.18),
        night: ShannonRGBA(hex: 0xFFFFFF, alpha: 0.10)
    )

    /// Ambient drop shadow under floating chrome. Daylight shadows are shorter
    /// and far weaker — a heavy black bloom under a white pill reads as grime.
    /// day rgba(92,72,45,0.12) · night rgba(0,0,0,0.28)
    static let shannonShadow = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0x5C482D, alpha: 0.12),
        night: ShannonRGBA(hex: 0x000000, alpha: 0.28)
    )

    // MARK: Pill (macOS notch)
    //
    // These sit *on top of* an `NSVisualEffectView` using the `.hudWindow`
    // material in both schemes, so they are deliberately translucent — the
    // alpha is doing real work and must not be flattened to an opaque value.

    /// Pill fill over the HUD material. day rgba(253,251,247,0.72) · night rgba(18,18,20,0.80)
    static let pillBackground = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0xFDFBF7, alpha: 0.72),
        night: ShannonRGBA(hex: 0x121214, alpha: 0.80)
    )

    /// Border at rest. Day carries real weight — a white pill on a bright
    /// desktop has no edge of its own, and an 8% seam left it looking like a
    /// rendering glitch outdoors. Night stays a whisper; the dark slab already
    /// separates itself from the wallpaper.
    /// day rgba(122,92,58,0.28) · night rgba(255,255,255,0.10)
    static let pillBorder = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0x7A5C3A, alpha: 0.28),
        night: ShannonRGBA(hex: 0xFFFFFF, alpha: 0.10)
    )

    /// Hairline while an agent is active — the accent glow. day #4F6EF7 · night #7B9FFF
    static let pillBorderActive = ShannonAdaptive.color(day: 0x4F6EF7, night: 0x7B9FFF)

    /// Opacity layer that stabilises the pill over an unknown wallpaper.
    ///
    /// At night a black scrim deepens the slab. In daylight the same black scrim
    /// greys out a white pill and is what made the notch look muddy outdoors, so
    /// day pushes *toward white* instead — the pill stays paper-bright and the
    /// dark text on it keeps its contrast.
    /// day rgba(255,255,255,0.34) · night rgba(0,0,0,0.18)
    static let pillScrim = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0xFDFBF7, alpha: 0.34),
        night: ShannonRGBA(hex: 0x000000, alpha: 0.18)
    )

    // MARK: Accent

    /// Primary interactive accent. day #3A5CF5 · night #6B8FFF
    static let shannonAccent = ShannonAdaptive.color(day: 0x3A5CF5, night: 0x6B8FFF)

    /// Accent-tinted fill for badges and selected rows. day #EEF1FE · night #1A2140
    static let shannonAccentSubtle = ShannonAdaptive.color(day: 0xEEF1FE, night: 0x1A2140)

    // MARK: Text

    /// Titles and body copy. day #1C1917 (17.5:1 on white) · night #F0F0F5
    static let shannonPrimary = ShannonAdaptive.color(day: 0x1C1917, night: 0xF0F0F5)

    /// Supporting copy, labels. day #6B6257 (6.0:1 on white) · night #8A8D9F
    static let shannonSecondary = ShannonAdaptive.color(day: 0x6B6257, night: 0x8A8D9F)

    /// Timestamps, units, metadata — the quietest text that is still *text*.
    ///
    /// Day was #A8ABBC, about 2.3:1 on white. The pill sets 9 pt labels in this
    /// token, so outdoors they were effectively blank. Darkened to clear 4.5:1
    /// while staying clearly subordinate to `shannonSecondary`.
    /// day #7D7365 (4.7:1 on white) · night #6A6D80
    static let shannonTertiary = ShannonAdaptive.color(day: 0x7D7365, night: 0x6A6D80)

    /// Genuinely non-textual greys: separators, disabled glyphs, empty tracks.
    /// Use this where the old low-contrast `shannonTertiary` was decorative
    /// rather than informative. day #DED6C8 · night #3C3F4E
    static let shannonQuaternary = ShannonAdaptive.color(day: 0xDED6C8, night: 0x3C3F4E)

    // MARK: Semantic states

    /// Run succeeded, agent idle-healthy. day #1A7F4B · night #34C77A
    static let shannonSuccess = ShannonAdaptive.color(day: 0x1A7F4B, night: 0x34C77A)

    /// Degraded, retrying, entropy drifting. day #C47A0A · night #F5B934
    static let shannonWarning = ShannonAdaptive.color(day: 0xC47A0A, night: 0xF5B934)

    /// Failure, collapse detected. day #C0392B · night #FF6B6B
    static let shannonError = ShannonAdaptive.color(day: 0xC0392B, night: 0xFF6B6B)

    /// No signal / not applicable. day #857C6E (4.2:1) · night #5A5D6E
    static let shannonNeutral = ShannonAdaptive.color(day: 0x857C6E, night: 0x5A5D6E)
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
