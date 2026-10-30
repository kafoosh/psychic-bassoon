import SwiftUI

// Shared easing + helpers for the animation routines.

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
/// Smoothstep on [0,1] — the routines' default easeInOut.
func smooth(_ x: Double) -> CGFloat {
    let t = min(max(x, 0), 1)
    return CGFloat(t * t * (3 - 2 * t))
}
/// Decelerating ease (fast→slow).
func easeOut(_ x: Double) -> CGFloat { let t = clamp01(x); return CGFloat(1 - (1 - t) * (1 - t)) }
/// Accelerating ease (slow→fast) — gravity.
func easeIn(_ x: Double) -> CGFloat { let t = clamp01(x); return CGFloat(t * t) }
// `smooth(_:)` (smoothstep) already exists globally and serves as easeInOut.

/// Normalized progress through a [start, end] window, clamped to 0…1.
func phase(_ t: Double, _ start: Double, _ end: Double) -> Double {
    guard end > start else { return t >= end ? 1 : 0 }
    return clamp01((t - start) / (end - start))
}

/// Project a drawing-space point to screen space at the given pose (minus the canvas offset).
func worldJoint(_ rig: Rig, _ p: CGPoint, _ part: BodyPart, _ pose: FigurePose, _ off: CGPoint) -> CGPoint {
    var w = rig.worldPoint(p, part: part, pose: pose)
    w.x -= off.x; w.y -= off.y
    return w
}

/// The held-prop anchor for one side: the hand under its CARRYING part (see Rig.leftHandPart —
/// the forearm when the drawn arm articulates so the prop rides the animated hand; the torso
/// when the hand was only estimated, so the prop stays ON the static drawn arm instead of
/// swinging away on an invisible arm's FK). Every routine anchors its apparatus through this.
func worldHand(_ rig: Rig, left: Bool, _ pose: FigurePose, _ off: CGPoint) -> CGPoint {
    left ? worldJoint(rig, rig.skeleton.leftHand, rig.leftHandPart, pose, off)
         : worldJoint(rig, rig.skeleton.rightHand, rig.rightHandPart, pose, off)
}

/// Keep a prop fully on screen: translate `center` so a box of the given half-extents sits
/// within the screen minus margins. Only SHIFTS — never resizes — so the prop keeps the
/// size the routine chose. If the prop is wider/taller than the available span it's centred
/// on that axis. The reveal card is run through this as a safety net so it can never be
/// cropped, even for an unusually long-armed (hand-anchored) figure.
func fitOnScreen(_ center: CGPoint, halfW: CGFloat, halfH: CGFloat, in screen: CGSize,
                 sideMargin: CGFloat = 12, topMargin: CGFloat = 56, bottomMargin: CGFloat = 12) -> CGPoint {
    var x = center.x, y = center.y
    let loX = sideMargin + halfW, hiX = screen.width - sideMargin - halfW
    x = loX <= hiX ? min(max(x, loX), hiX) : screen.width / 2
    let loY = topMargin + halfH, hiY = screen.height - bottomMargin - halfH
    y = loY <= hiY ? min(max(y, loY), hiY) : (loY + hiY) / 2
    return CGPoint(x: x, y: y)
}

// The shared opening EVERY routine plays: drop in → settle → wave hello → WALK to the
// roomier side of the screen. Each routine then performs its trick toward the OPPOSITE
// (now-open) side, starting at `Approach.done`. Returns the pose during the approach, or
// nil once it's over (the routine takes over, with the figure planted at `walkDX`).
enum Approach {
    static let dropDone: Double = 1.3      // fall 0.85 + land 0.45
    static let standDone: Double = 1.8
    static let waveDone: Double = 3.0
    static let done: Double = 4.7          // walk ends here; actions start

    static func pose(_ t: Double, skel: Skeleton, ground: CGFloat, walkDX: CGFloat) -> FigurePose? {
        var p = FigurePose.rest(skel)
        let drop = DropLand(fall: 0.85, land: 0.45, ground: ground)
        if t < drop.done { drop.apply(&p, at: t); return p }
        p.offset.y = ground
        let waveLeft = walkDX < 0

        if t < standDone {
            p.headAngle = 0.05 * CGFloat(sin(phase(t, dropDone, standDone) * .pi))
            return p
        }
        if t < waveDone {                                   // wave hello (toward travel side)
            let raise = easeOut(phase(t, standDone, standDone + 0.35))
            let down = 1 - easeIn(phase(t, waveDone - 0.2, waveDone))
            let mag = 2.0 * raise * down
            let osc = CGFloat(0.45 * sin(2 * .pi * 2.0 * (t - standDone - 0.35))) * down
            if waveLeft { p.leftArmAngle = mag; p.leftForearmAngle = osc; p.headAngle = 0.12 * raise }
            else { p.rightArmAngle = -mag; p.rightForearmAngle = -osc; p.headAngle = -0.12 * raise }
            return p
        }
        if t < done {                                       // walk to the roomier side
            let prog = smooth(phase(t, waveDone, done))
            p.offset.x = walkDX * prog
            let wp = t - waveDone
            let ramp = smooth(phase(t, waveDone, waveDone + 0.3)) * (1 - smooth(phase(t, done - 0.2, done)))
            let s = CGFloat(sin(2 * .pi * 1.5 * wp))
            p.leftLegAngle = 0.34 * ramp * s
            p.rightLegAngle = -0.34 * ramp * s
            p.leftArmAngle = -0.34 * ramp * s
            p.rightArmAngle = 0.34 * ramp * s
            p.offset.y = ground - 6 * CGFloat(abs(sin(2 * .pi * 1.5 * wp))) * ramp
            p.rootAngle = (walkDX >= 0 ? 0.06 : -0.06) * ramp
            return p
        }
        return nil
    }
}

// The shared opening every routine uses: the figure drops straight down from where it
// was drawn to the floor, lands with a squash, and settles. Mutates `p` in place.
struct DropLand {
    var fall: Double
    var land: Double
    var ground: CGFloat        // dropDistance
    var flailArms: Bool = true

    var done: Double { fall + land }

    func apply(_ p: inout FigurePose, at t: Double) {
        if t < fall {
            let f = t / fall
            p.offset.y = ground * CGFloat(f * f)               // accelerate
            if flailArms {
                let drag = easeOut(f)
                p.leftArmAngle = 1.3 * drag
                p.rightArmAngle = -1.3 * drag
                p.leftForearmAngle = 0.5 * drag
                p.rightForearmAngle = -0.5 * drag
            }
            p.headAngle = -0.15 * CGFloat(f)
        } else if t < fall + land {
            p.offset.y = ground
            let u = (t - fall) / land                          // 0…1
            let squash = sin(min(u, 1) * .pi)                  // 0→1→0
            p.scaleY = 1 - 0.20 * CGFloat(squash)
            p.scaleX = 1 + 0.14 * CGFloat(squash)
            let settle = CGFloat(1 - u)
            p.leftArmAngle = 1.3 * settle * 0.25
            p.rightArmAngle = -1.3 * settle * 0.25
            p.headAngle = -0.15 * settle + 0.10 * CGFloat(squash)
        } else {
            p.offset.y = ground
        }
    }
}
