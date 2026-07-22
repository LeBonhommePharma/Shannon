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
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .hudWindow
        view.state = .active
    }
}

/// Applies the full pill appearance — material, tint, hairline border, shadow,
/// and the accent glow that marks an active agent.
///
/// At rest at night the pill is close to invisible: a dark translucent slab with
/// a 10%-white seam. When an agent starts working the seam turns accent and a
/// soft accent glow blooms behind it.
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
                    Color.pillBackground
                }
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(
                    isActive ? Color.pillBorderActive : Color.pillBorder,
                    lineWidth: ShannonStroke.hairline
                )
            }
            .shadow(
                color: isActive
                    ? Color.shannonAccent.opacity(ShannonStroke.glowOpacity)
                    : .clear,
                radius: isActive ? ShannonStroke.glowRadius : 0
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
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
