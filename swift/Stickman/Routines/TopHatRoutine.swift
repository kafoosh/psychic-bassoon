import SwiftUI

// Top Hat: drop → wave → walk to the roomier side → a hat falls from the sky onto his
// head → he lifts it off to the OPEN side, reaches the other hand in, rummages, and
// pulls the card out. No box.
struct TopHatRoutine: AnimationRoutine {
    let rig: Rig
    let dropDistance: CGFloat
    let walkDX: CGFloat
    let sideSign: CGFloat       // hat held / card pulled toward this (open) side
    let propScale: CGFloat
    let screenSize: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(_ s: RoutineSetup) {
        rig = s.rig; dropDistance = s.dropDistance; walkDX = s.walkDX
        sideSign = s.sideSign; propScale = s.propScale; screenSize = s.screenSize
        topInset = s.topInset; bottomInset = s.bottomInset
    }

    let totalDuration: Double = 12.8
    private var skel: Skeleton { rig.skeleton }
    private var ink: Color { rig.inkColor }
    private var lw: CGFloat { max(rig.inkWidth * 0.9, 3) }
    private var holdLeft: Bool { sideSign < 0 }      // holding hand = open side

    private let tFall = 4.7, tImpact = 5.8, tGrab = 6.1, tLift = 7.1, tReachIn = 8.1,
                tRummage = 9.3, tPull = 10.5, tPresent = 11.8

    func pose(at t: Double) -> FigurePose {
        if let ap = Approach.pose(t, skel: skel, ground: dropDistance, walkDX: walkDX) { return ap }
        var p = FigurePose.rest(skel)
        p.offset = CGPoint(x: walkDX, y: dropDistance)
        let toward: CGFloat = sideSign

        if t < tImpact {                                // wait, look up at the falling hat
            p.headAngle = -0.10 * easeOut(phase(t, tFall + 0.6, tImpact))
        } else if t < tGrab {                           // hat impact squash
            let s = sin(phase(t, tImpact, tGrab) * .pi)
            p.scaleY = 1 - 0.08 * CGFloat(s); p.scaleX = 1 + 0.06 * CGFloat(s)
            p.headAngle = -0.10 * (1 - CGFloat(phase(t, tImpact, tGrab)))
        } else if t < tLift {                           // reach up, grab the hat
            let r = smooth(phase(t, tGrab, tLift - 0.1))
            p.leftArmAngle = 2.05 * r; p.rightArmAngle = -2.05 * r
            p.leftForearmAngle = -0.5 * r; p.rightForearmAngle = 0.5 * r
            p.headAngle = 0.05 * r
        } else if t < tReachIn {                        // lift off, carry to the open side
            let r = smooth(phase(t, tLift, tReachIn - 0.1))
            if holdLeft {
                p.leftArmAngle = lerp(2.05, 1.25, r); p.leftForearmAngle = lerp(-0.5, -0.15, r)
                p.rightArmAngle = lerp(-2.05, -0.15, r); p.rightForearmAngle = lerp(0.5, 0, r)
            } else {
                p.rightArmAngle = lerp(-2.05, -1.25, r); p.rightForearmAngle = lerp(0.5, 0.15, r)
                p.leftArmAngle = lerp(2.05, 0.15, r); p.leftForearmAngle = lerp(-0.5, 0, r)
            }
            p.headAngle = -0.06 * toward * r
        } else if t < tRummage {                        // reach the free hand into the hat
            let r = smooth(phase(t, tReachIn, tRummage - 0.1))
            holdArm(&p, upper: 1.25, fore: -0.15)
            reachArm(&p, upper: lerp(0.15, 1.6, r), fore: lerp(0, 1.5, r))
            p.rootAngle = 0.06 * toward * r; p.headAngle = lerp(-0.06 * toward, -0.14, r)
        } else if t < tPull {                           // rummage
            let w = sin(2 * .pi * 2.0 * (t - tRummage))
            let amp = CGFloat(sin(phase(t, tRummage, tPull) * .pi))
            holdArm(&p, upper: 1.25 + 0.06 * amp * CGFloat(w), fore: -0.15)
            reachArm(&p, upper: 1.62 + 0.12 * amp * CGFloat(w), fore: 1.5 + 0.1 * amp * CGFloat(sin(2 * .pi * 2.0 * (t - tRummage) + 0.9)))
            p.rootAngle = 0.06 * toward; p.headAngle = -0.14 + 0.05 * CGFloat(sin(2 * .pi * 1.6 * (t - tRummage)))
        } else if t < tPresent {                        // pull the card out & up
            let r = easeOut(phase(t, tPull, tPull + 1.0))
            holdArm(&p, upper: lerp(1.25, 0.55, r), fore: lerp(-0.15, 0.1, r))
            reachArm(&p, upper: lerp(1.62, 1.15, r), fore: lerp(1.5, 0.2, r))
            p.rootAngle = lerp(0.06 * toward, -0.03, r); p.headAngle = lerp(-0.14, 0.04, r)
        } else {                                        // present & hold
            holdArm(&p, upper: 0.55, fore: 0.1)
            reachArm(&p, upper: 1.15, fore: 0.2)
            let b = sin(phase(t, tPresent, tPresent + 0.6) * .pi)
            p.scaleY = 1 + 0.02 * CGFloat(b); p.headAngle = 0.05 * CGFloat(b)
        }
        return p
    }

    private func holdArm(_ p: inout FigurePose, upper: CGFloat, fore: CGFloat) {
        if holdLeft { p.leftArmAngle = upper; p.leftForearmAngle = fore }
        else { p.rightArmAngle = -upper; p.rightForearmAngle = -fore }
    }
    private func reachArm(_ p: inout FigurePose, upper: CGFloat, fore: CGFloat) {
        if holdLeft { p.rightArmAngle = -upper; p.rightForearmAngle = -fore }
        else { p.leftArmAngle = upper; p.leftForearmAngle = fore }
    }

    func drawProps(_ ctx: GraphicsContext, at t: Double, pose: FigurePose, originOffset off: CGPoint,
                   payload: RevealPayload?, style: RevealStyle, glyphs: GlyphStore?, paper: Color) {
        guard t >= tFall else { return }
        let head = worldJoint(rig, skel.headCenter, .head, pose, off)
        let hr = skel.headRadius
        let restBrim = CGPoint(x: head.x, y: head.y - hr * 0.55)
        let holdHand = worldHand(rig, left: holdLeft, pose, off)

        var brim: CGPoint
        var flip: CGFloat = 0
        if t < tImpact {
            let fp = easeIn(phase(t, tFall, tImpact))
            // Fall from just below the header (not off-screen above it), so the hat's whole
            // descent is visible instead of passing behind the top bar.
            // 0.40 is the crown height, but drawHat strokes the crown's top oval a further
            // ~0.075·propScale above the brim (plus line width + sketch jitter). Budget for
            // the whole hat, or its crown grazes the floating toolbar bubbles as it falls.
            let fallStartY = max(topInset + propScale * 0.48 + lw * 2, restBrim.y - propScale * 0.5)
            brim = CGPoint(x: head.x, y: lerp(fallStartY, restBrim.y, fp))
        } else if t < tLift {
            brim = restBrim
        } else {
            let bp = smooth(phase(t, tLift, tReachIn))
            brim = CGPoint(x: lerp(restBrim.x, holdHand.x, bp), y: lerp(restBrim.y, holdHand.y, bp))
            // The hat TUMBLES 180° while it's carried off the head, so it ends upside-down
            // in the hand — opening up. Pulling a card out of an upright hat's crown made
            // no sense; a magician flips the hat, then reaches INSIDE.
            flip = CGFloat(smooth(phase(t, tLift + 0.15, tReachIn - 0.15)))
        }

        // With the hat flipped, its OPENING sits one crown-height above the grip point —
        // the same spot the upright crown-top occupied, so the reach/rummage arm poses,
        // the sparkles, and the card's rise path all keep their tuned positions.
        let crownH = propScale * 0.40
        let brimW = propScale * 0.62, brimH = brimW * 0.22, crownW = brimW * 0.60
        let mouth = CGPoint(x: brim.x, y: brim.y - crownH)
        let mrx = crownW * 0.46, mry = brimH * 0.55           // the opening (shared with the clip)

        drawHat(ctx, grip: brim, flip: flip, opacity: 1)

        // The opening's rim is split about the card: the FAR (back) arc behind it, the NEAR
        // (front) arc over it — so the card sits IN the hole, not behind or in front of it.
        let openingUp = flip > 0.9
        if openingUp {
            SketchInk.sketch(ctx, arcPts(center: mouth, rx: mrx, ry: mry, from: .pi, to: 2 * .pi),
                             ink: ink, lw: lw * 0.85, closed: false, amp: lw * 0.4, seed: 45)
        }

        if t >= tPull {
            let r = easeOut(phase(t, tPull + 0.1, tPull + 1.0))
            // The card EXPANDS as it rises (0.72× → 1×): inside, it's sized to the hat's
            // hole; out in the open it grows to full reveal size — so it always fits
            // through the drawn opening however small the hat came out.
            let grow = CGFloat(lerp(0.72, 1.0, r))
            let cardW = propScale * 0.34 * grow, cardH = cardW * 1.4
            // Rise the card straight up out of the hat mouth (on the OPEN side where the
            // hat is held) rather than carrying it across to the far reach hand — that put
            // the reveal on the crowded side and cropped it. Clamp as a final safety net.
            let cx = mouth.x + sideSign * cardW * 0.10
            let cy = lerp(mouth.y + cardH * 0.20, mouth.y - cardH * 0.55, r)
            let op = CGFloat(easeOut(min(phase(t, tPull, tPull + 0.3), 1)))
            let center = fitOnScreen(CGPoint(x: cx, y: cy), halfW: cardW / 2, halfH: cardH / 2, in: screenSize,
                                     topMargin: topInset, bottomMargin: bottomInset)
            let rect = CGRect(x: center.x - cardW / 2, y: center.y - cardH / 2, width: cardW, height: cardH)
            // Visible only ABOVE the opening plane or THROUGH the hole — never below it.
            // The hat stays wireframe-transparent; this clip is what makes the card come
            // OUT OF the hat instead of appearing from behind it.
            var clip = Path()
            clip.addRect(CGRect(x: -2000, y: mouth.y - 4000, width: screenSize.width + 4000, height: 4000))
            clip.addEllipse(in: CGRect(x: mouth.x - mrx, y: mouth.y - mry, width: mrx * 2, height: mry * 2))
            var cc = ctx
            cc.clip(to: clip)
            SketchInk.cardFace(cc, rect: rect, opacity: op, ink: ink, lw: lw, paper: paper,
                               payload: payload, style: style, glyphs: glyphs)
        }

        if openingUp {
            SketchInk.sketch(ctx, arcPts(center: mouth, rx: mrx, ry: mry, from: 0, to: .pi),
                             ink: ink, lw: lw * 0.85, closed: false, amp: lw * 0.4, seed: 47)
        }

        if t >= tReachIn && t < tPull {
            SketchInk.sparkles(ctx, around: mouth, spread: propScale * 0.16,
                               intensity: 0.5 * CGFloat(sin(phase(t, tReachIn, tPull) * .pi)), ink: ink, lw: lw)
        }
    }

    private func arcPts(center: CGPoint, rx: CGFloat, ry: CGFloat, from a0: CGFloat, to a1: CGFloat) -> [CGPoint] {
        stride(from: a0, through: a1, by: (a1 - a0) / 20).map {
            CGPoint(x: center.x + rx * cos($0), y: center.y + ry * sin($0))
        }
    }

    /// Draws the hat WIREFRAME (lines only, transparent like every other prop) in LOCAL
    /// space (brim plane at the origin, crown extending up to −crownH) under a rotation
    /// of `flip`·π about the hat's own centre, anchored at `grip`. flip 0 = upright (brim
    /// at the grip); flip 1 = upside-down (crown at the grip, OPENING facing up at
    /// grip.y − crownH). The opening's rim is NOT drawn here — drawProps strokes its back
    /// arc behind the card and its front arc over it, which is what puts the card IN the
    /// hole.
    private func drawHat(_ ctx: GraphicsContext, grip: CGPoint, flip: CGFloat, opacity: CGFloat) {
        let brimW = propScale * 0.62, brimH = brimW * 0.22
        let crownW = brimW * 0.60, crownH = propScale * 0.40
        var c = ctx
        c.translateBy(x: grip.x, y: grip.y - crownH / 2)
        c.rotate(by: .radians(Double(flip) * .pi))
        c.translateBy(x: 0, y: crownH / 2)
        let brim = CGPoint.zero
        let top = CGPoint(x: 0, y: -crownH)
        SketchInk.sketch(c, SketchInk.ovalPts(center: brim, rx: brimW / 2, ry: brimH / 2),
                         ink: ink, lw: lw, closed: true, amp: lw * 0.7, seed: 41, opacity: opacity)
        SketchInk.sketch(c, [CGPoint(x: -crownW / 2, y: 0), CGPoint(x: -crownW / 2, y: top.y)],
                         ink: ink, lw: lw, closed: false, amp: lw * 0.5, seed: 42, opacity: opacity)
        SketchInk.sketch(c, [CGPoint(x: crownW / 2, y: 0), CGPoint(x: crownW / 2, y: top.y)],
                         ink: ink, lw: lw, closed: false, amp: lw * 0.5, seed: 43, opacity: opacity)
        SketchInk.sketch(c, SketchInk.ovalPts(center: top, rx: crownW / 2, ry: brimH * 0.55),
                         ink: ink, lw: lw, closed: true, amp: lw * 0.5, seed: 44, opacity: opacity)
        SketchInk.sketch(c, [CGPoint(x: -crownW / 2, y: -brimH * 0.4), CGPoint(x: crownW / 2, y: -brimH * 0.4)],
                         ink: ink, lw: lw * 0.8, closed: false, amp: lw * 0.4, seed: 46, opacity: opacity)
    }
}
