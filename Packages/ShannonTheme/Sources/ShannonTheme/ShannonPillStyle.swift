#if os(macOS)
import SwiftUI
import AppKit

/// The `NSVisualEffectView` behind the pill and the menu-bar popover.
///
/// `.sheet`, not `.hudWindow`. Measured on macOS 27 in `.darkAqua`, rendering
/// each stock material over three backdrops and sampling the result (sRGB, low
/// = dark):
///
///     material                over WHITE   over GREY50   over BLACK
///     .hudWindow                 0.706        0.375         0.077
///     .sheet                     0.237        0.167         0.107
///     .popover                   0.544        0.306         0.107
///     .windowBackground          0.119        0.119         0.119   (no vibrancy)
///
/// `.hudWindow` barely darkens a bright backdrop, so legibility had to be
/// bought with an opaque tint on top — which is why the pill ended up at ~0.90
/// composite opacity and stopped looking translucent at all. `.sheet` carries a
/// much stronger dark tint of its own while still tracking the backdrop
/// (0.237 → 0.107), i.e. it is genuinely vibrant. That lets the tint above it
/// drop to ~0.3–0.48 composite and *still* measure better contrast than the old
/// opaque slab. `.windowBackground`/`.contentBackground` are constant across
/// backdrops — they are opaque and were never candidates.
public struct PillMaterial: NSViewRepresentable {
    public init() {}

    private func configure(_ view: NSVisualEffectView) {
        view.material = .sheet
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
    public var cornerRadius: CGFloat

    public init(
        isActive: Bool,
        isQuiet: Bool = false,
        cornerRadius: CGFloat = ShannonLayout.Pill.collapsedRadius
    ) {
        self.isActive = isActive
        self.isQuiet = isQuiet
        self.cornerRadius = cornerRadius
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// Multiplier on `pillBackground`'s own alpha (0.42 at night), by state.
    ///
    /// The pill's job when quiet is to be *available*, not to be seen. It earns
    /// opacity by having something to say. Composite opacity including the
    /// scrim, measured:
    ///
    ///     quiet   0.62 → 0.305      resting 0.82 → 0.410      active 1.0 → 0.478
    ///
    /// against the ~0.902 the pill used to sit at — roughly a 3× reduction.
    /// Contrast over the worst-case white wallpaper still improves, because the
    /// `.sheet` material darkens far harder than `.hudWindow` did: primary text
    /// 12.4:1, secondary 5.5:1, tertiary 4.8:1 at the *most* transparent state.
    private var fillOpacity: Double {
        if isActive { return 1.0 }
        return isQuiet ? 0.62 : 0.82
    }

    /// The border earns weight the same way the fill does. A quiet pill keeps a
    /// true hairline; only a working one draws a hard outline.
    private var borderWidth: CGFloat {
        if isActive { return 2.0 }
        return isQuiet ? 0.75 : 1.25
    }

    /// Quiet chrome should not cast a slab shadow — that is what made the
    /// resting pill read as an object sitting on top of the desktop rather than
    /// part of it.
    private var ambientShadowRadius: CGFloat { isQuiet ? 6 : 12 }

    public func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // The vibrancy layer does the real work: it blurs and
                    // darkens whatever is behind the notch. Everything above it
                    // is a tint, not a cover.
                    PillMaterial()
                    Color.pillBackground.opacity(fillOpacity)
                    // Scrim direction follows the scheme — white in day, black
                    // at night. See `Color.pillScrim`.
                    Color.pillScrim.opacity(isQuiet ? 0.6 : 1.0)
                }
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(
                    isActive ? Color.pillBorderActive : Color.pillBorder,
                    lineWidth: borderWidth
                )
            }
            .shadow(
                color: isActive
                    ? Color.shannonAccent.opacity(ShannonStroke.glowOpacity)
                    : Color.shannonShadow.opacity(isQuiet ? 0.5 : 1.0),
                radius: isActive ? ShannonStroke.glowRadius : 5,
                y: isActive ? 0 : 1
            )
            // Second shadow pass for depth. Softened when quiet so the pill
            // floats rather than stamps.
            .shadow(
                color: Color.shannonShadow.opacity(isQuiet ? 0.45 : 1.0),
                radius: ambientShadowRadius,
                y: isQuiet ? 2 : 4
            )
            .animation(.shannonFloat, value: isActive)
            .animation(.shannonFloat, value: isQuiet)
    }
}

public extension View {
    /// One-call pill chrome. Pass `isActive: true` while an agent is working to
    /// swap the hairline for the accent border and light the glow; pass
    /// `isQuiet: true` when there is nothing to report, which fades the pill
    /// back toward the desktop instead of parking an opaque slab in the notch.
    func shannonPill(
        isActive: Bool = false,
        isQuiet: Bool = false,
        cornerRadius: CGFloat = ShannonLayout.Pill.collapsedRadius
    ) -> some View {
        modifier(PillStyle(isActive: isActive, isQuiet: isQuiet, cornerRadius: cornerRadius))
    }
}
#endif
