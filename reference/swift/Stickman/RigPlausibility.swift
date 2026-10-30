import Foundation
import CoreGraphics

// Post-fit plausibility validation — the outlier SAFETY NET.
//
// The fitter's confidence score is presence-based (head found, both arms present, …), so a
// catastrophic MISLABEL — the hip area read as an arm, the whole body read as an arm, a torso
// outline split into two counter-rotating "arms" — can still score high and articulate. When
// such a limb then swings by a routine's full arm angle (up to ~2 rad) about its snapped
// pivot, it visibly FLINGS. This pass inspects the finished labels + skeleton for geometric
// plausibility and demotes any implausible limb to `.torso` — the graceful per-stroke freeze:
// a `.torso` point takes no local rotation, so the demoted ink simply rides the root (drop /
// walk / lean) exactly like the proven non-articulated path, while the rest of the figure
// keeps performing.
//
// Runs INSIDE RigFitter.fit, after refineJoints and BEFORE the forearm split — so only
// whole-arm/leg labels exist (no FK parent-chain bookkeeping), and the downstream
// leftHandPart/rightHandPart computation automatically resolves a demoted side to `.torso`
// (props ride the root via the estimated-hand semantics).
//
// TUNING STANCE: every threshold clears the worst LEGITIMATE geometry the harness generates
// by a wide margin, and the harness gates "0 demotions on known-good figures" (clean set +
// fixtures). If a healthy figure ever trips a check, WIDEN that one threshold — never add
// compensating logic. A frozen good arm (a magician who never waves) is a lesser failure
// than a fling, but it is still a failure; the net exists for high-confidence implausibility
// only.
enum RigPlausibility {

    // Worst legitimate values (harness): lowAttach shoulder snap ≈ 0.45·trunk, asymArms
    // junction snap ≈ 0.59·trunk → band tops out at 0.72. A hanging arm's tip may dip past
    // the hip but its majority never does. A single mitten arm ≈ 28% of non-head ink. A
    // T-pose arm's lever ≈ 0.25·extent.
    private static let shoulderBandLo: CGFloat = -0.10   // × trunkLen, above the neck
    private static let shoulderBandHi: CGFloat = 0.72    // × trunkLen, below the neck
    // An arm attached low on a SHORT outlined torso only gets its first ARM label where it
    // exits the outline (its inside points read torso), so the labelled root sits deep —
    // the proportions sweep's legitimate worst ≈ 0.88. Hip clusters root at ≥ 1.0.
    private static let armRootDepthMax: CGFloat = 0.92   // topmost arm point, × trunkLen below the neck
    private static let belowHipFracMax: CGFloat = 0.60   // arm mass allowed below the hip band
    private static let sideInkFracMax: CGFloat = 0.45    // one side's arm ink ÷ non-head ink
    private static let leverExtentMax: CGFloat = 0.72    // shoulder→farthest-point ÷ figure extent
    // A SHORT torso makes any normal arm long relative to the trunk (an arm ≈ 2u on a 1.5u
    // trunk ≈ 1.4, the harness's short-torso worst ≈ 2.3) — the fling test proper is the
    // extent-relative lever above; this one only backstops a whole-body "arm".
    private static let leverTrunkMax: CGFloat = 3.2      // shoulder→farthest-point ÷ trunk length
    private static let escalateMassFrac: CGFloat = 0.50  // demoted ink ÷ non-head ink → full fallback

    enum Verdict {
        case ok
        case demoted            // parts were relabelled; re-refine the skeleton
        case fullFallback       // segmentation globally implausible; force the all-torso path
    }

    /// Inspect the labelled figure; demote implausible limbs to `.torso` in place.
    /// Appends one `RigDemotion` per frozen limb to `demotions`.
    static func validate(parts: inout [[BodyPart]], points: [[CGPoint]],
                         skeleton: Skeleton, bbox: CGRect,
                         demotions: inout [RigDemotion]) -> Verdict {
        let neck = skeleton.neck, hip = skeleton.hipCenter
        let trunkLen = max(hip.y - neck.y, 1)
        let bodyLen = max(bbox.maxY - neck.y, 1)
        let extent = max(bbox.width, bbox.height)

        // Per-stroke pre-demotion majorities — recorded on every demotion (including the
        // full-fallback ones) so the harness's false-positive metric can see what a demotion
        // undid. An empty preMajorities would silently opt a demotion out of FP accounting.
        func strokeMajorities() -> [BodyPart] {
            parts.map { ps in
                var counts: [BodyPart: Int] = [:]
                for p in ps { counts[p, default: 0] += 1 }
                return counts.max { $0.value < $1.value }?.key ?? .torso
            }
        }

        // ---- global tripwire: the trunk geometry itself is corrupt ----
        if hip.y < neck.y + bodyLen * 0.15 || hip.y > bbox.maxY - bodyLen * 0.02 {
            demotions.append(RigDemotion(side: "all", reason: "hip-sanity",
                                         strokes: Array(parts.indices), preMajorities: strokeMajorities()))
            return .fullFallback
        }

        // ---- gather per-side stats (pre-split labels: whole arms/legs only) ----
        var lArm: [CGPoint] = [], rArm: [CGPoint] = []
        var lLegN = 0, lLegHigh = 0, rLegN = 0, rLegHigh = 0
        var nonHead = 0
        let chestY = neck.y + bodyLen * 0.25
        for i in parts.indices {
            for (j, part) in parts[i].enumerated() {
                if part != .head { nonHead += 1 }
                switch part {
                case .leftArm: lArm.append(points[i][j])
                case .rightArm: rArm.append(points[i][j])
                case .leftLeg: lLegN += 1; if points[i][j].y < chestY { lLegHigh += 1 }
                case .rightLeg: rLegN += 1; if points[i][j].y < chestY { rLegHigh += 1 }
                default: break
                }
            }
        }
        guard nonHead > 0 else { return .ok }

        // Signed mean offset of a point set vs the lean-tracking neck→hip centreline.
        func meanOffset(_ pts: [CGPoint]) -> CGFloat? {
            guard !pts.isEmpty else { return nil }
            var sum: CGFloat = 0
            for p in pts {
                let f = min(max((p.y - neck.y) / trunkLen, 0), 1)
                sum += p.x - (neck.x + (hip.x - neck.x) * f)
            }
            return sum / CGFloat(pts.count)
        }

        // ---- per-side arm checks (any hit demotes that side) ----
        func armProblem(_ pts: [CGPoint], shoulder: CGPoint) -> String? {
            guard !pts.isEmpty else { return nil }
            // Arms attach on the UPPER trunk, so a genuine arm always has points near its
            // attachment. An "arm" whose TOPMOST point sits down by the hip is a mislabelled
            // hip/waist cluster (belt, tail, leg top) — the classic "hip extends out" fling.
            let rootDepth = (pts.map(\.y).min()! - neck.y) / trunkLen
            if rootDepth > armRootDepthMax {
                return "arm-root-depth(\(String(format: "%.2f", rootDepth)))"
            }
            let sy = (shoulder.y - neck.y) / trunkLen
            if sy < shoulderBandLo || sy > shoulderBandHi {
                return "shoulder-band(\(String(format: "%.2f", sy)))"
            }
            let below = pts.reduce(0) { $0 + ($1.y > hip.y + bodyLen * 0.10 ? 1 : 0) }
            if CGFloat(below) > CGFloat(pts.count) * belowHipFracMax { return "arm-below-hip" }
            if CGFloat(pts.count) > CGFloat(nonHead) * sideInkFracMax { return "arm-ink-cap" }
            var lever: CGFloat = 0
            for p in pts { lever = max(lever, hypot(p.x - shoulder.x, p.y - shoulder.y)) }
            if lever > extent * leverExtentMax { return "fling-lever(\(Int(lever))/\(Int(extent)))" }
            if lever > trunkLen * leverTrunkMax { return "arm-vs-trunk" }
            return nil
        }

        var toDemote: [(part: BodyPart, side: String, reason: String)] = []
        if let r = armProblem(lArm, shoulder: skeleton.leftShoulder) { toDemote.append((.leftArm, "Larm", r)) }
        if let r = armProblem(rArm, shoulder: skeleton.rightShoulder) { toDemote.append((.rightArm, "Rarm", r)) }

        // Both "arms" occupying the SAME side of the body: exactly one label contradicts the
        // side it actually occupies — freeze that one.
        if let lm = meanOffset(lArm), let rm = meanOffset(rArm) {
            let thresh = max(6, bbox.width * 0.08)
            if lm > thresh && rm > thresh, !toDemote.contains(where: { $0.part == .leftArm }) {
                toDemote.append((.leftArm, "Larm", "side-contradiction"))
            } else if lm < -thresh && rm < -thresh, !toDemote.contains(where: { $0.part == .rightArm }) {
                toDemote.append((.rightArm, "Rarm", "side-contradiction"))
            }
        }

        // A "leg" whose mass sits up in the chest is not a leg.
        if lLegN > 0, lLegHigh * 2 > lLegN { toDemote.append((.leftLeg, "Lleg", "leg-in-chest")) }
        if rLegN > 0, rLegHigh * 2 > rLegN { toDemote.append((.rightLeg, "Rleg", "leg-in-chest")) }

        // LEGS GO DOWN: a leg-majority stroke that neither reaches toward the ground nor
        // descends is hip-lateral body ink (a tail, a skirt curl, a belt end below the
        // crotch) — riding a leg it would wiggle with the walk and drag the hip-raise around.
        var legFreezeStrokes: [Int] = []
        for i in parts.indices where !parts[i].isEmpty {
            let legN = parts[i].reduce(0) { $0 + ($1 == .leftLeg || $1 == .rightLeg ? 1 : 0) }
            guard legN * 2 > parts[i].count else { continue }
            var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            for p in points[i] {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            let reachesGround = maxY >= bbox.maxY - bodyLen * 0.25
            let descends = (maxY - minY) >= (maxX - minX) * 1.2
            if !reachesGround && !descends { legFreezeStrokes.append(i) }
        }

        guard !toDemote.isEmpty || !legFreezeStrokes.isEmpty else { return .ok }

        // ---- apply: freeze each flagged limb to .torso (recording pre-demotion majorities) ----
        let preMajor = strokeMajorities()
        var demotedMass = 0
        for d in toDemote {
            var strokes: [Int] = []
            for i in parts.indices {
                var hit = false
                for j in parts[i].indices where parts[i][j] == d.part {
                    parts[i][j] = .torso
                    demotedMass += 1
                    hit = true
                }
                if hit { strokes.append(i) }
            }
            demotions.append(RigDemotion(side: d.side, reason: d.reason,
                                         strokes: strokes, preMajorities: strokes.map { preMajor[$0] }))
        }
        if !legFreezeStrokes.isEmpty {
            for i in legFreezeStrokes {
                for j in parts[i].indices where parts[i][j] == .leftLeg || parts[i][j] == .rightLeg {
                    parts[i][j] = .torso
                    demotedMass += 1
                }
            }
            demotions.append(RigDemotion(side: "leg", reason: "leg-not-grounded",
                                         strokes: legFreezeStrokes,
                                         preMajorities: legFreezeStrokes.map { preMajor[$0] }))
        }

        // Escalate only when the demotions consumed most of the body — the segmentation is
        // globally wrong, so the proven whole-figure fallback beats a half-frozen chimera.
        if CGFloat(demotedMass) > CGFloat(nonHead) * escalateMassFrac {
            demotions.append(RigDemotion(side: "all", reason: "mass(\(demotedMass)/\(nonHead))",
                                         strokes: Array(parts.indices), preMajorities: preMajor))
            return .fullFallback
        }
        return .demoted
    }
}
