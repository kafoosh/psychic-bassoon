import SwiftUI
import CoreGraphics

// The rigid parts a stickman is skinned into. Limbs split at the elbow / knee so a
// straight arm or leg can bend mid-way for a natural gait. A continuous stroke can
// span several parts (per-point assignment), so a one-stroke figure still articulates.
enum BodyPart: Int, CaseIterable, Hashable {
    case torso, head
    case leftArm, rightArm, leftForearm, rightForearm
    case leftLeg, rightLeg, leftShin, rightShin
}

// One of the participant's pen strokes, densified to a polyline, with a per-point
// body-part assignment and its original colour/width so the *real* drawing moves.
struct RigStroke {
    var points: [CGPoint]
    var parts: [BodyPart]
    var color: Color
    var width: CGFloat
    // A CLOSED-LOOP silhouette stroke (an outlined limb/torso, both walls in one path).
    // Such a stroke is INDIVISIBLE: it gets a single body part and is never split at the
    // elbow/knee, so both walls share one FK pivot and rotate as one rigid sheet (a thin
    // line stroke stays `false` and still splits arm→forearm for the wave). Defaults false
    // so every existing call site is byte-identical.
    var rigid: Bool = false
}

// Joint positions in the drawing's own coordinate space (canvas points). Elbows and
// knees sit mid-limb (inferred along a straight arm/leg) so the lower segment bends.
struct Skeleton {
    var bbox: CGRect
    var headCenter: CGPoint
    var headRadius: CGFloat
    var neck: CGPoint
    var leftShoulder: CGPoint
    var rightShoulder: CGPoint
    var leftElbow: CGPoint
    var rightElbow: CGPoint
    var hipCenter: CGPoint
    var leftHip: CGPoint
    var rightHip: CGPoint
    var leftKnee: CGPoint
    var rightKnee: CGPoint
    var feet: CGPoint
    // Far ends of the arms (the hands) — anchor points for held props (the wand).
    var leftHand: CGPoint
    var rightHand: CGPoint
    // Shin angle (about the knee) that makes each shin collinear with its thigh —
    // i.e. straightens out however the leg was drawn, so the animator can scissor a
    // rigid straight leg from the hip. 0 = leave the leg exactly as drawn.
    var leftShinStraighten: CGFloat = 0
    var rightShinStraighten: CGFloat = 0
}

// A single frame of motion. Angles are radians relative to the drawn rest pose
// (0 = as drawn). Forearm / shin angles are *local* to their parent limb. Root
// squash is about the feet; root rotation about the hips.
struct FigurePose {
    var offset: CGPoint = .zero
    var rootAngle: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var headAngle: CGFloat = 0
    var leftArmAngle: CGFloat = 0
    var rightArmAngle: CGFloat = 0
    var leftForearmAngle: CGFloat = 0
    var rightForearmAngle: CGFloat = 0
    var leftLegAngle: CGFloat = 0
    var rightLegAngle: CGFloat = 0
    var leftShinAngle: CGFloat = 0
    var rightShinAngle: CGFloat = 0
    var opacity: CGFloat = 1
}

/// One post-fit plausibility demotion (see `RigPlausibility`): a limb whose assignment was
/// geometrically implausible was frozen to `.torso`. Diagnostics only — the harness uses it
/// to count demotions and flag false positives (a demotion that undid truth-correct labels).
struct RigDemotion {
    var side: String               // "Larm" / "Rarm" / "Lleg" / "Rleg" / "all"
    var reason: String             // which check fired, e.g. "shoulder-band", "fling-lever"
    var strokes: [Int]             // stroke indices whose labels were changed
    var preMajorities: [BodyPart]  // each affected stroke's PRE-demotion majority part
}

struct Rig {
    var strokes: [RigStroke]
    var skeleton: Skeleton
    var confidence: CGFloat
    var articulated: Bool
    /// Plausibility demotions applied during fit (empty when the figure passed clean).
    var demotions: [RigDemotion] = []
    // The FK part that CARRIES each held-prop anchor (the hand). `.leftForearm`/`.rightForearm`
    // only when some drawn stroke actually articulates as that arm — then the prop rides the
    // animated hand. A hand that was merely ESTIMATED (a one-loop outline body, the all-torso
    // fallback, Auto-Rig off — no arm-labelled strokes) must ride the ROOT (`.torso`) instead:
    // swinging it on the invisible arm's FK drifts the prop (rod/balloon/wand) far away from
    // the static drawn arm, even off-screen.
    var leftHandPart: BodyPart = .torso
    var rightHandPart: BodyPart = .torso

    /// A non-articulated copy: every stroke collapses to one rigid `.torso` sheet, so the whole
    /// drawing moves as a SINGLE rigid sprite — the exact graceful path used when a figure can't
    /// be recognised. It still drops, lands, walks, and conjures (the routine's root transform +
    /// props use the skeleton, which is kept), the limbs just don't articulate. Drives the
    /// "Auto-Rig off" setting. Hand anchors ride the root too (no drawn arm moves).
    var nonArticulated: Rig {
        var copy = self
        for i in copy.strokes.indices {
            copy.strokes[i].parts = Array(repeating: .torso, count: copy.strokes[i].points.count)
            copy.strokes[i].rigid = false
        }
        copy.articulated = false
        copy.leftHandPart = .torso
        copy.rightHandPart = .torso
        return copy
    }

    /// Representative pen colour of the drawing (the longest stroke's) — used to draw
    /// the conjured props in the same hand the figure was drawn in.
    var inkColor: Color { (strokes.max { $0.points.count < $1.points.count })?.color ?? .primary }
    /// Representative pen width, so the props' line weight matches the figure.
    var inkWidth: CGFloat {
        let ws = strokes.map(\.width)
        return ws.isEmpty ? 4 : max(3, ws.reduce(0, +) / CGFloat(ws.count))
    }

    // Hierarchical forward kinematics. Each limb's lower segment bends about its
    // elbow / knee first, then the whole limb swings about the shoulder / hip, then
    // the root transform (squash about feet → lean about hips → translate). Because
    // every joint a child rotates about is itself carried by the parent rotation,
    // strokes crossing a joint stay connected — no tearing at shoulders/hips/knees.
    func worldPoint(_ p: CGPoint, part: BodyPart, pose: FigurePose) -> CGPoint {
        var local = p
        switch part {
        case .torso:
            break
        case .head:
            local = rigRotate(p, around: skeleton.neck, by: pose.headAngle)
        case .leftArm:
            local = rigRotate(p, around: skeleton.leftShoulder, by: pose.leftArmAngle)
        case .rightArm:
            local = rigRotate(p, around: skeleton.rightShoulder, by: pose.rightArmAngle)
        case .leftForearm:
            local = rigRotate(p, around: skeleton.leftElbow, by: pose.leftForearmAngle)
            local = rigRotate(local, around: skeleton.leftShoulder, by: pose.leftArmAngle)
        case .rightForearm:
            local = rigRotate(p, around: skeleton.rightElbow, by: pose.rightForearmAngle)
            local = rigRotate(local, around: skeleton.rightShoulder, by: pose.rightArmAngle)
        case .leftLeg:
            local = rigRotate(p, around: skeleton.leftHip, by: pose.leftLegAngle)
        case .rightLeg:
            local = rigRotate(p, around: skeleton.rightHip, by: pose.rightLegAngle)
        case .leftShin:
            local = rigRotate(p, around: skeleton.leftKnee, by: pose.leftShinAngle)
            local = rigRotate(local, around: skeleton.leftHip, by: pose.leftLegAngle)
        case .rightShin:
            local = rigRotate(p, around: skeleton.rightKnee, by: pose.rightShinAngle)
            local = rigRotate(local, around: skeleton.rightHip, by: pose.rightLegAngle)
        }
        var q = rigScaleAbout(local, skeleton.feet, pose.scaleX, pose.scaleY)
        q = rigRotate(q, around: skeleton.hipCenter, by: pose.rootAngle)
        q.x += pose.offset.x
        q.y += pose.offset.y
        return q
    }
}

// MARK: - Point math

func rigRotate(_ p: CGPoint, around c: CGPoint, by a: CGFloat) -> CGPoint {
    if a == 0 { return p }
    let s = sin(a), co = cos(a)
    let dx = p.x - c.x, dy = p.y - c.y
    return CGPoint(x: c.x + dx * co - dy * s, y: c.y + dx * s + dy * co)
}

func rigScaleAbout(_ p: CGPoint, _ c: CGPoint, _ sx: CGFloat, _ sy: CGFloat) -> CGPoint {
    CGPoint(x: c.x + (p.x - c.x) * sx, y: c.y + (p.y - c.y) * sy)
}
