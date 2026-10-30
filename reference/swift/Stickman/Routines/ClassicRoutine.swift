import SwiftUI

// The Classic: drop in → wave → walk to the roomier side → pull & flick a wand → a
// closed box floats in from the OPEN side → it opens → the paper rises out → it flips
// over to reveal the secret.
struct ClassicRoutine: AnimationRoutine {
    let rig: Rig
    let dropDistance: CGFloat
    let walkDX: CGFloat
    let sideSign: CGFloat      // box side (the open side, opposite the walk)
    let propScale: CGFloat
    let screenSize: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(_ s: RoutineSetup) {
        rig = s.rig; dropDistance = s.dropDistance; walkDX = s.walkDX
        sideSign = s.sideSign; propScale = s.propScale; screenSize = s.screenSize
        topInset = s.topInset; bottomInset = s.bottomInset
    }

    let totalDuration: Double = 12.0
    private var skel: Skeleton { rig.skeleton }
    private var ink: Color { rig.inkColor }
    private var lw: CGFloat { max(rig.inkWidth * 0.9, 3) }
    private var boxLeft: Bool { sideSign < 0 }

    // Action beats (after the shared approach).
    private let tWand = 4.7, tFlick = 5.7, tBox = 6.5, tOpen = 8.1, tRise = 9.1, tFlip = 10.2

    func pose(at t: Double) -> FigurePose {
        if let ap = Approach.pose(t, skel: skel, ground: dropDistance, walkDX: walkDX) { return ap }
        var p = FigurePose.rest(skel)
        p.offset = CGPoint(x: walkDX, y: dropDistance)

        let raise = easeOut(phase(t, tWand, tFlick))
        let flick = CGFloat(sin(.pi * phase(t, tFlick, tBox))) * 0.30
        let idle = t > tBox ? CGFloat(0.04 * sin((t - tBox) * 2)) : 0
        let mag = 1.6 * raise + flick + idle
        let fore = 0.25 * raise
        if boxLeft {
            p.leftArmAngle = mag; p.leftForearmAngle = fore; p.headAngle = 0.14 * raise
        } else {
            p.rightArmAngle = -mag; p.rightForearmAngle = -fore; p.headAngle = -0.14 * raise
        }
        return p
    }

    func drawProps(_ ctx: GraphicsContext, at t: Double, pose: FigurePose, originOffset off: CGPoint,
                   payload: RevealPayload?, style: RevealStyle, glyphs: GlyphStore?, paper: Color) {
        guard t >= tWand else { return }
        let hand = worldHand(rig, left: boxLeft, pose, off)
        let shoulder = boxLeft ? worldJoint(rig, skel.leftShoulder, .torso, pose, off)
                               : worldJoint(rig, skel.rightShoulder, .torso, pose, off)
        let feet = worldJoint(rig, skel.feet, .torso, pose, off)

        let wandOp = easeOut(phase(t, tWand, tWand + 0.3))
        SketchInk.wand(ctx, hand: hand, shoulder: shoulder, length: propScale * 0.30,
                       swing: 0, opacity: wandOp, ink: ink, lw: lw * 1.1)
        if t >= tFlick && t < tBox {
            let g = CGFloat(sin(.pi * phase(t, tFlick, tBox)))
            let dir = CGVector(dx: hand.x - shoulder.x, dy: hand.y - shoulder.y)
            let m = max(hypot(dir.dx, dir.dy), 1)
            let tip = CGPoint(x: hand.x + dir.dx / m * propScale * 0.30, y: hand.y + dir.dy / m * propScale * 0.30)
            SketchInk.sparkles(ctx, around: tip, spread: propScale * 0.12, intensity: g, ink: ink, lw: lw)
        }

        guard t >= tBox else { return }

        let boxW = propScale * 0.42, boxH = propScale * 0.34
        let targetX = feet.x + sideSign * propScale * 0.55
        let targetY = feet.y - propScale * 0.28
        let p1 = phase(t, tBox, tOpen)
        let startX = sideSign > 0 ? screenSize.width + boxW : -boxW
        let boxCX = lerp(startX, targetX, easeOut(p1))
        let boxCY = targetY + CGFloat(sin(p1 * .pi)) * (-propScale * 0.05)
        let boxOp = CGFloat(easeOut(min(p1 / 0.4, 1)))
        let boxRect = CGRect(x: boxCX - boxW / 2, y: boxCY - boxH / 2, width: boxW, height: boxH)
        let lidOpen = easeOut(phase(t, tOpen, tRise))

        drawLid(ctx, box: boxRect, open: lidOpen, opacity: boxOp)

        if t >= tRise {
            let mouthY = boxRect.minY
            let riseP = easeOut(phase(t, tRise, tFlip))
            let cardW = propScale * 0.30, cardH = propScale * 0.42
            let cardCenter = fitOnScreen(CGPoint(x: boxRect.midX, y: mouthY - CGFloat(riseP) * propScale * 0.46),
                                         halfW: cardW / 2, halfH: cardH / 2, in: screenSize,
                                         topMargin: topInset, bottomMargin: bottomInset)
            let cardCX = cardCenter.x
            let cardCY = cardCenter.y
            if t < tFlip {
                let sy = lerp(0.2, 1, CGFloat(easeOut(phase(t, tRise, tRise + 0.25))))
                let rect = CGRect(x: cardCX - cardW / 2, y: cardCY - cardH * sy / 2, width: cardW, height: cardH * sy)
                drawBlankCard(ctx, rect, opacity: 1, paper: paper)
            } else {
                let p2 = phase(t, tFlip, tFlip + 1.2)
                let wf = max(CGFloat(abs(cos(p2 * .pi))), 0.02)
                let rect = CGRect(x: cardCX - cardW * wf / 2, y: cardCY - cardH / 2, width: cardW * wf, height: cardH)
                if p2 < 0.5 {
                    drawBlankCard(ctx, rect, opacity: 1, paper: paper)
                } else {
                    SketchInk.cardFace(ctx, rect: rect, opacity: 1, ink: ink, lw: lw, paper: paper,
                                       payload: payload, style: style, glyphs: glyphs)
                    if p2 < 0.7 {
                        SketchInk.sparkles(ctx, around: CGPoint(x: cardCX, y: cardCY),
                                           spread: propScale * 0.22, intensity: CGFloat(sin(.pi * (p2 - 0.5) / 0.2)),
                                           ink: ink, lw: lw)
                    }
                }
            }
        }

        drawBoxBody(ctx, box: boxRect, opacity: boxOp)
    }

    // MARK: Box / card drawing

    private func drawBoxBody(_ ctx: GraphicsContext, box: CGRect, opacity: CGFloat) {
        SketchInk.sketch(ctx, SketchInk.rectPts(box), ink: ink, lw: lw, closed: true,
                         amp: box.height * 0.05, seed: 3.1, opacity: opacity)
        SketchInk.sketch(ctx, [CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.midX, y: box.maxY)],
                         ink: ink, lw: lw * 0.8, closed: false, amp: box.height * 0.04, seed: 5.7, opacity: opacity)
    }

    private func drawLid(_ ctx: GraphicsContext, box: CGRect, open: CGFloat, opacity: CGFloat) {
        let lidH = box.height * 0.30
        let lift = box.height * (0.10 + open * 0.95)
        let w = box.width * 1.06
        let bottomY = box.minY - lift
        let pts = [CGPoint(x: box.midX - w / 2, y: bottomY), CGPoint(x: box.midX + w / 2, y: bottomY),
                   CGPoint(x: box.midX + w / 2, y: bottomY - lidH), CGPoint(x: box.midX - w / 2, y: bottomY - lidH)]
        var dense: [CGPoint] = []
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4]
            for k in 0..<3 { let f = CGFloat(k) / 3; dense.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)) }
        }
        SketchInk.sketch(ctx, dense, ink: ink, lw: lw, closed: true, amp: box.height * 0.05, seed: 7.3, opacity: opacity)
    }

    private func drawBlankCard(_ ctx: GraphicsContext, _ rect: CGRect, opacity: CGFloat, paper: Color) {
        guard rect.width > 1 else { return }
        var c = ctx
        c.opacity = opacity
        c.fill(Path(roundedRect: rect, cornerRadius: rect.width * 0.08), with: .color(paper))
        SketchInk.sketch(ctx, SketchInk.rectPts(rect, perEdge: 4), ink: ink, lw: lw, closed: true,
                         amp: rect.width * 0.03, seed: 2.2, opacity: opacity)
        let inset = rect.insetBy(dx: rect.width * 0.22, dy: rect.height * 0.3)
        SketchInk.sketch(ctx, [CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.minY)],
                         ink: ink, lw: lw * 0.7, closed: false, amp: rect.width * 0.02, seed: 12.5, opacity: opacity * 0.7)
        SketchInk.sketch(ctx, [CGPoint(x: inset.minX, y: inset.maxY), CGPoint(x: inset.maxX, y: inset.maxY)],
                         ink: ink, lw: lw * 0.7, closed: false, amp: rect.width * 0.02, seed: 13.1, opacity: opacity * 0.7)
    }
}
