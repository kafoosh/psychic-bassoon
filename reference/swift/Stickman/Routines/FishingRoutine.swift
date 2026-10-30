import SwiftUI

// Fishing: drop → wave → walk to the roomier side → take out a rod (line dangling) →
// cast the line out to the OPEN side of the screen → bite & reel struggle → pull the
// card in from the side on the hook.
struct FishingRoutine: AnimationRoutine {
    let rig: Rig
    let dropDistance: CGFloat
    let walkDX: CGFloat
    let sideSign: CGFloat       // cast toward this (open) side
    let propScale: CGFloat
    let screenSize: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(_ s: RoutineSetup) {
        rig = s.rig; dropDistance = s.dropDistance; walkDX = s.walkDX
        sideSign = s.sideSign; propScale = s.propScale; screenSize = s.screenSize
        topInset = s.topInset; bottomInset = s.bottomInset
    }

    let totalDuration: Double = 12.6
    private var skel: Skeleton { rig.skeleton }
    private var ink: Color { rig.inkColor }
    private var lw: CGFloat { max(rig.inkWidth * 0.9, 3) }
    private var castLeft: Bool { sideSign < 0 }

    // Action beats (after the shared approach at 4.7).
    private let tRod = 4.7, tCast = 5.8, tWait = 6.7, tBite = 7.6, tReel = 8.1, tPull = 9.9, tPresent = 11.4

    func pose(at t: Double) -> FigurePose {
        if let ap = Approach.pose(t, skel: skel, ground: dropDistance, walkDX: walkDX) { return ap }
        var p = FigurePose.rest(skel)
        p.offset = CGPoint(x: walkDX, y: dropDistance)

        func arm(_ upper: CGFloat, _ fore: CGFloat) {
            if castLeft { p.leftArmAngle = upper; p.leftForearmAngle = fore }
            else { p.rightArmAngle = -upper; p.rightForearmAngle = -fore }
        }
        let toward: CGFloat = castLeft ? -1 : 1

        if t < tCast {                                  // take out the rod, hold it up-out
            let r = smooth(phase(t, tRod, tCast))
            arm(1.15 * r, -0.25 * r); p.headAngle = 0.12 * toward * r
        } else if t < tWait {                           // cast — flick out toward the side
            let r = easeOut(phase(t, tCast, tCast + 0.45))
            arm(lerp(1.15, 1.5, r), lerp(-0.25, -0.05, r))
            p.rootAngle = toward * 0.10 * CGFloat(sin(phase(t, tCast, tWait) * .pi))
            p.headAngle = 0.2 * toward
        } else if t < tBite {                           // watch the line
            arm(1.4 + 0.03 * CGFloat(sin(2 * .pi * (t - tWait) / 0.8)), -0.1)
            p.headAngle = 0.18 * toward
        } else if t < tReel {                           // bite — yanked toward the side
            let r = easeOut(phase(t, tBite, tBite + 0.2))
            arm(lerp(1.4, 1.2, r), lerp(-0.1, 0.2, r))
            p.rootAngle = toward * lerp(0, 0.22, r); p.headAngle = 0.1 * toward
        } else if t < tPull {                           // reel — lean BACK and tug
            let lean = easeOut(phase(t, tReel, tReel + 0.5))
            let tug = CGFloat(sin(2 * .pi * (t - tReel - 0.5) / 0.5))
            p.rootAngle = -toward * lerp(0.22, 0.30, lean) + toward * 0.06 * tug
            arm(1.45 + 0.30 * CGFloat(sin(2 * .pi * (t - tReel) / 0.5)),
                0.1 + 0.45 * CGFloat(sin(2 * .pi * (t - tReel) / 0.5 + .pi)))
            p.headAngle = 0.05 * toward + 0.06 * tug
            p.leftLegAngle = 0.12 * toward; p.rightLegAngle = -0.12 * toward
        } else if t < tPresent {                        // pull the card in
            let r = easeOut(phase(t, tPull, tPull + 0.9))
            p.rootAngle = -toward * lerp(0.30, 0.05, r)
            arm(lerp(1.45, 1.25, r), lerp(0.1, 0.15, r))
            p.headAngle = lerp(0.05 * toward, 0.08 * toward, r)
        } else {                                        // present & hold
            arm(1.2 + 0.02 * CGFloat(sin(2 * .pi * (t - tPresent))), 0.15)
            p.headAngle = 0.08 * toward
        }
        return p
    }

    func drawProps(_ ctx: GraphicsContext, at t: Double, pose: FigurePose, originOffset off: CGPoint,
                   payload: RevealPayload?, style: RevealStyle, glyphs: GlyphStore?, paper: Color) {
        guard t >= tRod else { return }
        let hand = worldHand(rig, left: castLeft, pose, off)
        let shoulder = castLeft ? worldJoint(rig, skel.leftShoulder, .torso, pose, off)
                                : worldJoint(rig, skel.rightShoulder, .torso, pose, off)
        var dir = CGVector(dx: hand.x - shoulder.x, dy: hand.y - shoulder.y)
        let m = max(hypot(dir.dx, dir.dy), 1); dir.dx /= m; dir.dy /= m
        let rodTip = CGPoint(x: hand.x + dir.dx * propScale * 0.34, y: hand.y + dir.dy * propScale * 0.34)
        SketchInk.sketch(ctx, [hand, rodTip], ink: ink, lw: lw * 1.2, closed: false, amp: lw * 0.2, seed: 30)

        let edgeX = sideSign < 0 ? -propScale * 0.12 : screenSize.width + propScale * 0.12
        let castY = rodTip.y + propScale * 0.06

        if t < tCast {                                  // line dangles from the rod tip
            let d = propScale * 0.22 * easeOut(phase(t, tRod, tCast))
            SketchInk.sketch(ctx, [rodTip, CGPoint(x: rodTip.x + 2, y: rodTip.y + d)],
                             ink: ink, lw: lw, closed: false, amp: 1.4, seed: 33)
            drawHook(ctx, at: CGPoint(x: rodTip.x + 2, y: rodTip.y + d))
        } else if t < tPull {                           // line out to the side edge
            let castP = easeOut(phase(t, tCast, tCast + 0.55))
            var hook = CGPoint(x: lerp(rodTip.x, edgeX, castP), y: lerp(rodTip.y + propScale * 0.22, castY, castP))
            var amp: CGFloat = 1.6
            if t >= tBite && t < tReel {
                let jerk = CGFloat(exp(-10 * (t - tBite - 0.02)) * sin(2 * .pi * (t - tBite) / 0.12))
                hook.x -= sideSign * propScale * 0.05 * jerk; amp = 2.6
            } else if t >= tReel {
                hook.x -= sideSign * propScale * 0.03 * CGFloat(sin(2 * .pi * (t - tReel) / 0.5)); amp = 2.2
            } else if t < tWait { amp = 2.4 }
            let sag = CGPoint(x: (rodTip.x + hook.x) / 2, y: max(rodTip.y, castY) + propScale * 0.05)
            SketchInk.sketch(ctx, [rodTip, sag, hook], ink: ink, lw: lw, closed: false, amp: amp, seed: 33)
        } else {                                        // pull the card in from the side
            let pullP = easeOut(phase(t, tPull, tPull + 1.0))
            let target = CGPoint(x: rodTip.x + sideSign * propScale * 0.10, y: rodTip.y + propScale * 0.30)
            let hook = CGPoint(x: lerp(edgeX, target.x, pullP), y: lerp(castY, target.y, pullP))
            SketchInk.sketch(ctx, [rodTip, hook], ink: ink, lw: lw, closed: false,
                             amp: lerp(1.8, 1.2, pullP), seed: 33)
            drawHook(ctx, at: hook)
            let cardW = propScale * 0.32, cardH = cardW * 1.4
            let center = fitOnScreen(CGPoint(x: hook.x, y: hook.y + cardH * 0.55),
                                     halfW: cardW / 2, halfH: cardH / 2, in: screenSize,
                                     topMargin: topInset, bottomMargin: bottomInset)
            let sway = CGFloat(0.16 * cos(2 * .pi * (t - tPull) / 0.5)) * (1 - pullP)
                     + CGFloat(0.05 * cos(2 * .pi * (t - tPull) / 0.9)) * pullP
            let op = CGFloat(easeOut(min(phase(t, tPull, tPull + 0.2), 1)))
            drawSwaying(ctx, center: center, w: cardW, h: cardH, angle: sway, opacity: op,
                        paper: paper, payload: payload, style: style, glyphs: glyphs)
            if t >= tPresent && t < tPresent + 0.5 {
                SketchInk.sparkles(ctx, around: center, spread: propScale * 0.5,
                                   intensity: 0.5 * CGFloat(sin(phase(t, tPresent, tPresent + 0.5) * .pi)),
                                   ink: ink, lw: lw)
            }
        }
    }

    private func drawHook(_ ctx: GraphicsContext, at p: CGPoint) {
        let s = propScale / 200
        let pts = [p, CGPoint(x: p.x, y: p.y + 18 * s), CGPoint(x: p.x + 8 * s, y: p.y + 24 * s),
                   CGPoint(x: p.x + 2 * s, y: p.y + 30 * s)]
        SketchInk.sketch(ctx, pts, ink: ink, lw: lw, closed: false, amp: 1.2, seed: 34)
    }

    private func drawSwaying(_ ctx: GraphicsContext, center: CGPoint, w: CGFloat, h: CGFloat, angle: CGFloat,
                             opacity: CGFloat, paper: Color, payload: RevealPayload?, style: RevealStyle, glyphs: GlyphStore?) {
        var c = ctx
        c.translateBy(x: center.x, y: center.y)
        c.rotate(by: .radians(Double(angle)))
        c.translateBy(x: -center.x, y: -center.y)
        let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        SketchInk.cardFace(c, rect: rect, opacity: opacity, ink: ink, lw: lw, paper: paper,
                           payload: payload, style: style, glyphs: glyphs)
    }
}
