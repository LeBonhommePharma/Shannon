import SwiftUI
import ShannonCore

// MARK: - PetAvatarCanvasWatch
//
// Lightweight procedural pet avatar for watchOS.
// Mirrors iOS PetAvatarCanvas but stripped to the subset that renders
// well at watch-face complication sizes (20–100 pt).
// Shared by ShannonWatch and ShannonComplication via watchOS/Sources/Shared/.

@available(watchOS 10.0, *)
struct PetAvatarCanvasWatch: View {
    let params: PetAvatarShapeParams
    let mood: PetMood
    let size: CGFloat
    private var overlay: PetMoodOverlay { PetMoodOverlay.from(mood: mood) }

    var body: some View {
        Canvas { ctx, sz in
            let cx = sz.width/2, cy = sz.height/2, r = min(cx, cy) * 0.85
            let bodyColor = Color(hue: params.hue, saturation: params.saturation, brightness: 0.8)
            ctx.fill(circleBody(cx: cx, cy: cy, r: r), with: .color(bodyColor))
            if !overlay.eyesClosed {
                drawEyes(ctx: ctx, cx: cx, cy: cy, r: r)
            }
        }
        .scaleEffect(overlay.avatarScale)
        .frame(width: size, height: size)
    }

    private func circleBody(cx: CGFloat, cy: CGFloat, r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx-r, y: cy-r, width: r*2, height: r*2))
    }

    private func drawEyes(ctx: GraphicsContext, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let ey = cy - r * 0.1
        let er = r * 0.16, pr = er * CGFloat(params.pupilScale * overlay.pupilScale)
        let pupil = Color(hue: params.accentHue, saturation: 0.9, brightness: 0.2)
        for ex in [cx - r*0.28, cx + r*0.28] {
            ctx.fill(Path(ellipseIn: CGRect(x: ex-er, y: ey-er, width: er*2, height: er*2)),
                     with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: ex-pr, y: ey-pr, width: pr*2, height: pr*2)),
                     with: .color(pupil))
        }
    }
}
