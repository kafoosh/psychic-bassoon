#if DEBUG
import SwiftUI
import PencilKit
import UIKit
import CoreGraphics

// ============================================================================
// RIG REGRESSION SUITE (DEBUG only — never auto-runs; safe to keep in the tree).
//
// simctl can't draw/tap, so we VERIFY the auto-rig by constructing PKDrawings in
// code from a library of swappable PART VARIATIONS (heads / torsos / arms / legs,
// each in LINE and OUTLINE forms, plus decorations), composing them into standing
// figures with known GROUND-TRUTH body-part labels, running the real RigFitter,
// scoring predicted-vs-intended part labels, bucketing failures by part-variation
// tag, and (a) writing a report to Documents/righarness.txt and (b) dumping
// rig_*.png frames (rest / part-coloured / joint-stressed) for visual no-tear checks.
//
// HOW TO RUN: temporarily add `RigHarness.run()` to A_Little_GuyApp.init() (DEBUG),
// launch in the sim, then read back the report + PNGs from the app's Documents:
//   CONT=$(xcrun simctl get_app_container <UDID> com.kenneth.A-Little-Guy data)
//   cat "$CONT/Documents/righarness.txt"   # + open "$CONT/Documents/"rig_*.png
// Remove the RigHarness.run() call again before committing. See [[rig-debug-harness-workflow]].
// ============================================================================

// One synthetic stroke + the body part ALL its points are intended to belong to.
struct LabeledStroke {
    var points: [CGPoint]
    var part: BodyPart
    var truth: TruthLabel? = nil       // override when the stroke is not a single part (λ spine+leg)
}

/// Ground truth for one stroke. `.part` = every point belongs to that part; the pair cases
/// mark a single stroke DELIBERATELY carrying both limbs of a pair (arms drawn as one ∩,
/// legs as one ∧) — correct means the fitter split it into both sides, not one whole part.
enum TruthLabel {
    case part(BodyPart)
    case armPair
    case legPair
    case spineLeg        // ONE stroke: the spine continuing into a leg (λ) — torso + leg, never arm
}

/// A hand-built regression fixture (reproduces a real user drawing / reported failure),
/// now with ground truth so it is SCORED, not just eyeballed.
struct UserFixture {
    var name: String
    var strokes: [PKStroke]
    var truth: [TruthLabel]
}

// MARK: - Part variation axes

enum HeadVariant: String, CaseIterable {
    case circle          // closed round head (stick-figure classic)
    case bigCircle       // oversized round head (a common failure trigger)
    case smallCircle     // small round head
    case wideOval        // wide oval head (Character 1)
    case tallOval        // tall oval head
    case openArc         // unclosed head loop (people often don't close it)
}

enum TorsoVariant: String, CaseIterable {
    case spineLine       // a single vertical line (true stick figure)
    case rectOutline     // closed rectangle body (Character 1)
    case roundedBlob     // closed rounded capsule body (Character 2)
    case trapezoid       // wider at shoulders, narrow at hip
    case ovalBody        // closed ellipse body
    // ---- adversarial (outlier stressors; never in the baseline cross product) ----
    case openTaperOutline // OPEN ∪ body outline whose two free ends ARE the shoulders
    case hourglass       // closed hourglass: wide shoulders/hips, pinched waist
}

enum ArmVariant: String, CaseIterable {
    case lineDown        // single line angling down-and-out
    case lineT           // single horizontal line (T-pose)
    case outlineMitten   // closed teardrop/capsule outline (Character 2)
    case bentLine        // shoulder→elbow→hand polyline with a bend
    case lowAttach       // arm rooted OFFSET down the torso, well below the shoulders
    // ---- adversarial ----
    case handOnHip       // akimbo: shoulder → elbow out → hand back ON the hip
    case raisedFist      // arm raised beside the head + a fist blob at the tip
    case twoStroke       // upper arm + forearm as TWO strokes meeting at the elbow
    case crossBody       // arm folded ACROSS the chest: shoulder → hand on the opposite hip

    var isOutline: Bool { self == .outlineMitten }
}

enum LegVariant: String, CaseIterable {
    case lineStraight    // single line straight down
    case lineSplay       // single line down-and-out
    case outlineTapered  // closed tapered capsule outline (Character 2)
    case bentLine        // hip→knee→foot polyline with a bend
    // ---- legs drawn TO THE SIDE (the reported failure family) ----
    case sideways        // BOTH legs veer the same way (stance shifted to one side)
    case crossed         // legs cross the centreline (scissor X — foot lands on the opposite side)
    case steepSplay      // very wide diagonal splay to both sides
    case sideOutline     // both legs are OUTLINE tubes veering to one side
    // ---- adversarial ----
    case monoTube        // ONE chunky open tube centred under the spine (both legs as one mass)
    case twoStroke       // thigh + shin as TWO strokes meeting at the knee

    var isOutline: Bool { self == .outlineTapered || self == .sideOutline || self == .monoTube }
}

struct Decorations: OptionSet {
    let rawValue: Int
    static let ears  = Decorations(rawValue: 1 << 0)   // two triangles on the head (Character 1)
    static let face  = Decorations(rawValue: 1 << 1)   // eyes + mouth inside the head
    static let hands = Decorations(rawValue: 1 << 2)   // small blobs at the arm tips
    static let feet  = Decorations(rawValue: 1 << 3)   // small blobs at the leg tips
    static let hair  = Decorations(rawValue: 1 << 4)   // strokes on top of the head
    static let neck  = Decorations(rawValue: 1 << 5)   // a neck line between head and torso (→ torso)
    // ---- adversarial (hip-lateral ink + head-seed stressors) ----
    static let belt  = Decorations(rawValue: 1 << 6)   // horizontal line across the torso above the hip (→ torso)
    static let tail  = Decorations(rawValue: 1 << 7)   // a curl out one side from the hip (→ torso)
    static let hat   = Decorations(rawValue: 1 << 8)   // brim + crown sitting on the head top (→ head)
}

struct FigureSpec {
    var head: HeadVariant
    var torso: TorsoVariant
    var arm: ArmVariant
    var leg: LegVariant
    var deco: Decorations = []
    var lean: CGFloat = 0          // horizontal shear (radians-ish), pivoting at the head
    var scale: CGFloat = 1
    var wobble: CGFloat = 0        // hand-drawn jitter amplitude (points)
    var seed: UInt64 = 1
    var penScale: CGFloat = 1      // stroke width multiplier (thick pens fill the crotch gap)
    var oneLeg: Bool = false       // draw only the left leg (Step 5b's ≥2-leg gate / legacy path)
    // ---- body PROPORTIONS (× u). The baseline fixes 3.0 / 2.6 → the crotch always sits at
    // ~56% of neck→feet. Real figures vary: a short torso + long legs puts the crotch near
    // 30–40%, where every "root must be in the lower body" gate starts to miss the legs.
    var torsoLen: CGFloat = 3.0    // shoulder → hip
    var legLen: CGFloat = 2.6      // hip → foot
    var lambdaLeg: Bool = false    // the LEFT leg is the CONTINUATION of the spine stroke (λ body)

    var tags: [String] {
        var t = ["head:\(head)", "torso:\(torso)", "arm:\(arm)", "leg:\(leg)"]
        if deco.contains(.ears)  { t.append("deco:ears") }
        if deco.contains(.face)  { t.append("deco:face") }
        if deco.contains(.hands) { t.append("deco:hands") }
        if deco.contains(.feet)  { t.append("deco:feet") }
        if deco.contains(.hair)  { t.append("deco:hair") }
        if deco.contains(.neck)  { t.append("deco:neck") }
        if deco.contains(.belt)  { t.append("deco:belt") }
        if deco.contains(.tail)  { t.append("deco:tail") }
        if deco.contains(.hat)   { t.append("deco:hat") }
        if abs(lean) > 0.04 { t.append("lean") }
        if wobble > 1.5 { t.append("wobble") }
        if penScale > 1.5 { t.append("thickPen") }
        if oneLeg { t.append("oneLeg") }
        let crotchFrac = (torsoLen + 0.3) / (torsoLen + 0.3 + legLen)
        if crotchFrac < 0.42 { t.append("shortTorso") }
        else if crotchFrac > 0.62 { t.append("longTorso") }
        if lambdaLeg { t.append("lambdaLeg") }
        return t
    }
}

// MARK: - Deterministic RNG (reproducible figures)

struct LCG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
    mutating func bool(_ p: CGFloat = 0.5) -> Bool { unit() < p }
    mutating func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
}

// MARK: - Figure geometry

struct Metrics {
    var cx: CGFloat
    var headCenter: CGPoint
    var headRX: CGFloat
    var headRY: CGFloat
    var neckY: CGFloat
    var shoulderY: CGFloat
    var shoulderHalfW: CGFloat
    var hipY: CGFloat
    var legHalfW: CGFloat
    var footY: CGFloat
    var u: CGFloat                 // base unit
}

enum RigPartLibrary {

    // ---- low-level point generators -------------------------------------

    private static func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat,
                                from a0: CGFloat = 0, to a1: CGFloat = 2 * .pi, n: Int = 28) -> [CGPoint] {
        (0...n).map { i in
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(n)
            return CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a))
        }
    }

    private static func line(_ a: CGPoint, _ b: CGPoint, n: Int = 12) -> [CGPoint] {
        (0...n).map { i in
            let f = CGFloat(i) / CGFloat(n)
            return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
    }

    private static func polyline(_ pts: [CGPoint], n: Int = 8) -> [CGPoint] {
        guard pts.count > 1 else { return pts }
        var out: [CGPoint] = []
        for i in 1..<pts.count { out += line(pts[i - 1], pts[i], n: n) }
        return out
    }

    private static func rectLoop(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> [CGPoint] {
        polyline([CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0),
                  CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1),
                  CGPoint(x: x0, y: y0)], n: 10)
    }

    /// A closed tapered "tube" (capsule) from `a` to `b` with half-widths `wa`/`wb` and a
    /// rounded tip at `b` — used for OUTLINE arms/legs. Both sides + tip in one closed loop,
    /// so a correct rig must rotate the whole loop as ONE rigid piece.
    private static func tube(_ a: CGPoint, _ b: CGPoint, wa: CGFloat, wb: CGFloat) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.001)
        let nx = -dy / len, ny = dx / len            // unit perpendicular
        var pts: [CGPoint] = []
        pts += line(CGPoint(x: a.x + nx * wa, y: a.y + ny * wa),
                    CGPoint(x: b.x + nx * wb, y: b.y + ny * wb), n: 10)   // side 1
        let tipAng0 = atan2(ny, nx)                                       // round the tip
        pts += (1...8).map { i in
            let t = tipAng0 - .pi * CGFloat(i) / 8
            return CGPoint(x: b.x + wb * cos(t), y: b.y + wb * sin(t))
        }
        pts += line(CGPoint(x: b.x - nx * wb, y: b.y - ny * wb),
                    CGPoint(x: a.x - nx * wa, y: a.y - ny * wa), n: 10)   // side 2
        pts.append(pts.first!)                                            // close
        return pts
    }

    // ---- parts ----------------------------------------------------------

    static func head(_ v: HeadVariant, _ m: Metrics) -> [LabeledStroke] {
        let c = m.headCenter
        let pts: [CGPoint]
        switch v {
        case .circle, .bigCircle, .smallCircle:
            pts = ellipse(c, m.headRX, m.headRY)
        case .wideOval:
            pts = ellipse(c, m.headRX, m.headRY)
        case .tallOval:
            pts = ellipse(c, m.headRX, m.headRY)
        case .openArc:
            pts = ellipse(c, m.headRX, m.headRY, from: -.pi / 2 + 0.5, to: 1.5 * .pi - 0.2)
        }
        return [LabeledStroke(points: pts, part: .head)]
    }

    static func torso(_ v: TorsoVariant, _ m: Metrics) -> [LabeledStroke] {
        let cx = m.cx, hw = m.shoulderHalfW
        let pts: [CGPoint]
        switch v {
        case .spineLine:
            pts = line(CGPoint(x: cx, y: m.neckY), CGPoint(x: cx, y: m.hipY))
        case .rectOutline:
            pts = rectLoop(cx - hw, m.shoulderY, cx + hw, m.hipY)
        case .roundedBlob:
            pts = tube(CGPoint(x: cx, y: m.shoulderY), CGPoint(x: cx, y: m.hipY), wa: hw, wb: hw * 0.85)
        case .trapezoid:
            pts = polyline([CGPoint(x: cx - hw, y: m.shoulderY), CGPoint(x: cx + hw, y: m.shoulderY),
                            CGPoint(x: cx + hw * 0.6, y: m.hipY), CGPoint(x: cx - hw * 0.6, y: m.hipY),
                            CGPoint(x: cx - hw, y: m.shoulderY)], n: 10)
        case .ovalBody:
            pts = ellipse(CGPoint(x: cx, y: (m.shoulderY + m.hipY) / 2), hw, (m.hipY - m.shoulderY) / 2)
        case .openTaperOutline:
            // An OPEN ∪ whose two free ends are the SHOULDERS: down the tapering left wall,
            // around the hip bottom, back up the right wall. The endpoint geometry is exactly
            // what limbPairJunction looks for in a both-limbs stroke (two free tips on opposite
            // sides of the spine) — a misfire splits the whole body into two counter-rotating arms.
            pts = polyline([CGPoint(x: cx - hw, y: m.shoulderY),
                            CGPoint(x: cx - hw * 0.62, y: m.hipY - m.u * 0.15),
                            CGPoint(x: cx, y: m.hipY + m.u * 0.12),
                            CGPoint(x: cx + hw * 0.62, y: m.hipY - m.u * 0.15),
                            CGPoint(x: cx + hw, y: m.shoulderY)], n: 12)
        case .hourglass:
            // Pinched waist: the 30th-percentile waist measurement under-reads the shoulder
            // width, shrinking every torso-band gate that divides arm from torso.
            let midY = (m.shoulderY + m.hipY) / 2
            pts = polyline([CGPoint(x: cx - hw, y: m.shoulderY), CGPoint(x: cx + hw, y: m.shoulderY),
                            CGPoint(x: cx + hw * 0.45, y: midY), CGPoint(x: cx + hw * 0.95, y: m.hipY),
                            CGPoint(x: cx - hw * 0.95, y: m.hipY), CGPoint(x: cx - hw * 0.45, y: midY),
                            CGPoint(x: cx - hw, y: m.shoulderY)], n: 8)
        }
        return [LabeledStroke(points: pts, part: .torso)]
    }

    /// `side` = -1 left, +1 right. Returns the matching arm part.
    static func arm(_ v: ArmVariant, side: CGFloat, _ m: Metrics) -> [LabeledStroke] {
        let part: BodyPart = side < 0 ? .leftArm : .rightArm
        let sh = CGPoint(x: m.cx + side * m.shoulderHalfW, y: m.shoulderY)
        let u = m.u
        let pts: [CGPoint]
        switch v {
        case .lineDown:
            pts = line(sh, CGPoint(x: sh.x + side * u * 1.1, y: sh.y + u * 1.7))
        case .lineT:
            pts = line(sh, CGPoint(x: sh.x + side * u * 1.9, y: sh.y + u * 0.15))
        case .outlineMitten:
            let hand = CGPoint(x: sh.x + side * u * 1.0, y: sh.y + u * 1.7)
            pts = tube(sh, hand, wa: u * 0.32, wb: u * 0.42)
        case .bentLine:
            let elbow = CGPoint(x: sh.x + side * u * 0.9, y: sh.y + u * 0.9)
            pts = polyline([sh, elbow, CGPoint(x: elbow.x + side * u * 0.2, y: elbow.y + u * 1.0)])
        case .lowAttach:
            // Roots offset DOWN the torso (the reported "arms drawn offset" case): the near-root
            // points sit inside the torso band, so without arm consolidation the stroke splits
            // torso|arm and stretches when the arm swings.
            // Offset is capped at 45% of the trunk so a SHORT torso still gets an arm, not a
            // hip-rooted line (the baseline trunk is 3u, where 1.1u is the binding value).
            let root = CGPoint(x: m.cx + side * m.shoulderHalfW * 0.5, y: m.shoulderY + min(u * 1.1, (m.hipY - m.shoulderY) * 0.45))
            pts = line(root, CGPoint(x: root.x + side * u * 1.2, y: root.y + u * 1.1))
        case .handOnHip:
            // Akimbo: a GENUINE arm that ends at the hip — the false-positive stressor for any
            // "arm near the hip is implausible" rule (only the ROOT height distinguishes it
            // from a hip-rooted mislabel).
            let elbow = CGPoint(x: sh.x + side * u * 0.85, y: sh.y + u * 0.85)
            let hand = CGPoint(x: m.cx + side * max(m.shoulderHalfW * 0.6, u * 0.12), y: m.hipY - u * 0.12)
            pts = polyline([sh, elbow, hand])
        case .raisedFist:
            // Raised beside the head + a fist blob at the tip: stresses the head detector
            // (a roundish blob in the top band) and the raised-tip reclaim.
            let fistC = CGPoint(x: sh.x + side * u * 0.8, y: m.headCenter.y)
            return [LabeledStroke(points: line(sh, fistC), part: part),
                    LabeledStroke(points: ellipse(fistC, u * 0.16, u * 0.16), part: part)]
        case .twoStroke:
            // The forearm stroke ROOTS at the elbow — in the lower body on a short torso —
            // and must never be mistaken for a leg (it would pull the hip up to the elbows).
            let elbow = CGPoint(x: sh.x + side * u * 0.8, y: sh.y + u * 0.8)
            let hand = CGPoint(x: elbow.x + side * u * 0.3, y: elbow.y + u * 0.9)
            return [LabeledStroke(points: line(sh, elbow), part: part),
                    LabeledStroke(points: line(elbow, hand), part: part)]
        case .crossBody:
            // Crosses the spine: the far half reads as the OTHER side's arm per point, and the
            // both-arms-in-one-stroke logic must not split one folded arm into two.
            let elbow = CGPoint(x: sh.x + side * u * 0.5, y: sh.y + u * 0.7)
            let hand = CGPoint(x: m.cx - side * max(m.shoulderHalfW * 0.7, u * 0.35), y: m.hipY - u * 0.25)
            pts = polyline([sh, elbow, hand])
        }
        return [LabeledStroke(points: pts, part: part)]
    }

    static func leg(_ v: LegVariant, side: CGFloat, _ m: Metrics) -> [LabeledStroke] {
        let part: BodyPart = side < 0 ? .leftLeg : .rightLeg
        let hip = CGPoint(x: m.cx + side * m.legHalfW, y: m.hipY)
        let u = m.u
        let pts: [CGPoint]
        switch v {
        case .lineStraight:
            pts = line(hip, CGPoint(x: hip.x + side * u * 0.15, y: m.footY))
        case .lineSplay:
            pts = line(hip, CGPoint(x: hip.x + side * u * 0.8, y: m.footY))
        case .outlineTapered:
            pts = tube(hip, CGPoint(x: hip.x + side * u * 0.25, y: m.footY), wa: u * 0.32, wb: u * 0.26)
        case .bentLine:
            let knee = CGPoint(x: hip.x + side * u * 0.2, y: (hip.y + m.footY) / 2)
            pts = polyline([hip, knee, CGPoint(x: knee.x + side * u * 0.3, y: m.footY)])
        case .sideways:
            // BOTH legs veer LEFT (independent of side) — the whole stance is shifted to one
            // side, like the reported drawing. Feet end up offset to the same side of the hips.
            pts = line(hip, CGPoint(x: hip.x - u * 0.95, y: m.footY))
        case .crossed:
            // Legs CROSS the centreline (scissor X): the left-hip leg's foot lands right of
            // centre and vice-versa, so each leg stroke spans the spine x.
            pts = line(hip, CGPoint(x: m.cx - side * u * 0.85, y: m.footY))
        case .steepSplay:
            // Very wide diagonal splay — feet far out to both sides (steep from vertical).
            pts = line(hip, CGPoint(x: hip.x + side * u * 1.5, y: m.footY))
        case .sideOutline:
            // Outline-tube legs both veering to one side (outline form of `.sideways`).
            pts = tube(hip, CGPoint(x: hip.x - u * 0.85, y: m.footY), wa: u * 0.30, wb: u * 0.24)
        case .monoTube:
            // ONE chunky open tube centred under the spine (both legs drawn as a single mass).
            // Its two wall-ends straddle the spine, so a loose limb-pair clearance can split
            // one leg into a counter-rotating left+right pair. Emitted once (side < 0 only).
            if side > 0 { return [] }
            let top = CGPoint(x: m.cx, y: m.hipY)
            let w = max(m.legHalfW * 1.4, u * 0.7)
            var p = tube(top, CGPoint(x: m.cx + u * 0.1, y: m.footY), wa: w, wb: w * 0.9)
            p.removeLast()                       // leave the loop OPEN (fat, not closed)
            return [LabeledStroke(points: p, part: .leftLeg)]
        case .twoStroke:
            // Thigh ends at the knee, the shin starts there: the thigh stroke never reaches
            // the ground, so it must be found by CHAINING onto the shin's root.
            let knee = CGPoint(x: hip.x + side * u * 0.25, y: (hip.y + m.footY) / 2)
            return [LabeledStroke(points: line(hip, knee), part: part),
                    LabeledStroke(points: line(knee, CGPoint(x: knee.x + side * u * 0.2, y: m.footY)), part: part)]
        }
        return [LabeledStroke(points: pts, part: part)]
    }

    static func decorations(_ d: Decorations, _ m: Metrics, spec: FigureSpec) -> [LabeledStroke] {
        var out: [LabeledStroke] = []
        let c = m.headCenter, u = m.u
        if d.contains(.ears) {
            let lx = c.x - m.headRX * 0.6, rx = c.x + m.headRX * 0.6, ty = c.y - m.headRY
            out.append(LabeledStroke(points: polyline([CGPoint(x: lx - u * 0.2, y: ty + u * 0.1),
                                                       CGPoint(x: lx, y: ty - u * 0.6),
                                                       CGPoint(x: lx + u * 0.2, y: ty + u * 0.05)]), part: .head))
            out.append(LabeledStroke(points: polyline([CGPoint(x: rx - u * 0.2, y: ty + u * 0.05),
                                                       CGPoint(x: rx, y: ty - u * 0.6),
                                                       CGPoint(x: rx + u * 0.2, y: ty + u * 0.1)]), part: .head))
        }
        if d.contains(.face) {
            out.append(LabeledStroke(points: ellipse(CGPoint(x: c.x - m.headRX * 0.35, y: c.y - m.headRY * 0.15), u * 0.06, u * 0.06), part: .head))
            out.append(LabeledStroke(points: ellipse(CGPoint(x: c.x + m.headRX * 0.35, y: c.y - m.headRY * 0.15), u * 0.06, u * 0.06), part: .head))
            // zigzag / smile mouth
            out.append(LabeledStroke(points: polyline([CGPoint(x: c.x - m.headRX * 0.45, y: c.y + m.headRY * 0.3),
                                                       CGPoint(x: c.x - m.headRX * 0.15, y: c.y + m.headRY * 0.5),
                                                       CGPoint(x: c.x + m.headRX * 0.15, y: c.y + m.headRY * 0.5),
                                                       CGPoint(x: c.x + m.headRX * 0.45, y: c.y + m.headRY * 0.3)]), part: .head))
        }
        if d.contains(.hair) {
            let ty = c.y - m.headRY
            for k in -1...1 {
                let x = c.x + CGFloat(k) * m.headRX * 0.4
                out.append(LabeledStroke(points: line(CGPoint(x: x, y: ty + u * 0.1),
                                                      CGPoint(x: x + CGFloat(k) * u * 0.2, y: ty - u * 0.5)), part: .head))
            }
        }
        if d.contains(.neck) {
            // a neck line from the head's bottom down into the torso top — rides with the torso
            out.append(LabeledStroke(points: line(CGPoint(x: c.x, y: c.y + m.headRY - u * 0.05),
                                                  CGPoint(x: c.x, y: m.shoulderY + u * 0.15)), part: .torso))
        }
        if d.contains(.hands), spec.arm != .handOnHip, spec.arm != .raisedFist {
            for side: CGFloat in [-1, 1] {
                let sh = CGPoint(x: m.cx + side * m.shoulderHalfW, y: m.shoulderY)
                let hand = CGPoint(x: sh.x + side * u * 1.0, y: sh.y + u * 1.7)
                out.append(LabeledStroke(points: ellipse(hand, u * 0.18, u * 0.18),
                                         part: side < 0 ? .leftArm : .rightArm))
            }
        }
        if d.contains(.feet), spec.leg != .monoTube {
            for side: CGFloat in [-1, 1] where !(spec.oneLeg && side > 0) {
                let hip = CGPoint(x: m.cx + side * m.legHalfW, y: m.hipY)
                let foot = CGPoint(x: hip.x + side * u * 0.25, y: m.footY)
                out.append(LabeledStroke(points: line(foot, CGPoint(x: foot.x + side * u * 0.5, y: foot.y)),
                                         part: side < 0 ? .leftLeg : .rightLeg))
            }
        }
        if d.contains(.belt) {
            // Hip-lateral ink that belongs to the BODY: a waist/belt line just above the hip.
            // Overhang past the torso band is the classic "hip area becomes an arm" bait.
            let bw = max(m.shoulderHalfW * 0.65, u * 0.5)
            let y = m.hipY - u * 0.35
            out.append(LabeledStroke(points: line(CGPoint(x: m.cx - bw, y: y),
                                                  CGPoint(x: m.cx + bw, y: y)), part: .torso))
        }
        if d.contains(.tail) {
            // A curl out one side from the hip — hip-rooted, laterally extended, torso-truth.
            out.append(LabeledStroke(points: polyline([
                CGPoint(x: m.cx + m.shoulderHalfW * 0.4, y: m.hipY - u * 0.1),
                CGPoint(x: m.cx + m.shoulderHalfW * 0.4 + u * 0.75, y: m.hipY + u * 0.2),
                CGPoint(x: m.cx + m.shoulderHalfW * 0.4 + u * 1.2, y: m.hipY - u * 0.3)]), part: .torso))
        }
        if d.contains(.hat) {
            // Brim + crown ON the head top: a compact-ish stroke ABOVE the head that can bait
            // the head detector (head-seed stressor).
            let ty = c.y - m.headRY - u * 0.05
            out.append(LabeledStroke(points: line(CGPoint(x: c.x - m.headRX * 0.9, y: ty),
                                                  CGPoint(x: c.x + m.headRX * 0.9, y: ty)), part: .head))
            out.append(LabeledStroke(points: polyline([
                CGPoint(x: c.x - m.headRX * 0.5, y: ty),
                CGPoint(x: c.x - m.headRX * 0.45, y: ty - u * 0.8),
                CGPoint(x: c.x + m.headRX * 0.45, y: ty - u * 0.8),
                CGPoint(x: c.x + m.headRX * 0.5, y: ty)]), part: .head))
        }
        return out
    }

    // ---- compose --------------------------------------------------------

    private static func metrics(for spec: FigureSpec, canvas: CGSize) -> Metrics {
        let u = 46 * spec.scale
        var headRY = u * 1.0
        var headRX = u * 1.0
        switch spec.head {
        case .circle:      headRX = u * 1.0; headRY = u * 1.0
        case .bigCircle:   headRX = u * 1.7; headRY = u * 1.7
        case .smallCircle: headRX = u * 0.6; headRY = u * 0.6
        case .wideOval:    headRX = u * 1.6; headRY = u * 0.95
        case .tallOval:    headRX = u * 0.85; headRY = u * 1.4
        case .openArc:     headRX = u * 1.0; headRY = u * 1.0
        }
        let cx = canvas.width * 0.5
        let topY = canvas.height * 0.16
        let headCenter = CGPoint(x: cx, y: topY + headRY)
        let neckY = headCenter.y + headRY
        let shoulderY = neckY + u * 0.3
        // Fuller torsos are wide; a spine line is essentially zero-width (arms hang off the spine).
        let shoulderHalfW: CGFloat = spec.torso == .spineLine ? u * 0.12 : u * 0.95
        let bodyLen = u * spec.torsoLen
        let hipY = shoulderY + bodyLen
        let legHalfW = u * 0.5
        let footY = hipY + u * spec.legLen
        return Metrics(cx: cx, headCenter: headCenter, headRX: headRX, headRY: headRY,
                       neckY: neckY, shoulderY: shoulderY, shoulderHalfW: shoulderHalfW,
                       hipY: hipY, legHalfW: legHalfW, footY: footY, u: u)
    }

    /// Build the figure: returns the PKDrawing fed to the fitter + the per-stroke
    /// ground-truth parts (index-aligned with the drawing's strokes).
    static func build(_ spec: FigureSpec, canvas: CGSize) -> (drawing: PKDrawing, truth: [TruthLabel]) {
        let m = metrics(for: spec, canvas: canvas)
        var labeled: [LabeledStroke] = []
        labeled += head(spec.head, m)
        let torsoStrokes = torso(spec.torso, m)
        let leftLeg = leg(spec.leg, side: -1, m)
        if spec.lambdaLeg, spec.torso == .spineLine, torsoStrokes.count == 1, leftLeg.count == 1, !spec.leg.isOutline {
            // λ body: neck → hip → left foot in ONE pen stroke (a very common way to draw it).
            labeled.append(LabeledStroke(points: torsoStrokes[0].points + leftLeg[0].points, part: .torso, truth: .spineLeg))
        } else {
            labeled += torsoStrokes
            labeled += leftLeg
        }
        labeled += arm(spec.arm, side: -1, m)
        labeled += arm(spec.arm, side: 1, m)
        if !spec.oneLeg { labeled += leg(spec.leg, side: 1, m) }
        labeled += decorations(spec.deco, m, spec: spec)

        // Apply lean (horizontal shear about the head) + hand-drawn wobble.
        var rng = LCG(spec.seed)
        let pivotY = m.headCenter.y
        let ink = PKInk(.pen, color: UIColor(red: 0.95, green: 0.27, blue: 0.13, alpha: 1))
        let width = max(m.u * 0.12, 4) * spec.penScale
        var strokes: [PKStroke] = []
        var truth: [TruthLabel] = []
        for ls in labeled {
            let pts = ls.points.map { p -> CGPoint in
                var q = p
                q.x += spec.lean * (q.y - pivotY)
                if spec.wobble > 0 {
                    q.x += rng.range(-spec.wobble, spec.wobble)
                    q.y += rng.range(-spec.wobble, spec.wobble)
                }
                return q
            }
            strokes.append(makeStroke(pts, ink: ink, width: width))
            truth.append(ls.truth ?? .part(ls.part))
        }
        return (PKDrawing(strokes: strokes), truth)
    }

    private static func makeStroke(_ pts: [CGPoint], ink: PKInk, width: CGFloat) -> PKStroke {
        let size = CGSize(width: width, height: width)
        let points = pts.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: size,
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
}

// MARK: - Scoring + report

enum RigHarness {

    /// Coarse part group (side-aware) — what the animation actually cares about.
    private static func group(_ p: BodyPart) -> String {
        switch p {
        case .head: return "head"
        case .torso: return "torso"
        case .leftArm, .leftForearm: return "Larm"
        case .rightArm, .rightForearm: return "Rarm"
        case .leftLeg, .leftShin: return "Lleg"
        case .rightLeg, .rightShin: return "Rleg"
        }
    }
    // Side-insensitive group (mirror swaps are far less catastrophic than torso↔arm tears).
    private static func limb(_ g: String) -> String {
        switch g {
        case "Larm", "Rarm": return "arm"
        case "Lleg", "Rleg": return "leg"
        default: return g
        }
    }

    // MARK: - Spec populations

    /// The ORIGINAL variant lists (the baseline). The cross product + randomized batch MUST
    /// keep using exactly these — adding the adversarial cases to them would change every
    /// seeded `rng.pick` and silently rebase the whole 1900-figure baseline.
    private static let coreHeads: [HeadVariant] = [.circle, .bigCircle, .smallCircle, .wideOval, .tallOval, .openArc]
    private static let coreTorsos: [TorsoVariant] = [.spineLine, .rectOutline, .roundedBlob, .trapezoid, .ovalBody]
    private static let coreArms: [ArmVariant] = [.lineDown, .lineT, .outlineMitten, .bentLine, .lowAttach]
    private static let coreLegs: [LegVariant] = [.lineStraight, .lineSplay, .outlineTapered, .bentLine,
                                                 .sideways, .crossed, .steepSplay, .sideOutline]

    private static func cleanSpecs() -> [FigureSpec] {
        var specs: [FigureSpec] = []
        // Deterministic cross product of the core variants (no deco / lean / wobble) —
        // isolates which part SHAPE breaks the fitter.
        var sid: UInt64 = 1
        for h in coreHeads {
            for t in coreTorsos {
                for a in coreArms {
                    for l in coreLegs {
                        // A touch of wobble/lean even here: real drawings are never perfectly
                        // symmetric, and a pixel-exact centred spine hits degenerate ties.
                        specs.append(FigureSpec(head: h, torso: t, arm: a, leg: l,
                                                lean: 0.02, wobble: 1.5, seed: sid)); sid += 1
                    }
                }
            }
        }
        // Randomized realistic figures: decorations + lean + wobble + scale.
        var rng = LCG(0xA11CE)
        for _ in 0..<700 {
            var deco: Decorations = []
            if rng.bool(0.5) { deco.insert(.face) }
            if rng.bool(0.25) { deco.insert(.ears) }
            if rng.bool(0.3) { deco.insert(.hands) }
            if rng.bool(0.3) { deco.insert(.feet) }
            if rng.bool(0.2) { deco.insert(.hair) }
            if rng.bool(0.3) { deco.insert(.neck) }
            specs.append(FigureSpec(
                head: rng.pick(coreHeads),
                torso: rng.pick(coreTorsos),
                arm: rng.pick(coreArms),
                leg: rng.pick(coreLegs),
                deco: deco,
                lean: rng.range(-0.18, 0.18),
                scale: rng.range(0.75, 1.45),
                wobble: rng.bool(0.5) ? rng.range(0, 4) : 0,
                seed: sid)); sid += 1
        }
        return specs
    }

    /// Outlier stressors — belts/tails at the hip, hats/fists at the head, open torso
    /// outlines, hourglass waists, mono-tube legs, thick pens, one-legged figures. Failures
    /// here are EXPECTED at first: this batch exists to measure the holes before fixing them,
    /// so it is scored as its own population and never gates the clean baseline.
    private static func adversarialSpecs() -> [FigureSpec] {
        let torsos = coreTorsos + [.openTaperOutline, .hourglass]
        let arms = coreArms + [.handOnHip, .raisedFist, .twoStroke, .crossBody]
        let legs = coreLegs + [.monoTube, .twoStroke]
        var specs: [FigureSpec] = []
        var rng = LCG(0xBADD1E)
        var sid: UInt64 = 100_000
        for _ in 0..<400 {
            var deco: Decorations = []
            if rng.bool(0.4) { deco.insert(.face) }
            if rng.bool(0.3) { deco.insert(.belt) }
            if rng.bool(0.25) { deco.insert(.tail) }
            if rng.bool(0.15) { deco.insert(.hat) }
            if rng.bool(0.2) { deco.insert(.hands) }
            if rng.bool(0.2) { deco.insert(.feet) }
            if rng.bool(0.2) { deco.insert(.neck) }
            var spec = FigureSpec(
                head: rng.pick(coreHeads),
                torso: rng.pick(torsos),
                arm: rng.pick(arms),
                leg: rng.pick(legs),
                deco: deco,
                lean: rng.range(-0.15, 0.15),
                scale: rng.range(0.8, 1.35),
                wobble: rng.bool(0.5) ? rng.range(0, 3.5) : 0,
                seed: sid)
            if rng.bool(0.25) { spec.penScale = 2.5 }
            if rng.bool(0.08) { spec.oneLeg = true }
            specs.append(spec); sid += 1
        }
        return specs
    }

    /// Body PROPORTIONS sweep — the axis the baseline never varies. Short torsos / long legs
    /// put the crotch at 28–45% of neck→feet (the baseline is pinned at ~56%), with the
    /// common λ body (spine + one leg in a single stroke), thin and thick pens. The reported
    /// "part of the leg became the arm" lives here: a leg root above the fitter's lower-body
    /// gates reads as an arm root. Gated like the clean set once fixed.
    private static func proportionSpecs() -> [FigureSpec] {
        var specs: [FigureSpec] = []
        var rng = LCG(0x5151A7)
        var sid: UInt64 = 200_000
        let legs: [LegVariant] = [.lineStraight, .lineSplay, .bentLine, .sideways, .crossed, .steepSplay, .outlineTapered, .twoStroke]
        let arms: [ArmVariant] = coreArms + [.twoStroke, .crossBody]
        for _ in 0..<600 {
            var deco: Decorations = []
            if rng.bool(0.4) { deco.insert(.face) }
            if rng.bool(0.2) { deco.insert(.hands) }
            if rng.bool(0.2) { deco.insert(.feet) }
            if rng.bool(0.2) { deco.insert(.neck) }
            var spec = FigureSpec(
                head: rng.pick(coreHeads),
                torso: rng.bool(0.6) ? .spineLine : rng.pick(coreTorsos),
                arm: rng.pick(arms),
                leg: rng.pick(legs),
                deco: deco,
                lean: rng.range(-0.12, 0.12),
                scale: rng.range(0.45, 1.4),       // down to a SMALL figure (pen weight dominates)
                wobble: rng.bool(0.5) ? rng.range(0, 3) : 0,
                seed: sid)
            spec.torsoLen = rng.range(1.2, 3.6)
            spec.legLen = rng.range(2.0, 4.6)
            if rng.bool(0.3) { spec.penScale = rng.range(1.6, 2.8) }
            if rng.bool(0.35) { spec.lambdaLeg = true }
            specs.append(spec); sid += 1
        }
        return specs
    }

    // MARK: - Per-figure scoring (shared by the generated suites and the hand-built fixtures)

    struct FigureResult {
        var strokeTotal = 0
        var strokeOK = 0
        var figOK = true
        var mismatch = false                     // fitter stroke count != truth count
        var failParts: [String] = []             // "torso->Larm"
        var confusion: [(String, String)] = []   // (intended, predicted majority)
        var torsoStrokes = 0, torsoAsArm = 0
        var legStrokes = 0, legAsArm = 0
        var legSplitArm = 0                      // a leg stroke carrying a real run of ARM labels
        var outlineLimbStrokes = 0, outlineLimbTorn = 0
        var armMassFraction: CGFloat = 0         // arm-labelled pts / non-head pts (rig-only)
        var bothArmsSameSide = false
        var validatorDemotions = 0
        var validatorFPs = 0                     // a demotion that undid truth-correct limb labels
    }

    /// Score one fitted rig against ground truth. `outline[i]` marks strokes drawn as outline
    /// limbs (the tear metric applies only to those); pass [] to skip tear checks. The rules
    /// are unchanged from the original inline scorer: the stroke's MAJORITY must land in the
    /// right side-insensitive limb group with concentration >= 0.55 (minor near-joint leakage
    /// is invisible when animated — points near a pivot barely move), a neck-zone torso↔head
    /// confusion is forgiven (both ride the head pivot), and a `.armPair`/`.legPair` stroke is
    /// correct iff the fitter split it into BOTH sides (each >= 25% of points, foreign <= 20%).
    private static func scoreFigure(_ rig: Rig, truth: [TruthLabel], outline: [Bool] = []) -> FigureResult {
        var res = FigureResult()
        // Validator bookkeeping: a demotion is a FALSE POSITIVE when it froze a limb whose
        // pre-demotion majority already matched the truth (the net undid a correct rig).
        res.validatorDemotions = rig.demotions.count
        for d in rig.demotions {
            for (k, si) in d.strokes.enumerated() {
                guard si < truth.count, k < d.preMajorities.count else { continue }
                let intendedLimb: String
                switch truth[si] {
                case .part(let p): intendedLimb = limb(group(p))
                case .armPair: intendedLimb = "arm"
                case .legPair: intendedLimb = "leg"
                case .spineLeg: intendedLimb = "torso"   // a λ stroke is torso-majority; a leg demotion on it is not scored as FP
                }
                if (intendedLimb == "arm" || intendedLimb == "leg"),
                   limb(group(d.preMajorities[k])) == intendedLimb {
                    res.validatorFPs += 1
                    break
                }
            }
        }
        guard rig.strokes.count == truth.count else {
            res.mismatch = true
            res.figOK = false
            return res
        }
        for (i, rs) in rig.strokes.enumerated() {
            res.strokeTotal += 1
            var counts: [String: Int] = [:]
            for p in rs.parts { counts[group(p), default: 0] += 1 }
            let majority = counts.max { $0.value < $1.value }?.key ?? "torso"
            let n = max(rs.parts.count, 1)
            let concentration = CGFloat(counts[majority] ?? 0) / CGFloat(n)

            let correct: Bool
            let intendedKey: String
            switch truth[i] {
            case .part(let part):
                let intended = group(part)
                intendedKey = intended
                let midY = rs.points.reduce(0) { $0 + $1.y } / CGFloat(max(rs.points.count, 1))
                let inNeckZone = midY < rig.skeleton.bbox.minY + rig.skeleton.bbox.height * 0.42
                let neckOK = inNeckZone && ((intended == "torso" && majority == "head") || (intended == "head" && majority == "torso"))
                correct = (limb(majority) == limb(intended) && concentration >= 0.55) || neckOK
                if part == .torso {
                    res.torsoStrokes += 1
                    if limb(majority) == "arm" { res.torsoAsArm += 1 }
                }
                if part == .leftLeg || part == .rightLeg || part == .leftShin || part == .rightShin {
                    res.legStrokes += 1
                    if limb(majority) == "arm" { res.legAsArm += 1 }
                    // PART of a leg labelled arm — the reported "leg top swings up as an arm":
                    // the majority may still be leg, but any real run of arm points on a leg
                    // stroke animates as a limb hanging off the hip.
                    let armN = (counts["Larm"] ?? 0) + (counts["Rarm"] ?? 0)
                    if armN * 12 > n { res.legSplitArm += 1 }
                }
                if (part == .leftArm || part == .rightArm || part == .leftLeg || part == .rightLeg),
                   i < outline.count, outline[i] {
                    res.outlineLimbStrokes += 1
                    if concentration < 0.7 { res.outlineLimbTorn += 1 }
                }
            case .armPair:
                intendedKey = "armP"
                let l = counts["Larm"] ?? 0, r = counts["Rarm"] ?? 0
                let armN = l + r
                let headN = counts["head"] ?? 0, legN = (counts["Lleg"] ?? 0) + (counts["Rleg"] ?? 0)
                // Both sides must be substantially present (a collapse onto one side is THE
                // failure this truth kind exists to catch). Torso leakage where the stroke
                // crosses the trunk is benign — those points sit near the pivots and barely
                // move — but head/leg leakage is a real bind error.
                correct = armN * 2 >= n && min(l, r) * 4 >= armN && headN * 10 <= n && legN * 10 <= n
            case .legPair:
                intendedKey = "legP"
                let l = counts["Lleg"] ?? 0, r = counts["Rleg"] ?? 0
                let legN = l + r
                let headN = counts["head"] ?? 0, armN = (counts["Larm"] ?? 0) + (counts["Rarm"] ?? 0)
                correct = legN * 2 >= n && min(l, r) * 4 >= legN && headN * 10 <= n && armN * 10 <= n
            case .spineLeg:
                // λ body: the spine running straight on into a leg. The lower part must be a
                // leg, the rest torso (or head at the neck) — and NEVER an arm.
                intendedKey = "spLeg"
                let legN = (counts["Lleg"] ?? 0) + (counts["Rleg"] ?? 0)
                let armN = (counts["Larm"] ?? 0) + (counts["Rarm"] ?? 0)
                res.legStrokes += 1
                if armN * 12 > n { res.legSplitArm += 1 }
                if limb(majority) == "arm" { res.legAsArm += 1 }
                correct = legN * 5 >= n && armN * 12 <= n
            }
            res.confusion.append((intendedKey, majority))
            if correct { res.strokeOK += 1 } else { res.figOK = false; res.failParts.append("\(intendedKey)->\(majority)") }
        }

        // Rig-wide arm plausibility metrics (labels + skeleton only — no ground truth, so the
        // same definitions can run on a real user drawing).
        var armPts = 0, nonHead = 0
        var lSum: CGFloat = 0, rSum: CGFloat = 0
        var lN = 0, rN = 0
        let sk = rig.skeleton
        let trunkDY = max(sk.hipCenter.y - sk.neck.y, 1)
        for s in rig.strokes {
            for (j, p) in s.points.enumerated() {
                let part = s.parts[j]
                if part != .head { nonHead += 1 }
                switch part {
                case .leftArm, .leftForearm, .rightArm, .rightForearm:
                    armPts += 1
                    // signed offset vs the lean-tracking neck→hip centreline
                    let f = min(max((p.y - sk.neck.y) / trunkDY, 0), 1)
                    let cx = sk.neck.x + (sk.hipCenter.x - sk.neck.x) * f
                    if part == .leftArm || part == .leftForearm { lSum += p.x - cx; lN += 1 }
                    else { rSum += p.x - cx; rN += 1 }
                default: break
                }
            }
        }
        res.armMassFraction = nonHead == 0 ? 0 : CGFloat(armPts) / CGFloat(nonHead)
        if lN > 0, rN > 0 {
            let lm = lSum / CGFloat(lN), rm = rSum / CGFloat(rN)
            let thresh = max(6, sk.bbox.width * 0.08)
            res.bothArmsSameSide = (lm > thresh && rm > thresh) || (lm < -thresh && rm < -thresh)
        }
        return res
    }

    /// Worst animated-bbox extent ÷ rest extent across one routine (the fling detector —
    /// translation preserves extent; only a bad pivot/mislabel blows it up).
    private static func explosionRatio(_ rig: Rig, slot: AnimationSlot, bounds: CGRect,
                                       topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let origExtent = max(rig.skeleton.bbox.width, rig.skeleton.bbox.height)
        guard origExtent > 1 else { return 1 }
        let setup = RoutineSetup.make(rig: rig, canvasBounds: bounds, contentOffset: .zero,
                                      topInset: topInset, bottomInset: bottomInset)
        let routine = AnimationFactory.make(slot, setup)
        var worst: CGFloat = 1
        var t = 0.0
        while t <= routine.totalDuration + 0.001 {
            let pose = routine.pose(at: t)
            var lo = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
            var hi = CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude)
            for s in rig.strokes {
                for (j, p) in s.points.enumerated() {
                    let w = rig.worldPoint(p, part: s.parts[j], pose: pose)
                    lo.x = min(lo.x, w.x); lo.y = min(lo.y, w.y); hi.x = max(hi.x, w.x); hi.y = max(hi.y, w.y)
                }
            }
            worst = max(worst, max(hi.x - lo.x, hi.y - lo.y) / origExtent)
            t += 0.5
        }
        return worst
    }

    private static func isOutlinePart(_ spec: FigureSpec, _ part: BodyPart) -> Bool {
        switch part {
        case .leftArm, .rightArm: return spec.arm.isOutline
        case .leftLeg, .rightLeg: return spec.leg.isOutline
        default: return false
        }
    }

    // MARK: - Suite evaluation

    private struct SuiteStats {
        var figures = 0, figuresOK = 0
        var strokeTotal = 0, strokeOK = 0
        var torsoStrokes = 0, torsoAsArm = 0
        var legStrokes = 0, legAsArm = 0, legSplitArm = 0
        var outlineLimbStrokes = 0, outlineLimbTorn = 0
        var mismatches = 0
        var armDominant = 0                      // armMassFraction > 0.55
        var armMassSum: CGFloat = 0
        var bothArmsSameSide = 0
        var animExplode = 0
        var slotExplode: [String: Int] = [:]
        var tagFail: [String: (n: Int, fail: Int)] = [:]
        var tagExplode: [String: (n: Int, fail: Int)] = [:]
        var confusion: [String: [String: Int]] = [:]
        var examples: [String] = []
        var animExamples: [String] = []
        var validatorDemotions = 0               // wired up by the plausibility validator
        var validatorFPs = 0                     // demotions that hit truth-correct labels
        var demotionReasons: [String: Int] = [:] // which plausibility check fired
    }

    private static let explosionInsets: (top: CGFloat, bottom: CGFloat) = (130, 96)   // worst-case Notes chrome

    private static func evaluate(_ title: String, specs: [FigureSpec],
                                 canvas: CGSize, traits: UITraitCollection,
                                 dumpFailures prefix: String? = nil) -> String {
        let animBounds = CGRect(origin: .zero, size: canvas)
        var st = SuiteStats()
        var dumped = 0
        var failingSeeds: [UInt64] = []
        for (figIndex, spec) in specs.enumerated() {
            let (drawing, truth) = RigPartLibrary.build(spec, canvas: canvas)
            let rig = RigFitter.fit(drawing, traits: traits)
            st.figures += 1
            defer {
                // Optional per-failure rig render (part colours + joints) for eyeballing a set.
                if let prefix, dumped < 40, let last = st.examples.last, last.contains("seed=\(spec.seed)") || st.animExamples.last?.contains("seed=\(spec.seed)") == true {
                    dumped += 1
                    writeImage(renderRig(rig, pose: .rest(rig.skeleton), size: canvas, partColors: true, joints: true), "\(prefix)_\(spec.seed).png")
                    RigFitter.trace = ""
                    _ = RigFitter.fit(drawing, traits: traits)
                    let tr = RigFitter.trace ?? ""
                    RigFitter.trace = nil
                    let d = "\(spec.tags.joined(separator: ","))\n truth: " + truth.enumerated().map { "\($0.offset)=\($0.element)" }.joined(separator: " ") + "\n" + diagText(rig) + "TRACE\n" + tr
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("\(prefix)_\(spec.seed).txt")
                    try? d.data(using: .utf8)?.write(to: url)
                }
            }

            // --- animation explosion: EVERY routine, realistic chrome insets ---
            var explodedSlots: [String] = []
            for slot in AnimationSlot.playable {
                let ratio = explosionRatio(rig, slot: slot, bounds: animBounds,
                                           topInset: explosionInsets.top, bottomInset: explosionInsets.bottom)
                if ratio > 2.2 {
                    explodedSlots.append("\(slot)")
                    st.slotExplode["\(slot)", default: 0] += 1
                }
            }
            let exploded = !explodedSlots.isEmpty
            if exploded { st.animExplode += 1 }
            for tag in spec.tags { st.tagExplode[tag, default: (0, 0)].n += 1; if exploded { st.tagExplode[tag]!.fail += 1 } }
            if exploded && st.animExamples.count < 40 {
                st.animExamples.append("seed=\(spec.seed) [\(explodedSlots.joined(separator: ","))] [\(spec.tags.joined(separator: ","))]")
            }

            // --- label scoring ---
            let outline = truth.map { t -> Bool in if case .part(let p) = t { return isOutlinePart(spec, p) } else { return false } }
            let res = scoreFigure(rig, truth: truth, outline: outline)
            st.strokeTotal += res.strokeTotal; st.strokeOK += res.strokeOK
            st.torsoStrokes += res.torsoStrokes; st.torsoAsArm += res.torsoAsArm
            st.legStrokes += res.legStrokes; st.legAsArm += res.legAsArm; st.legSplitArm += res.legSplitArm
            st.outlineLimbStrokes += res.outlineLimbStrokes; st.outlineLimbTorn += res.outlineLimbTorn
            if res.mismatch { st.mismatches += 1 }
            st.armMassSum += res.armMassFraction
            if res.armMassFraction > 0.55 { st.armDominant += 1 }
            if res.bothArmsSameSide { st.bothArmsSameSide += 1 }
            st.validatorDemotions += res.validatorDemotions
            st.validatorFPs += res.validatorFPs
            for d in rig.demotions {
                st.demotionReasons[d.reason.components(separatedBy: "(")[0], default: 0] += 1
            }
            for (a, b) in res.confusion { st.confusion[a, default: [:]][b, default: 0] += 1 }
            if res.figOK { st.figuresOK += 1 } else { failingSeeds.append(spec.seed) }
            for tag in spec.tags {
                st.tagFail[tag, default: (0, 0)].n += 1
                if !res.figOK { st.tagFail[tag]!.fail += 1 }
            }
            // Sample failures across the WHOLE range (not just early circle-head seeds), plus
            // always grab a few eared ones (they live only in the randomized tail).
            let sampled = !res.figOK && (figIndex % 19 == 0 || prefix != nil || (spec.deco.contains(.ears) && st.examples.count < 56))
            if sampled && st.examples.count < 60 {
                st.examples.append(res.mismatch
                    ? "STROKE-COUNT MISMATCH seed=\(spec.seed) \(spec.tags.joined(separator: ","))"
                    : "seed=\(spec.seed) conf=\(String(format: "%.2f", rig.confidence)) art=\(rig.articulated) [\(spec.tags.joined(separator: ","))]  fails: \(res.failParts.prefix(6).joined(separator: " "))"
                      + (rig.demotions.isEmpty ? "" : "  demoted: " + rig.demotions.map { "\($0.side):\($0.reason)" }.joined(separator: " ")))
            }
        }

        // ---- section report ----
        var r = "\(title)\n" + String(repeating: "-", count: title.count) + "\n"
        r += "figures: \(st.figures)   figuresFullyCorrect: \(st.figuresOK) (\(pct(st.figuresOK, st.figures)))\n"
        r += "stroke part accuracy: \(st.strokeOK)/\(st.strokeTotal) (\(pct(st.strokeOK, st.strokeTotal)))\n"
        r += "torso strokes mislabeled as ARM: \(st.torsoAsArm)/\(st.torsoStrokes) (\(pct(st.torsoAsArm, st.torsoStrokes)))\n"
        r += "leg strokes mislabeled as ARM: \(st.legAsArm)/\(st.legStrokes) (\(pct(st.legAsArm, st.legStrokes)))\n"
        r += "leg strokes PARTLY labeled ARM (leg top swings as an arm): \(st.legSplitArm)/\(st.legStrokes) (\(pct(st.legSplitArm, st.legStrokes)))\n"
        r += "outline limb strokes TORN (split): \(st.outlineLimbTorn)/\(st.outlineLimbStrokes) (\(pct(st.outlineLimbTorn, st.outlineLimbStrokes)))\n"
        r += "stroke-count MISMATCHES (counted as failed figures): \(st.mismatches)\n"
        let meanMass = st.figures == 0 ? 0 : st.armMassSum / CGFloat(st.figures)
        r += "arm-dominant rigs (arm ink > 55% of body): \(st.armDominant)   mean arm-mass fraction: \(String(format: "%.2f", meanMass))\n"
        r += "both-arms-on-one-side rigs: \(st.bothArmsSameSide)\n"
        let reasonStr = st.demotionReasons.sorted { $0.value > $1.value }
            .map { "\($0.key):\($0.value)" }.joined(separator: " ")
        r += "validator demotions: \(st.validatorDemotions)   validator FALSE POSITIVES: \(st.validatorFPs)"
            + (reasonStr.isEmpty ? "\n" : "   by check: \(reasonStr)\n")
        let slotStr = AnimationSlot.playable.map { "\($0):\(st.slotExplode["\($0)"] ?? 0)" }.joined(separator: " ")
        r += "ANIMATION EXPLODED (any routine, insets \(Int(explosionInsets.top))/\(Int(explosionInsets.bottom))): \(st.animExplode)/\(st.figures) (\(pct(st.animExplode, st.figures)))  per-routine: \(slotStr)\n\n"
        r += "EXPLOSION RATE BY TAG (worst first):\n"
        for (tag, v) in st.tagExplode.sorted(by: { fr($0.value) > fr($1.value) }).prefix(14) {
            let label = tag.padding(toLength: 22, withPad: " ", startingAt: 0)
            r += "  \(label) \(v.fail)/\(v.n)  \(pct(v.fail, v.n))\n"
        }
        r += "EXPLOSION EXAMPLES:\n" + st.animExamples.joined(separator: "\n") + "\n\n"
        r += "FAILURE RATE BY TAG (worst first):\n"
        for (tag, v) in st.tagFail.sorted(by: { fr($0.value) > fr($1.value) }) {
            let label = tag.padding(toLength: 22, withPad: " ", startingAt: 0)
            r += "  \(label) \(v.fail)/\(v.n)  \(pct(v.fail, v.n))\n"
        }
        r += "\nCONFUSION (intended -> predicted majority):\n"
        for (intended, preds) in st.confusion.sorted(by: { $0.key < $1.key }) {
            let parts = preds.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            r += "  \(intended.padding(toLength: 6, withPad: " ", startingAt: 0)) -> \(parts)\n"
        }
        r += "\nEXAMPLE FAILURES:\n" + st.examples.joined(separator: "\n") + "\n"
        r += "ALL FAILING SEEDS: " + failingSeeds.map(String.init).joined(separator: " ") + "\n\n"
        return r
    }

    /// Score the hand-built user fixtures (label pass/fail + explosion across every routine).
    private static func evaluateFixtures(traits: UITraitCollection) -> String {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let fixtures = userFixtures()
        var body = ""
        var pass = 0
        for f in fixtures {
            let rig = RigFitter.fit(PKDrawing(strokes: f.strokes), traits: traits)
            let res = scoreFigure(rig, truth: f.truth)
            var explodedSlots: [String] = []
            for slot in AnimationSlot.playable {
                if explosionRatio(rig, slot: slot, bounds: bounds,
                                  topInset: explosionInsets.top, bottomInset: explosionInsets.bottom) > 2.2 {
                    explodedSlots.append("\(slot)")
                }
            }
            let ok = res.figOK && explodedSlots.isEmpty
            if ok { pass += 1 }
            body += "  \(f.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(ok ? "PASS" : "FAIL")"
            if res.mismatch { body += "  STROKE-COUNT MISMATCH" }
            else if !res.figOK { body += "  labels: \(res.failParts.joined(separator: " "))" }
            if !explodedSlots.isEmpty { body += "  EXPLODES: \(explodedSlots.joined(separator: ","))" }
            if !rig.demotions.isEmpty {
                body += "  demoted: " + rig.demotions.map { "\($0.side):\($0.reason)" }.joined(separator: " ")
            }
            body += "\n"
        }
        var r = "HAND-BUILT FIXTURES (user-reported failures, scored)\n----------------------------------------------------\n"
        r += "FIXTURES: \(pass)/\(fixtures.count) pass\n" + body + "\n"
        return r
    }

    static func run() {
        let canvas = CGSize(width: 390, height: 844)
        let traits = UITraitCollection(userInterfaceStyle: .light)
        var r = "RIG HARNESS REPORT\n==================\n\n"
        r += evaluate("CLEAN SET (baseline-guarded)", specs: cleanSpecs(), canvas: canvas, traits: traits, dumpFailures: "clean_fail")
        r += evaluate("ADVERSARIAL SET (outlier stressors)", specs: adversarialSpecs(), canvas: canvas, traits: traits, dumpFailures: "adv_fail")
        r += evaluate("PROPORTIONS SET (short torso / long legs / λ body)", specs: proportionSpecs(), canvas: canvas, traits: traits, dumpFailures: "prop_fail")
        r += evaluateFixtures(traits: traits)
        write(r)
        dumpVisuals()
    }

    // MARK: - Visual verification (renders to PNGs in the sandbox)

    /// Render the two showcase characters (and a stick figure regression) at rest, part-coloured,
    /// and in a joint-stressing pose — so we can SEE that nothing tears or folds when animated.
    private static func dumpVisuals() {
        let canvas = CGSize(width: 390, height: 844)
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let figs: [(String, FigureSpec)] = [
            // Character 1: wide eared head + zigzag mouth, rectangle body, line arms/legs.
            ("char1", FigureSpec(head: .wideOval, torso: .rectOutline, arm: .lineDown, leg: .lineStraight, deco: [.ears, .face], scale: 1.15, seed: 1)),
            // Character 2: round smiley head, rounded outline body, OUTLINE arms + legs.
            ("char2", FigureSpec(head: .bigCircle, torso: .roundedBlob, arm: .outlineMitten, leg: .outlineTapered, deco: [.face], scale: 1.1, seed: 2)),
            // Plain stick figure (regression: must still rig + bend at the elbow).
            ("stick", FigureSpec(head: .circle, torso: .spineLine, arm: .lineDown, leg: .lineStraight, scale: 1.1, seed: 3)),
        ]
        let sz = CGSize(width: 390, height: 720)
        for (name, spec) in figs {
            let (drawing, _) = RigPartLibrary.build(spec, canvas: canvas)
            let rig = RigFitter.fit(drawing, traits: traits)
            writeImage(renderRig(rig, pose: .rest(rig.skeleton), size: sz, partColors: false, joints: true), "rig_\(name)_1rest.png")
            writeImage(renderRig(rig, pose: .rest(rig.skeleton), size: sz, partColors: true, joints: false), "rig_\(name)_2parts.png")
            var p = FigurePose.rest(rig.skeleton)
            p.leftArmAngle = -1.0; p.rightArmAngle = 1.0      // swing both arms up/out
            p.leftForearmAngle = -0.7; p.rightForearmAngle = 0.7
            p.leftLegAngle = 0.32; p.rightLegAngle = -0.32    // scissor the legs
            p.headAngle = 0.28; p.rootAngle = 0.08; p.scaleX = 1.06; p.scaleY = 0.9
            writeImage(renderRig(rig, pose: p, size: sz, partColors: false, joints: false), "rig_\(name)_3stress.png")
        }
        dumpRoutineFrames()
        dumpUserFigures()
        dumpStagingCheck()
        dumpDotFaceCheck()
        dumpPropAnchorCheck()
    }

    // MARK: - Issue 2: animation playfield (header/footer) check
    //
    // The performance stage sits BELOW the toolbars in the ZStack, so anything drawn in the top
    // header band or the bottom toolbar band is OCCLUDED ("blocked by header/bottom row toolbar").
    // With the chrome-aware floor + playfield-capped propScale + inset-aware fitOnScreen, the
    // figure (after its drop) and the reveal reach must stay BETWEEN the bars. This samples every
    // routine for {small-high, normal, big} figures using representative (worst-case Notes) insets
    // and asserts it. A small figure used to force OVER-SIZED props that poked into the header —
    // the exact reported failure. Writes staging.txt; also dumps the small figure's frames with
    // the header/footer bands drawn so it can be seen.
    private static func dumpStagingCheck() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let viewport = bounds.height
        let topInset: CGFloat = 130          // worst-case Notes header (large button size)
        let bottomInset: CGFloat = 96        // bottom accessory bar + home indicator
        let playTop = topInset, playBottom = viewport - bottomInset

        func mk(_ pts: [CGPoint]) -> PKStroke {
            let ink = PKInk(.pen, color: UIColor(red: 0.95, green: 0.27, blue: 0.13, alpha: 1))
            let size = CGSize(width: max(3, 6), height: 6)
            let sp = pts.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: sp, creationDate: Date()))
        }
        func ell(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> [CGPoint] {
            stride(from: 0, through: 2 * CGFloat.pi, by: 2 * CGFloat.pi / 30).map { CGPoint(x: c.x + rx * cos($0), y: c.y + ry * sin($0)) }
        }
        func ln(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
            (0...14).map { i in let f = CGFloat(i) / 14; return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f) }
        }
        // A plain stick figure at a given scale, with its HEAD TOP at headTopY.
        func figure(scale: CGFloat, headTopY: CGFloat) -> PKDrawing {
            let cx: CGFloat = 196, u = 70 * scale, hr = u * 0.45
            let headC = CGPoint(x: cx, y: headTopY + hr)
            let neck = CGPoint(x: cx, y: headC.y + hr)
            let hip = CGPoint(x: cx, y: neck.y + u * 1.5)
            let footY = hip.y + u * 1.4
            return PKDrawing(strokes: [
                mk(ell(headC, hr, hr * 1.05)),
                mk(ln(neck, hip)),
                mk(ln(CGPoint(x: neck.x, y: neck.y + u * 0.2), CGPoint(x: cx - u * 0.9, y: neck.y + u * 0.9))),
                mk(ln(CGPoint(x: neck.x, y: neck.y + u * 0.2), CGPoint(x: cx + u * 0.9, y: neck.y + u * 0.9))),
                mk(ln(hip, CGPoint(x: cx - u * 0.5, y: footY))),
                mk(ln(hip, CGPoint(x: cx + u * 0.5, y: footY))),
            ])
        }

        let figs: [(String, CGFloat, CGFloat, Bool)] = [   // name, scale, headTopY, expectFigFits
            ("small_high", 0.45, 110, true),               // small + drawn high (the reported case)
            ("normal",     1.0,  240, true),
            ("big",        1.7,  150, false),              // taller than the playfield — card must still fit
        ]
        var r = "STAGING CHECK (issue 2 — animation vs header/footer)\n===================================================\n"
        r += "viewport=\(Int(viewport)) topInset=\(Int(topInset)) bottomInset=\(Int(bottomInset)) playfield=[\(Int(playTop)),\(Int(playBottom))]\n"
        r += "PASS = figure (post-drop) within playfield (where expected) AND reveal card top >= header.\n\n"
        var allOK = true
        for (fname, scale, topY, expectFig) in figs {
            let rig = RigFitter.fit(figure(scale: scale, headTopY: topY), traits: traits)
            let setup = RoutineSetup.make(rig: rig, canvasBounds: bounds, contentOffset: .zero,
                                          topInset: topInset, bottomInset: bottomInset)
            r += "\(fname): figH=\(Int(rig.skeleton.bbox.height)) propScale=\(Int(setup.propScale)) drop=\(Int(setup.dropDistance))\n"
            for slot in AnimationSlot.playable {
                let routine = AnimationFactory.make(slot, setup)
                var lo = CGFloat.greatestFiniteMagnitude, hi = -CGFloat.greatestFiniteMagnitude
                let dt = 0.2, n = Int(routine.totalDuration / dt)
                for k in 0...n where Double(k) * dt >= 1.5 {     // ignore the initial fall-in
                    let pose = routine.pose(at: Double(k) * dt)
                    for s in rig.strokes { for (j, p) in s.points.enumerated() {
                        let w = rig.worldPoint(p, part: s.parts[j], pose: pose)
                        lo = min(lo, w.y); hi = max(hi, w.y)
                    } }
                }
                let climax = routine.pose(at: routine.totalDuration - 0.2)
                let feetY = rig.worldPoint(rig.skeleton.feet, part: .torso, pose: climax).y
                let cardTop = feetY - 1.15 * setup.propScale     // worst-case upward reveal reach
                let figOK = lo >= playTop - 2 && hi <= playBottom + 2
                let cardOK = cardTop >= playTop - 2
                let fail = (expectFig && !figOK) || !cardOK
                if fail { allOK = false }
                r += "   \(String(describing: slot).padding(toLength: 8, withPad: " ", startingAt: 0)) figY=[\(Int(lo)),\(Int(hi))] feet=\(Int(feetY)) cardTop=\(Int(cardTop))  \(figOK ? "figOK" : "FIG-OOB")\(expectFig ? "" : "(ok-tall)") \(cardOK ? "cardOK" : "CARD-OOB")\(fail ? "  <<< FAIL" : "")\n"
            }
        }
        r = "RESULT: \(allOK ? "PASS — every routine stays within the playfield" : "FAIL — see <<< lines")\n\n" + r
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("staging.txt")
        try? r.data(using: .utf8)?.write(to: url)

        // Visual: the small figure at each routine's climax with the header/footer bands drawn.
        let smallRig = RigFitter.fit(figure(scale: 0.45, headTopY: 110), traits: traits)
        let smallSetup = RoutineSetup.make(rig: smallRig, canvasBounds: bounds, contentOffset: .zero,
                                           topInset: topInset, bottomInset: bottomInset)
        for slot in AnimationSlot.playable {
            let routine = AnimationFactory.make(slot, smallSetup)
            let img = renderRigWithBands(smallRig, pose: routine.pose(at: routine.totalDuration - 0.3),
                                         size: bounds.size, topInset: topInset, bottomInset: bottomInset)
            writeImage(img, "stage_small_\(slot).png")
        }
    }

    // MARK: - Dot-face check (single-point eyes must survive the rig)
    //
    // A single-tap dot (an eye drawn as ONE control point, or a tap cluster with no extent)
    // used to be dropped by the fitter's `pts.count >= 2` guard — face details vanished the
    // moment the figure came to life. This builds a stick figure whose face is exactly those
    // degenerate strokes, fits it, and asserts each dot SURVIVES (a renderable ≥2-point,
    // nonzero-length rig stroke), is bound to the HEAD, and RIDES the head through the whole
    // Classic routine (a mislabeled dot would drift during the wave/walk). Writes dotface.txt.
    private static func dumpDotFaceCheck() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let traits = UITraitCollection(userInterfaceStyle: .light)

        func mk(_ pts: [CGPoint]) -> PKStroke {
            let ink = PKInk(.pen, color: .black)
            let size = CGSize(width: 6, height: 6)
            let sp = pts.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: sp, creationDate: Date()))
        }
        func ell(_ c: CGPoint, _ r: CGFloat) -> [CGPoint] {
            stride(from: 0, through: 2 * CGFloat.pi, by: 2 * CGFloat.pi / 30).map { CGPoint(x: c.x + r * cos($0), y: c.y + r * sin($0)) }
        }
        func ln(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
            (0...14).map { i in let f = CGFloat(i) / 14; return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f) }
        }

        // Plain stick figure + degenerate face details.
        let cx: CGFloat = 196, u: CGFloat = 70, hr = u * 0.45
        let headC = CGPoint(x: cx, y: 240 + hr)
        let neck = CGPoint(x: cx, y: headC.y + hr)
        let hip = CGPoint(x: cx, y: neck.y + u * 1.5)
        let footY = hip.y + u * 1.4
        var strokes: [PKStroke] = [
            mk(ell(headC, hr)),
            mk(ln(neck, hip)),
            mk(ln(CGPoint(x: neck.x, y: neck.y + u * 0.2), CGPoint(x: cx - u * 0.9, y: neck.y + u * 0.9))),
            mk(ln(CGPoint(x: neck.x, y: neck.y + u * 0.2), CGPoint(x: cx + u * 0.9, y: neck.y + u * 0.9))),
            mk(ln(hip, CGPoint(x: cx - u * 0.5, y: footY))),
            mk(ln(hip, CGPoint(x: cx + u * 0.5, y: footY))),
        ]
        let leftEye = CGPoint(x: headC.x - hr * 0.35, y: headC.y - hr * 0.15)
        let rightEye = CGPoint(x: headC.x + hr * 0.35, y: headC.y - hr * 0.15)
        let nose = CGPoint(x: headC.x, y: headC.y + hr * 0.15)
        let dotIdx = strokes.count..<(strokes.count + 3)
        strokes.append(mk([leftEye]))                                     // ONE control point (a pure tap)
        strokes.append(mk([rightEye, rightEye, rightEye]))                // a tap cluster, zero extent
        strokes.append(mk([nose, CGPoint(x: nose.x + 0.05, y: nose.y)])) // two points, sub-pixel extent
        let drawing = PKDrawing(strokes: strokes)

        var r = "DOT-FACE CHECK (single-point eyes survive + ride the head)\n==========================================================\n"
        var ok = true
        let rig = RigFitter.fit(drawing, traits: traits)
        if rig.strokes.count != strokes.count {
            ok = false
            r += "FAIL: rig has \(rig.strokes.count) strokes, drew \(strokes.count) — a dot was dropped\n"
        } else {
            let setup = RoutineSetup.make(rig: rig, canvasBounds: bounds, contentOffset: .zero,
                                          topInset: 130, bottomInset: 96)
            let routine = AnimationFactory.make(.classic, setup)
            for i in dotIdx {
                let s = rig.strokes[i]
                var len: CGFloat = 0
                for j in 1..<s.points.count { len += hypot(s.points[j].x - s.points[j - 1].x, s.points[j].y - s.points[j - 1].y) }
                let headBound = s.parts.allSatisfy { $0 == .head }
                var maxDrift: CGFloat = 0
                var t = 0.0
                while t <= routine.totalDuration {
                    let pose = routine.pose(at: t)
                    let hc = rig.worldPoint(rig.skeleton.headCenter, part: .head, pose: pose)
                    for (j, p) in s.points.enumerated() {
                        let w = rig.worldPoint(p, part: s.parts[j], pose: pose)
                        maxDrift = max(maxDrift, hypot(w.x - hc.x, w.y - hc.y))
                    }
                    t += 0.2
                }
                let renderable = s.points.count >= 2 && len > 0.1
                let rides = maxDrift <= rig.skeleton.headRadius * 2
                if !(renderable && headBound && rides) { ok = false }
                r += "dot[\(i)]: pts=\(s.points.count) len=\(String(format: "%.2f", len)) head=\(headBound) maxDriftFromHead=\(Int(maxDrift)) (headR=\(Int(rig.skeleton.headRadius)))"
                    + (renderable ? "" : "  <<< NOT RENDERABLE") + (headBound ? "" : "  <<< NOT HEAD") + (rides ? "" : "  <<< FLUNG OFF HEAD") + "\n"
            }
        }
        r = "RESULT: \(ok ? "PASS — dots survive, bind to the head, and ride it through the routine" : "FAIL — see <<< lines")\n\n" + r
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dotface.txt")
        try? r.data(using: .utf8)?.write(to: url)
    }

    // MARK: - Prop anchor + top-hat flip check (end-to-end, props included)
    //
    // Issue: a ONE-STROKE outline body (like the user's drawn character) classifies whole as
    // torso — no arm-labelled points — so the hand anchors defaulted to the SHOULDERS and every
    // conjured prop (wand/rod/brush/hat/card) appeared at the top of the arm. `refineJoints`
    // now estimates a hand per side from the drawing's lateral extremes when a side has no arm
    // points. This builds such a figure (right arm extended, left arm hanging), asserts the
    // estimated hands land at the drawn arm TIPS, and dumps END-TO-END frames (figure + props
    // via LittleGuyStage.drawFrame) for Classic on the outline figure and TopHat on a stick
    // figure — the latter to eyeball the hat's 180° flip before the card emerges. proptest.txt.
    private static func dumpPropAnchorCheck() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let traits = UITraitCollection(userInterfaceStyle: .light)

        func mk(_ pts: [CGPoint], w: CGFloat = 6) -> PKStroke {
            let ink = PKInk(.pen, color: UIColor(red: 0.85, green: 0.16, blue: 0.02, alpha: 1))
            let sp = pts.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: w, height: w),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: sp, creationDate: Date()))
        }
        func ell(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> [CGPoint] {
            stride(from: 0, through: 2 * CGFloat.pi, by: 2 * CGFloat.pi / 40).map { CGPoint(x: c.x + rx * cos($0), y: c.y + ry * sin($0)) }
        }
        func ln(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
            (0...14).map { i in let f = CGFloat(i) / 14; return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f) }
        }

        // The user's figure: ONE closed outline for the whole body — right arm extended out
        // to the side, left arm hanging — plus a head loop, dot eyes, and a smile.
        let outlineBody: [CGPoint] = [
            CGPoint(x: 175, y: 315),                                    // left neck
            CGPoint(x: 150, y: 360), CGPoint(x: 120, y: 440),
            CGPoint(x: 95, y: 520), CGPoint(x: 105, y: 532),            // left hand tip (hanging)
            CGPoint(x: 140, y: 480), CGPoint(x: 163, y: 440),
            CGPoint(x: 170, y: 560),                                    // left hip
            CGPoint(x: 150, y: 750), CGPoint(x: 172, y: 755),           // left foot
            CGPoint(x: 205, y: 610),                                    // crotch
            CGPoint(x: 230, y: 750), CGPoint(x: 255, y: 745),           // right foot
            CGPoint(x: 245, y: 570), CGPoint(x: 250, y: 470),           // right torso
            CGPoint(x: 310, y: 445), CGPoint(x: 370, y: 428),           // right arm underside
            CGPoint(x: 372, y: 412),                                    // right hand tip (extended)
            CGPoint(x: 300, y: 400), CGPoint(x: 235, y: 380),           // arm top back to shoulder
            CGPoint(x: 225, y: 320), CGPoint(x: 175, y: 315),           // right neck, close
        ]
        var densified: [CGPoint] = []
        for i in 1..<outlineBody.count { densified += ln(outlineBody[i - 1], outlineBody[i]) }
        let head = CGPoint(x: 200, y: 255)
        let outlineFig = PKDrawing(strokes: [
            mk(ell(head, 58, 55)),
            mk(densified),
            mk([CGPoint(x: 180, y: 240)]),                              // dot eye (1 point)
            mk([CGPoint(x: 222, y: 238)]),                              // dot eye
            mk(ln(CGPoint(x: 178, y: 275), CGPoint(x: 220, y: 278))),   // smile
        ])

        var r = "PROP ANCHOR CHECK (hands estimated on an unrigged outline body)\n================================================================\n"
        var ok = true
        let rig = RigFitter.fit(outlineFig, traits: traits)
        let sk = rig.skeleton
        let rightTip = CGPoint(x: 372, y: 412), leftTip = CGPoint(x: 100, y: 526)
        let dR = hypot(sk.rightHand.x - rightTip.x, sk.rightHand.y - rightTip.y)
        let dL = hypot(sk.leftHand.x - leftTip.x, sk.leftHand.y - leftTip.y)
        let offShoulderR = hypot(sk.rightHand.x - sk.rightShoulder.x, sk.rightHand.y - sk.rightShoulder.y)
        let offShoulderL = hypot(sk.leftHand.x - sk.leftShoulder.x, sk.leftHand.y - sk.leftShoulder.y)
        let handsOK = dR < 60 && dL < 60 && offShoulderR > 40 && offShoulderL > 40
        if !handsOK { ok = false }
        r += "articulated=\(rig.articulated) conf=\(String(format: "%.2f", rig.confidence))\n"
        r += "rightHand=(\(Int(sk.rightHand.x)),\(Int(sk.rightHand.y))) drawnTip=(372,412) miss=\(Int(dR))pt offShoulder=\(Int(offShoulderR))pt\n"
        r += "leftHand=(\(Int(sk.leftHand.x)),\(Int(sk.leftHand.y))) drawnTip=(100,526) miss=\(Int(dL))pt offShoulder=\(Int(offShoulderL))pt\n"
        r += handsOK ? "hands: OK — anchored at the drawn arm tips\n" : "hands: <<< FAIL — prop would conjure at the wrong spot\n"
        // Estimated hands must ride the ROOT (.torso), not the invisible arm's FK — otherwise
        // the rod/balloon/wand swings far off the static drawn arm (the reported bug).
        let carryOK = rig.leftHandPart == .torso && rig.rightHandPart == .torso
        if !carryOK { ok = false }
        r += "carrying parts: L=\(rig.leftHandPart) R=\(rig.rightHandPart) \(carryOK ? "OK — ride the root" : "<<< FAIL — would swing on invisible arm")\n"

        // End-to-end frames: figure + props, exactly what the stage draws.
        let payload = RevealPayload.card(Card(value: 12, suit: .diamonds))
        let paper = Color(red: 0.984, green: 0.965, blue: 0.918)         // Little Guy cream
        func dumpFrames(_ name: String, rig: Rig, slot: AnimationSlot, times: [Double]) {
            let setup = RoutineSetup.make(rig: rig, canvasBounds: bounds, contentOffset: .zero,
                                          topInset: 130, bottomInset: 96)
            let routine = AnimationFactory.make(slot, setup)
            for t in times {
                let tt = min(t, routine.totalDuration - 0.05)
                let renderer = ImageRenderer(content:
                    Canvas { ctx, size in
                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paper))
                        LittleGuyStage.drawFrame(ctx, at: tt, rig: rig, routine: routine,
                                                 originOffset: .zero, payload: payload,
                                                 revealStyle: .typed, glyphs: nil, paper: paper)
                    }
                    .frame(width: bounds.width, height: bounds.height)
                )
                renderer.scale = 2
                if let img = renderer.uiImage { writeImage(img, "prop_\(name)_t\(String(format: "%04.1f", tt)).png") }
            }
        }
        dumpFrames("outline_classic", rig: rig, slot: .classic, times: [9.0, 11.6])
        // Fishing on the SAME unrigged outline body — the rod must sit ON the drawn extended
        // arm (hand rides the root), not swing away on the invisible arm's FK (the reported
        // "rod far from the arm / out of frame" bug).
        dumpFrames("outline_fishing", rig: rig, slot: .fishing, times: [5.2, 8.8, 12.2])

        // A plain stick figure through TOP HAT — lift, tumble-flip, rummage, card out of the
        // opening, present. The flip is the thing to eyeball: crown-down, opening-up.
        let cx: CGFloat = 196, u: CGFloat = 70, hr = u * 0.45
        let headC = CGPoint(x: cx, y: 240 + hr)
        let neck = CGPoint(x: cx, y: headC.y + hr)
        let hip = CGPoint(x: cx, y: neck.y + u * 1.5)
        let stick = PKDrawing(strokes: [
            mk(ell(headC, hr, hr * 1.05)),
            mk(ln(neck, hip)),
            mk(ln(CGPoint(x: neck.x, y: neck.y + u * 0.2), CGPoint(x: cx - u * 0.9, y: neck.y + u * 0.9))),
            mk(ln(CGPoint(x: neck.x, y: neck.y + u * 0.2), CGPoint(x: cx + u * 0.9, y: neck.y + u * 0.9))),
            mk(ln(hip, CGPoint(x: cx - u * 0.5, y: hip.y + u * 1.4))),
            mk(ln(hip, CGPoint(x: cx + u * 0.5, y: hip.y + u * 1.4))),
        ])
        let stickRig = RigFitter.fit(stick, traits: traits)
        let stickCarryOK = stickRig.leftHandPart == .leftForearm && stickRig.rightHandPart == .rightForearm
        if !stickCarryOK { ok = false }
        r += "stick carrying parts: L=\(stickRig.leftHandPart) R=\(stickRig.rightHandPart) \(stickCarryOK ? "OK — ride the animated hand" : "<<< FAIL")\n"
        dumpFrames("stick_tophat", rig: stickRig, slot: .topHat, times: [6.5, 7.5, 8.6, 10.9, 11.3, 12.6])
        // Painter through the card draw-on / fill / present — the card must show ONE border
        // (cardFace's), not the old outline + inset cardFace pair.
        dumpFrames("stick_painter", rig: stickRig, slot: .painter, times: [7.8, 9.7, 10.3, 11.9])

        r = "RESULT: \(ok ? "PASS" : "FAIL") — see prop_*.png for the end-to-end frames\n\n" + r
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("proptest.txt")
        try? r.data(using: .utf8)?.write(to: url)
    }

    /// Figure render with the header/footer occlusion bands overlaid (red), so the playfield is visible.
    private static func renderRigWithBands(_ rig: Rig, pose: FigurePose, size: CGSize,
                                           topInset: CGFloat, bottomInset: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            // chrome bands (where the toolbars occlude)
            UIColor.systemRed.withAlphaComponent(0.28).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: topInset))
            ctx.fill(CGRect(x: 0, y: size.height - bottomInset, width: size.width, height: bottomInset))
            for stroke in rig.strokes where stroke.points.count >= 2 {
                let path = UIBezierPath()
                for (i, pt) in stroke.points.enumerated() {
                    let wp = rig.worldPoint(pt, part: stroke.parts[i], pose: pose)
                    if i == 0 { path.move(to: wp) } else { path.addLine(to: wp) }
                }
                UIColor(stroke.color).setStroke()
                path.lineWidth = stroke.width; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
            }
        }
    }

    // Realistic hand-drawn approximations (a stick figure + a fuller body in CLOSED and OPEN
    // outline forms, plus every reported-failure reproduction) — the permanent regression
    // fixtures. Each carries GROUND TRUTH so run() scores it (labels + explosion across all
    // routines); dumpUserFigures() additionally renders diag + PNG frames for eyeballing.
    private static func userFixtures() -> [UserFixture] {
        func mk(_ pts: [CGPoint]) -> PKStroke {
            let ink = PKInk(.pen, color: UIColor(red: 0.95, green: 0.27, blue: 0.13, alpha: 1))
            let size = CGSize(width: 7, height: 7)
            let sp = pts.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: sp, creationDate: Date()))
        }
        func ell(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, gap: CGFloat = 0) -> [CGPoint] {
            let span = 2 * CGFloat.pi - gap
            return stride(from: 0, through: span, by: span / 30).map { CGPoint(x: c.x + rx * cos($0), y: c.y + ry * sin($0)) }
        }
        func ln(_ a: CGPoint, _ b: CGPoint, _ n: Int = 14) -> [CGPoint] {
            (0...n).map { i in let f = CGFloat(i) / CGFloat(n); return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f) }
        }
        func poly(_ ps: [CGPoint]) -> [CGPoint] { var o: [CGPoint] = []; for i in 1..<ps.count { o += ln(ps[i - 1], ps[i], 8) }; return o }
        func tube(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat, closed: Bool = true) -> [CGPoint] {
            let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 0.001), nx = -dy / len, ny = dx / len
            var p = ln(CGPoint(x: a.x + nx * w, y: a.y + ny * w), CGPoint(x: b.x + nx * w, y: b.y + ny * w), 10)
            let t0 = atan2(ny, nx); p += (1...8).map { i in let t = t0 - .pi * CGFloat(i) / 8; return CGPoint(x: b.x + w * cos(t), y: b.y + w * sin(t)) }
            p += ln(CGPoint(x: b.x - nx * w, y: b.y - ny * w), CGPoint(x: a.x - nx * w, y: a.y - ny * w), 10)
            if closed { p.append(p.first!) }
            return p
        }
        let P = TruthLabel.part
        return [
            UserFixture(name: "user1", strokes: [   // stick figure
                mk(ell(CGPoint(x: 197, y: 232), 66, 74)),
                mk(poly([CGPoint(x: 204, y: 305), CGPoint(x: 202, y: 420), CGPoint(x: 206, y: 545)])),
                mk(ln(CGPoint(x: 202, y: 345), CGPoint(x: 132, y: 418))),
                mk(ln(CGPoint(x: 210, y: 345), CGPoint(x: 286, y: 400))),
                mk(ln(CGPoint(x: 206, y: 545), CGPoint(x: 150, y: 660))),
                mk(ln(CGPoint(x: 206, y: 545), CGPoint(x: 258, y: 665))),
            ], truth: [P(.head), P(.torso), P(.leftArm), P(.rightArm), P(.leftLeg), P(.rightLeg)]),
            UserFixture(name: "user2", strokes: [   // fuller outline body, CLOSED loops
                mk(ell(CGPoint(x: 196, y: 232), 78, 82, gap: 0.4)),
                mk(tube(CGPoint(x: 204, y: 362), CGPoint(x: 204, y: 520), 46)),
                mk(tube(CGPoint(x: 172, y: 372), CGPoint(x: 150, y: 512), 22)),
                mk(tube(CGPoint(x: 240, y: 372), CGPoint(x: 268, y: 500), 22)),
                mk(tube(CGPoint(x: 186, y: 515), CGPoint(x: 182, y: 675), 22)),
                mk(tube(CGPoint(x: 226, y: 515), CGPoint(x: 236, y: 685), 22)),
            ], truth: [P(.head), P(.torso), P(.leftArm), P(.rightArm), P(.leftLeg), P(.rightLeg)]),
            UserFixture(name: "user2open", strokes: [   // same but arms + legs drawn as OPEN loops (not closed)
                mk(ell(CGPoint(x: 196, y: 232), 78, 82, gap: 0.4)),
                mk(tube(CGPoint(x: 204, y: 362), CGPoint(x: 204, y: 520), 44, closed: false)),
                mk(tube(CGPoint(x: 158, y: 375), CGPoint(x: 142, y: 512), 20, closed: false)),
                mk(tube(CGPoint(x: 254, y: 375), CGPoint(x: 272, y: 500), 20, closed: false)),
                mk(tube(CGPoint(x: 180, y: 518), CGPoint(x: 176, y: 688), 18, closed: false)),
                mk(tube(CGPoint(x: 240, y: 518), CGPoint(x: 248, y: 688), 18, closed: false)),
            ], truth: [P(.head), P(.torso), P(.leftArm), P(.rightArm), P(.leftLeg), P(.rightLeg)]),
            UserFixture(name: "neckThin", strokes: [   // fuller body with a THIN drawn neck (head floats above the torso)
                mk(ell(CGPoint(x: 200, y: 215), 58, 60)),
                mk(ln(CGPoint(x: 200, y: 276), CGPoint(x: 202, y: 330))),        // neck line
                mk(tube(CGPoint(x: 202, y: 335), CGPoint(x: 202, y: 500), 44)),  // torso
                mk(tube(CGPoint(x: 168, y: 345), CGPoint(x: 150, y: 500), 20)),  // L arm
                mk(tube(CGPoint(x: 236, y: 345), CGPoint(x: 256, y: 490), 20)),  // R arm
                mk(tube(CGPoint(x: 182, y: 498), CGPoint(x: 178, y: 660), 18)),  // L leg
                mk(tube(CGPoint(x: 224, y: 498), CGPoint(x: 230, y: 662), 18)),  // R leg
            ], truth: [P(.head), P(.torso), P(.torso), P(.leftArm), P(.rightArm), P(.leftLeg), P(.rightLeg)]),
            UserFixture(name: "neckFat", strokes: [   // fuller body with a FAT/outlined neck (the case that became an arm)
                mk(ell(CGPoint(x: 200, y: 215), 58, 60)),
                mk(tube(CGPoint(x: 200, y: 278), CGPoint(x: 200, y: 332), 13)),  // OUTLINE neck
                mk(tube(CGPoint(x: 202, y: 336), CGPoint(x: 202, y: 500), 44)),  // torso
                mk(tube(CGPoint(x: 168, y: 346), CGPoint(x: 150, y: 500), 20)),  // L arm
                mk(tube(CGPoint(x: 236, y: 346), CGPoint(x: 256, y: 490), 20)),  // R arm
                mk(tube(CGPoint(x: 182, y: 498), CGPoint(x: 178, y: 660), 18)),  // L leg
                mk(tube(CGPoint(x: 224, y: 498), CGPoint(x: 230, y: 662), 18)),  // R leg
            ], truth: [P(.head), P(.torso), P(.torso), P(.leftArm), P(.rightArm), P(.leftLeg), P(.rightLeg)]),
            // ---- The reported failure: legs drawn to the side / crossed (from the screenshots).
            // Big oval head, V arms from the neck, spine, and the two legs forming a scissor X
            // that veers LEFT (the down-left leg is long + steep). This rig misplaced the hip and
            // mislabeled the leg tops, so the routine flung the limbs (arms wrapped the head, a
            // leg shot off-screen). Keep as a permanent regression fixture.
            UserFixture(name: "sideLegX", strokes: [
                mk(ell(CGPoint(x: 210, y: 286), 62, 70)),                  // big oval head
                mk(ln(CGPoint(x: 212, y: 354), CGPoint(x: 214, y: 540))),  // spine
                mk(ln(CGPoint(x: 214, y: 388), CGPoint(x: 112, y: 470))),  // L arm (down-left)
                mk(ln(CGPoint(x: 210, y: 386), CGPoint(x: 300, y: 432))),  // R arm (down-right)
                mk(ln(CGPoint(x: 230, y: 514), CGPoint(x: 150, y: 672))),  // L leg: starts right, crosses down-LEFT (long/steep)
                mk(ln(CGPoint(x: 202, y: 532), CGPoint(x: 292, y: 648))),  // R leg: starts left, crosses down-RIGHT
            ], truth: [P(.head), P(.torso), P(.leftArm), P(.rightArm), P(.leftLeg), P(.rightLeg)]),
            // Both legs veer to ONE side without crossing (the cleaner "legs drawn slightly to the
            // side" reading): hips under the spine, but both feet shifted left of the hips.
            UserFixture(name: "sideLegLean", strokes: [
                mk(ell(CGPoint(x: 200, y: 270), 60, 66)),
                mk(ln(CGPoint(x: 202, y: 334), CGPoint(x: 204, y: 520))),
                mk(ln(CGPoint(x: 204, y: 366), CGPoint(x: 120, y: 452))),
                mk(ln(CGPoint(x: 200, y: 364), CGPoint(x: 286, y: 432))),
                mk(ln(CGPoint(x: 196, y: 520), CGPoint(x: 120, y: 668))),  // L leg → down-left
                mk(ln(CGPoint(x: 214, y: 520), CGPoint(x: 150, y: 672))),  // R leg → also down-left (both lean left)
            ], truth: [P(.head), P(.torso), P(.leftArm), P(.rightArm), P(.leftLeg), P(.rightLeg)]),
            // Arms attached OFFSET down the torso — the left a plain diagonal from below the
            // neck, the right a Z that dips ACROSS the spine before extending out (from the
            // user's screenshots). Without arm consolidation the Z-arm's near-spine points read
            // as torso, the stroke split torso|arm, and the body visibly STRETCHED when the arm
            // rotated up for the wand. Keep as a permanent regression fixture.
            UserFixture(name: "offsetArm", strokes: [
                mk(ell(CGPoint(x: 200, y: 232), 55, 52)),
                mk(ln(CGPoint(x: 202, y: 285), CGPoint(x: 204, y: 420))),  // torso
                mk(ln(CGPoint(x: 201, y: 330), CGPoint(x: 140, y: 368))),  // L arm, offset root
                mk(poly([CGPoint(x: 203, y: 345), CGPoint(x: 188, y: 364),
                         CGPoint(x: 256, y: 392)])),                       // R arm: Z across the spine
                mk(ln(CGPoint(x: 204, y: 420), CGPoint(x: 186, y: 528))),  // L leg
                mk(ln(CGPoint(x: 206, y: 420), CGPoint(x: 214, y: 526))),  // R leg
            ], truth: [P(.head), P(.torso), P(.leftArm), P(.rightArm), P(.leftLeg), P(.rightLeg)]),
            // BOTH arms drawn in ONE ∩-arched stroke (left hand → up over the spine → right
            // hand), from the user's screenshot. The arch's 2D spread made isFat call it an
            // OUTLINE: it was polygon-filled, bound rigid, and Step 7a classified the whole
            // stroke as TORSO (its centroid sits on the spine) — both arms vanished. The
            // double-back gate in isFat keeps it a thin line so the per-point split survives.
            UserFixture(name: "archArms", strokes: [
                mk(ell(CGPoint(x: 200, y: 250), 55, 65)),
                mk(ln(CGPoint(x: 202, y: 316), CGPoint(x: 204, y: 560))),  // spine
                mk(poly([CGPoint(x: 135, y: 470), CGPoint(x: 150, y: 420),
                         CGPoint(x: 172, y: 380), CGPoint(x: 200, y: 355),
                         CGPoint(x: 228, y: 378), CGPoint(x: 252, y: 420),
                         CGPoint(x: 270, y: 480)])),                       // BOTH arms: one ∩ stroke
                mk(ln(CGPoint(x: 204, y: 560), CGPoint(x: 158, y: 700))),  // L leg
                mk(ln(CGPoint(x: 206, y: 560), CGPoint(x: 252, y: 700))),  // R leg
            ], truth: [P(.head), P(.torso), .armPair, P(.leftLeg), P(.rightLeg)]),
            // Same figure with the LEGS also in one ∧ stroke — the leg twin of the arch-arm
            // failure (fat → rigid → sided whole to one leg instead of splitting at the crotch).
            UserFixture(name: "archArmsVLegs", strokes: [
                mk(ell(CGPoint(x: 200, y: 250), 55, 65)),
                mk(ln(CGPoint(x: 202, y: 316), CGPoint(x: 204, y: 555))),
                mk(poly([CGPoint(x: 135, y: 470), CGPoint(x: 172, y: 380),
                         CGPoint(x: 200, y: 355), CGPoint(x: 228, y: 378),
                         CGPoint(x: 270, y: 480)])),                       // BOTH arms: one ∧ stroke
                mk(poly([CGPoint(x: 152, y: 705), CGPoint(x: 204, y: 556),
                         CGPoint(x: 254, y: 710)])),                       // BOTH legs: one ∧ stroke
            ], truth: [P(.head), P(.torso), .armPair, .legPair]),
            // The STEEP arch: hands hang LOW, so the arch is taller than wide — its major axis
            // is vertical and the path doubles back along it exactly like an outline tube, so
            // isFat's travel gate can't clear this one. Covered by the Step 7a limb-pair split
            // (endpoints on opposite sides + fold on the spine) instead.
            UserFixture(name: "steepArchArms", strokes: [
                mk(ell(CGPoint(x: 200, y: 250), 55, 65)),
                mk(ln(CGPoint(x: 202, y: 316), CGPoint(x: 204, y: 560))),
                mk(poly([CGPoint(x: 140, y: 540), CGPoint(x: 155, y: 430),
                         CGPoint(x: 178, y: 372), CGPoint(x: 200, y: 352),
                         CGPoint(x: 226, y: 370), CGPoint(x: 246, y: 432),
                         CGPoint(x: 262, y: 545)])),                       // BOTH arms: one steep ∩
                mk(ln(CGPoint(x: 204, y: 560), CGPoint(x: 158, y: 700))),
                mk(ln(CGPoint(x: 206, y: 560), CGPoint(x: 252, y: 700))),
            ], truth: [P(.head), P(.torso), .armPair, P(.leftLeg), P(.rightLeg)]),
            // ---- One-stroke arm pairs with NO symmetry (user screenshots, round 2) ----
            // Arms at DIFFERENT heights: one raised toward head height, crossing the spine
            // mid-torso, the other hanging low. The old balance test collapsed both onto the
            // dominant side (one arm died and streaked when the live one swung); per-side
            // REACH now keeps the split, so each side of the body is its own arm.
            UserFixture(name: "asymArms", strokes: [
                mk(ell(CGPoint(x: 200, y: 250), 52, 62)),
                mk(ln(CGPoint(x: 202, y: 314), CGPoint(x: 204, y: 560))),  // spine
                mk(poly([CGPoint(x: 128, y: 300), CGPoint(x: 156, y: 342),
                         CGPoint(x: 180, y: 380), CGPoint(x: 203, y: 420),
                         CGPoint(x: 226, y: 462), CGPoint(x: 258, y: 532)])), // raised L → cross → low R
                mk(ln(CGPoint(x: 204, y: 560), CGPoint(x: 158, y: 700))),
                mk(ln(CGPoint(x: 206, y: 560), CGPoint(x: 252, y: 700))),
            ], truth: [P(.head), P(.torso), .armPair, P(.leftLeg), P(.rightLeg)]),
            // Check-mark arms: L hand LOW, junction HIGH on the spine, R arm near-horizontal
            // at shoulder height — the junction sits nowhere near the endpoints' midpoint.
            UserFixture(name: "checkArms", strokes: [
                mk(ell(CGPoint(x: 200, y: 250), 52, 62)),
                mk(ln(CGPoint(x: 202, y: 314), CGPoint(x: 204, y: 560))),
                mk(poly([CGPoint(x: 138, y: 478), CGPoint(x: 164, y: 428),
                         CGPoint(x: 186, y: 388), CGPoint(x: 204, y: 366),
                         CGPoint(x: 244, y: 360), CGPoint(x: 300, y: 348)])), // low L → junction → flat R
                mk(ln(CGPoint(x: 204, y: 560), CGPoint(x: 158, y: 700))),
                mk(ln(CGPoint(x: 206, y: 560), CGPoint(x: 252, y: 700))),
            ], truth: [P(.head), P(.torso), .armPair, P(.leftLeg), P(.rightLeg)]),
            // Shallow V through the spine: one branch hangs down-left, the other points
            // up-right (the TopHat "doubled arm" screenshot). Nearly straight — the bend is
            // too shallow for any fold test, but per-side reach still reads two arms.
            UserFixture(name: "vArmsUp", strokes: [
                mk(ell(CGPoint(x: 200, y: 250), 52, 62)),
                mk(ln(CGPoint(x: 202, y: 314), CGPoint(x: 204, y: 560))),
                mk(poly([CGPoint(x: 150, y: 470), CGPoint(x: 176, y: 428),
                         CGPoint(x: 203, y: 388), CGPoint(x: 246, y: 362),
                         CGPoint(x: 288, y: 338)])),                       // down-left ↘ junction ↗ up-right
                mk(ln(CGPoint(x: 204, y: 560), CGPoint(x: 158, y: 700))),
                mk(ln(CGPoint(x: 206, y: 560), CGPoint(x: 252, y: 700))),
            ], truth: [P(.head), P(.torso), .armPair, P(.leftLeg), P(.rightLeg)]),
            // Two separate arms at different heights, each slightly DISCONNECTED from the
            // spine (a visible gap between arm root and body).
            UserFixture(name: "floatSideArms", strokes: [
                mk(ell(CGPoint(x: 200, y: 250), 52, 62)),
                mk(ln(CGPoint(x: 202, y: 314), CGPoint(x: 204, y: 560))),
                mk(ln(CGPoint(x: 186, y: 362), CGPoint(x: 130, y: 398))),  // L arm, root 16pt off the spine
                mk(ln(CGPoint(x: 222, y: 432), CGPoint(x: 280, y: 472))),  // R arm, lower + 18pt off
                mk(ln(CGPoint(x: 204, y: 560), CGPoint(x: 158, y: 700))),
                mk(ln(CGPoint(x: 206, y: 560), CGPoint(x: 252, y: 700))),
            ], truth: [P(.head), P(.torso), P(.leftArm), P(.rightArm), P(.leftLeg), P(.rightLeg)]),
            // A NARROW ∧ legs stroke on a WIDE-armed figure: the feet sit closer together
            // than 30% of the figure width (which is dominated by the T-pose arm span), so a
            // figure-width endpoint gate on the leg-pair split wrongly vetoed it — both legs
            // then glued to one hip and limped through the scissor walk. The pair split must
            // be judged stroke-locally (clearance + junction-at-top), never vs figure width.
            UserFixture(name: "narrowVLegs", strokes: [
                mk(ell(CGPoint(x: 200, y: 250), 52, 62)),
                mk(ln(CGPoint(x: 202, y: 314), CGPoint(x: 204, y: 560))),  // spine
                mk(ln(CGPoint(x: 202, y: 340), CGPoint(x: 62, y: 330))),   // L arm: wide T-pose
                mk(ln(CGPoint(x: 206, y: 340), CGPoint(x: 344, y: 334))),  // R arm: wide T-pose
                mk(poly([CGPoint(x: 170, y: 700), CGPoint(x: 204, y: 562),
                         CGPoint(x: 240, y: 706)])),                       // BOTH legs: one NARROW ∧
            ], truth: [P(.head), P(.torso), P(.leftArm), P(.rightArm), .legPair]),
            // A SMALL figure drawn high on the canvas (issue #2: animation occluded by the
            // header/bottom bars). Also exercised by the staging check.
            UserFixture(name: "smallHigh", strokes: [
                mk(ell(CGPoint(x: 196, y: 150), 26, 28)),
                mk(ln(CGPoint(x: 196, y: 178), CGPoint(x: 197, y: 250))),
                mk(ln(CGPoint(x: 196, y: 196), CGPoint(x: 158, y: 232))),
                mk(ln(CGPoint(x: 197, y: 196), CGPoint(x: 236, y: 232))),
                mk(ln(CGPoint(x: 197, y: 250), CGPoint(x: 172, y: 312))),
                mk(ln(CGPoint(x: 197, y: 250), CGPoint(x: 222, y: 312))),
            ], truth: [P(.head), P(.torso), P(.leftArm), P(.rightArm), P(.leftLeg), P(.rightLeg)]),
        ]
    }

    /// Diag + PNG dumps for the fixtures (the scored pass/fail lives in run()).
    /// Joints + per-stroke part histograms, for reading a rig off a text file.
    private static func diagText(_ rig: Rig) -> String {
        let s = rig.skeleton
        var d = " bbox=\(s.bbox) conf=\(rig.confidence) art=\(rig.articulated)\n neck=\(s.neck) head=\(s.headCenter) r=\(s.headRadius)\n"
        d += " Lsh=\(s.leftShoulder) Lel=\(s.leftElbow) Lhand=\(s.leftHand)\n"
        d += " Rsh=\(s.rightShoulder) Rel=\(s.rightElbow) Rhand=\(s.rightHand)\n"
        d += " hip=\(s.hipCenter) feet=\(s.feet)\n"
        if !rig.demotions.isEmpty {
            d += " demotions: " + rig.demotions.map { "\($0.side):\($0.reason) strokes=\($0.strokes)" }.joined(separator: "; ") + "\n"
        }
        for (i, st) in rig.strokes.enumerated() {
            var counts: [BodyPart: Int] = [:]
            for p in st.parts { counts[p, default: 0] += 1 }
            let bb = st.points.reduce(into: (CGFloat.infinity, -CGFloat.infinity, CGFloat.infinity, -CGFloat.infinity)) {
                $0.0 = min($0.0, $1.x); $0.1 = max($0.1, $1.x); $0.2 = min($0.2, $1.y); $0.3 = max($0.3, $1.y)
            }
            let hist = counts.sorted { "\($0.key)" < "\($1.key)" }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            d += " stroke\(i) rigid=\(st.rigid) x[\(Int(bb.0))-\(Int(bb.1))] y[\(Int(bb.2))-\(Int(bb.3))]  \(hist)\n"
        }
        return d
    }

    private static func dumpUserFigures() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let times: [Double] = [0.8, 2.5, 4.0, 6.0]
        for f in userFixtures() {
            let name = f.name
            let rig = RigFitter.fit(PKDrawing(strokes: f.strokes), traits: traits)
            // text diagnostic: joints + per-stroke part histograms
            let s = rig.skeleton
            var d = "\(name)\n bbox=\(s.bbox)\n neck=\(s.neck) head=\(s.headCenter) r=\(s.headRadius)\n"
            d += " Lsh=\(s.leftShoulder) Lel=\(s.leftElbow) Lhand=\(s.leftHand)\n"
            d += " Rsh=\(s.rightShoulder) Rel=\(s.rightElbow) Rhand=\(s.rightHand)\n"
            d += " hip=\(s.hipCenter) feet=\(s.feet)\n"
            for (i, st) in rig.strokes.enumerated() {
                var counts: [BodyPart: Int] = [:]
                for p in st.parts { counts[p, default: 0] += 1 }
                let bb = st.points.reduce(into: (CGFloat.infinity, -CGFloat.infinity, CGFloat.infinity, -CGFloat.infinity)) {
                    $0.0 = min($0.0, $1.x); $0.1 = max($0.1, $1.x); $0.2 = min($0.2, $1.y); $0.3 = max($0.3, $1.y)
                }
                let hist = counts.sorted { "\($0.key)" < "\($1.key)" }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
                d += " stroke\(i) rigid=\(st.rigid) x[\(Int(bb.0))-\(Int(bb.1))] y[\(Int(bb.2))-\(Int(bb.3))]  \(hist)\n"
            }
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("u_\(name)_diag.txt")
            try? d.data(using: .utf8)?.write(to: url)
            writeImage(renderRig(rig, pose: .rest(rig.skeleton), size: bounds.size, partColors: true, joints: true), "u_\(name)_rig.png")
            let setup = RoutineSetup.make(rig: rig, canvasBounds: bounds, contentOffset: .zero)
            let routine = AnimationFactory.make(.classic, setup)
            for t in times {
                let lbl = String(format: "%04.1f", t).replacingOccurrences(of: ".", with: "")
                writeImage(renderRig(rig, pose: routine.pose(at: t), size: bounds.size, partColors: false, joints: false), "u_\(name)_t\(lbl).png")
            }
        }
    }

    /// Render the REAL default (Classic) animation routine at several time points — this is
    /// what the performer actually sees (the static stress pose above can lie about how large
    /// routine rotations land). Frames cover drop → wave → walk → trick.
    private static func dumpRoutineFrames() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let figs: [(String, FigureSpec)] = [
            ("stick", FigureSpec(head: .circle, torso: .spineLine, arm: .lineDown, leg: .lineSplay, scale: 1.1, seed: 3)),
            ("char2", FigureSpec(head: .bigCircle, torso: .roundedBlob, arm: .outlineMitten, leg: .outlineTapered, deco: [.face], scale: 1.1, seed: 2)),
        ]
        let times: [Double] = [0.8, 2.5, 4.0, 6.0, 9.0]
        for (name, spec) in figs {
            let (drawing, _) = RigPartLibrary.build(spec, canvas: bounds.size)
            let rig = RigFitter.fit(drawing, traits: traits)
            let setup = RoutineSetup.make(rig: rig, canvasBounds: bounds, contentOffset: .zero)
            let routine = AnimationFactory.make(.classic, setup)
            for t in times {
                let pose = routine.pose(at: t)
                let label = String(format: "%04.1f", t).replacingOccurrences(of: ".", with: "")
                writeImage(renderRig(rig, pose: pose, size: bounds.size, partColors: false, joints: false), "anim_\(name)_t\(label).png")
            }
        }
    }

    private static let partColor: [BodyPart: UIColor] = [
        .head: .systemYellow, .torso: .white,
        .leftArm: .systemGreen, .leftForearm: .systemMint,
        .rightArm: .systemBlue, .rightForearm: .systemCyan,
        .leftLeg: .systemOrange, .leftShin: .systemRed,
        .rightLeg: .systemPurple, .rightShin: .systemPink,
    ]

    private static func renderRig(_ rig: Rig, pose: FigurePose, size: CGSize, partColors: Bool, joints: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            for stroke in rig.strokes where stroke.points.count >= 2 {
                if partColors {
                    // Colour each SEGMENT by its point's part — shows true per-point labels.
                    for i in 1..<stroke.points.count {
                        let a = rig.worldPoint(stroke.points[i - 1], part: stroke.parts[i - 1], pose: pose)
                        let b = rig.worldPoint(stroke.points[i], part: stroke.parts[i], pose: pose)
                        let seg = UIBezierPath(); seg.move(to: a); seg.addLine(to: b)
                        (partColor[stroke.parts[i]] ?? .gray).setStroke()
                        seg.lineWidth = stroke.width; seg.lineCapStyle = .round; seg.stroke()
                    }
                    continue
                }
                let path = UIBezierPath()
                for (i, pt) in stroke.points.enumerated() {
                    let wp = rig.worldPoint(pt, part: stroke.parts[i], pose: pose)
                    if i == 0 { path.move(to: wp) } else { path.addLine(to: wp) }
                }
                UIColor(stroke.color).setStroke()
                path.lineWidth = stroke.width
                path.lineCapStyle = .round; path.lineJoinStyle = .round
                path.stroke()
            }
            if joints {
                let s = rig.skeleton
                let marks: [(CGPoint, UIColor)] = [
                    (s.neck, .systemYellow), (s.leftShoulder, .systemGreen), (s.rightShoulder, .systemBlue),
                    (s.leftElbow, .systemMint), (s.rightElbow, .systemCyan),
                    (s.hipCenter, .systemRed), (s.leftHand, .green), (s.rightHand, .blue),
                    (s.feet, .magenta),
                ]
                for (p, c) in marks {
                    c.setFill()
                    ctx.cgContext.fillEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                }
            }
        }
    }

    /// Save the exact PKDrawing strokes (for replaying a real on-device figure in the harness).
    /// Writes to Documents/cap_<n>.drawing — pull with `simctl get_app_container … data`.
    static func captureDrawing(_ drawing: PKDrawing) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var n = 0
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("cap_\(n).drawing").path) { n += 1 }
        try? drawing.dataRepresentation().write(to: dir.appendingPathComponent("cap_\(n).drawing"))
    }

    /// Replay every captured cap_*.drawing through the rig + REAL Classic routine, dumping
    /// the rest rig (part-coloured + joints) and routine frames. Call from app init (DEBUG).
    static func replayCaptured() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var n = 0
        while let data = try? Data(contentsOf: dir.appendingPathComponent("cap_\(n).drawing")),
              let drawing = try? PKDrawing(data: data) {
            let rig = RigFitter.fit(drawing, traits: traits)
            writeImage(renderRig(rig, pose: .rest(rig.skeleton), size: bounds.size, partColors: true, joints: true), "cap_\(n)_rig.png")
            let setup = RoutineSetup.make(rig: rig, canvasBounds: bounds, contentOffset: .zero)
            let routine = AnimationFactory.make(.classic, setup)
            for t in [0.8, 2.5, 4.0, 6.0] as [Double] {
                let lbl = String(format: "%04.1f", t).replacingOccurrences(of: ".", with: "")
                writeImage(renderRig(rig, pose: routine.pose(at: t), size: bounds.size, partColors: false, joints: false), "cap_\(n)_t\(lbl).png")
            }
            n += 1
        }
    }

    private static func writeImage(_ image: UIImage, _ name: String) {
        guard let data = image.pngData() else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        try? data.write(to: url)
    }

    private static func fr(_ v: (n: Int, fail: Int)) -> CGFloat { v.n == 0 ? 0 : CGFloat(v.fail) / CGFloat(v.n) }
    private static func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }

    private static func write(_ s: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("righarness.txt")
        try? s.data(using: .utf8)?.write(to: url)
    }
}
#endif
