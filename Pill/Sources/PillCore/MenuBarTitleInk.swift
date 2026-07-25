import Foundation

// MARK: - Menu-bar title ink (pure, appearance-independent)

/// sRGB ink for NSStatusItem titles on macOS Liquid Glass menu bars.
///
/// Shannon forces `NSApp.appearance = darkAqua` for the pill overlay. Under that
/// appearance, `NSColor.labelColor` resolves to **white @ ~0.85** — unreadable
/// on a light / translucent menu bar (MBP 14" wallpaper glass). Status-item
/// chrome must therefore use **absolute sRGB**, not dynamic label colors that
/// follow the app appearance.
public enum MenuBarTitleInk: Sendable {
    public enum Role: String, Sendable, Equatable, CaseIterable {
        /// Idle / busy telemetry (CPU %, agent count) — dark ink on light glass.
        case calm
        /// Host load ≥ 80% — gold, still dark enough for light glass.
        case elevated
        /// Host load ≥ 92% — red stress.
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

    /// Absolute sRGB components for a status-item title role.
    public static func sRGB(for role: Role) -> SRGB {
        switch role {
        case .calm:
            // Near-black @ high alpha — readable on light Liquid Glass.
            return SRGB(r: 0.08, g: 0.08, b: 0.10, a: 0.94)
        case .elevated:
            // Dark gold (not systemYellow washed to white under darkAqua).
            return SRGB(r: 0.72, g: 0.42, b: 0.02, a: 1)
        case .critical:
            return SRGB(r: 0.82, g: 0.12, b: 0.10, a: 1)
        case .ask:
            return SRGB(r: 0.86, g: 0.40, b: 0.04, a: 1)
        case .collapse:
            return SRGB(r: 0.86, g: 0.14, b: 0.12, a: 1)
        }
    }

    /// Role from host load percent (same bands as SystemResourceLogic).
    public static func loadRole(percent: Double?) -> Role {
        guard let p = percent, p.isFinite else { return .calm }
        if p >= 92 { return .critical }
        if p >= 80 { return .elevated }
        return .calm
    }

    /// True when ink is dark enough for a light / translucent menu bar.
    ///
    /// Rejects near-white (the darkAqua `labelColor` failure mode).
    public static func isReadableOnLightGlass(_ ink: SRGB) -> Bool {
        // White@0.85 luminance ≈ 0.85 — must stay well below that.
        ink.relativeLuminance < 0.55 && ink.a >= 0.75
    }

    /// Pure proof that calm ink is not the darkAqua white-label failure.
    public static func calmIsNotWhiteOnLight() -> Bool {
        isReadableOnLightGlass(sRGB(for: .calm))
    }
}
