import SwiftUI

// MARK: - AgentNotch-class notch chrome roles
//
// Pure color / opacity / spring *roles* for the Dynamic Island HUD. Feature
// views name a role; they never invent one-off hex for island fill, attention
// ink, or collapse alarm. Numbers match the public AgentNotch product class
// (opaque black island, high-contrast attention) plus Shannon’s entropy
// differentiator (collapse = error red).
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
    public static let islandExpandedFillOpacity: Double = 0.92

    /// Collapsed hairline border opacities (quiet vs non-quiet).
    public static let islandHairlineQuiet: Double = 0.35
    public static let islandHairlineRest: Double = 0.50

    /// Collapsed border width (pt).
    public static let islandHairlineWidthQuiet: CGFloat = 0.5
    public static let islandHairlineWidthRest: CGFloat = 0.65

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
    ///
    /// - needsYou → warning amber
    /// - working → caller style ink (agent brand) or accent fallback
    /// - finished → success green
    /// - collapse → error red
    /// - idle / unknown → style ink / secondary
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
            "islandSpringResponse": "\(islandSpring.response)",
            "islandSpringDamping": "\(islandSpring.dampingFraction)",
            "panelMorphDuration": "\(panelMorphDuration)",
            "closedTopRadius": "\(closedRadii.top)",
            "closedBottomRadius": "\(closedRadii.bottom)",
            "openTopRadius": "\(openRadii.top)",
            "openBottomRadius": "\(openRadii.bottom)",
            "wingExtension": "\(DynamicIslandGeometry.wingExtension)",
        ]
    }
}

public extension Color {
    /// AgentNotch-class pure-black notch island shell (semantic role).
    static let notchIslandFill = AgentNotchChrome.islandFill
}
