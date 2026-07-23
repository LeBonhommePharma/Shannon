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
                    // Slightly stronger tint than stock pillBackground so the
                    // slab reads against both light and dark wallpapers on 27.x.
                    Color.pillBackground.opacity(0.92)
                    Color.black.opacity(0.18)
                }
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(
                    isActive ? Color.pillBorderActive : Color.pillBorder.opacity(0.85),
                    lineWidth: isActive ? ShannonStroke.hairline * 1.5 : ShannonStroke.hairline * 1.25
                )
            }
            .shadow(
                color: isActive
                    ? Color.shannonAccent.opacity(ShannonStroke.glowOpacity)
                    : Color.black.opacity(0.28),
                radius: isActive ? ShannonStroke.glowRadius : 5,
                y: isActive ? 0 : 1
            )
            .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
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
