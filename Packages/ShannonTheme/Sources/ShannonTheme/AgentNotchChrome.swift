import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - AgentNotch-class notch chrome roles
//
// Pure color / opacity / spring *roles* for the Dynamic Island HUD. Feature
// views name a role; they never invent one-off hex for island fill, attention
// ink, or collapse alarm. Numbers target the public AgentNotch product class
// (opaque black island, snappy DI morph, high-contrast attention) plus
// Shannon’s entropy differentiator (collapse = error red).
//
// Dual-HUD rule: notch + menu-bar must call these roles (or the same semantic
// Color tokens) so needs-you / working / done cannot drift.

/// Semantic chrome for the Mac notch island and shared attention HUD.
public enum AgentNotchChrome: Sendable {

    // MARK: Island shell (AgentNotch Dynamic Island)

    /// Opaque pure-black island fill — hardware cutout + software hang read as
    /// one silhouette. Never translucent indigo (that greys out as a sticker).
    public static let islandFill = Color(red: 0, green: 0, blue: 0)

    /// Expanded board still uses a near-black shell; board cards carry glass.
    public static let islandExpandedFillOpacity: Double = 0.94

    /// Collapsed hairline border opacities (quiet vs rest) — higher than a
    /// “sticker” 0.2 so the island edge reads under Liquid Glass menubars.
    public static let islandHairlineQuiet: Double = 0.42
    public static let islandHairlineRest: Double = 0.62

    /// Collapsed border width (pt).
    public static let islandHairlineWidthQuiet: CGFloat = 0.55
    public static let islandHairlineWidthRest: CGFloat = 0.75

    /// Top-edge specular strength on the black island (AgentNotch refractive lip).
    public static let islandSpecularOpacity: Double = 0.085

    // MARK: Attention ink (shared notch + menu-bar)

    /// Product attention roles — map 1:1 to live surface attention + collapse.
    public enum AttentionRole: String, CaseIterable, Sendable, Equatable {
        case needsYou
        case working
        case finished
        case idle
        case unknown
        /// Shannon differentiator: measured entropy collapse (never invent).
        case collapse
    }

    /// High-contrast ink for a HUD capsule / badge / scan line.
    public static func ink(
        for role: AttentionRole,
        styleInk: Color = .shannonAccent
    ) -> Color {
        switch role {
        case .needsYou: return .shannonWarning
        case .working: return styleInk
        case .finished: return .shannonSuccess
        case .collapse: return .shannonError
        case .idle, .unknown: return styleInk
        }
    }

    /// Capsule wash behind badge labels (notch + menu-bar).
    public static func badgeWash(for role: AttentionRole) -> Color {
        switch role {
        case .needsYou: return Color.shannonWarning.opacity(0.18)
        case .working: return Color.shannonAccent.opacity(0.16)
        case .finished: return Color.shannonSuccess.opacity(0.16)
        case .collapse: return Color.shannonError.opacity(0.20)
        case .idle, .unknown: return Color.white.opacity(0.08)
        }
    }

    /// Map live-surface attention raw names (fail-closed → unknown).
    public static func role(attentionRaw: String) -> AttentionRole {
        switch attentionRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "needsyou", "needs_you", "needs-you": return .needsYou
        case "working": return .working
        case "finished", "done": return .finished
        case "idle": return .idle
        case "collapse", "collapsed", "wary": return .collapse
        default: return .unknown
        }
    }

    // MARK: Label / badge geometry (AgentNotch density)

    /// Section header letter-spacing (popover + roster).
    public static let sectionHeaderTracking: CGFloat = 1.05

    /// Collapsed island primary label tracking (tight, scannable).
    public static let islandLabelTracking: CGFloat = -0.15

    public static let badgeHorizontalPadding: CGFloat = 6
    public static let badgeVerticalPadding: CGFloat = 2

    // MARK: Status-item title (menu bar)

    /// Point size for `NSStatusBarButton` attributed titles — AgentNotch density.
    public static let statusItemTitlePointSize: CGFloat = 12

    #if canImport(AppKit)
    /// Shipped status-item title font (monospaced digits for H / %).
    public static var statusItemTitleFont: NSFont {
        NSFont.monospacedDigitSystemFont(
            ofSize: statusItemTitlePointSize,
            weight: .semibold
        )
    }
    #endif

    // MARK: Spring single-source contract

    /// Island expand/collapse spring — must equal `ShannonSpring.float`.
    public static var islandSpring: ShannonSpring { ShannonSpring.float }

    /// AppKit panel morph duration — must equal `islandSpring.panelDuration`.
    public static var panelMorphDuration: TimeInterval {
        ShannonMotion.panelMorphDuration
    }

    /// Geometry radii contract (AgentNotch closed 6/14, open 19/24).
    public static var closedRadii: (top: CGFloat, bottom: CGFloat) {
        DynamicIslandGeometry.radii(expanded: false)
    }

    public static var openRadii: (top: CGFloat, bottom: CGFloat) {
        DynamicIslandGeometry.radii(expanded: true)
    }

    /// Diagnostics snapshot for tests / probe.
    public static var policySnapshot: [String: String] {
        [
            "islandFill": "pureBlack",
            "islandExpandedFillOpacity": "\(islandExpandedFillOpacity)",
            "islandHairlineQuiet": "\(islandHairlineQuiet)",
            "islandHairlineRest": "\(islandHairlineRest)",
            "islandSpecularOpacity": "\(islandSpecularOpacity)",
            "islandSpringResponse": "\(islandSpring.response)",
            "islandSpringDamping": "\(islandSpring.dampingFraction)",
            "panelMorphDuration": "\(panelMorphDuration)",
            "closedTopRadius": "\(closedRadii.top)",
            "closedBottomRadius": "\(closedRadii.bottom)",
            "openTopRadius": "\(openRadii.top)",
            "openBottomRadius": "\(openRadii.bottom)",
            "wingExtension": "\(DynamicIslandGeometry.wingExtension)",
            "statusItemTitlePointSize": "\(statusItemTitlePointSize)",
            "sectionHeaderTracking": "\(sectionHeaderTracking)",
        ]
    }
}

public extension Color {
    /// AgentNotch-class pure-black notch island shell (semantic role).
    static let notchIslandFill = AgentNotchChrome.islandFill
}

// MARK: - Shared HUD badge (notch + menu-bar)

/// Capsule attention badge used by both the collapsed island and the menu-bar
/// roster so dual-HUD cannot invent a second style.
public struct AgentNotchBadge: View {
    public var text: String
    public var role: AgentNotchChrome.AttentionRole
    public var styleInk: Color

    public init(
        text: String,
        role: AgentNotchChrome.AttentionRole,
        styleInk: Color = .shannonAccent
    ) {
        self.text = text
        self.role = role
        self.styleInk = styleInk
    }

    public var body: some View {
        Text(text)
            .font(.shannonMenuSection)
            .foregroundStyle(AgentNotchChrome.ink(for: role, styleInk: styleInk))
            .lineLimit(1)
            .padding(.horizontal, AgentNotchChrome.badgeHorizontalPadding)
            .padding(.vertical, AgentNotchChrome.badgeVerticalPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(AgentNotchChrome.badgeWash(for: role))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        AgentNotchChrome.ink(for: role, styleInk: styleInk).opacity(0.28),
                        lineWidth: 0.5
                    )
            )
    }
}
