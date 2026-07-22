import SwiftUI
import ShannonCore

// MARK: - PetAvatarCanvas (iPad / iPadOS shared)
//
// Mirrors iOS/Sources/Shared/PetAvatarCanvas.swift for the iPad Xcode target.
// Keep both files in sync when changing the rendering logic.

@available(iOS 17.0, *)
public struct PetAvatarCanvas: View {
    public let params: PetAvatarShapeParams
    public let mood: PetMood
    public let size: CGFloat

    public init(params: PetAvatarShapeParams, mood: PetMood, size: CGFloat) {
        self.params = params; self.mood = mood; self.size = size
    }

    private var overlay: PetMoodOverlay { PetMoodOverlay.from(mood: mood) }

    public var body: some View {
        Canvas { ctx, sz in
            let cx = sz.width/2, cy = sz.height/2, r = min(cx, cy) * 0.85
            ctx.fill(bodyPath(cx: cx, cy: cy, r: r),
                     with: .color(Color(hue: params.hue, saturation: params.saturation, brightness: 0.8)))
            if overlay.eyesClosed { drawClosedEyes(ctx: ctx, cx: cx, cy: cy, r: r) }
            else                  { drawEyes(ctx: ctx, cx: cx, cy: cy, r: r) }
        }
        .scaleEffect(overlay.avatarScale)
        .frame(width: size, height: size)
    }

    private func bodyPath(cx: CGFloat, cy: CGFloat, r: CGFloat) -> Path {
        switch params.bodyShape {
        case 1:
            return Path(roundedRect: CGRect(x: cx-r*0.8, y: cy-r*0.8,
                                            width: r*1.6, height: r*1.6), cornerRadius: r*0.3)
        case 2:
            var p = Path()
            p.move(to: CGPoint(x: cx, y: cy-r)); p.addLine(to: CGPoint(x: cx+r, y: cy))
            p.addLine(to: CGPoint(x: cx, y: cy+r)); p.addLine(to: CGPoint(x: cx-r, y: cy))
            p.closeSubpath(); return p
        default:
            return Path(ellipseIn: CGRect(x: cx-r, y: cy-r, width: r*2, height: r*2))
        }
    }

    private func drawEyes(ctx: GraphicsContext, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let ey = cy + CGFloat(overlay.eyeVerticalOffset)*r - r*0.1
        let er = r*0.16, pr = er * CGFloat(params.pupilScale * overlay.pupilScale)
        let pupil = Color(hue: params.accentHue, saturation: 0.9, brightness: 0.2)
        for ex in [cx - r*0.28, cx + r*0.28] {
            ctx.fill(Path(ellipseIn: CGRect(x: ex-er, y: ey-er, width: er*2, height: er*2)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: ex-pr, y: ey-pr, width: pr*2, height: pr*2)), with: .color(pupil))
        }
    }

    private func drawClosedEyes(ctx: GraphicsContext, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let ey = cy - r*0.1
        let lc = Color(hue: params.hue, saturation: 0.6, brightness: 0.4)
        for ex in [cx - r*0.28, cx + r*0.28] {
            var p = Path(); p.move(to: CGPoint(x: ex-r*0.12, y: ey))
            p.addLine(to: CGPoint(x: ex+r*0.12, y: ey))
            ctx.stroke(p, with: .color(lc), lineWidth: r*0.06)
        }
    }
}
