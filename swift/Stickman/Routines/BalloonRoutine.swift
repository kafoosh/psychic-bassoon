import SwiftUI

// Balloon: drop → wave → walk to the roomier side → inflate a balloon beside his face
// (toward the open side) → it floats up → pops → the card appears and settles.
struct BalloonRoutine: AnimationRoutine {
    let rig: Rig
    let dropDistance: CGFloat
    let walkDX: CGFloat
    let sideSign: CGFloat       // balloon forms on this (open) side of the face
    let propScale: CGFloat
    let screenSize: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(_ s: RoutineSetup) {
        rig = s.rig; dropDistance = s.dropDistance; walkDX = s.walkDX
        sideSign = s.sideSign; propScale = s.propScale; screenSize = s.screenSize
        topInset = s.topInset; bottomInset = s.bottomInset
    }

    let totalDuration: Double = 12.2
    private var skel: Skeleton { rig.skeleton }
    private var ink: Color { rig.inkColor }
    private var lw: CGFloat { max(rig.inkWidth * 0.9, 3) }

    private let tHands = 4.7, tInflate = 5.6, tRelease = 8.0, tStrain = 9.6, tPop = 9.95, tCard = 10.1

    func pose(at t: Double) -> FigurePose {
        if let ap = Approach.pose(t, skel: skel, ground: dropDistance, walkDX: walkDX) { return ap }
        var p = FigurePose.rest(skel)
        p.offset = CGPoint(x: walkDX, y: dropDistance)
        let toward: CGFloat = sideSign

        if t < tInflate {                               // bring hands up beside the face
            let r = smooth(phase(t, tHands, tInflate))
            p.leftArmAngle = 0.85 * r; p.rightArmAngle = -0.85 * r
            p.leftForearmAngle = 1.2 * r; p.rightForearmAngle = -1.2 * r
            p.headAngle = (0.16 * toward - 0.05) * r; p.rootAngle = 0.05 * r
        } else if t < tRelease {                        // inflate — puffs
            var puff: CGFloat = 0
            for c in [tInflate + 0.6, tInflate + 1.4, tInflate + 2.0] where t > c - 0.18 && t < c + 0.18 {
                puff += CGFloat(sin((t - (c - 0.18)) / 0.36 * .pi))
            }
            p.scaleY = 1 - 0.05 * puff; p.scaleX = 1 + 0.05 * puff
            p.leftArmAngle = 0.9; p.rightArmAngle = -0.9
            p.leftForearmAngle = 1.1; p.rightForearmAngle = -1.1
            p.headAngle = 0.16 * toward - 0.05 - 0.05 * puff; p.rootAngle = 0.05
        } else if t < tStrain {                         // release & watch it rise
            let r = smooth(phase(t, tRelease, tRelease + 1.0))
            p.leftForearmAngle = lerp(1.1, 0.5, CGFloat(easeOut(phase(t, tRelease, tRelease + 0.3))))
            p.rightForearmAngle = lerp(-1.1, -0.5, CGFloat(easeOut(phase(t, tRelease, tRelease + 0.3))))
            let reach = sin(phase(t, tRelease, tStrain) * .pi)
            p.leftArmAngle = 0.9 + (toward < 0 ? 0.7 : 0) * CGFloat(reach)
            p.rightArmAngle = -0.9 - (toward > 0 ? 0.7 : 0) * CGFloat(reach)
            p.headAngle = lerp(0.1 * toward, -0.42, r)
        } else if t < tCard {                           // strain & pop
            if t < tPop { p.leftArmAngle = 0.9; p.rightArmAngle = -0.9; p.headAngle = -0.42 }
            else {
                let r = easeOut(phase(t, tPop, tCard + 0.3))
                p.headAngle = lerp(-0.42, -0.18, r)
                p.leftArmAngle = lerp(0.9, 1.3, r); p.rightArmAngle = lerp(-0.9, -1.3, r)
                p.scaleX = 1 + 0.06 * CGFloat(sin(phase(t, tPop, tCard) * .pi))
            }
        } else {                                        // present
            let r = smooth(phase(t, tCard, tCard + 0.8))
            p.leftArmAngle = lerp(1.3, 0.7, r); p.rightArmAngle = lerp(-1.3, -0.7, r)
            p.leftForearmAngle = 0.25; p.rightForearmAngle = -0.25
            p.headAngle = lerp(-0.18, -0.28, r)
        }
        return p
    }

    private func radius(at t: Double) -> CGFloat {
        if t < tInflate { return 0 }
        if t < tRelease {
            let p = phase(t, tInflate, tRelease)
            let r: CGFloat
            if p < 0.22 { r = lerp(0, 0.16, CGFloat(p / 0.22)) }
            else if p < 0.55 { r = lerp(0.16, 0.26, CGFloat((p - 0.22) / 0.33)) }
            else if p < 0.85 { r = lerp(0.26, 0.34, CGFloat((p - 0.55) / 0.30)) }
            else { r = lerp(0.34, 0.36, CGFloat((p - 0.85) / 0.15)) }
            return propScale * r
        }
        if t < tPop { return propScale * lerp(0.36, 0.40, CGFloat(easeOut(phase(t, tStrain, tPop)))) }
        return propScale * 0.40
    }

    // Float up to just below the header — NOT a fixed screen fraction, which sat behind the
    // top bar. The balloon (radius ≈ 0.40·propScale at the top) keeps its full body visible.
    // 0.40 × the ~1.06 strain stretch the balloon reaches before the pop, so the top of a
    // fully-stretched balloon still clears the chrome.
    private var floatEndY: CGFloat { max(topInset + propScale * 0.425 + lw * 3, screenSize.height * 0.20) }

    private func balloonCenter(at t: Double, _ off: CGPoint, _ pose: FigurePose) -> CGPoint {
        let head = worldJoint(rig, skel.headCenter, .head, pose, off)
        let R = radius(at: min(t, tPop))
        let beside = CGPoint(x: head.x + sideSign * (skel.headRadius * 0.7 + R * 0.5), y: head.y - R * 0.35)
        if t < tRelease { return beside }
        let R8 = radius(at: tRelease)
        let start = CGPoint(x: head.x + sideSign * (skel.headRadius * 0.7 + R8 * 0.5), y: head.y - R8 * 0.35)
        let fp = smooth(phase(min(t, tStrain), tRelease, tStrain))
        let x = start.x + sideSign * propScale * 0.08 * CGFloat(fp) + CGFloat(sin(Double(fp) * 2 * .pi * 1.2)) * propScale * 0.04
        let y = lerp(start.y, floatEndY, fp)
        return CGPoint(x: x, y: y)
    }

    func drawProps(_ ctx: GraphicsContext, at t: Double, pose: FigurePose, originOffset off: CGPoint,
                   payload: RevealPayload?, style: RevealStyle, glyphs: GlyphStore?, paper: Color) {
        let popCenter = balloonCenter(at: tPop, off, pose)

        if t >= tInflate && t < tPop {                  // balloon present
            let R = radius(at: t)
            guard R > 1 else { return }
            let center = balloonCenter(at: t, off, pose)
            let stretch: CGFloat = t >= tStrain ? 1.06 : 1.0
            SketchInk.sketch(ctx, SketchInk.ovalPts(center: center, rx: R * 0.92, ry: R * stretch),
                             ink: ink, lw: lw, closed: true, amp: lw * 0.9, seed: 51)
            let knot = CGPoint(x: center.x, y: center.y + R * stretch)
            SketchInk.sketch(ctx, [CGPoint(x: knot.x - lw, y: knot.y), CGPoint(x: knot.x, y: knot.y + lw * 2.5),
                                   CGPoint(x: knot.x + lw, y: knot.y)], ink: ink, lw: lw, closed: true, amp: lw * 0.4, seed: 52)
            // string trails to the hand CLOSEST to the balloon (the open side) while
            // held, then dangles after release
            let nearHand = worldHand(rig, left: sideSign < 0, pose, off)
            let end: CGPoint = t < tRelease
                ? nearHand
                : CGPoint(x: knot.x + CGFloat(sin(t * 4)) * R * 0.1, y: knot.y + R * 1.3)
            var pts: [CGPoint] = []
            for k in 0...8 {
                let u = CGFloat(k) / 8
                pts.append(CGPoint(x: lerp(knot.x, end.x, u) + CGFloat(sin(Double(u) * .pi)) * R * 0.1,
                                   y: lerp(knot.y, end.y, u)))
            }
            SketchInk.sketch(ctx, pts, ink: ink, lw: lw * 0.8, closed: false, amp: lw * 0.5, seed: 53)
        } else if t >= tPop && t < tCard + 0.3 {        // POP burst
            let q = easeOut(phase(t, tPop, tCard + 0.3))
            let R = radius(at: tPop)
            for i in 0..<8 {
                let a = Double(i) / 8 * 2 * .pi + 0.3
                let d = R * 0.2 + q * R * 1.4
                let base = CGPoint(x: popCenter.x + CGFloat(cos(a)) * d, y: popCenter.y + CGFloat(sin(a)) * d)
                let tip = CGPoint(x: base.x + CGFloat(cos(a)) * R * 0.3, y: base.y + CGFloat(sin(a)) * R * 0.3)
                SketchInk.sketch(ctx, [base, tip], ink: ink, lw: lw, closed: false, amp: lw * 0.6,
                                 seed: CGFloat(60 + i), opacity: 1 - q)
            }
            SketchInk.sparkles(ctx, around: popCenter, spread: R * 1.1, intensity: 0.9 * (1 - q), ink: ink, lw: lw)
        }

        if t >= tCard {                                 // card materializes & settles
            let cardW = propScale * 0.42, cardH = cardW * 1.4
            let birth = easeOut(phase(t, tCard, tCard + 0.4))
            let scale = lerp(0, 1.12, CGFloat(birth)) - lerp(0, 0.12, CGFloat(easeOut(phase(t, tCard + 0.4, tCard + 0.6))))
            let op = CGFloat(easeOut(min(phase(t, tCard, tCard + 0.2), 1)))
            let settleP = easeOut(phase(t, tCard + 0.4, tCard + 1.6))
            let targetY = max(popCenter.y + propScale * 0.16, cardH / 2 + propScale * 0.06)
            let cy = lerp(popCenter.y, targetY, settleP)
            let spin = lerp(0.5, 0, CGFloat(easeOut(phase(t, tCard, tCard + 0.6))))
            let sway = CGFloat(0.06 * sin(phase(t, tCard + 0.4, tCard + 1.6) * 2 * .pi * 2)) * (1 - CGFloat(settleP))
            let w = cardW * max(scale, 0.02), h = cardH * max(scale, 0.02)
            let center = fitOnScreen(CGPoint(x: popCenter.x, y: cy),
                                     halfW: cardW / 2, halfH: cardH / 2, in: screenSize,
                                     topMargin: topInset, bottomMargin: bottomInset)
            var c = ctx
            c.translateBy(x: center.x, y: center.y)
            c.rotate(by: .radians(Double(spin + sway)))
            c.translateBy(x: -center.x, y: -center.y)
            let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            SketchInk.cardFace(c, rect: rect, opacity: op, ink: ink, lw: lw, paper: paper,
                               payload: payload, style: style, glyphs: glyphs)
            if t < tCard + 0.6 {
                SketchInk.sparkles(ctx, around: center, spread: cardW * 0.7,
                                   intensity: 0.4 * (1 - CGFloat(phase(t, tCard, tCard + 0.6))), ink: ink, lw: lw)
            }
        }
    }
}
