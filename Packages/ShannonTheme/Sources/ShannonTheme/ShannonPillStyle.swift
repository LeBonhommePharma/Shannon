#if os(macOS)
import SwiftUI
import AppKit

/// Material roles for vibrancy surfaces (measured on macOS 27 Liquid Glass).
///
///     material                over WHITE   over GREY50   over BLACK
///     .hudWindow                 0.706        0.375         0.077
///     .sheet                     0.237        0.167         0.107
///     .popover                   0.544        0.306         0.107
///     .menu                      0.48ish      —             —     (system menus)
///     .windowBackground          0.119        0.119         0.119   (no vibrancy)
///
/// - **expanded pill board** → `.sheet` (readable glass over wallpaper)
/// - **menu-bar popover** → `.popover` (lighter Liquid Glass, matches system menus)
public enum ShannonMaterialKind: Sendable {
    case sheet
    case popover
    case menu

    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .sheet: return .sheet
        case .popover: return .popover
        case .menu: return .menu
        }
    }
}

/// The `NSVisualEffectView` behind the pill board and the menu-bar popover.
///
/// `.sheet` (default) not `.hudWindow`. `.hudWindow` barely darkens a bright
/// backdrop, so legibility used to need an opaque tint — composite ~0.90 and no
/// real translucency. `.sheet` carries its own dark tint while still tracking
/// the backdrop (0.237 → 0.107). Use `.popover` for the status-item menu so it
/// reads like a system Liquid Glass surface rather than a second sheet.
public struct PillMaterial: NSViewRepresentable {
    public var kind: ShannonMaterialKind

    public init(kind: ShannonMaterialKind = .sheet) {
        self.kind = kind
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = kind.nsMaterial
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        // Lock appearance to dark — Shannon always renders in dark mode
        // regardless of the system setting.
        view.appearance = NSAppearance(named: .darkAqua)
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }
}

/// Applies the full pill appearance — material, tint, hairline border, shadow,
/// and the accent glow that marks an active agent.
///
/// macOS 27 ("Liquid Glass") made the menu bar more translucent; a 10%-white
/// seam on a near-clear slab was effectively invisible and users reported the
/// app "does nothing". Idle chrome now keeps a readable border and a soft
/// ambient shadow even when `isActive` is false; the accent glow still only
/// blooms when an agent is live.
public struct PillStyle: ViewModifier {
    public var isActive: Bool
    /// Nothing to report — no busy agent, no pending approval, no alert.
    /// Drives the most transparent, most recessive presentation.
    public var isQuiet: Bool
    /// Collapsed notch-resident state: black island chrome (matches hardware
    /// notch), no ambient shadow halo, hairline outline only.
    public var isCollapsed: Bool
    /// Physical camera cutout: flush top edge + bottom lip only (MBP 14"/16").
    /// When false, collapsed uses a full continuous capsule (external displays).
    public var notchIsland: Bool
    public var cornerRadius: CGFloat

    public init(
        isActive: Bool,
        isQuiet: Bool = false,
        isCollapsed: Bool = false,
        notchIsland: Bool = false,
        cornerRadius: CGFloat = ShannonLayout.Pill.collapsedRadius
    ) {
        self.isActive = isActive
        self.isQuiet = isQuiet
        self.isCollapsed = isCollapsed
        self.notchIsland = notchIsland
        self.cornerRadius = cornerRadius
    }

    /// Island on hardware: top corners 0 (flush with bezel), bottom = lip radius.
    /// Everywhere else: continuous rounded rectangle (all corners equal).
    private var shape: UnevenRoundedRectangle {
        if isCollapsed && notchIsland {
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            )
        }
        return UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: cornerRadius,
            style: .continuous
        )
    }

    /// Multiplier on `pillBackground`'s own alpha, by state.
    ///
    /// Collapsed notch form is intentionally denser: translucent sheet over a
    /// black notch reads as a *grey frosted sticker*, not part of the island.
    /// Quiet still fades, but stays dark enough to read as notch chrome.
    private var fillOpacity: Double {
        if isCollapsed {
            // Physical island: stay fully opaque even when quiet — recessive
            // transparency turns the cutout into a grey sticker over the camera.
            if isActive { return 1.0 }
            return isQuiet ? 0.98 : 1.0
        }
        if isActive { return 1.0 }
        return isQuiet ? 0.62 : 0.82
    }

    /// Notch island uses opaque pure-black so the hardware camera cutout and
    /// the software hang read as one silhouette against wallpaper (Liquid Glass
    /// greys a translucent fill and looks like “only the camera”).
    private var notchIslandFill: Color {
        Color(red: 0.0, green: 0.0, blue: 0.0)
    }

    /// Collapsed notch chrome never uses the "working" border/glow — those
    /// float the strip off the hardware cutout. Expanded may still light up.
    private var showActiveChrome: Bool { isActive && !isCollapsed }

    private var borderWidth: CGFloat {
        if isCollapsed { return isQuiet ? 0.5 : 0.65 }
        if showActiveChrome { return 1.5 }
        return isQuiet ? 0.75 : 1.25
    }

    private var borderColor: Color {
        if isCollapsed {
            // Hairline only — never pillBorderActive electric blue on the island.
            return Color.pillBorder.opacity(isQuiet ? 0.35 : 0.5)
        }
        return showActiveChrome ? Color.pillBorderActive : Color.pillBorder
    }

    private var ambientShadowRadius: CGFloat {
        if isCollapsed { return 0 }
        return isQuiet ? 6 : 12
    }

    public func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if isCollapsed {
                        // Opaque black island only — no vibrancy/tint (those grey
                        // the silhouette and break the continuous camera hole).
                        notchIslandFill
                    } else {
                        // Liquid Glass stack: vibrancy → indigo tint → scrim →
                        // top-edge specular (macOS 27 system panels use a soft
                        // highlight so glass reads as refractive, not flat grey).
                        PillMaterial(kind: .sheet)
                        Color.pillBackground.opacity(fillOpacity)
                        Color.pillScrim.opacity(isQuiet ? 0.55 : 0.92)
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isQuiet ? 0.06 : 0.10),
                                Color.white.opacity(0.02),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: 0.42)
                        )
                    }
                }
                .clipShape(shape)
            }
            .overlay {
                // Dual-stroke: soft outer rim + crisp inner hairline (Liquid Glass).
                ZStack {
                    shape.strokeBorder(borderColor.opacity(0.45), lineWidth: borderWidth + 0.75)
                    shape.strokeBorder(borderColor, lineWidth: borderWidth)
                }
            }
            // Accent glow: expanded + working only. Collapsed never glows
            // (even when isActive) — that was the blue halo on the notch.
            .shadow(
                color: showActiveChrome
                    ? Color.shannonAccent.opacity(ShannonStroke.glowOpacity)
                    : Color.shannonShadow.opacity(isCollapsed ? 0 : (isQuiet ? 0.45 : 0.85)),
                radius: showActiveChrome ? ShannonStroke.glowRadius : (isCollapsed ? 0 : 6),
                y: showActiveChrome ? 0 : (isCollapsed ? 0 : 1)
            )
            .shadow(
                color: Color.shannonShadow.opacity(isCollapsed ? 0 : (isQuiet ? 0.35 : 0.75)),
                radius: ambientShadowRadius,
                y: isQuiet ? 2 : 5
            )
            .animation(.shannonChrome, value: isActive)
            .animation(.shannonChrome, value: isQuiet)
            .animation(.shannonFloat, value: isCollapsed)
    }
}

// MARK: - Grouped glass section (popover / expanded board)

/// Soft continuous card used inside Liquid Glass surfaces so sections float
/// rather than stacking as flat dividers (macOS 27 Settings / Control Center).
public struct ShannonGlassSection: ViewModifier {
    public var emphasized: Bool

    public init(emphasized: Bool = false) {
        self.emphasized = emphasized
    }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, ShannonSpacing.sm)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: ShannonRadius.md, style: .continuous)
                    .fill(Color.white.opacity(emphasized ? 0.08 : 0.045))
                    .overlay {
                        RoundedRectangle(cornerRadius: ShannonRadius.md, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(emphasized ? 0.14 : 0.07),
                                lineWidth: 0.5
                            )
                    }
            }
    }
}

public extension View {
    /// Grouped Liquid Glass section chrome for popover / board subsections.
    func shannonGlassSection(emphasized: Bool = false) -> some View {
        modifier(ShannonGlassSection(emphasized: emphasized))
    }
}

public extension View {
    /// One-call pill chrome. Pass `isActive: true` while an agent is working to
    /// swap the hairline for the accent border and light the glow; pass
    /// `isQuiet: true` when there is nothing to report; pass `isCollapsed: true`
    /// for the notch-resident strip (black island, no floating shadow); pass
    /// `notchIsland: true` on a physical MacBook cutout so top corners stay
    /// flush with the bezel.
    func shannonPill(
        isActive: Bool = false,
        isQuiet: Bool = false,
        isCollapsed: Bool = false,
        notchIsland: Bool = false,
        cornerRadius: CGFloat = ShannonLayout.Pill.collapsedRadius
    ) -> some View {
        modifier(PillStyle(
            isActive: isActive,
            isQuiet: isQuiet,
            isCollapsed: isCollapsed,
            notchIsland: notchIsland,
            cornerRadius: cornerRadius
        ))
    }
}
#endif
