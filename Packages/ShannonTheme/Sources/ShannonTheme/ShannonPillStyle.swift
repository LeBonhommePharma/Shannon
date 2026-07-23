#if os(macOS)
import SwiftUI
import AppKit

/// The `NSVisualEffectView` behind the pill.
///
/// `.hudWindow` in **both** colour schemes — it is the only stock material that
/// stays legible over arbitrary desktop content while remaining genuinely
/// translucent. The scheme difference comes from the `pillBackground` tint
/// layered on top, not from swapping materials.
public struct PillMaterial: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // macOS 27 Liquid Glass: `.hudWindow` still resolves; force `.active`
        // and the app's effective appearance so the material does not wash out
        // to fully clear when the panel is non-key (LSUIElement).
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.appearance = NSApp.effectiveAppearance
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .hudWindow
        view.state = .active
        view.isEmphasized = true
        view.appearance = NSApp.effectiveAppearance
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
    public var cornerRadius: CGFloat

    public init(isActive: Bool, cornerRadius: CGFloat = ShannonLayout.Pill.collapsedRadius) {
        self.isActive = isActive
        self.cornerRadius = cornerRadius
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    public func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    PillMaterial()
                    // Near-opaque tint. Daylight legibility beats translucency:
                    // a 72%-white slab over a busy wallpaper leaves the 11 pt
                    // status text fighting whatever is behind it.
                    Color.pillBackground.opacity(0.96)
                    // Scrim direction follows the scheme — white in day, black
                    // at night. See `Color.pillScrim`.
                    Color.pillScrim
                }
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(
                    isActive ? Color.pillBorderActive : Color.pillBorder,
                    // A hairline is invisible on a bright desk; the resting
                    // border is a full point so the pill always has an edge.
                    lineWidth: isActive ? 2 : 1
                )
            }
            .shadow(
                color: isActive
                    ? Color.shannonAccent.opacity(ShannonStroke.glowOpacity)
                    : Color.shannonShadow,
                radius: isActive ? ShannonStroke.glowRadius : 4,
                y: isActive ? 0 : 1
            )
            // Contact shadow only — lifts the pill off the desktop without the
            // heavy bloom that read as grime under a white slab.
            .shadow(color: Color.shannonShadow, radius: 10, y: 3)
            .animation(.shannonSnap, value: isActive)
    }
}

public extension View {
    /// One-call pill chrome. Pass `isActive: true` while an agent is working to
    /// swap the hairline for the accent border and light the glow.
    func shannonPill(
        isActive: Bool = false,
        cornerRadius: CGFloat = ShannonLayout.Pill.collapsedRadius
    ) -> some View {
        modifier(PillStyle(isActive: isActive, cornerRadius: cornerRadius))
    }
}
#endif
