import SwiftUI

// MARK: - Semantic colour tokens
//
// Feature code never names a hex value. It names a role — "this is a surface",
// "this is secondary text" — and the token resolves per colour scheme.
//
// Day  is crisp and airy: near-white with cool undertones, deep indigo accent.
// Night is deep and low-emission: near-black with warm undertones (#0D0D10,
// never pure black), electric blue accent that stays legible at low brightness.

public extension Color {

    // MARK: Backgrounds

    /// Window / scene background. day #F5F6FA · night #0D0D10
    static let shannonBackground = ShannonAdaptive.color(day: 0xF5F6FA, night: 0x0D0D10)

    /// Cards, sheets, list rows. day #FFFFFF · night #18181C
    static let shannonSurface = ShannonAdaptive.color(day: 0xFFFFFF, night: 0x18181C)

    /// Surfaces stacked on top of `shannonSurface`. day #ECEDF2 · night #222228
    static let shannonSurfaceElevated = ShannonAdaptive.color(day: 0xECEDF2, night: 0x222228)

    // MARK: Pill (macOS notch)
    //
    // These sit *on top of* an `NSVisualEffectView` using the `.hudWindow`
    // material in both schemes, so they are deliberately translucent — the
    // alpha is doing real work and must not be flattened to an opaque value.

    /// Pill fill over the HUD material. day rgba(255,255,255,0.72) · night rgba(18,18,20,0.80)
    static let pillBackground = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0xFFFFFF, alpha: 0.72),
        night: ShannonRGBA(hex: 0x121214, alpha: 0.80)
    )

    /// Hairline at rest — barely there, especially at night.
    /// day rgba(0,0,0,0.08) · night rgba(255,255,255,0.10)
    static let pillBorder = ShannonAdaptive.color(
        day: ShannonRGBA(hex: 0x000000, alpha: 0.08),
        night: ShannonRGBA(hex: 0xFFFFFF, alpha: 0.10)
    )

    /// Hairline while an agent is active — the accent glow. day #4F6EF7 · night #7B9FFF
    static let pillBorderActive = ShannonAdaptive.color(day: 0x4F6EF7, night: 0x7B9FFF)

    // MARK: Accent

    /// Primary interactive accent. day #3A5CF5 · night #6B8FFF
    static let shannonAccent = ShannonAdaptive.color(day: 0x3A5CF5, night: 0x6B8FFF)

    /// Accent-tinted fill for badges and selected rows. day #EEF1FE · night #1A2140
    static let shannonAccentSubtle = ShannonAdaptive.color(day: 0xEEF1FE, night: 0x1A2140)

    // MARK: Text

    /// Titles and body copy. day #0F0F12 · night #F0F0F5
    static let shannonPrimary = ShannonAdaptive.color(day: 0x0F0F12, night: 0xF0F0F5)

    /// Supporting copy, labels. day #6B6E80 · night #8A8D9F
    static let shannonSecondary = ShannonAdaptive.color(day: 0x6B6E80, night: 0x8A8D9F)

    /// Disabled text, separators, placeholder glyphs. day #A8ABBC · night #4A4D5E
    static let shannonTertiary = ShannonAdaptive.color(day: 0xA8ABBC, night: 0x4A4D5E)

    // MARK: Semantic states

    /// Run succeeded, agent idle-healthy. day #1A7F4B · night #34C77A
    static let shannonSuccess = ShannonAdaptive.color(day: 0x1A7F4B, night: 0x34C77A)

    /// Degraded, retrying, entropy drifting. day #C47A0A · night #F5B934
    static let shannonWarning = ShannonAdaptive.color(day: 0xC47A0A, night: 0xF5B934)

    /// Failure, collapse detected. day #C0392B · night #FF6B6B
    static let shannonError = ShannonAdaptive.color(day: 0xC0392B, night: 0xFF6B6B)

    /// No signal / not applicable. day #8A8D9F · night #5A5D6E
    static let shannonNeutral = ShannonAdaptive.color(day: 0x8A8D9F, night: 0x5A5D6E)
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
    ]

    public static let pill: [ShannonColorToken] = [
        .init("pillBackground", .pillBackground, group: "Pill"),
        .init("pillBorder", .pillBorder, group: "Pill"),
        .init("pillBorderActive", .pillBorderActive, group: "Pill"),
    ]

    public static let accent: [ShannonColorToken] = [
        .init("shannonAccent", .shannonAccent, group: "Accent"),
        .init("shannonAccentSubtle", .shannonAccentSubtle, group: "Accent"),
    ]

    public static let text: [ShannonColorToken] = [
        .init("shannonPrimary", .shannonPrimary, group: "Text"),
        .init("shannonSecondary", .shannonSecondary, group: "Text"),
        .init("shannonTertiary", .shannonTertiary, group: "Text"),
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
