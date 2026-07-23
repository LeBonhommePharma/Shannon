// PetRenderer.swift — draws a companion pet with SwiftUI Canvas + Path.
//
// No image assets, no UIKit/AppKit drawing. Every character is authored in a
// 32×32 design space with the origin at the top-left, then scaled to whatever
// the view is actually given, so the same paths serve a 32pt card badge and a
// blown-up QA preview.
//
// Aesthetic rules the drawings hold to:
//   • Recognisable from the silhouette alone at 32pt — no interior detail that
//     survives only at 4×.
//   • 2–3 fills per pet plus an ink, budgeted in PetKind.palette.
//   • 1.5pt equivalent outline (scaled with the view).
//   • Eyes carry the expression; the body is secondary and mostly just breathes.

import SwiftUI

// MARK: - View

struct PetRenderer: View {
    let pet: PetKind
    let state: PetAnimationState
    /// The owning agent's brand tint. Used for the ground shadow and the gear's
    /// sparkles, so the pet stays tied to its agent without repainting the
    /// character's own identity.
    let agentColor: Color

    @StateObject private var animator = PetAnimator()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let frame = animator.frame(kind: pet, state: state, now: timeline.date)
                PetArt.draw(pet: pet,
                            frame: frame,
                            palette: pet.palette,
                            agentColor: agentColor,
                            in: &ctx,
                            size: size)
            }
        }
        .frame(width: 32, height: 32)
        .onAppear { animator.update(for: state) }
        .onChange(of: state) { newState in animator.update(for: newState) }
        .accessibilityLabel(Text("\(pet.accessibilityNoun), \(state.rawValue)"))
    }
}

// MARK: - Drawing

enum PetArt {

    /// Design-space edge length. All coordinates below are in these units.
    static let design: CGFloat = 32

    static func draw(pet: PetKind,
                     frame f: PetFrame,
                     palette pal: PetPalette,
                     agentColor: Color,
                     in ctx: inout GraphicsContext,
                     size: CGSize) {

        let s  = min(size.width, size.height) / design
        let lw = 1.5 * s

        // Soft contact shadow, tinted by the agent. Grounds the character and
        // is the only place the raw brand colour appears.
        let shadowW = 15.0 * f.breath
        ctx.fill(Path(ellipseIn: Rct(16 - shadowW / 2, 27.6, shadowW, 2.6, s)),
                 with: .color(agentColor.opacity(0.16)))

        // Body transform: breathe about the feet, bounce, lean forward.
        ctx.translateBy(x: 16 * s, y: 28 * s)
        ctx.scaleBy(x: CGFloat(f.breath), y: CGFloat(f.breath))
        ctx.translateBy(x: 0, y: CGFloat(f.yOffset) * s)
        if f.lean != 0 { ctx.rotate(by: .degrees(f.lean * 5)) }
        ctx.translateBy(x: -16 * s, y: -28 * s)

        switch pet {
        case .owl:     owl(&ctx, s, lw, f, pal)
        case .raven:   raven(&ctx, s, lw, f, pal)
        case .fox:     fox(&ctx, s, lw, f, pal)
        case .dolphin: dolphin(&ctx, s, lw, f, pal)
        case .wolf:    wolf(&ctx, s, lw, f, pal)
        case .beaver:  beaver(&ctx, s, lw, f, pal)
        case .gear:    gear(&ctx, s, lw, f, pal, agentColor)
        }
    }

    // MARK: Owl — ear tufts, huge amber eyes, cream breast

    private static func owl(_ ctx: inout GraphicsContext, _ s: CGFloat, _ lw: CGFloat,
                            _ f: PetFrame, _ pal: PetPalette) {
        let d = f.headDroop

        // Ear tufts, behind the head.
        let tufts = Path { p in
            p.move(to: P(9.0, 11 + d, s));  p.addLine(to: P(6.4, 3.4 + d, s))
            p.addLine(to: P(13.2, 8.0 + d, s)); p.closeSubpath()
            p.move(to: P(23.0, 11 + d, s)); p.addLine(to: P(25.6, 3.4 + d, s))
            p.addLine(to: P(18.8, 8.0 + d, s)); p.closeSubpath()
        }
        ctx.fill(tufts, with: .color(pal.primary))
        ctx.stroke(tufts, with: .color(pal.ink), lineWidth: lw)

        // Body. The owl's head is the top of its body, so only the face and
        // tufts droop — sliding the whole bird down would just walk it out of
        // the 32pt box.
        let body = Path(ellipseIn: Rct(7.0, 8.5, 18.0, 20.0, s))
        ctx.fill(body, with: .color(pal.primary))
        ctx.stroke(body, with: .color(pal.ink), lineWidth: lw)

        // Breast.
        ctx.fill(Path(ellipseIn: Rct(11.0, 16.0, 10.0, 12.0, s)),
                 with: .color(pal.secondary))

        // Feet.
        let feet = Path { p in
            p.move(to: P(12.6, 28.4, s)); p.addLine(to: P(12.6, 30.0, s))
            p.move(to: P(19.4, 28.4, s)); p.addLine(to: P(19.4, 30.0, s))
        }
        ctx.stroke(feet, with: .color(pal.ink), lineWidth: lw)

        eye(&ctx, at: P(12.2, 15.2 + d, s), r: 3.4 * s, open: f.eyeOpen,
            sclera: pal.accent, ink: pal.ink, lw: lw)
        eye(&ctx, at: P(19.8, 15.2 + d, s), r: 3.4 * s, open: f.eyeOpen,
            sclera: pal.accent, ink: pal.ink, lw: lw)

        // Beak, tucked between the eyes.
        let beak = Path { p in
            p.move(to: P(16.0, 17.6 + d, s)); p.addLine(to: P(14.3, 21.4 + d, s))
            p.addLine(to: P(17.7, 21.4 + d, s)); p.closeSubpath()
        }
        ctx.fill(beak, with: .color(pal.ink))
    }

    // MARK: Raven — wedge beak, folded wing, violet sheen

    private static func raven(_ ctx: inout GraphicsContext, _ s: CGFloat, _ lw: CGFloat,
                              _ f: PetFrame, _ pal: PetPalette) {
        let d = f.headDroop

        let body = Path { p in
            p.move(to: P(10.0, 26.5, s))
            p.addCurve(to: P(12.5, 8.0 + d, s),
                       control1: P(6.0, 21.0, s),  control2: P(7.0, 10.5 + d, s))
            p.addCurve(to: P(20.5, 10.0 + d, s),
                       control1: P(16.0, 5.6 + d, s), control2: P(19.5, 6.8 + d, s))
            p.addCurve(to: P(27.5, 27.0, s),
                       control1: P(24.0, 15.0, s), control2: P(27.0, 20.0, s))
            p.addCurve(to: P(10.0, 26.5, s),
                       control1: P(20.0, 24.5, s), control2: P(14.0, 25.0, s))
            p.closeSubpath()
        }
        ctx.fill(body, with: .color(pal.primary))
        ctx.stroke(body, with: .color(pal.ink), lineWidth: lw)

        // Folded wing — the violet sheen, the only lift in an almost-black bird.
        let wing = Path { p in
            p.move(to: P(13.0, 13.5, s))
            p.addCurve(to: P(23.0, 23.5, s),
                       control1: P(20.0, 14.0, s), control2: P(23.0, 18.0, s))
            p.addCurve(to: P(13.0, 13.5, s),
                       control1: P(18.0, 20.0, s), control2: P(14.0, 17.0, s))
            p.closeSubpath()
        }
        ctx.fill(wing, with: .color(pal.secondary))

        // Beak.
        let beak = Path { p in
            p.move(to: P(19.6, 11.2 + d, s)); p.addLine(to: P(29.0, 13.0 + d, s))
            p.addLine(to: P(19.6, 15.0 + d, s)); p.closeSubpath()
        }
        ctx.fill(beak, with: .color(pal.secondary))
        ctx.stroke(beak, with: .color(pal.ink), lineWidth: lw * 0.8)

        // Legs.
        let legs = Path { p in
            p.move(to: P(14.0, 26.0, s)); p.addLine(to: P(13.4, 30.0, s))
            p.move(to: P(19.0, 26.4, s)); p.addLine(to: P(19.6, 30.0, s))
        }
        ctx.stroke(legs, with: .color(pal.ink), lineWidth: lw)

        // Single visible eye — a raven in profile.
        eye(&ctx, at: P(16.6, 12.0 + d, s), r: 2.3 * s, open: f.eyeOpen,
            sclera: pal.accent, ink: pal.ink, lw: lw)
    }

    // MARK: Fox — pointed ears, cream-tipped tail, sharp muzzle

    private static func fox(_ ctx: inout GraphicsContext, _ s: CGFloat, _ lw: CGFloat,
                            _ f: PetFrame, _ pal: PetPalette) {
        let d = f.headDroop

        // Brush tail sweeping up the left side, drawn first so it sits behind
        // the body. It has to stay fat all the way to the tip — a thin crescent
        // collapses into a stray mark at 32pt.
        let tailTip = (x: 5.2, y: 11.0)
        let tail = Path { p in
            p.move(to: P(13.5, 25.0, s))
            p.addCurve(to: P(tailTip.x, tailTip.y, s),
                       control1: P(2.5, 27.5, s), control2: P(0.6, 15.0, s))
            p.addCurve(to: P(13.5, 25.0, s),
                       control1: P(9.5, 12.0, s), control2: P(11.5, 19.5, s))
            p.closeSubpath()
        }
        ctx.fill(tail, with: .color(pal.primary))
        ctx.stroke(tail, with: .color(pal.ink), lineWidth: lw)

        // Cream tip, centred on the tail's own endpoint so it never floats free.
        let tip = Path(ellipseIn: Rct(tailTip.x - 2.8, tailTip.y - 2.6, 5.6, 5.2, s))
        ctx.fill(tip, with: .color(pal.secondary))
        ctx.stroke(tip, with: .color(pal.ink), lineWidth: lw)

        // Body.
        let body = Path(ellipseIn: Rct(9.5, 15.0, 15.0, 14.5, s))
        ctx.fill(body, with: .color(pal.primary))
        ctx.stroke(body, with: .color(pal.ink), lineWidth: lw)

        // Ears.
        let ears = Path { p in
            p.move(to: P(11.2, 9.0 + d, s));  p.addLine(to: P(9.4, 1.6 + d, s))
            p.addLine(to: P(16.0, 6.0 + d, s)); p.closeSubpath()
            p.move(to: P(21.8, 9.0 + d, s)); p.addLine(to: P(23.6, 1.6 + d, s))
            p.addLine(to: P(17.0, 6.0 + d, s)); p.closeSubpath()
        }
        ctx.fill(ears, with: .color(pal.primary))
        ctx.stroke(ears, with: .color(pal.ink), lineWidth: lw)

        // Head.
        let head = Path(ellipseIn: Rct(10.0, 6.0 + d, 13.0, 11.5, s))
        ctx.fill(head, with: .color(pal.primary))
        ctx.stroke(head, with: .color(pal.ink), lineWidth: lw)

        // Muzzle wedge.
        let muzzle = Path { p in
            p.move(to: P(13.0, 13.6 + d, s)); p.addLine(to: P(16.5, 20.2 + d, s))
            p.addLine(to: P(20.0, 13.6 + d, s)); p.closeSubpath()
        }
        ctx.fill(muzzle, with: .color(pal.secondary))

        eye(&ctx, at: P(13.5, 11.4 + d, s), r: 2.2 * s, open: f.eyeOpen,
            sclera: pal.secondary, ink: pal.ink, lw: lw)
        eye(&ctx, at: P(19.5, 11.4 + d, s), r: 2.2 * s, open: f.eyeOpen,
            sclera: pal.secondary, ink: pal.ink, lw: lw)

        ctx.fill(Path(ellipseIn: Rct(15.4, 17.4 + d, 2.2, 2.0, s)), with: .color(pal.ink))
    }

    // MARK: Dolphin — dorsal fin, fluke, permanent smile

    private static func dolphin(_ ctx: inout GraphicsContext, _ s: CGFloat, _ lw: CGFloat,
                                _ f: PetFrame, _ pal: PetPalette) {
        // Fluke — two broad lobes spread roughly horizontally. A single
        // upright lobe is a shark tail, which is most of why this read wrong.
        let fluke = Path { p in
            p.move(to: P(7.0, 20.4, s))
            p.addCurve(to: P(0.6, 15.4, s),
                       control1: P(4.6, 18.6, s), control2: P(2.0, 15.8, s))
            p.addCurve(to: P(5.4, 21.4, s),
                       control1: P(2.6, 18.4, s), control2: P(4.2, 20.4, s))
            p.addCurve(to: P(0.8, 26.4, s),
                       control1: P(4.0, 22.6, s), control2: P(2.2, 24.6, s))
            p.addCurve(to: P(7.6, 22.6, s),
                       control1: P(3.4, 25.2, s), control2: P(5.6, 23.6, s))
            p.closeSubpath()
        }
        ctx.fill(fluke, with: .color(pal.primary))
        ctx.stroke(fluke, with: .color(pal.ink), lineWidth: lw)

        // Dorsal fin — small and swept back toward the tail.
        let fin = Path { p in
            p.move(to: P(13.8, 9.6, s)); p.addLine(to: P(10.6, 4.4, s))
            p.addLine(to: P(17.4, 8.2, s)); p.closeSubpath()
        }
        ctx.fill(fin, with: .color(pal.primary))
        ctx.stroke(fin, with: .color(pal.ink), lineWidth: lw)

        // Body, beak to the right. The melon (the rounded forehead) and the
        // notch where the beak meets the jaw are the two cues that separate a
        // dolphin from a generic fish — without them this reads as a shark.
        let body = Path { p in
            p.move(to: P(4.5, 20.5, s))
            p.addCurve(to: P(17.5, 7.4, s),                       // back → melon
                       control1: P(7.5, 10.5, s),  control2: P(12.0, 7.4, s))
            p.addCurve(to: P(28.8, 12.6, s),                      // melon → beak
                       control1: P(23.0, 7.6, s),  control2: P(26.6, 10.2, s))
            p.addCurve(to: P(28.8, 14.6, s),                      // blunt rostrum tip
                       control1: P(29.8, 13.0, s), control2: P(29.8, 14.2, s))
            p.addCurve(to: P(18.6, 17.2, s),                      // under the beak
                       control1: P(25.0, 15.6, s), control2: P(21.6, 16.4, s))
            p.addCurve(to: P(10.0, 24.5, s),                      // belly
                       control1: P(16.4, 21.4, s), control2: P(13.4, 24.0, s))
            p.addCurve(to: P(4.5, 20.5, s),
                       control1: P(7.5, 24.8, s),  control2: P(5.5, 23.0, s))
            p.closeSubpath()
        }
        ctx.fill(body, with: .color(pal.primary))
        ctx.stroke(body, with: .color(pal.ink), lineWidth: lw)

        // Pale underside.
        let belly = Path { p in
            p.move(to: P(9.0, 22.0, s))
            p.addCurve(to: P(25.0, 13.6, s),
                       control1: P(15.0, 24.6, s), control2: P(21.0, 19.5, s))
            p.addCurve(to: P(9.0, 22.0, s),
                       control1: P(20.0, 19.0, s), control2: P(14.0, 22.2, s))
            p.closeSubpath()
        }
        ctx.fill(belly, with: .color(pal.secondary))

        // The smile — a dolphin is mostly its mouth line.
        let smile = Path { p in
            p.move(to: P(19.4, 16.2, s))
            p.addQuadCurve(to: P(28.8, 13.4, s), control: P(24.6, 16.8, s))
        }
        ctx.stroke(smile, with: .color(pal.ink), lineWidth: lw * 0.9)

        eye(&ctx, at: P(20.4, 12.4, s), r: 1.9 * s, open: f.eyeOpen,
            sclera: pal.accent, ink: pal.ink, lw: lw)
    }

    // MARK: Wolf — cool grey-blue, long muzzle, amber almond eyes

    private static func wolf(_ ctx: inout GraphicsContext, _ s: CGFloat, _ lw: CGFloat,
                             _ f: PetFrame, _ pal: PetPalette) {
        let d = f.headDroop

        // Upright, not swept back: ears whose inner vertex reaches the midline
        // cross over each other and read as an X rather than as a pair.
        let leftEar:  [(Double, Double)] = [(8.2, 11.6 + d), (6.4, 2.0 + d), (13.6, 8.8 + d)]
        let rightEar: [(Double, Double)] = [(23.8, 11.6 + d), (25.6, 2.0 + d), (18.4, 8.8 + d)]

        let ears = Path { p in
            for tri in [leftEar, rightEar] { addTriangle(&p, tri, s) }
        }
        ctx.fill(ears, with: .color(pal.primary))
        ctx.stroke(ears, with: .color(pal.ink), lineWidth: lw)

        // Inner ears, derived by shrinking each ear toward its own centroid so
        // they cannot drift outside the shape they belong to.
        ctx.fill(Path { p in
            for tri in [leftEar, rightEar] { addTriangle(&p, shrink(tri, by: 0.45), s) }
        }, with: .color(pal.secondary))

        // Head — a broad shield tapering to the muzzle.
        let head = Path { p in
            p.move(to: P(7.8, 10.0 + d, s))
            p.addLine(to: P(24.2, 10.0 + d, s))
            p.addCurve(to: P(16.0, 27.0 + d, s),
                       control1: P(25.6, 18.0 + d, s), control2: P(22.0, 21.5 + d, s))
            p.addCurve(to: P(7.8, 10.0 + d, s),
                       control1: P(10.0, 21.5 + d, s), control2: P(6.4, 18.0 + d, s))
            p.closeSubpath()
        }
        ctx.fill(head, with: .color(pal.primary))
        ctx.stroke(head, with: .color(pal.ink), lineWidth: lw)

        // Muzzle.
        ctx.fill(Path(ellipseIn: Rct(11.6, 17.0 + d, 8.8, 8.6, s)),
                 with: .color(pal.secondary))

        // Nose + mouth.
        ctx.fill(Path { p in
            p.move(to: P(16.0, 21.4 + d, s)); p.addLine(to: P(13.9, 18.2 + d, s))
            p.addLine(to: P(18.1, 18.2 + d, s)); p.closeSubpath()
        }, with: .color(pal.ink))
        ctx.stroke(Path { p in
            p.move(to: P(16.0, 21.4 + d, s)); p.addLine(to: P(16.0, 23.6 + d, s))
        }, with: .color(pal.ink), lineWidth: lw * 0.8)

        eye(&ctx, at: P(12.3, 13.4 + d, s), r: 2.3 * s, open: f.eyeOpen,
            sclera: pal.accent, ink: pal.ink, lw: lw, almond: true)
        eye(&ctx, at: P(19.7, 13.4 + d, s), r: 2.3 * s, open: f.eyeOpen,
            sclera: pal.accent, ink: pal.ink, lw: lw, almond: true)
    }

    // MARK: Beaver — buck teeth, cross-hatched paddle tail

    private static func beaver(_ ctx: inout GraphicsContext, _ s: CGFloat, _ lw: CGFloat,
                               _ f: PetFrame, _ pal: PetPalette) {
        let d = f.headDroop

        // Paddle tail, behind and to the left.
        let tail = Path { p in
            p.move(to: P(11.0, 21.0, s))
            p.addCurve(to: P(2.2, 25.4, s),
                       control1: P(7.0, 19.4, s), control2: P(2.2, 20.6, s))
            p.addCurve(to: P(11.5, 26.6, s),
                       control1: P(2.2, 29.4, s), control2: P(7.5, 29.2, s))
            p.closeSubpath()
        }
        // A darker brown, not ink-over-brown: translucent ink desaturates to
        // grey here, and the palette has no grey in it.
        ctx.fill(tail, with: .color(Color(hex: 0x5E3A17)))
        ctx.stroke(tail, with: .color(pal.ink), lineWidth: lw)
        ctx.stroke(Path { p in
            p.move(to: P(4.4, 22.4, s)); p.addLine(to: P(5.8, 28.2, s))
            p.move(to: P(7.8, 21.2, s)); p.addLine(to: P(8.8, 27.8, s))
        }, with: .color(pal.secondary.opacity(0.45)), lineWidth: lw * 0.6)

        // Body.
        let body = Path(ellipseIn: Rct(8.5, 13.0, 16.0, 16.5, s))
        ctx.fill(body, with: .color(pal.primary))
        ctx.stroke(body, with: .color(pal.ink), lineWidth: lw)

        // The plank it is forever working on — Cowork's green.
        let plank = Path(roundedRect: Rct(17.5, 22.5, 9.5, 3.6, s),
                         cornerSize: CGSize(width: 1.2 * s, height: 1.2 * s))
        ctx.fill(plank, with: .color(pal.accent))
        ctx.stroke(plank, with: .color(pal.ink), lineWidth: lw * 0.7)

        // Ears.
        for x in [11.8, 21.2] {
            let ear = Path(ellipseIn: Rct(x - 1.7, 5.4 + d, 3.4, 3.4, s))
            ctx.fill(ear, with: .color(pal.primary))
            ctx.stroke(ear, with: .color(pal.ink), lineWidth: lw * 0.8)
        }

        // Head.
        let head = Path(ellipseIn: Rct(10.2, 5.0 + d, 12.6, 11.6, s))
        ctx.fill(head, with: .color(pal.primary))
        ctx.stroke(head, with: .color(pal.ink), lineWidth: lw)

        // Snout.
        ctx.fill(Path(ellipseIn: Rct(12.9, 11.0 + d, 7.4, 5.6, s)),
                 with: .color(pal.secondary))
        ctx.fill(Path(ellipseIn: Rct(15.2, 11.6 + d, 2.8, 2.2, s)),
                 with: .color(pal.ink))

        // Buck teeth — the whole character in two rectangles.
        let teeth = Path { p in
            p.addRoundedRect(in: Rct(14.6, 15.4 + d, 2.2, 4.6, s),
                             cornerSize: CGSize(width: 0.5 * s, height: 0.5 * s))
            p.addRoundedRect(in: Rct(17.2, 15.4 + d, 2.2, 4.6, s),
                             cornerSize: CGSize(width: 0.5 * s, height: 0.5 * s))
        }
        ctx.fill(teeth, with: .color(pal.secondary))
        ctx.stroke(teeth, with: .color(pal.ink), lineWidth: lw * 0.7)

        eye(&ctx, at: P(13.6, 9.4 + d, s), r: 1.9 * s, open: f.eyeOpen,
            sclera: pal.secondary, ink: pal.ink, lw: lw)
        eye(&ctx, at: P(19.4, 9.4 + d, s), r: 1.9 * s, open: f.eyeOpen,
            sclera: pal.secondary, ink: pal.ink, lw: lw)
    }

    // MARK: Gear — the literal ⚙️, but it turns

    private static func gear(_ ctx: inout GraphicsContext, _ s: CGFloat, _ lw: CGFloat,
                             _ f: PetFrame, _ pal: PetPalette, _ agentColor: Color) {
        // Sparkles are pinned to the card, not to the spinning gear.
        if f.sparkle > 0.01 {
            let burst = Path { p in
                for i in 0 ..< 5 {
                    let a = Double(i) / 5 * 2 * .pi - .pi / 2
                    let cx = 16 + cos(a) * 14.2, cy = 16 + sin(a) * 14.2
                    let r  = 2.8 * f.sparkle
                    p.move(to: P(cx, cy - r, s));      p.addLine(to: P(cx + r * 0.32, cy - r * 0.32, s))
                    p.addLine(to: P(cx + r, cy, s));   p.addLine(to: P(cx + r * 0.32, cy + r * 0.32, s))
                    p.addLine(to: P(cx, cy + r, s));   p.addLine(to: P(cx - r * 0.32, cy + r * 0.32, s))
                    p.addLine(to: P(cx - r, cy, s));   p.addLine(to: P(cx - r * 0.32, cy - r * 0.32, s))
                    p.closeSubpath()
                }
            }
            ctx.fill(burst, with: .color(pal.accent.opacity(0.55 + 0.45 * f.sparkle)))
        }

        ctx.translateBy(x: 16 * s, y: 16 * s)
        ctx.rotate(by: .radians(f.spin))

        // Eight teeth, plus a punched-out hub via the even-odd rule so the card
        // shows through rather than a fake background fill.
        let rOuter = 13.6, rInner = 9.4, step = 2 * Double.pi / 8
        let teeth = Path { p in
            for i in 0 ..< 8 {
                let a = Double(i) * step
                let pts = [(rInner, a - step * 0.26), (rOuter, a - step * 0.145),
                           (rOuter, a + step * 0.145), (rInner, a + step * 0.26)]
                for (idx, pt) in pts.enumerated() {
                    let q = P(cos(pt.1) * pt.0, sin(pt.1) * pt.0, s)
                    if i == 0 && idx == 0 { p.move(to: q) } else { p.addLine(to: q) }
                }
            }
            p.closeSubpath()
            p.addEllipse(in: Rct(-4.2, -4.2, 8.4, 8.4, s))
        }
        ctx.fill(teeth, with: .color(pal.primary), style: FillStyle(eoFill: true))
        ctx.stroke(teeth, with: .color(pal.ink), lineWidth: lw)

        // Hub ring, and three spokes so the rotation is actually legible.
        ctx.stroke(Path(ellipseIn: Rct(-7.4, -7.4, 14.8, 14.8, s)),
                   with: .color(pal.secondary), lineWidth: lw * 1.1)
        let spokes = Path { p in
            for i in 0 ..< 3 {
                let a = Double(i) / 3 * 2 * .pi
                p.move(to: P(cos(a) * 4.4, sin(a) * 4.4, s))
                p.addLine(to: P(cos(a) * 8.6, sin(a) * 8.6, s))
            }
        }
        ctx.stroke(spokes, with: .color(pal.secondary), lineWidth: lw * 0.9)

        // A single amber tooth marker, tinted by the agent — makes 1 rpm
        // perceptible, which a rotationally symmetric gear otherwise is not.
        ctx.fill(Path(ellipseIn: Rct(-1.6, -12.8, 3.2, 3.2, s)),
                 with: .color(agentColor.opacity(0.9)))
    }

    // MARK: Eyes

    /// The expressive element. `open` is the lid aperture: 0 shut, 1 resting,
    /// up to ~1.3 in alert.
    private static func eye(_ ctx: inout GraphicsContext,
                            at c: CGPoint,
                            r: CGFloat,
                            open: Double,
                            sclera: Color,
                            ink: Color,
                            lw: CGFloat,
                            almond: Bool = false) {
        let o     = max(0, open)
        let grow  = o > 1 ? 1 + 0.12 * (o - 1) : 1
        let rx    = r * CGFloat(grow) * (almond ? 1.25 : 1)
        let ry    = r * CGFloat(grow) * CGFloat(min(o, 1)) * (almond ? 0.80 : 1)

        // Drowsy or shut. A squashed ellipse plus a lid line collapses into a
        // dark bar at this size; a single downward arc reads unmistakably as a
        // contented closed eye instead.
        guard o > 0.35 else {
            // Kept narrower than the open eye: two full-width arcs side by side
            // merge into something that reads as a moustache, not eyelids.
            let ax = rx * 0.86
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: c.x - ax, y: c.y - r * 0.34))
                p.addQuadCurve(to: CGPoint(x: c.x + ax, y: c.y - r * 0.34),
                               control: CGPoint(x: c.x, y: c.y + r * 0.52))
            }, with: .color(ink), lineWidth: lw * 1.15)
            return
        }

        ctx.fill(Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry,
                                        width: rx * 2, height: ry * 2)),
                 with: .color(sclera))

        let px = rx * 0.55, py = min(ry, rx * 0.55)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - px, y: c.y - py,
                                        width: px * 2, height: py * 2)),
                 with: .color(ink))

        // Catchlight — cheap, and it is what makes the pet look awake.
        let hr = rx * 0.19
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - rx * 0.34 - hr, y: c.y - ry * 0.42 - hr,
                                        width: hr * 2, height: hr * 2)),
                 with: .color(.white.opacity(0.92)))

    }

    // MARK: Design-space helpers

    /// Appends a closed triangle in design space.
    private static func addTriangle(_ p: inout Path, _ t: [(Double, Double)], _ s: CGFloat) {
        guard t.count == 3 else { return }
        p.move(to: P(t[0].0, t[0].1, s))
        p.addLine(to: P(t[1].0, t[1].1, s))
        p.addLine(to: P(t[2].0, t[2].1, s))
        p.closeSubpath()
    }

    /// Pulls every vertex `f` of the way toward the centroid. Used for inner
    /// ears, which must stay strictly inside the outer ear at any size.
    private static func shrink(_ t: [(Double, Double)], by f: Double) -> [(Double, Double)] {
        let cx = t.reduce(0) { $0 + $1.0 } / Double(t.count)
        let cy = t.reduce(0) { $0 + $1.1 } / Double(t.count)
        return t.map { (($0.0 + (cx - $0.0) * f), ($0.1 + (cy - $0.1) * f)) }
    }

    /// Design-space point → view point.
    private static func P(_ x: Double, _ y: Double, _ s: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(x) * s, y: CGFloat(y) * s)
    }

    /// Design-space rect → view rect.
    private static func Rct(_ x: Double, _ y: Double,
                            _ w: Double, _ h: Double, _ s: CGFloat) -> CGRect {
        CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s,
               width: CGFloat(w) * s, height: CGFloat(h) * s)
    }
}
