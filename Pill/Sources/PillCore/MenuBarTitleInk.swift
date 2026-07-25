import Foundation

// MARK: - Menu-bar title ink (pure, appearance-independent)

/// sRGB ink for NSStatusItem titles on macOS Liquid Glass menu bars.
///
/// Shannon forces `NSApp.appearance = darkAqua` for the pill overlay. Under that
/// appearance, `NSColor.labelColor` resolves to **white @ ~0.85** — unreadable
/// on a light / translucent menu bar. Status-item chrome uses **absolute sRGB**.
///
/// Host-load titles prefer `sRGB(loadPercent:)` — continuous scarcity intensity
/// (red only at critical), not full solid gold/red band jumps.
public enum MenuBarTitleInk: Sendable {
    public enum Role: String, Sendable, Equatable, CaseIterable {
        /// Idle / busy telemetry without a load percent.
        case calm
        /// Legacy elevated band (~80–92%). Prefer `sRGB(loadPercent:)`.
        case elevated
        /// Legacy critical band (≥92%). Prefer `sRGB(loadPercent:)`.
        case critical
        /// Gate approval pending.
        case ask
        /// Measured entropy collapse.
        case collapse
    }

    public struct SRGB: Sendable, Equatable {
        public var r: Double
        public var g: Double
        public var b: Double
        public var a: Double

        public init(r: Double, g: Double, b: Double, a: Double = 1) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        /// Relative luminance (WCAG), 0 = black, 1 = white.
        public var relativeLuminance: Double {
            func lin(_ c: Double) -> Double {
                let x = max(0, min(1, c))
                return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            let R = lin(r), G = lin(g), B = lin(b)
            return 0.2126 * R + 0.7152 * G + 0.0722 * B
        }
    }

    /// Continuous host-load ink (preferred for CPU % / constrained titles).
    public static func sRGB(loadPercent: Double?) -> SRGB {
        let scar = ResourceScarcityTint.sRGB(percent: loadPercent)
        let I = ResourceScarcityTint.intensity(percent: loadPercent ?? 0)
        // Dark base for Liquid Glass legibility; blend scarcity chroma in.
        let baseR = 0.08, baseG = 0.08, baseB = 0.10
        let mix = 0.30 + 0.70 * I
        return SRGB(
            r: baseR + (scar.r - baseR) * mix,
            g: baseG + (scar.g - baseG) * mix,
            b: baseB + (scar.b - baseB) * mix,
            a: 0.88 + 0.12 * I
        )
    }

    /// Absolute sRGB for a discrete role.
    ///
    /// Load roles sample the continuous scarcity ramp at representative percents.
    /// Ask/collapse stay discrete (not host-load).
    public static func sRGB(for role: Role) -> SRGB {
        switch role {
        case .calm:
            return sRGB(loadPercent: 20)
        case .elevated:
            return sRGB(loadPercent: 85)
        case .critical:
            return sRGB(loadPercent: 96)
        case .ask:
            return SRGB(r: 0.86, g: 0.40, b: 0.04, a: 1)
        case .collapse:
            return SRGB(r: 0.86, g: 0.14, b: 0.12, a: 1)
        }
    }

    /// Role from host load percent (legacy). Prefer `sRGB(loadPercent:)`.
    public static func loadRole(percent: Double?) -> Role {
        guard let p = percent, p.isFinite else { return .calm }
        if p >= ResourceScarcityTint.criticalThreshold { return .critical }
        if p >= 80 { return .elevated }
        return .calm
    }

    /// True when ink is dark enough for a light / translucent menu bar.
    public static func isReadableOnLightGlass(_ ink: SRGB) -> Bool {
        ink.relativeLuminance < 0.55 && ink.a >= 0.75
    }

    public static func calmIsNotWhiteOnLight() -> Bool {
        isReadableOnLightGlass(sRGB(for: .calm))
    }
}
