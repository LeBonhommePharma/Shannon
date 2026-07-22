import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A literal sRGB colour with straight (non-premultiplied) alpha.
///
/// Tokens are declared in terms of these, never used directly by feature code.
public struct ShannonRGBA: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB` literal, e.g. `ShannonRGBA(hex: 0x3A5CF5)`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// Builds a `Color` that resolves against the current colour scheme.
///
/// Platform behaviour:
/// - **macOS** — a dynamic `NSColor` keyed off `NSAppearance`, so it follows
///   system appearance changes live, including inside `NSVisualEffectView`.
/// - **iOS** — a dynamic `UIColor` keyed off `UITraitCollection.userInterfaceStyle`.
/// - **watchOS** — the interface is permanently dark, so the night value is used
///   unconditionally. There is no dynamic-provider API on watchOS.
///
/// Because the adaptation happens below SwiftUI, these tokens also work in
/// AppKit/UIKit contexts and respect `.preferredColorScheme` overrides applied
/// by `PreviewProvider`.
public enum ShannonAdaptive {
    public static func color(day: ShannonRGBA, night: ShannonRGBA) -> Color {
        #if os(watchOS)
        return night.color
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(from: isDark ? night : day)
        })
        #elseif canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            UIColor(from: traits.userInterfaceStyle == .dark ? night : day)
        })
        #else
        return day.color
        #endif
    }

    /// Convenience for tokens declared as plain `0xRRGGBB` hex pairs.
    public static func color(day: UInt32, night: UInt32) -> Color {
        color(day: ShannonRGBA(hex: day), night: ShannonRGBA(hex: night))
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
private extension NSColor {
    convenience init(from rgba: ShannonRGBA) {
        self.init(
            srgbRed: CGFloat(rgba.red),
            green: CGFloat(rgba.green),
            blue: CGFloat(rgba.blue),
            alpha: CGFloat(rgba.alpha)
        )
    }
}
#elseif canImport(UIKit)
private extension UIColor {
    convenience init(from rgba: ShannonRGBA) {
        self.init(
            red: CGFloat(rgba.red),
            green: CGFloat(rgba.green),
            blue: CGFloat(rgba.blue),
            alpha: CGFloat(rgba.alpha)
        )
    }
}
#endif
