import SwiftUI
import ShannonCore
import ShannonTheme

// MARK: - PetPillView

/// Embeds the pet avatar in the left slot of the macOS notch pill.
/// Compact: 28×28 pt with a static mood ring.
/// Expanded: 44×44 pt with a breathing animation loop.
/// AirPods nod → happy bounce + 3 XP. Shake → sad shake + 1 XP.
@available(macOS 14.0, *)
public struct PetPillView: View {
    // PetStore is @Observable (Observation), not ObservableObject.
    @Bindable public var store: PetStore
    public var isExpanded: Bool

    @State private var breathe = false
    @State private var bounceScale: CGFloat = 1

    private var avatarSize: CGFloat { isExpanded ? 44 : 28 }

    public init(store: PetStore, isExpanded: Bool) {
        self.store = store
        self.isExpanded = isExpanded
    }

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(moodColor.opacity(0.7), lineWidth: isExpanded ? 2 : 1)
            PetAvatarCanvasMac(params: PetAvatarDescriptor.params(for: store.pet.avatarSeed),
                               mood: store.pet.mood,
                               size: avatarSize)
        }
        .frame(width: avatarSize, height: avatarSize)
        .scaleEffect(breathe ? 1.04 : 0.97)
        .scaleEffect(bounceScale)
        .animation(
            isExpanded
                ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                : .default,
            value: breathe
        )
        .onAppear    { breathe = isExpanded }
        .onChange(of: isExpanded) { _, v in breathe = v }
        .help("Pet: \(store.pet.name) · \(store.pet.mood.label)")
    }

    // MARK: Mood colour

    public var moodColor: Color {
        switch store.pet.mood.colorRole {
        case .blue:   return .shannonAccent
        case .teal:   return Color(hue: 0.5, saturation: 0.7, brightness: 0.8)
        case .amber:  return .shannonWarning
        case .red:    return .shannonError
        case .gray:   return .shannonNeutral
        case .purple: return Color(hue: 0.78, saturation: 0.6, brightness: 0.8)
        }
    }

    // MARK: AirPods gesture callbacks (called from HeadGestureDetector)

    /// Called when the user nods while AirPods are active.
    public func handleNod(engine: PetInteractionEngine) {
        engine.handle(.nodConfirm)
        withAnimation(.spring(response: 0.2, dampingFraction: 0.4)) { bounceScale = 1.25 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring()) { bounceScale = 1 }
        }
    }

    /// Called when the user shakes while AirPods are active.
    public func handleShake(engine: PetInteractionEngine) {
        engine.handle(.shakeDeny)
        let original = bounceScale
        for i in 0..<4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.07) {
                withAnimation(.linear(duration: 0.06)) { bounceScale = i % 2 == 0 ? 0.85 : 1.05 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { bounceScale = original }
    }
}

// MARK: - PetAvatarCanvasMac

/// macOS-specific procedural avatar canvas (mirrors iOS PetAvatarCanvas
/// without depending on the iOS Shared source group).
@available(macOS 14.0, *)
struct PetAvatarCanvasMac: View {
    let params: PetAvatarShapeParams
    let mood: PetMood
    let size: CGFloat

    private var overlay: PetMoodOverlay { PetMoodOverlay.from(mood: mood) }

    var body: some View {
        Canvas { ctx, sz in
            let cx = sz.width / 2, cy = sz.height / 2, r = min(cx, cy) * 0.85
            ctx.fill(bodyPath(cx: cx, cy: cy, r: r),
                     with: .color(Color(hue: params.hue, saturation: params.saturation, brightness: 0.8)))
            if overlay.eyesClosed {
                drawClosedEyes(ctx: ctx, cx: cx, cy: cy, r: r)
            } else {
                drawEyes(ctx: ctx, cx: cx, cy: cy, r: r)
            }
        }
        .scaleEffect(overlay.avatarScale)
        .frame(width: size, height: size)
    }

    private func bodyPath(cx: CGFloat, cy: CGFloat, r: CGFloat) -> Path {
        switch params.bodyShape {
        case 1:
            return Path(roundedRect: CGRect(x: cx-r*0.8, y: cy-r*0.8,
                                            width: r*1.6, height: r*1.6),
                        cornerRadius: r * 0.3)
        case 2:
            var p = Path()
            p.move(to: CGPoint(x: cx, y: cy - r)); p.addLine(to: CGPoint(x: cx + r, y: cy))
            p.addLine(to: CGPoint(x: cx, y: cy + r)); p.addLine(to: CGPoint(x: cx - r, y: cy))
            p.closeSubpath(); return p
        default:
            return Path(ellipseIn: CGRect(x: cx-r, y: cy-r, width: r*2, height: r*2))
        }
    }

    private func drawEyes(ctx: GraphicsContext, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let ey = cy + CGFloat(overlay.eyeVerticalOffset) * r - r * 0.1
        let er = r * 0.16, pr = er * CGFloat(params.pupilScale * overlay.pupilScale)
        let pupil = Color(hue: params.accentHue, saturation: 0.9, brightness: 0.2)
        for ex in [cx - r*0.28, cx + r*0.28] {
            ctx.fill(Path(ellipseIn: CGRect(x: ex-er, y: ey-er, width: er*2, height: er*2)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: ex-pr, y: ey-pr, width: pr*2, height: pr*2)), with: .color(pupil))
        }
    }

    private func drawClosedEyes(ctx: GraphicsContext, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let ey = cy - r * 0.1
        let lc = Color(hue: params.hue, saturation: 0.6, brightness: 0.4)
        for ex in [cx - r*0.28, cx + r*0.28] {
            var p = Path(); p.move(to: CGPoint(x: ex - r*0.12, y: ey))
            p.addLine(to: CGPoint(x: ex + r*0.12, y: ey))
            ctx.stroke(p, with: .color(lc), lineWidth: r * 0.06)
        }
    }
}
