import SwiftUI

// Painter: drop → wave → walk to the roomier side → use the wand to draw the card into
// existence in mid-air on the OPEN side (progressive draw-on) → the face fills in → the
// card lifts to present.
struct PainterRoutine: AnimationRoutine {
    let rig: Rig
    let dropDistance: CGFloat
    let walkDX: CGFloat
    let sideSign: CGFloat       // draw on this (open) side
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
    private var drawLeft: Bool { sideSign < 0 }

    // Raise the wand → wave it (a flourish) → the magic beam reaches OUT to the card spot →
    // draw the card on → fill → lift. (Was: the wand line just snapped to the card corner.)
    private let tRaise = 4.7, tWave = 5.4, tReach = 6.3, tDraw = 6.9, tClose = 9.5, tFill = 9.9, tLift = 10.9, tHold = 11.8

    func pose(at t: Double) -> FigurePose {
        if let ap = Approach.pose(t, skel: skel, ground: dropDistance, walkDX: walkDX) { return ap }
        var p = FigurePose.rest(skel)
        p.offset = CGPoint(x: walkDX, y: dropDistance)

        func setArm(_ upper: CGFloat, _ fore: CGFloat) {
            if drawLeft { p.leftArmAngle = upper; p.leftForearmAngle = fore }
            else { p.rightArmAngle = -upper; p.rightForearmAngle = -fore }
        }

        if t < tWave {                                  // raise the wand hand
            let r = smooth(phase(t, tRaise, tWave))
            setArm(1.45 * r, 0.40 * r); p.headAngle = (drawLeft ? 0.16 : -0.16) * r
        } else if t < tReach {                          // wave the wand (a flourish)
            let amp = CGFloat(sin(phase(t, tWave, tReach) * .pi))     // ramp 0→1→0
            let wob = CGFloat(sin(2 * .pi * 1.7 * (t - tWave)))
            setArm(1.45 + 0.18 * amp * wob, 0.40 + 0.30 * amp * wob)
            p.headAngle = (drawLeft ? 0.18 : -0.18) + 0.06 * amp * wob
        } else if t < tDraw {                           // settle, aim the wand at the card spot
            let r = smooth(phase(t, tReach, tDraw))
            setArm(lerp(1.45, 1.55, r), lerp(0.40, 0.50, r)); p.headAngle = (drawLeft ? 0.20 : -0.20)
        } else if t < tClose {                          // draw-on (hold, slight sway)
            let sway = CGFloat(0.05 * sin(2 * .pi * (t - tDraw) / 1.0))
            setArm(1.55 + sway, 0.50); p.headAngle = (drawLeft ? 0.20 : -0.20)
        } else if t < tLift {                           // close loop, present toward the card
            let r = smooth(phase(t, tClose, tLift))
            setArm(lerp(1.55, 1.1, r), lerp(0.50, 0.2, r)); p.headAngle = (drawLeft ? 0.10 : -0.10)
        } else if t < tHold {                           // lift & present
            let r = easeOut(phase(t, tLift, tHold))
            setArm(lerp(1.1, 1.5, r), lerp(0.2, 0.5, r)); p.headAngle = 0; p.rootAngle = 0
        } else {
            setArm(1.45, 0.5)
        }
        return p
    }

    func drawProps(_ ctx: GraphicsContext, at t: Double, pose: FigurePose, originOffset off: CGPoint,
                   payload: RevealPayload?, style: RevealStyle, glyphs: GlyphStore?, paper: Color) {
        guard t >= tRaise else { return }
        let feet = worldJoint(rig, skel.feet, .torso, pose, off)
        let hand = worldHand(rig, left: drawLeft, pose, off)
        let shoulder = drawLeft ? worldJoint(rig, skel.leftShoulder, .torso, pose, off)
                                : worldJoint(rig, skel.rightShoulder, .torso, pose, off)

        let w = propScale * 0.58, h = propScale * 0.82
        let center = fitOnScreen(CGPoint(x: feet.x + sideSign * propScale * 0.52, y: feet.y - propScale * 0.62),
                                 halfW: w / 2, halfH: h / 2, in: screenSize,
                                 topMargin: topInset, bottomMargin: bottomInset)
        let baseRect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        let perim = SketchInk.rectPts(baseRect, perEdge: 28)
        let cardStart = perim.first ?? center        // where the draw-on (and the reach) lands

        // The wand held in the hand, pointing away from the shoulder, swung by `swing`.
        let wandLen = propScale * 0.24
        func wandTip(_ swing: CGFloat) -> CGPoint {
            var dx = hand.x - shoulder.x, dy = hand.y - shoulder.y
            let mag = hypot(dx, dy); if mag < 1 { dx = 0; dy = -1 } else { dx /= mag; dy /= mag }
            let sa = sin(swing), ca = cos(swing)
            return CGPoint(x: hand.x + (dx * ca - dy * sa) * wandLen, y: hand.y + (dx * sa + dy * ca) * wandLen)
        }
        // The wand STICK only (no tip star — the star is the travelling "magic point").
        func wandStick(_ tip: CGPoint) {
            let mid = CGPoint(x: (hand.x + tip.x) / 2, y: (hand.y + tip.y) / 2)
            SketchInk.sketch(ctx, [hand, mid, tip], ink: ink, lw: lw * 1.1, closed: false, amp: lw * 0.3, seed: 4.4)
        }

        // ---- Before the draw-on: raise the wand → wave it → the magic reaches OUT to the card ----
        if t < tDraw {
            let waveAmp = CGFloat(sin(phase(t, tWave, tReach) * .pi))   // 0→1→0 over the wave
            let swing = 0.45 * waveAmp * CGFloat(sin(2 * .pi * 1.7 * (t - tWave)))
            let tip = wandTip(swing)
            wandStick(tip)
            if t >= tReach {
                // a glowing beam extends from the wand tip out to where the card will be painted
                let reach = easeOut(phase(t, tReach, tDraw))
                let end = CGPoint(x: lerp(tip.x, cardStart.x, reach), y: lerp(tip.y, cardStart.y, reach))
                SketchInk.sketch(ctx, [tip, end], ink: ink, lw: lw * 0.85, closed: false, amp: lw * 0.4, seed: 14)
                SketchInk.star(ctx, center: end, radius: propScale * 0.05, ink: ink, lw: lw * 0.85)
                SketchInk.sparkles(ctx, around: end, spread: propScale * 0.07, intensity: 0.7, ink: ink, lw: lw)
            } else {
                // raise + wave: the wand tip glows and flicks
                SketchInk.star(ctx, center: tip, radius: propScale * 0.05, ink: ink, lw: lw * 0.85)
                SketchInk.sparkles(ctx, around: tip, spread: propScale * 0.05, intensity: 0.4 + 0.5 * waveAmp, ink: ink, lw: lw)
            }
            return
        }

        // ---- draw-on: the wand projects the card outline from a distance ----
        if t < tClose {
            let progress = smooth(phase(t, tDraw, tClose))
            let tip = SketchInk.sketchPartial(ctx, perim, progress: CGFloat(progress), ink: ink, lw: lw,
                                              closed: true, amp: lw * 0.6, seed: 7)
            let wTip = wandTip(0)
            wandStick(wTip)
            SketchInk.sketch(ctx, [wTip, tip], ink: ink, lw: lw * 0.85, closed: false, amp: lw * 0.3, seed: 14)
            SketchInk.star(ctx, center: tip, radius: propScale * 0.05, ink: ink, lw: lw * 0.85)
            SketchInk.sparkles(ctx, around: tip, spread: propScale * 0.05, intensity: 0.6, ink: ink, lw: lw)
            return
        }

        let riseP = easeOut(phase(t, tLift, tHold))
        let dx = -sideSign * propScale * 0.06 * riseP
        let dy = -propScale * 0.22 * riseP
        let rect = baseRect.offsetBy(dx: dx, dy: dy)

        // One card, one border: cardFace owns the outline from the moment the draw-on
        // completes, and `wipe` fills the face + secret in top-down — so the finished card
        // matches every other routine's (no second inset border).
        let wipe = t < tFill ? 0 : smooth(phase(t, tFill, tLift))
        SketchInk.cardFace(ctx, rect: rect, opacity: 1, ink: ink, lw: lw, paper: paper,
                           payload: payload, style: style, glyphs: glyphs, wipe: CGFloat(wipe))
        if t >= tClose && t < tFill {
            SketchInk.sparkles(ctx, around: CGPoint(x: rect.midX, y: rect.midY),
                               spread: propScale * 0.5, intensity: 0.8 * CGFloat(sin(phase(t, tClose, tFill) * .pi)),
                               ink: ink, lw: lw)
        }
    }
}
