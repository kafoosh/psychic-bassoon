import SwiftUI
import PencilKit
import UIKit

// Turns the participant's PKDrawing into a rigged figure.
//
// THE MODEL: a stickman's strokes ARE its bones, but a fuller-bodied character's strokes
// are SILHOUETTE OUTLINES of thick parts — the bone is the medial axis of a filled region,
// not any stroke. So we don't classify the drawn lines directly. We RASTERIZE the figure
// into an occupancy grid (closed strokes filled as solid polygons, open strokes stamped as
// thick lines), read each row's horizontal occupied RUNS, and reason about the silhouette:
//   • the central run's MEASURED width is the torso width → a wide rectangle/blob's edges
//     sit INSIDE the torso and are never mistaken for arms;
//   • a lateral run beside the torso is an arm; below the crotch every run is a leg;
//   • a CLOSED-LOOP stroke is bound to ONE body part (majority vote) and never split at the
//     elbow → both silhouette walls share one FK pivot and rotate as one rigid sheet.
// Thin stick figures are the degenerate case (narrow central run, open strokes that still
// split arm→forearm for the wave), so they rig exactly as before. Low confidence → a
// graceful whole-body fallback. Stroke colours are resolved against the canvas appearance.
enum RigFitter {

    #if DEBUG
    /// Harness-only step trace: when non-nil, `fit` appends a per-stroke label histogram after
    /// each labelling step so a mislabel can be pinned to the pass that made it.
    nonisolated(unsafe) static var trace: String? = nil
    #endif

    static func fit(_ drawing: PKDrawing, traits: UITraitCollection) -> Rig {
        func traceStep(_ name: String, _ parts: [[BodyPart]], _ extra: String = "") {
            #if DEBUG
            guard trace != nil else { return }
            var line = "  [\(name)]\(extra)\n"
            for (i, ps) in parts.enumerated() {
                var counts: [BodyPart: Int] = [:]
                for p in ps { counts[p, default: 0] += 1 }
                line += "    s\(i): " + counts.sorted { "\($0.key)" < "\($1.key)" }.map { "\($0.key):\($0.value)" }.joined(separator: " ") + "\n"
            }
            trace! += line
            #endif
        }

        // ---- Step 0: sample → densified polylines, resolve colours, flag closed loops ----
        struct Raw { var points: [CGPoint]; var color: Color; var width: CGFloat; var closed: Bool; var fat: Bool }
        var raw: [Raw] = []
        for stroke in drawing.strokes {
            let t = stroke.transform
            var pts: [CGPoint] = []
            for sp in stroke.path { pts.append(sp.location.applying(t)) }
            pts = densify(pts)
            // A single-tap DOT (an eye, a nose, a freckle) samples as ONE control point — or a
            // tight cluster with no real extent — so it died on the guard below and face details
            // vanished the moment the figure came to life. Keep it: give the point a sliver of
            // length so its bbox is real (the detail-folding pass then binds it to the head) and
            // so the stage's round line cap paints it (a zero-length path can render as nothing).
            if pts.count == 1 { pts.append(pts[0]) }
            if let bb = boundingBox(pts), max(bb.width, bb.height) < 0.7 {
                let c = CGPoint(x: bb.midX, y: bb.midY)
                pts = [CGPoint(x: c.x - 0.35, y: c.y), CGPoint(x: c.x + 0.35, y: c.y)]
            }
            guard pts.count >= 2 else { continue }
            // The visible pen weight, MEASURED from the stroke's own rendered pixels (area ÷
            // centreline length). PKStrokePoint.size understates what PencilKit actually paints
            // — and varies by ink — so the animated figure came out thinner than it was drawn.
            // Measuring the render is ink-agnostic and self-calibrating, so the live stroke keeps
            // the exact weight on screen. Falls back to the nominal size if the measure fails.
            let nominal = stroke.path.count > 0
                ? max(2, stroke.path.reduce(0) { $0 + $1.size.width } / CGFloat(stroke.path.count))
                : 4
            let w = renderedWidth(stroke, fallback: nominal)
            let resolved = stroke.ink.color.resolvedColor(with: traits)
            // `closed` = a tight loop; `fat` = a 2D outline (incl. an OPEN "U") — both are
            // silhouette outlines that must be FILLED when rasterized and bound RIGIDLY.
            raw.append(Raw(points: pts, color: Color(uiColor: resolved), width: w, closed: isClosed(pts), fat: isFat(pts)))
        }

        let allPoints = raw.flatMap { $0.points }
        let bbox = boundingBox(allPoints) ?? .zero
        guard bbox.width > 1, bbox.height > 1, !raw.isEmpty else {
            return allTorsoFallback(raw.map { ($0.points, $0.color, $0.width) }, bbox: bbox)
        }
        let avgInkW = raw.map(\.width).reduce(0, +) / CGFloat(raw.count)

        // ---- Step 1: rasterize (closed → filled polygon, open → thick stamped line) ----
        var grid = RasterGrid(bbox: bbox)
        for r in raw {
            // Fill any outline (closed loop OR open 2D "U"); else a hollow outline reads as two
            // runs with a gap and is mistaken for two legs / a split torso.
            if r.closed || r.fat { grid.fillPolygon(r.points) }
            grid.stampPolyline(r.points, width: r.width)
        }
        // NB: no morphological close — polygon-fill already solidifies outlines, and a close
        // would bridge the narrow inseam between two closely-drawn legs into one blob (defeating
        // crotch detection). Touching strokes don't need bridging: runs are read per row.

        // ---- Step 2: per-row occupied runs ----
        let rowRuns: [[Run]] = (0..<grid.rows).map { grid.runs(row: $0) }
        guard let topRow = (0..<grid.rows).first(where: { !rowRuns[$0].isEmpty }),
              let botRow = (0..<grid.rows).last(where: { !rowRuns[$0].isEmpty }) else {
            return allTorsoFallback(raw.map { ($0.points, $0.color, $0.width) }, bbox: bbox)
        }

        // ---- Step 3: head (largest centred top-band blob), neck, spine track ----
        let topCenterX = robustTopCenterX(allPoints, bbox)
        let headDet = detectHead(raw.map { $0.points }, figure: bbox, centerX: topCenterX, inkWidth: avgInkW)
        let headIndex = headDet?.index ?? -1
        let headCenter = headDet?.center ?? CGPoint(x: robustTopCenterX(allPoints, bbox), y: bbox.minY + 0.13 * bbox.height)
        let headRadius = headDet?.radius ?? max(0.10 * bbox.height, 14)
        // The neck sits at the head's actual BOTTOM edge, not headCenter+radius — a wide oval
        // head's radius (= width/2) would otherwise reach well below it and swallow the
        // shoulders/arm-tops into the head zone.
        let headBottom = headDet?.bottom ?? (headCenter.y + headRadius)
        let neckY = min(headBottom, bbox.minY + 0.55 * bbox.height)
        let neckRow = grid.row(neckY)

        // Spine x per row: follow the run nearest the previous spine x, seeded at the head.
        // Robust to lean (the centreline tracks the body down) and to splayed limbs.
        var spineX = [CGFloat](repeating: headCenter.x, count: grid.rows)
        var prev = headCenter.x
        let maxSpineStep = max(2, grid.cellSize * 0.5)
        for r in topRow...botRow {
            let rs = rowRuns[r]
            if rs.isEmpty { spineX[r] = prev; continue }
            // Prefer the run that still CONTAINS the spine; else the nearest. Then move toward
            // its centre only a little per row — the spine is near-vertical, so a big jump means
            // an arm merged into the run, and we must NOT let the centreline drift onto the arm
            // (which would mislabel that arm as torso and the spine as an arm).
            let cr = rs.first { $0.x0 <= prev && prev <= $0.x1 } ?? rs.min { abs($0.xMid - prev) < abs($1.xMid - prev) }!
            spineX[r] = prev + max(-maxSpineStep, min(maxSpineStep, cr.xMid - prev))
            prev = spineX[r]
        }
        for r in 0..<topRow { spineX[r] = spineX[topRow] }

        // ---- Step 4: crotch via the band gap-walk, run-aware (immune to lean) ----
        // Walking UP from the feet: a leg band has two runs split by a wide gap; the crotch
        // is the top of the feet-connected two-run region (where the legs merge). We stop at
        // the single-run torso, so the ARMS (a higher multi-run band) are never read as legs.
        let gapThresh = max(grid.cellSize * 2, bbox.height * 0.025)   // closely-spaced filled legs still split
        let scanTopRow = grid.row(neckY + (bbox.maxY - neckY) * 0.30)
        var crotchRow = grid.row(neckY + (bbox.maxY - neckY) * 0.55)   // fallback
        var crotchX = spineX[min(crotchRow, grid.rows - 1)]
        // A thick pen fills ≈ inkWidth/cellSize rows solid where the legs meet, so the walk
        // must tolerate that many merged rows before concluding the crotch — a fixed 1-row
        // tolerance stopped a fat-pen walk far below the true crotch (the too-low crotch that
        // strands leg ink in the arm band). Capped so the walk can't tunnel through the torso.
        let missCap = min(6, max(2, Int(ceil(avgInkW / max(grid.cellSize, 1)))))
        // The band above the legs is read as "still legs" only while it LOOKS like two legs:
        // once a row holds ≥3 runs (spine + arms, or arms hanging beside the leg tops on a
        // short torso) or the gap's midpoint jumps sideways (the widest gap switched from
        // between-the-legs to between-an-arm-and-the-spine), the walk has reached the arm
        // band and stops. Without this a short-torso figure's hanging arms were walked
        // straight through — the crotch landed at the SHOULDERS and both arms became legs.
        // (Feet — a dash or blob at each leg tip — add runs too, so the stops only apply
        // above the bottom 30% of the body; the arm band is never that low.)
        var legIdx = -1, misses = 0
        var lastMid: CGFloat? = nil
        let midJump = max(grid.cellSize * 2.5, bbox.width * 0.06)
        let feetBandY = bbox.maxY - (bbox.maxY - neckY) * 0.30
        for r in stride(from: botRow, through: scanTopRow, by: -1) {
            let (two, mid) = twoLegged(rowRuns[r], gapThresh: gapThresh)
            if two {
                if legIdx >= 0, grid.cellY(r) < feetBandY {
                    if rowRuns[r].count >= 3 { break }
                    if let lm = lastMid, abs(mid - lm) > midJump { break }
                }
                legIdx = r; crotchX = mid; misses = 0; lastMid = mid
            }
            else if legIdx >= 0 { misses += 1; if misses > missCap { break } }
        }
        if legIdx >= 0 {
            crotchRow = legIdx
        } else {                                  // no gap → legs drawn straight down / touching
            let widthThresh = max(grid.cellSize * 4, bbox.width * 0.30)
            for r in stride(from: botRow, through: scanTopRow, by: -1) {
                if let cr = central(rowRuns[r], spineX: spineX[r]), cr.w <= widthThresh {
                    crotchRow = r; crotchX = cr.xMid; break
                }
            }
        }
        crotchRow = min(max(crotchRow, neckRow + 1), botRow)
        var crotchY = grid.cellY(crotchRow)

        // ---- Step 5: torso width MEASURED from the central run (the anti-edge-as-arm fix) ----
        // Measure over the MIDDLE of the torso (35–90% neck→crotch) where arms don't reach, so
        // a merged-in arm at the shoulders can't inflate it. This width is then used to TRIM the
        // torso: anything in the central run beyond it is an arm (handles arms that touch the
        // torso — Character 1's corner arms, Character 2's attached loops — uniformly).
        var halfs: [CGFloat] = []
        if crotchRow > neckRow + 1 {
            for r in (neckRow + 1)..<crotchRow {
                if let cr = central(rowRuns[r], spineX: spineX[r]) { halfs.append(cr.w / 2) }
            }
        }
        // A 30th-percentile of central-run half-widths over the whole torso gives the un-merged
        // torso "waist": an arm touching the torso only ADDS width (high percentile), so a low
        // percentile can't be inflated by a merged arm. The torso (a closed stroke) survives
        // any over-trim via its majority vote; the arm gets correctly peeled off.
        let sortedHalfs = halfs.sorted()
        let measuredHalf = sortedHalfs.isEmpty ? max(avgInkW, 8) : sortedHalfs[Int(CGFloat(sortedHalfs.count) * 0.30)]
        // Floor is just a small absolute guard against a degenerate zero-width torso — NOT
        // head-relative (a big head must not widen the torso band and swallow arm roots on a
        // thin-spine stick figure). The measured waist already carries the true torso width.
        let torsoHalfW = min(max(measuredHalf, 6), bbox.width * 0.45)
        let torsoReach = torsoHalfW * 1.25     // taper/wobble tolerance before calling it an arm
        let bodyLen = max(bbox.maxY - neckY, 1)

        // ---- Step 5b: leg-stroke-first detection (robust to legs drawn TO THE SIDE) ----
        // The symmetric run-gap crotch (Step 4) assumes legs descend roughly straight and splay
        // EVENLY about the spine. It breaks when both legs veer to ONE side (the crotch lands too
        // low and the lateral leg points read as ARMS) or when the legs CROSS (a single leg gets
        // split across the crotch and tears in the scissor walk). So: find the THIN lower-body
        // LEG strokes directly, side each WHOLE stroke by its ROOT (top end) — by RELATIVE order,
        // not side of any axis, so two legs both veering one way still resolve to one left + one
        // right — and relocate the single central hip to the roots' convergence. The arm/leg
        // boundary is a root-HEIGHT gate: arms root at the shoulders (high), legs at the hips
        // (low), which is provably side-agnostic and keeps every arm an arm.
        //
        // WHAT COUNTS AS A LEG STROKE (the anti-"leg top swings as an arm" gates): the old
        // test demanded the root in the lower 60% of the body (`root.y > 0.40·bodyLen`). That
        // is only true of the baseline's proportions (crotch ≈ 56% of neck→feet); a SHORT
        // torso with LONG legs roots its legs at 25–40%, the pass went silent, and the legacy
        // gap-walk crotch (which lands too LOW on thick pens / narrow or crossed legs) left
        // the leg TOPS in the arm band — the reported indecent rig: a chunk of leg hinged at
        // the hip and swung up like an arm. Now a thin descending stroke is a leg if it roots
        // in the lower body OR REACHES THE GROUND — a hanging arm ends well above the feet
        // whatever the proportions, a leg always lands there. Legs drawn thigh+shin are
        // CHAINED: a descending stroke whose foot sits on a detected leg's root (the knee) is
        // that leg's upper segment, so the hip still rises to the thigh roots.
        let shoulderBandY = neckY + bodyLen * 0.18
        let hipBandY = neckY + bodyLen * 0.40
        let groundY = bbox.maxY - bodyLen * 0.20
        var legSide = [BodyPart?](repeating: nil, count: raw.count)
        var legStrokesDetected = false
        do {
            var legStrokes: [(i: Int, rootX: CGFloat, rootY: CGFloat)] = []
            var isLeg = [Bool](repeating: false, count: raw.count)
            var candidates: [(i: Int, root: CGPoint, foot: CGPoint)] = []
            for i in raw.indices where !raw[i].closed && !raw[i].fat {
                let bb = boundingBox(raw[i].points) ?? .zero
                if bb.midY < neckY { continue }                       // an upper / head-zone stroke
                let (root, foot) = strokeRoot(raw[i].points)
                guard root.y >= shoulderBandY,                        // whole stroke hangs below the shoulders
                      foot.y - root.y > bodyLen * 0.08 else { continue } // real vertical descent (not a dash / horizontal)
                candidates.append((i, root, foot))
                // Reaches the ground, or roots low AND is leg-long: a two-stroke arm's FOREARM
                // also roots in the lower body on a short torso, but it is short and ends in
                // mid-air; a leg is the longest thing hanging off the figure.
                if foot.y - root.y > bodyLen * 0.12,
                   foot.y >= groundY || (root.y > hipBandY && foot.y - root.y > bodyLen * 0.25) {
                    isLeg[i] = true
                    legStrokes.append((i, root.x, root.y))
                }
            }
            // Chain upper segments (thigh above a detected shin): foot ON a leg root.
            let joinR = max(avgInkW * 2.5, bodyLen * 0.05)
            var grew = true
            while grew {
                grew = false
                for c in candidates where !isLeg[c.i] {
                    let touches = legStrokes.contains { ls in
                        !(ls.i == c.i) && hypot(c.foot.x - ls.rootX, c.foot.y - ls.rootY) <= joinR
                    }
                    if touches {
                        isLeg[c.i] = true
                        legStrokes.append((c.i, c.root.x, c.root.y))
                        grew = true
                    }
                }
            }
            if legStrokes.count >= 2 {
                legStrokesDetected = true
                // Hip x = the median root x (even counts average the middle pair, so two legs
                // meet in between and thigh+shin pairs don't bias it onto one leg).
                let xs = legStrokes.map(\.rootX).sorted()
                let hipX = xs.count % 2 == 1 ? xs[xs.count / 2] : (xs[xs.count / 2 - 1] + xs[xs.count / 2]) / 2
                if legStrokes.count == 2 {
                    let (lo, hi) = legStrokes[0].rootX <= legStrokes[1].rootX
                        ? (legStrokes[0], legStrokes[1]) : (legStrokes[1], legStrokes[0])
                    legSide[lo.i] = .leftLeg
                    legSide[hi.i] = .rightLeg
                } else {
                    for ls in legStrokes { legSide[ls.i] = ls.rootX < hipX ? .leftLeg : .rightLeg }
                }
                let topRootY = legStrokes.map(\.rootY).min() ?? crotchY
                let hipY = min(max(topRootY, neckY + bodyLen * 0.20), bbox.maxY - bbox.height * 0.10)
                crotchX = hipX
                crotchY = hipY
                crotchRow = min(max(grid.row(hipY), neckRow + 1), botRow)
            } else if let only = legStrokes.first {
                // ONE detached leg stroke (the other leg is the spine's own continuation — the
                // λ body — or the figure is one-legged): it is still a WHOLE leg, sided by the
                // way it goes from its root. The hip stays on the legacy path (gap-walk + the
                // leg-silhouette hip-raise), which needs ≥2 roots to converge.
                let (root, foot) = strokeRoot(raw[only.i].points)
                let dx = foot.x - root.x
                let side: BodyPart = abs(dx) > avgInkW ? (dx < 0 ? .leftLeg : .rightLeg)
                    : (root.x < spineX[grid.row(root.y)] ? .leftLeg : .rightLeg)
                legSide[only.i] = side
                // Its root still says where the hip IS — never let the gap-walk's crotch sit
                // ABOVE it (that is the walk having climbed into the arm band).
                let hipY = min(max(root.y, neckY + bodyLen * 0.20), bbox.maxY - bbox.height * 0.10)
                if hipY < crotchY {
                    crotchY = hipY
                    crotchRow = min(max(grid.row(hipY), neckRow + 1), botRow)
                    crotchX = (root.x + spineX[crotchRow]) / 2
                }
            }
        }

        // ---- Step 6: label every occupied cell. The central run is trimmed to the torso slab;
        //              its lateral overhang and any separate side run become arms. ----
        var label = [BodyPart?](repeating: nil, count: grid.rows * grid.cols)
        for r in topRow...botRow {
            let rs = rowRuns[r]
            let cx = spineX[r]
            let centralRun = central(rs, spineX: cx)
            for run in rs {
                if r <= neckRow {
                    for c in run.c0...run.c1 { label[r * grid.cols + c] = .head }
                } else if r >= crotchRow {
                    let part: BodyPart = run.xMid < crotchX ? .leftLeg : .rightLeg
                    for c in run.c0...run.c1 { label[r * grid.cols + c] = part }
                } else if let cr = centralRun, cr.c0 == run.c0, cr.c1 == run.c1 {
                    for c in run.c0...run.c1 {
                        let x = grid.cellX(c)
                        let part: BodyPart = x < cx - torsoReach ? .leftArm : (x > cx + torsoReach ? .rightArm : .torso)
                        label[r * grid.cols + c] = part
                    }
                } else {
                    // A separate side run between neck and crotch is an arm — but only in the
                    // UPPER body. A side run deeper than ~55% of the body, NEAR the crotch
                    // laterally, is leg ink that a too-low crotch stranded above crotchRow
                    // (thick pens / a merged inseam): labelling it arm is the "hip area
                    // extends out" fling. The lateral gate keeps a LONG hanging arm's hand —
                    // which can reach this deep but hangs far out from the crotch — an arm.
                    let deep = grid.cellY(r) > neckY + bodyLen * 0.55
                        && abs(run.xMid - crotchX) < max(torsoHalfW * 2, bbox.width * 0.18)
                    let part: BodyPart = deep ? (run.xMid < crotchX ? .leftLeg : .rightLeg)
                                              : (run.xMid < cx ? .leftArm : .rightArm)
                    for c in run.c0...run.c1 { label[r * grid.cols + c] = part }
                }
            }
        }

        // Geometry fallback for points whose cell has no label (wobble outside the silhouette).
        let neckX = spineX[neckRow]
        func centerAt(_ y: CGFloat) -> CGFloat {
            let y0 = neckY, y1 = crotchY
            guard y1 > y0 + 1 else { return crotchX }
            let t = min(max((y - y0) / (y1 - y0), 0), 1)
            return neckX + (crotchX - neckX) * t
        }
        func geomFallback(_ p: CGPoint) -> BodyPart {
            if hypot(p.x - headCenter.x, p.y - headCenter.y) <= headRadius * 1.2 || p.y < neckY { return .head }
            let cx = centerAt(p.y)
            if p.y >= crotchY { return p.x < cx ? .leftLeg : .rightLeg }
            if abs(p.x - cx) < torsoHalfW { return .torso }
            return p.x < cx ? .leftArm : .rightArm
        }
        func labelAt(_ p: CGPoint) -> BodyPart {
            let c = grid.col(p.x), r = grid.row(p.y)
            if let l = label[r * grid.cols + c] { return l }
            for rad in 1...2 {
                for dr in -rad...rad { for dc in -rad...rad {
                    let rr = r + dr, cc = c + dc
                    if rr >= 0, rr < grid.rows, cc >= 0, cc < grid.cols, let l = label[rr * grid.cols + cc] { return l }
                } }
            }
            return geomFallback(p)
        }

        // ---- Step 7: skin each stroke (closed loop → ONE rigid part; line → per-point) ----
        var regionParts: [[BodyPart]] = []
        var rigidFlags: [Bool] = []
        var foldHeadFlags: [Bool] = []
        for r0 in raw {
            let bb = boundingBox(r0.points) ?? .zero
            // Detail-folding: a small stroke inside the head disc (eyes/mouth/dots/hair/horns)
            // rides the head — it must never spawn a phantom limb near the shoulder.
            // (…and nothing of it below the neck: a raised arm beside a WIDE head — whose
            // "radius" is its half-width — sits inside that generous disc, but it is rooted
            // at the shoulder; face details, hair and ears never reach below the neck.)
            let foldHead = bb.midY < neckY + headRadius * 0.2
                && max(bb.width, bb.height) < headRadius * 1.5
                && hypot(bb.midX - headCenter.x, bb.midY - headCenter.y) < headRadius * 1.25
                && bb.maxY <= neckY + avgInkW
            // A stroke is RIGID (indivisible, one body part) if it's a closed loop OR a "fat"
            // 2D blob — an OUTLINE limb drawn as an open "U" (two walls that double back) is fat
            // even though it isn't closed, so it still rotates as one piece instead of tearing.
            // A thin line stays non-rigid and still splits arm→forearm for the wave.
            let rigid = !foldHead && (r0.closed || r0.fat)
            var parts = r0.points.map { foldHead ? .head : labelAt($0) }
            if foldHead {
                // all head already
            } else if rigid {
                let win = majorityPart(parts)            // an outline is indivisible
                parts = Array(repeating: win, count: parts.count)
            } else {
                parts = smoothParts(parts)               // kill 1–2-point flips on open lines
                // A hand RAISED to head height lives in rows the silhouette calls HEAD, so a
                // raised arm's tip gets glued to the head and tears off when the arm swings.
                parts = reclaimRaisedTips(parts, pts: r0.points, headCenter: headCenter, headRadius: headRadius)
            }
            regionParts.append(parts)
            rigidFlags.append(rigid)
            foldHeadFlags.append(foldHead)
        }

        // ---- Step 7g: a RAISED arm is not head ----
        // Rows above the neck are HEAD in the silhouette, so an arm raised beside the head
        // (shoulder → fist at head height) reads as head unless its root rows happened to get
        // arm labels for the tip-reclaim to extend. A thin, un-folded, head-majority stroke
        // that is not the head itself, ATTACHES at the trunk top (its lower end is below the
        // neck, near the trunk centreline) and reaches out BESIDE the head is a raised arm.
        // Hair, ears, a hat brim and face details never reach below the neck; a drawn neck
        // line sits on the centreline, not beside the head.
        for i in raw.indices where !rigidFlags[i] && !foldHeadFlags[i] && i != headIndex {
            let ps = regionParts[i], pts = raw[i].points
            guard pts.count >= 4 else { continue }
            let headN = ps.reduce(0) { $0 + ($1 == .head ? 1 : 0) }
            guard headN * 2 > ps.count else { continue }
            let a = pts[0], b = pts[pts.count - 1]
            let low = a.y >= b.y ? a : b
            guard low.y > neckY + avgInkW * 0.5,
                  abs(low.x - neckX) <= max(torsoHalfW * 1.5, 10) + avgInkW else { continue }
            var lateral: CGFloat = 0, n = 0
            for (j, p) in pts.enumerated() where ps[j] == .head { lateral += abs(p.x - headCenter.x); n += 1 }
            guard n > 0, lateral / CGFloat(n) > headRadius * 0.35 else { continue }
            let meanX = pts.reduce(0) { $0 + $1.x } / CGFloat(pts.count)
            regionParts[i] = Array(repeating: meanX < neckX ? .leftArm : .rightArm, count: ps.count)
        }

        traceStep("7 skin", regionParts, " crotch=(\(Int(crotchX)),\(Int(crotchY))) neck=\(Int(neckY)) torsoHalfW=\(Int(torsoHalfW)) legDetected=\(legStrokesDetected)")
        // Detected leg strokes are WHOLE rigid legs, sided by their root. Override whatever
        // per-point labels the silhouette produced — this rescues a leg-top mislabeled as an
        // arm (veer-to-side) and makes the stroke indivisible so the scissor walk can't tear it
        // (crossed legs). Done here so the position-based fat-stroke pass (7a) can't re-decide them.
        for i in raw.indices where legSide[i] != nil {
            regionParts[i] = Array(repeating: legSide[i]!, count: raw[i].points.count)
        }

        // ---- Step 7a: classify FAT (outline) strokes as WHOLE limbs by position ----
        // Outline limbs that touch the torso MERGE into one silhouette blob, so per-row runs
        // can't separate them (no torso-only rows to measure a waist from). But each is a
        // distinct stroke, so classify it whole: the most-central UPPER fat stroke is the torso;
        // other upper fat strokes are arms; lower fat strokes are legs. Thin strokes are left to
        // the silhouette per-point labels above — stick figures are untouched.
        let bodyMid = neckY + bodyLen * 0.55
        // A fat stroke is TRUNK (torso or a drawn neck — both sit on the spine) if its centroid
        // is near the centreline AT ITS OWN HEIGHT (`spineX`, which tracks a lean); otherwise
        // it's a lateral limb. Comparing to the lean-tracking spine — not the head x — keeps a
        // leaned torso central, while the tight threshold keeps an arm hanging beside a wide
        // torso lateral. So a drawn neck rides with the torso instead of becoming an arm.
        let trunkThreshold = max(torsoHalfW * 0.6, bbox.width * 0.10)
        // Strokes split as a LIMB PAIR (both arms / both legs in one stroke) at their drawn
        // fold. That split is authoritative: 7b/7c must not re-split them at the noisy
        // pre-consolidation crotch/arm axes.
        var pairHandled = [Bool](repeating: false, count: raw.count)
        // A genuine limb PAIR folds at the TOP of its stroke — the crotch apex / shoulder
        // fold — with both branches hanging DOWN from it. The impostors cross the spine at
        // their BOTTOM: an open leg tube's rounded far tip, an open ∪ torso outline's hip
        // bottom. Splitting one of those tears the drawing into two counter-rotating halves
        // (the reported "body splits open"), so a junction in the lower stroke is a veto.
        func junctionNearTop(_ pts: [CGPoint], _ j: Int) -> Bool {
            var lo = CGFloat.greatestFiniteMagnitude, hi = -CGFloat.greatestFiniteMagnitude
            for p in pts { lo = min(lo, p.y); hi = max(hi, p.y) }
            return pts[j].y <= lo + (hi - lo) * 0.45
        }
        var upperFat: [(i: Int, cx: CGFloat, axis: CGFloat)] = []
        for i in raw.indices where rigidFlags[i] && legSide[i] == nil {
            if majorityPart(regionParts[i]) == .head { continue }   // leave the head alone
            let pts = raw[i].points
            let cx = pts.reduce(0) { $0 + $1.x } / CGFloat(pts.count)
            let cy = pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count)
            let axis = spineX[grid.row(cy)]
            if cy >= bodyMid {
                // BOTH legs drawn in one ∧ stroke read as fat (the path doubles back along the
                // vertical major axis exactly like an outline tube), so whole-siding would glue
                // both legs to ONE hip. The limb-pair test tells them apart by the endpoints:
                // an ∧'s ends are the two FEET on opposite sides of the crotch, a tube's ends
                // sit together at its root. Split per side; the hip-raise below then lifts the
                // pivot to the apex, so each branch swings where the legs actually join.
                // Clearance stays modest: the ∧'s own polygon-fill inflates the measured torso
                // waist (its solid triangle reads as wide torso rows), so a full-torsoHalfW bar
                // can exceed the feet's real lateral offsets. Tubes are rejected by the
                // endpoint/fold structure, not the clearance, so half-width is safe.
                let margin = max(torsoHalfW * 0.5, 8)
                if !raw[i].closed,
                   let pair = limbPairJunction(pts, spineAt: { spineX[grid.row($0.y)] }, clearance: margin),
                   junctionNearTop(pts, pair.j) {
                    let first: BodyPart = pair.firstIsLeft ? .leftLeg : .rightLeg
                    let second: BodyPart = pair.firstIsLeft ? .rightLeg : .leftLeg
                    regionParts[i] = pts.indices.map { $0 <= pair.j ? first : second }
                    rigidFlags[i] = false
                    pairHandled[i] = true
                } else {
                    regionParts[i] = Array(repeating: cx < axis ? .leftLeg : .rightLeg, count: pts.count)
                }
            } else {
                upperFat.append((i, cx, axis))
            }
        }
        for f in upperFat {
            let pts = raw[f.i].points
            // BOTH arms drawn in one ∧/∩ stroke, STEEPER than wide: the major axis is vertical
            // and the path doubles back along it, so isFat's travel gate can't clear it (a wide
            // arch is cleared there). Its centroid sits ON the spine, so the trunk test below
            // would swallow both arms as torso. Same limb-pair discriminator as the legs:
            // free ends far out on OPPOSITE sides, each branch labelled whole from the junction.
            let reach = max(torsoReach * 1.5, bbox.width * 0.12)
            if !raw[f.i].closed,
               let pair = limbPairJunction(pts, spineAt: { spineX[grid.row($0.y)] }, clearance: reach) {
                if junctionNearTop(pts, pair.j) {
                    let first: BodyPart = pair.firstIsLeft ? .leftArm : .rightArm
                    let second: BodyPart = pair.firstIsLeft ? .rightArm : .leftArm
                    regionParts[f.i] = pts.indices.map { $0 <= pair.j ? first : second }
                    rigidFlags[f.i] = false
                    pairHandled[f.i] = true
                } else {
                    // Structurally a pair but folded at the BOTTOM: an open ∪ torso outline,
                    // or both arms RAISED in one ∨ stroke. Ambiguous — so freeze it as TRUNK.
                    // For the ∪ that is simply correct; for a raised ∨ it is the graceful
                    // lesser evil (the centroid fallback below would make the whole two-arm
                    // stroke ONE arm and swing the far branch about the wrong shoulder).
                    regionParts[f.i] = Array(repeating: .torso, count: pts.count)
                }
            } else if abs(f.cx - f.axis) < trunkThreshold {
                regionParts[f.i] = Array(repeating: .torso, count: pts.count)
            } else {
                regionParts[f.i] = Array(repeating: f.cx < f.axis ? .leftArm : .rightArm, count: pts.count)
            }
        }

        traceStep("7a fat", regionParts)
        // ---- Step 7b: consolidate THIN leg strokes + raise the hip to the leg junction ----
        // The gap-based crotch sits too LOW when the legs meet at a point (inverted-V) or thick
        // strokes overlap near the join, so the leg TOPS get mislabeled as arms — which drags
        // the elbow/hand down the body and flings the limb when it animates. A one-sided
        // leg-dominated stroke becomes one whole leg; a centre-crossing one keeps its split.
        // Then the hip rises to the topmost leg point so the leg pivots where it really attaches.
        for i in raw.indices where !rigidFlags[i] {   // fat legs already handled in 7a
            if legSide[i] != nil { continue }          // detected leg strokes: already whole by root, never split
            if pairHandled[i] { continue }             // a limb pair is already split at its junction
            let legN = regionParts[i].reduce(0) { $0 + (($1 == .leftLeg || $1 == .rightLeg) ? 1 : 0) }
            guard legN * 2 > regionParts[i].count else { continue }
            let pts = raw[i].points
            // A leg-majority stroke ROOTED AT THE NECK is the spine running on into a leg (the
            // λ body, leg-heavy on a short torso) — consolidating it would make the whole
            // spine a leg and drag the hip up to the neck. It keeps its torso|leg split.
            if strokeRoot(pts).root.y < shoulderBandY { continue }
            let minX = pts.map(\.x).min() ?? 0, maxX = pts.map(\.x).max() ?? 0
            let margin = max(torsoHalfW, 8)
            if minX < crotchX - margin && maxX > crotchX + margin {
                regionParts[i] = pts.map { $0.x < crotchX ? .leftLeg : .rightLeg }   // inverted-V in one stroke
            } else {
                let cx = pts.reduce(0) { $0 + $1.x } / CGFloat(pts.count)
                regionParts[i] = Array(repeating: cx < crotchX ? .leftLeg : .rightLeg, count: pts.count)
            }
        }
        traceStep("7b legs", regionParts)
        // ---- Step 7c: heal the TRUNK — absorb small mislabel islands on a torso stroke ----
        // An arm CROSSING the spine drags the tracked centreline sideways for a few rows, so
        // a short run of true spine points falls outside the shifted torso band and rides an
        // arm — when that arm waves, a chunk of the BODY swings with it (a visible mid-spine
        // tear). On a stroke that is clearly the trunk (torso-majority), a short INTERIOR
        // island of limb labels bounded by torso on both sides is relabelled torso; 1–2-point
        // tails at the stroke ends are noise and absorbed too. A genuine spine+arm drawn as
        // one stroke keeps its arm: that arm is a long END segment, not a short interior island.
        // MUST run BEFORE the arm consolidation below: once that pass makes a stroke 100% arm
        // the torso-majority guard here can never heal it — and the island bound aligns with
        // the consolidation floor (both n/5) so no island size falls between heal and
        // consolidate (the old n/6..n/5 dead band stayed split and tore mid-spine).
        for i in raw.indices where !rigidFlags[i] && !pairHandled[i] {
            let parts = regionParts[i]
            let n = parts.count
            let torsoN = parts.reduce(0) { $0 + ($1 == .torso ? 1 : 0) }
            guard torsoN * 2 > n else { continue }
            var healed = parts
            var k = 0
            while k < n {
                if healed[k] == .torso { k += 1; continue }
                var e = k
                while e + 1 < n && healed[e + 1] == healed[k] { e += 1 }
                let len = e - k + 1
                let interior = k > 0 && e < n - 1 && healed[k - 1] == .torso && healed[e + 1] == .torso
                if (interior && len <= max(4, n / 5)) || (!interior && len <= 2) {
                    for m in k...e { healed[m] = .torso }
                }
                k = e + 1
            }
            regionParts[i] = healed
        }

        traceStep("7c heal", regionParts)
        // ---- Step 7e: a thin stroke is NEVER half arm, half leg ----
        // An arm and a leg don't share a pen stroke, so a thin stroke carrying BOTH labels is
        // one limb cut by a misplaced crotch: (a) the TOP of a leg stranded in the arm band —
        // the hinge at the hip that swings up like an arm (the reported indecent rig); (b) a
        // hanging arm whose hand dips below the crotch on a short torso — its tip scissors with
        // the legs while the arm waves. Decide the WHOLE stroke by what a leg is: it reaches
        // the ground, or roots in the lower body, or (the λ body: spine → hip → foot in one
        // stroke) its arm run is sandwiched between the trunk and the leg. Otherwise it's an
        // arm whole. Detected legs and pair-split strokes are already whole and left alone.
        for i in raw.indices where !rigidFlags[i] && !pairHandled[i] && legSide[i] == nil {
            let ps = regionParts[i]
            var lArm = 0, rArm = 0, lLeg = 0, rLeg = 0
            for p in ps {
                switch p {
                case .leftArm: lArm += 1
                case .rightArm: rArm += 1
                case .leftLeg: lLeg += 1
                case .rightLeg: rLeg += 1
                default: break
                }
            }
            let armN = lArm + rArm, legN = lLeg + rLeg
            let pts = raw[i].points
            let (root, foot) = strokeRoot(pts)
            let torsoN = ps.reduce(0) { $0 + ($1 == .torso ? 1 : 0) }
            if armN == 0, legN > 0, torsoN > 0, foot.y < groundY, root.y <= hipBandY {
                // torso|leg with no arm labels: an arm that starts INSIDE a wide torso outline
                // and dips below the crotch (or any upper-rooted dangle). It's not a leg — it
                // ends in mid-air — and the leg tail would scissor with the walk while the
                // rest stays put, tearing the stroke at the crotch line. Ride the root.
                regionParts[i] = ps.map { $0 == .leftLeg || $0 == .rightLeg ? .torso : $0 }
                continue
            }
            guard armN > 0, legN > 0 else { continue }
            // λ shape: in PATH order the labels go torso … arm … leg (or the reverse) — and
            // the torso run is the SPINE: it spans most of the trunk's height. A hanging arm
            // that starts inside a wide torso outline and ends below the crotch shows the
            // same torso|arm|leg sequence, but its torso run is a short stretch at the root.
            var sandwiched = false
            var tLo = CGFloat.greatestFiniteMagnitude, tHi = -CGFloat.greatestFiniteMagnitude
            for (j, p) in ps.enumerated() where p == .torso { tLo = min(tLo, pts[j].y); tHi = max(tHi, pts[j].y) }
            if torsoN * 10 >= ps.count * 3, tHi - tLo >= (crotchY - neckY) * 0.6 {
                let seq = ps.map { $0 == .leftArm || $0 == .rightArm ? 1 : ($0 == .leftLeg || $0 == .rightLeg ? 2 : ($0 == .torso ? 0 : 3)) }
                var k = 0
                while k < seq.count {
                    if seq[k] != 1 { k += 1; continue }
                    var e = k
                    while e + 1 < seq.count && seq[e + 1] == 1 { e += 1 }
                    let before = k > 0 ? seq[k - 1] : -1, after = e + 1 < seq.count ? seq[e + 1] : -1
                    if (before == 0 && after == 2) || (before == 2 && after == 0) { sandwiched = true }
                    k = e + 1
                }
            }
            let isLeg = foot.y >= groundY || root.y > hipBandY || sandwiched
            var out = ps
            if isLeg {
                let side: BodyPart = lLeg >= rLeg ? .leftLeg : .rightLeg
                for j in out.indices where out[j] == .leftArm || out[j] == .rightArm { out[j] = side }
            } else {
                let side: BodyPart = lArm >= rArm ? .leftArm : .rightArm
                for j in out.indices where out[j] == .leftLeg || out[j] == .rightLeg { out[j] = side }
            }
            regionParts[i] = out
        }

        traceStep("7e mixed", regionParts)
        // ---- Step 7d: consolidate THIN arm strokes (the anti-"offset arm" fix) ----
        // An arm drawn attached BELOW the shoulders — or one whose first segment dips across the
        // spine before heading out — keeps TORSO labels for its near-centreline points, so ONE
        // pen stroke ends up split torso|arm: when the arm swings, the torso-labelled points stay
        // with the body and the segment between the two groups visibly STRETCHES the figure (and
        // the shoulder snap can land mid-stroke, flinging the limb). Mirror the leg consolidation:
        // an arm-DOMINATED thin stroke becomes ONE whole arm on its dominant side, and Step 8's
        // shoulder snap then finds its true root (the arm point nearest the neck) — so an offset
        // arm pivots where it was actually drawn to attach. Kept split: a stroke whose points
        // reach FAR laterally on BOTH sides (both arms drawn in one line across the chest). Left
        // alone: anything rooted in the leg band (that's Step 5b/7b territory).
        for i in raw.indices where !rigidFlags[i] {
            if legSide[i] != nil { continue }
            if pairHandled[i] { continue }             // a limb pair is already split at its junction
            var leftN = 0, rightN = 0, legN = 0, torsoN = 0
            for part in regionParts[i] {
                switch part {
                case .leftArm: leftN += 1
                case .rightArm: rightN += 1
                case .leftLeg, .rightLeg: legN += 1
                case .torso: torsoN += 1
                default: break
                }
            }
            let armN = leftN + rightN
            let count = regionParts[i].count
            // ≥3 arm points: 1–2 stray labels must never promote a whole stroke to an arm.
            guard armN >= 3, armN > legN * 3 else { continue }
            let pts = raw[i].points
            // Root must sit in the UPPER body — and, when the crotch is high (short trunk),
            // strictly ABOVE the hip: 0.40·bodyLen is measured to the FEET, so on a leggy
            // figure it can land at hip height, and a hip-rooted lateral stroke consolidated
            // here becomes the "hip extends out" arm.
            guard strokeRoot(pts).root.y < min(neckY + bodyLen * 0.40, crotchY - bodyLen * 0.05) else { continue }
            let axis = spineX[grid.row(pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count))]
            let reachL = axis - (pts.map(\.x).min() ?? axis)
            let reachR = (pts.map(\.x).max() ?? axis) - axis
            // Arm-DOMINATED — or an upper-body stroke that clearly EXITS the torso band on one
            // side: an arm rooted inside a WIDE torso overlaps the torso band for most of its
            // length, so a majority test alone misses it. The exit evidence is the ARM-LABELLED
            // POINT COUNT itself — the trim line already sits 25% beyond the measured torso
            // wall, so a run of points past it is a limb, not wobble (smoothParts has killed
            // 1–2-point noise). A distance margin on top double-counts and misses real arms.
            let armish = armN * 2 > count
                || (armN + torsoN >= count * 8 / 10 && armN >= max(5, count / 5))
            guard armish else { continue }
            // Both-arms-in-one-stroke: genuine limb REACH past the torso band on EACH side
            // keeps the per-side split — whatever hangs left of the body is the left arm,
            // right of it the right arm, however UNEQUAL the two branches are. (The old
            // balance test — minority ≥ 20% of arm mass — collapsed a pair drawn at
            // DIFFERENT heights or with an off-centre junction onto the dominant side: one
            // arm died, and the dead branch streaked when the live one swung. Balance was
            // redundant belt-and-braces: a single arm dipping a little across the spine
            // already fails the REACH test — its far-side excursion is shallow — and is
            // consolidated whole. The tiny count floor just rejects 1–3-point noise.)
            let bothArms = min(leftN, rightN) >= max(4, count / 12)
                && min(reachL, reachR) > max(torsoReach * 2, bbox.width * 0.12)
            if bothArms { continue }
            let side: BodyPart = leftN == rightN
                ? (reachL > reachR ? .leftArm : .rightArm)
                : (leftN > rightN ? .leftArm : .rightArm)
            regionParts[i] = Array(repeating: side, count: count)
        }

        // ---- Step 7h: a dangling segment rides the limb it hangs from ----
        // Arms drawn as upper arm + forearm: on a short torso the forearm ROOTS at an elbow
        // that is already below the hip, so the silhouette calls it a leg — and a "leg" that
        // ends in mid-air at the elbow scissors beside the real legs while the upper arm
        // waves off without it. A thin limb stroke that does not reach the ground and whose
        // root sits ON the END of an arm stroke is that arm's continuation. Legs reach the
        // ground, so no real leg is ever re-classed; detected legs are skipped outright.
        do {
            let joinR = max(avgInkW * 2.5, bodyLen * 0.05)
            for i in raw.indices where !rigidFlags[i] && !pairHandled[i] && legSide[i] == nil {
                let ps = regionParts[i], pts = raw[i].points
                guard pts.count >= 3 else { continue }
                let legN = ps.reduce(0) { $0 + ($1 == .leftLeg || $1 == .rightLeg ? 1 : 0) }
                guard legN * 10 >= ps.count * 9 else { continue }
                let (root, foot) = strokeRoot(pts)
                guard foot.y < groundY else { continue }
                var adopt: BodyPart? = nil
                var bestD = joinR
                for k in raw.indices where k != i && !rigidFlags[k] && raw[k].points.count >= 4 {
                    let kp = raw[k].points, kl = regionParts[k]
                    for (e, part) in [(0, kl[0]), (kp.count - 1, kl[kp.count - 1])]
                    where part == .leftArm || part == .rightArm {
                        let d = dist(root, kp[e])
                        if d <= bestD { bestD = d; adopt = part }
                    }
                }
                if let adopt { regionParts[i] = Array(repeating: adopt, count: ps.count) }
            }
        }

        traceStep("7d arms", regionParts)
        // ---- Step 7f: a small blob at a limb's TIP rides that limb ----
        // Hands and feet are often a little loop at the end of the arm/leg line. 7a classes
        // every outline by POSITION, and a hand hanging below the body's midpoint on a short
        // torso is "a lower fat stroke" → leg: the hand then stays with the legs while the arm
        // waves away from it. A small closed stroke whose centre sits on the END of a thin
        // stroke takes that end's label, whatever its height.
        // (A fist raised beside the head was folded INTO the head by the detail pass — it is
        // within the head's reach — so a head-majority blob is also eligible when it lies
        // outside the head disc and tips an ARM; eyes/ears sit inside the disc.)
        for i in raw.indices where raw[i].closed && !(foldHeadFlags[i] && regionParts[i].count < 4) {
            let bb = boundingBox(raw[i].points) ?? .zero
            let size = max(bb.width, bb.height)
            guard size < max(headRadius * 0.9, bodyLen * 0.12) else { continue }
            let c = CGPoint(x: bb.midX, y: bb.midY)
            let headMajority = majorityPart(regionParts[i]) == .head
            if headMajority, hypot(c.x - headCenter.x, c.y - headCenter.y) <= headRadius * 1.05 { continue }
            let snap = max(size * 0.9, avgInkW * 2)
            var best: (d: CGFloat, part: BodyPart)? = nil
            for k in raw.indices where k != i && !rigidFlags[k] && raw[k].points.count >= 4 {
                let pts = raw[k].points, ps = regionParts[k]
                for (e, part) in [(0, ps[0]), (pts.count - 1, ps[pts.count - 1])] {
                    guard part != .torso, part != .head else { continue }
                    if headMajority, part != .leftArm, part != .rightArm { continue }
                    let d = dist(c, pts[e])
                    if d <= snap, best == nil || d < best!.d { best = (d, part) }
                }
            }
            if let best { regionParts[i] = Array(repeating: best.part, count: raw[i].points.count) }
        }

        traceStep("7f blobs", regionParts)
        // Hip-raise from the leg silhouette — only on the LEGACY path. When Step 5b detected the
        // legs, the hip is already at the root convergence; the feet/upper-band median below would
        // drift it toward the veer side and re-corrupt the clean central hip, so skip it.
        if !legStrokesDetected {
            var legPts: [CGPoint] = []
            for i in raw.indices {
                for (j, p) in raw[i].points.enumerated() where regionParts[i][j] == .leftLeg || regionParts[i][j] == .rightLeg {
                    legPts.append(p)
                }
            }
            // ~6th-percentile topmost leg point, not the single min: one stray leg label used
            // to drag the hip up the body (and its median-x sideways) all by itself.
            let legYs = legPts.map(\.y).sorted()
            if !legYs.isEmpty {
                let topLegY = legYs[min(legYs.count - 1, legYs.count / 16)]
                let raised = min(max(topLegY, neckY + bodyLen * 0.20), bbox.maxY - bbox.height * 0.10)
                if raised < crotchY {
                    crotchY = raised
                    let upper = legPts.filter { $0.y <= crotchY + bodyLen * 0.15 }.map(\.x).sorted()
                    if !upper.isEmpty { crotchX = upper[upper.count / 2] }

                    // The cell labels were assigned against the ORIGINAL (lower) crotch, and the
                    // hip just moved UP past some of them — points in that stale band that sat in
                    // a side run were labelled ARM and would now be "arms" rooted below the hip
                    // (the reported "hip area extends out" fling). Re-side them as legs: a thin
                    // stroke rooted in the lower body whose mass sits below the raised crotch is
                    // leg ink whole; otherwise only the stale arm-labelled END runs below the
                    // crotch move (an arm TIP that merely dips past the hip keeps its arm).
                    for i in raw.indices where !rigidFlags[i] && !pairHandled[i] && legSide[i] == nil {
                        let pts = raw[i].points
                        var ps = regionParts[i]
                        let armN = ps.reduce(0) { $0 + ($1 == .leftArm || $1 == .rightArm ? 1 : 0) }
                        guard armN > 0 else { continue }
                        let root = strokeRoot(pts).root
                        let meanY = pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count)
                        if root.y > neckY + bodyLen * 0.45, meanY > crotchY {
                            let cxm = pts.reduce(0) { $0 + $1.x } / CGFloat(pts.count)
                            regionParts[i] = Array(repeating: cxm < crotchX ? .leftLeg : .rightLeg,
                                                   count: ps.count)
                        } else if armN * 2 <= ps.count {
                            // Stale TAIL re-siding is for MINORITY-arm strokes only: an
                            // arm-MAJORITY stroke here is a genuine (likely consolidated) arm
                            // rooted high, and a hanging hand that merely dips below the raised
                            // crotch must keep its arm — or the tip would scissor with the legs
                            // while the arm waves.
                            var j = 0
                            while j < ps.count, ps[j] == .leftArm || ps[j] == .rightArm, pts[j].y >= crotchY {
                                ps[j] = pts[j].x < crotchX ? .leftLeg : .rightLeg; j += 1
                            }
                            var k = ps.count - 1
                            while k >= 0, ps[k] == .leftArm || ps[k] == .rightArm, pts[k].y >= crotchY {
                                ps[k] = pts[k].x < crotchX ? .leftLeg : .rightLeg; k -= 1
                            }
                            regionParts[i] = ps
                        }
                    }
                }
            }
        }

        traceStep("hip-raise", regionParts, " crotch=(\(Int(crotchX)),\(Int(crotchY)))")
        // ---- Step 8: skeleton joints + elbow/knee/hand/foot refinement ----
        func baseSkeleton() -> Skeleton {
            let shoulderY = neckY + (crotchY - neckY) * 0.10
            let leftShoulder = CGPoint(x: neckX - torsoHalfW, y: shoulderY)
            let rightShoulder = CGPoint(x: neckX + torsoHalfW, y: shoulderY)
            let hipCenter = CGPoint(x: crotchX, y: crotchY)
            return Skeleton(
                bbox: bbox, headCenter: headCenter, headRadius: headRadius,
                neck: CGPoint(x: neckX, y: neckY),
                leftShoulder: leftShoulder, rightShoulder: rightShoulder,
                leftElbow: leftShoulder, rightElbow: rightShoulder,
                hipCenter: hipCenter, leftHip: hipCenter, rightHip: hipCenter,
                leftKnee: hipCenter, rightKnee: hipCenter,
                feet: CGPoint(x: crotchX, y: bbox.maxY),
                leftHand: leftShoulder, rightHand: rightShoulder)
        }
        var skeleton = refineJoints(baseSkeleton(), points: raw.map { $0.points }, parts: regionParts)

        // ---- Step 8b: plausibility net — freeze geometrically implausible limbs ----
        // (See RigPlausibility. Runs BEFORE the forearm split so a demotion is a plain
        // whole-arm/leg relabel, and before the hand-part computation so a demoted side's
        // props automatically ride the root.)
        var demotions: [RigDemotion] = []
        var forceFallback = false
        switch RigPlausibility.validate(parts: &regionParts, points: raw.map { $0.points },
                                        skeleton: skeleton, bbox: bbox, demotions: &demotions) {
        case .ok:
            break
        case .demoted:
            // The surviving joints — and the demoted side's ESTIMATED hand — must be derived
            // from the FINAL labels, so re-refine against them.
            skeleton = refineJoints(baseSkeleton(), points: raw.map { $0.points }, parts: regionParts)
        case .fullFallback:
            // Wipe the labels HERE (not just in Step 9) and re-refine: with no arm points
            // left, refineJoints estimates the hands from the drawing's lateral extremes —
            // otherwise the hand anchors (and every conjured prop) would sit wherever the
            // discarded implausible labels had put them.
            forceFallback = true
            for i in regionParts.indices {
                regionParts[i] = Array(repeating: .torso, count: regionParts[i].count)
            }
            skeleton = refineJoints(baseSkeleton(), points: raw.map { $0.points }, parts: regionParts)
        }

        traceStep("8b validate", regionParts, " demotions=\(demotions.map { "\($0.side):\($0.reason)" })")
        // ---- Step 9: build strokes (rigid-aware forearm split), confidence, fallback ----
        var strokes: [RigStroke] = []
        for (i, r0) in raw.enumerated() {
            let parts = r0.points.enumerated().map { j, p in
                splitSegment(p, regionParts[i][j], rigid: rigidFlags[i], skeleton)
            }
            strokes.append(RigStroke(points: r0.points, parts: parts, color: r0.color, width: r0.width, rigid: rigidFlags[i]))
        }

        let confidence = score(strokes: strokes, skeleton: skeleton, headFound: headDet != nil)
        let articulated = confidence >= 0.5 && !forceFallback
        if !articulated {
            for i in strokes.indices {
                strokes[i].parts = Array(repeating: .torso, count: strokes[i].points.count)
                strokes[i].rigid = false
            }
        }
        // Held-prop carrying parts (see Rig.leftHandPart): the forearm only if some final
        // stroke point actually articulates as that arm; an estimated hand rides the root.
        var leftHandPart = BodyPart.torso, rightHandPart = BodyPart.torso
        for s in strokes {
            for p in s.parts {
                if p == .leftArm || p == .leftForearm { leftHandPart = .leftForearm }
                if p == .rightArm || p == .rightForearm { rightHandPart = .rightForearm }
            }
        }
        return Rig(strokes: strokes, skeleton: skeleton, confidence: confidence, articulated: articulated,
                   demotions: demotions, leftHandPart: leftHandPart, rightHandPart: rightHandPart)
    }

    // MARK: - Run classification

    /// Largest-gap test for a leg band: ≥2 runs split by a wide gap. Returns the gap midpoint
    /// (the lean-invariant crotch x) — measured per band, so it never references a global axis.
    private static func twoLegged(_ runs: [Run], gapThresh: CGFloat) -> (Bool, CGFloat) {
        guard runs.count >= 2 else { return (false, runs.first?.xMid ?? 0) }
        var bestGap: CGFloat = 0, mid = runs[0].xMid
        for i in 1..<runs.count {
            let gap = runs[i].x0 - runs[i - 1].x1
            if gap > bestGap { bestGap = gap; mid = (runs[i - 1].x1 + runs[i].x0) / 2 }
        }
        return (bestGap >= gapThresh, mid)
    }

    /// The torso slice at a row: the run straddling the spine, else the run nearest it.
    private static func central(_ runs: [Run], spineX: CGFloat) -> Run? {
        runs.first { $0.x0 <= spineX && spineX <= $0.x1 }
            ?? runs.min { abs($0.xMid - spineX) < abs($1.xMid - spineX) }
    }

    /// The ROOT (topmost / min-y point) and FOOT (bottommost / max-y point) of a stroke —
    /// pen-direction-agnostic. A standing limb attaches at its root; the leg-stroke pass sides
    /// and locates the hip from the ROOT, never the foot, so a leg drawn to one side, crossed,
    /// or steeply splayed still attaches at the right place (and a leg drawn foot-up still roots).
    private static func strokeRoot(_ pts: [CGPoint]) -> (root: CGPoint, foot: CGPoint) {
        var root = pts[0], foot = pts[0]
        for p in pts {
            if p.y < root.y { root = p }
            if p.y > foot.y { foot = p }
        }
        return (root, foot)
    }

    /// A LIMB PAIR drawn as ONE open stroke (both arms as a ∧/∩ arch or a check-mark, both
    /// legs as a ∧): both ENDPOINTS are free limb tips on OPPOSITE sides of the body
    /// centreline, each well clear of it. A genuine outline tube fails on the endpoints —
    /// they sit TOGETHER at its root (same side, no clearance) — and a torso outline's ends
    /// hug the centreline. The JUNCTION (where the pair attaches to the body) is the path
    /// point NEAREST the tracked spine at its own height. NO symmetry is assumed: the
    /// junction may sit anywhere between the tips (arms at different heights, an off-centre
    /// apex, one branch raised and one hanging), and measuring against the lean-tracking
    /// spine — not a single axis x — survives the noisy pre-consolidation crotch (the ∧'s
    /// polygon-fill corrupts the run gaps near the feet). Returns the junction's path index
    /// + the FIRST branch's side, so the caller labels each BRANCH whole by path order (not
    /// by an x threshold — a branch that hooks back across the centreline stays one limb).
    /// The junction must be interior (both branches substantial) or this isn't a pair.
    private static func limbPairJunction(_ pts: [CGPoint], spineAt: (CGPoint) -> CGFloat,
                                         clearance: CGFloat) -> (j: Int, firstIsLeft: Bool)? {
        guard pts.count >= 8, let a = pts.first, let b = pts.last else { return nil }
        let offA = a.x - spineAt(a), offB = b.x - spineAt(b)
        guard offA * offB < 0, min(abs(offA), abs(offB)) > clearance else { return nil }
        var jIdx = 0
        var best = CGFloat.greatestFiniteMagnitude
        for (i, p) in pts.enumerated() {
            let d = abs(p.x - spineAt(p))
            if d < best { best = d; jIdx = i }
        }
        let minBranch = max(3, pts.count / 8)
        guard jIdx >= minBranch, jIdx <= pts.count - 1 - minBranch else { return nil }
        return (jIdx, offA < 0)
    }

    /// Reclaim a raised arm TIP from the head: a contiguous head-labelled run at a stroke
    /// END, adjacent to ARM labels, whose tip point is clearly OUTSIDE the head disc, is a
    /// hand drawn up at head height (arms at different heights) — it belongs to that arm,
    /// not the head, or the tip stays behind when the arm waves. Decoration strokes are
    /// untouched: they are majority-head with no adjacent arm labels (or were folded to the
    /// head whole), and an arm ROOT that merely brushes the head band fails the distance
    /// test (it sits at the neck, inside the disc), so the baseline figures are unchanged.
    private static func reclaimRaisedTips(_ parts: [BodyPart], pts: [CGPoint],
                                          headCenter: CGPoint, headRadius: CGFloat) -> [BodyPart] {
        let n = parts.count
        guard n >= 4 else { return parts }
        var out = parts
        let farR = headRadius * 1.15
        if out[0] == .head {
            var e = 0
            while e + 1 < n && out[e + 1] == .head { e += 1 }
            if e + 1 < n, out[e + 1] == .leftArm || out[e + 1] == .rightArm,
               hypot(pts[0].x - headCenter.x, pts[0].y - headCenter.y) > farR {
                for m in 0...e { out[m] = out[e + 1] }
            }
        }
        if out[n - 1] == .head {
            var s = n - 1
            while s > 0 && out[s - 1] == .head { s -= 1 }
            if s > 0, out[s - 1] == .leftArm || out[s - 1] == .rightArm,
               hypot(pts[n - 1].x - headCenter.x, pts[n - 1].y - headCenter.y) > farR {
                for m in s..<n { out[m] = out[s - 1] }
            }
        }
        return out
    }

    private static func majorityPart(_ parts: [BodyPart]) -> BodyPart {
        var counts: [BodyPart: Int] = [:]
        for p in parts { counts[p, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? .torso
    }

    /// Smooth out isolated 1–2-point label flips on an OPEN stroke (a sliding-window majority),
    /// so a single pen path that genuinely spans a joint reads as two clean segments.
    private static func smoothParts(_ parts: [BodyPart]) -> [BodyPart] {
        guard parts.count >= 5 else { return parts }
        var out = parts
        for i in 2..<(parts.count - 2) {
            var counts: [BodyPart: Int] = [:]
            for k in (i - 2)...(i + 2) { counts[parts[k], default: 0] += 1 }
            if let win = counts.max(by: { $0.value < $1.value })?.key { out[i] = win }
        }
        return out
    }

    // MARK: - Head detection (unchanged — used for headCenter/radius + the confidence bonus)

    private static func detectHead(_ strokePoints: [[CGPoint]], figure: CGRect, centerX: CGFloat,
                                   inkWidth: CGFloat) -> (center: CGPoint, radius: CGFloat, bottom: CGFloat, index: Int)? {
        guard figure.height > 0 else { return nil }
        let tinyFloor = max(14, figure.height * 0.05)
        // The ROOT (topmost point) of every stroke that reaches the GROUND. A blob with TWO
        // such roots spread along its bottom edge has legs hanging off it — it is the TORSO,
        // however head-like its shape. This separates a small head on a short, wide outlined
        // body (the body out-sizes the head and reaches into the top band) from a hat on a
        // head: nothing roots along a hat's bottom but the head's own top, and only the
        // spine roots at a head's bottom. Grounded strokes only — outline arms rooted at
        // the shoulders of a small head sit on its bottom edge too, but end in mid-air.
        let groundY = figure.maxY - figure.height * 0.25
        let roots: [CGPoint] = strokePoints.compactMap { pts in
            guard let b = boundingBox(pts), max(b.width, b.height) >= figure.height * 0.08,
                  b.maxY >= groundY else { return nil }
            return pts.min { $0.y < $1.y }
        }
        func hasLegs(_ b: CGRect) -> Bool {
            let tol = inkWidth * 0.5 + max(b.width, b.height) * 0.05
            let xs = roots.filter { abs($0.y - b.maxY) <= tol && $0.x >= b.minX - tol && $0.x <= b.maxX + tol }.map(\.x)
            guard xs.count >= 2, let lo = xs.min(), let hi = xs.max() else { return false }
            return hi - lo >= b.width * 0.25
        }
        // The head is a roundish top-band blob that is BIG, near the TOP, and near the figure's
        // top-centre. Score = size − topOffset − centreOffset. This beats: small ears/horns/hair
        // (too small), a fat outlined ARM in the top band (too far off-centre), and a torso (too
        // low, also excluded by the tight top band + aspect gate). Works for closed/open/big/small
        // heads. The head's BOTTOM edge (maxY) anchors the neck, not its size-radius.
        var best: (center: CGPoint, radius: CGFloat, score: CGFloat, maxY: CGFloat, index: Int)? = nil
        var fallback: (center: CGPoint, radius: CGFloat, score: CGFloat, maxY: CGFloat, index: Int)? = nil
        for (i, pts) in strokePoints.enumerated() {
            guard let b = boundingBox(pts), b.width > 0, b.height > 0 else { continue }
            let aspect = b.width / b.height
            let size = max(b.width, b.height)
            let inTopBand = b.midY < figure.minY + figure.height * 0.35
            let compact = size < figure.height * 0.6
            let roundish = aspect > 0.5 && aspect < 2.1     // excludes elongated limbs
            guard inTopBand, compact, roundish, size >= tinyFloor else { continue }
            let score = size - 0.6 * (b.minY - figure.minY) - 1.0 * abs(b.midX - centerX)
            let cand = (CGPoint(x: b.midX, y: b.midY), size / 2, score, b.maxY, i)
            if fallback == nil || score > fallback!.score { fallback = cand }
            if hasLegs(b) { continue }                      // a torso, not a head
            if best == nil || score > best!.score { best = cand }
        }
        return (best ?? fallback).map { ($0.center, $0.radius, $0.maxY, $0.index) }
    }

    // MARK: - Joint refinement (legs stay whole rigid segments; arms get an elbow for the wave)

    private static func refineJoints(_ s: Skeleton, points: [[CGPoint]], parts: [[BodyPart]]) -> Skeleton {
        var leftArm: [CGPoint] = [], rightArm: [CGPoint] = []
        var leftLeg: [CGPoint] = [], rightLeg: [CGPoint] = []
        for (i, pts) in points.enumerated() {
            for (j, p) in pts.enumerated() {
                switch parts[i][j] {
                case .leftArm:  leftArm.append(p)
                case .rightArm: rightArm.append(p)
                case .leftLeg:  leftLeg.append(p)
                case .rightLeg: rightLeg.append(p)
                default: break
                }
            }
        }
        var out = s
        // Snap each shoulder to the arm's ACTUAL attachment — the arm point nearest the TRUNK
        // (the neck→hip segment), NOT nearest the neck — so the arm pivots where it really
        // meets the body. Nearest-the-neck breaks asymmetric drawings: a hand RAISED toward
        // head height is closer to the neck than the drawn attachment is, and a near-flat arm
        // can be closest to the neck mid-branch — either way the shoulder lands on the free
        // tip or the middle, and the wave rotates the arm about its own hand (the "doubled
        // arm" streak). Nearest-the-trunk finds the crossing/junction wherever the arm was
        // drawn to attach — but only within the UPPER trunk (arms attach there): an unbounded
        // argmin let an arm that merely TOUCHES the low body (hand-on-hip) put its pivot on
        // its own hand at hip height, so the wave rotated the arm about its hand. If no arm
        // point reaches the upper trunk, keep the default geometric shoulder.
        let trunkLen = max(s.hipCenter.y - s.neck.y, 1)
        let snapBandMaxY = s.neck.y + trunkLen * 0.65
        let lArmUpper = leftArm.filter { $0.y <= snapBandMaxY }
        let rArmUpper = rightArm.filter { $0.y <= snapBandMaxY }
        out.leftShoulder  = lArmUpper.min  { distToSegment($0, s.neck, s.hipCenter) < distToSegment($1, s.neck, s.hipCenter) } ?? s.leftShoulder
        out.rightShoulder = rArmUpper.min { distToSegment($0, s.neck, s.hipCenter) < distToSegment($1, s.neck, s.hipCenter) } ?? s.rightShoulder
        out.leftElbow  = midToFarthest(from: out.leftShoulder,  in: leftArm)  ?? out.leftShoulder
        out.rightElbow = midToFarthest(from: out.rightShoulder, in: rightArm) ?? out.rightShoulder
        out.leftHand   = farthest(from: out.leftShoulder,  in: leftArm)  ?? out.leftShoulder
        out.rightHand  = farthest(from: out.rightShoulder, in: rightArm) ?? out.rightShoulder

        // No labelled arm points on a side (a one-stroke outline body, an all-torso fallback,
        // or Auto-Rig off): the hand anchor stays AT the shoulder, so a conjured prop (wand /
        // rod / brush / hat) floats at the TOP of the arm. Estimate the hand instead: the drawn
        // point most laterally past the torso edge on that side, inside the ARM BAND — below
        // the neck, down to a little past the hip (a hand hanging past the hip still counts;
        // legs are only lateral near the FEET, far below the band, so they can't win).
        let bodyLen = max(s.bbox.maxY - s.neck.y, 1)
        let bandTop = s.neck.y + bodyLen * 0.06
        let bandBot = s.hipCenter.y + bodyLen * 0.15
        func estimateHand(side: CGFloat) -> CGPoint? {          // side: -1 left, +1 right
            let shoulderHalf = abs((side < 0 ? s.leftShoulder.x : s.rightShoulder.x) - s.neck.x)
            var best: CGPoint? = nil
            var bestOff = max(shoulderHalf * 1.25, 10)          // must clear the torso edge
            for pts in points {
                for p in pts where p.y >= bandTop && p.y <= bandBot {
                    let f = min(max((p.y - s.neck.y) / max(s.hipCenter.y - s.neck.y, 1), 0), 1)
                    let cx = s.neck.x + (s.hipCenter.x - s.neck.x) * f   // lean-tracking centreline
                    let off = (p.x - cx) * side
                    if off > bestOff { bestOff = off; best = p }
                }
            }
            return best
        }
        if leftArm.isEmpty, let h = estimateHand(side: -1) {
            out.leftHand = h
            out.leftElbow = CGPoint(x: (out.leftShoulder.x + h.x) / 2, y: (out.leftShoulder.y + h.y) / 2)
        }
        if rightArm.isEmpty, let h = estimateHand(side: 1) {
            out.rightHand = h
            out.rightElbow = CGPoint(x: (out.rightShoulder.x + h.x) / 2, y: (out.rightShoulder.y + h.y) / 2)
        }

        let leftFoot  = farthest(from: s.leftHip,  in: leftLeg)
        let rightFoot = farthest(from: s.rightHip, in: rightLeg)
        out.leftKnee  = leftFoot.flatMap  { bendVertex(leftLeg,  from: s.leftHip,  to: $0) }
                        ?? midToFarthest(from: s.leftHip,  in: leftLeg)  ?? s.leftHip
        out.rightKnee = rightFoot.flatMap { bendVertex(rightLeg, from: s.rightHip, to: $0) }
                        ?? midToFarthest(from: s.rightHip, in: rightLeg) ?? s.rightHip
        out.leftShinStraighten  = straightenAngle(hip: s.leftHip,  knee: out.leftKnee,  foot: leftFoot)
        out.rightShinStraighten = straightenAngle(hip: s.rightHip, knee: out.rightKnee, foot: rightFoot)
        return out
    }

    private static func bendVertex(_ pts: [CGPoint], from a: CGPoint, to b: CGPoint) -> CGPoint? {
        let abx = b.x - a.x, aby = b.y - a.y
        let len = hypot(abx, aby)
        guard len > 1 else { return nil }
        var best: CGPoint? = nil, bestD: CGFloat = 0
        for p in pts {
            let perp = abs((p.x - a.x) * aby - (p.y - a.y) * abx) / len
            if perp > bestD { bestD = perp; best = p }
        }
        return bestD > len * 0.08 ? best : nil
    }

    private static func straightenAngle(hip: CGPoint, knee: CGPoint, foot: CGPoint?) -> CGFloat {
        guard let foot else { return 0 }
        let tx = knee.x - hip.x, ty = knee.y - hip.y
        let sx = foot.x - knee.x, sy = foot.y - knee.y
        guard hypot(tx, ty) > 1, hypot(sx, sy) > 1 else { return 0 }
        return atan2(sx * ty - sy * tx, sx * tx + sy * ty)
    }

    private static func farthest(from joint: CGPoint, in pts: [CGPoint]) -> CGPoint? {
        pts.max(by: { dist($0, joint) < dist($1, joint) })
    }
    private static func midToFarthest(from joint: CGPoint, in pts: [CGPoint]) -> CGPoint? {
        guard let far = pts.max(by: { dist($0, joint) < dist($1, joint) }) else { return nil }
        guard dist(far, joint) > 8 else { return nil }
        return CGPoint(x: (joint.x + far.x) / 2, y: (joint.y + far.y) / 2)
    }

    /// An ARM point past the elbow becomes a forearm (so the arm bends for the wave). A
    /// closed-loop (rigid) limb is INDIVISIBLE — both walls keep one part and swing about the
    /// shoulder/hip as one piece. Legs are never split.
    private static func splitSegment(_ p: CGPoint, _ part: BodyPart, rigid: Bool, _ s: Skeleton) -> BodyPart {
        if rigid { return part }
        switch part {
        case .leftArm:  return beyond(p, s.leftShoulder,  s.leftElbow)  ? .leftForearm  : .leftArm
        case .rightArm: return beyond(p, s.rightShoulder, s.rightElbow) ? .rightForearm : .rightArm
        default:        return part
        }
    }
    private static func beyond(_ p: CGPoint, _ joint: CGPoint, _ mid: CGPoint) -> Bool {
        let dMid = dist(mid, joint)
        return dMid > 1 && dist(p, joint) > dMid
    }

    // MARK: - Confidence + fallback

    private static func score(strokes: [RigStroke], skeleton: Skeleton, headFound: Bool) -> CGFloat {
        var present = Set<BodyPart>()
        for s in strokes { for part in s.parts { present.insert(part) } }
        let hasLeftArm  = present.contains(.leftArm)  || present.contains(.leftForearm)
        let hasRightArm = present.contains(.rightArm) || present.contains(.rightForearm)
        let hasLeftLeg  = present.contains(.leftLeg)  || present.contains(.leftShin)
        let hasRightLeg = present.contains(.rightLeg) || present.contains(.rightShin)
        var c: CGFloat = 0
        if headFound { c += 0.4 }
        if skeleton.bbox.height >= skeleton.bbox.width { c += 0.2 }
        if hasLeftArm && hasRightArm { c += 0.2 }
        if hasLeftLeg && hasRightLeg { c += 0.2 }
        return c
    }

    private static func allTorsoFallback(_ raw: [([CGPoint], Color, CGFloat)], bbox: CGRect) -> Rig {
        let strokes = raw.map { RigStroke(points: $0.0, parts: Array(repeating: .torso, count: $0.0.count), color: $0.1, width: $0.2) }
        let c = CGPoint(x: bbox.midX, y: bbox.midY)
        let skel = Skeleton(bbox: bbox, headCenter: CGPoint(x: bbox.midX, y: bbox.minY), headRadius: max(bbox.height * 0.1, 10),
                            neck: c, leftShoulder: c, rightShoulder: c, leftElbow: c, rightElbow: c,
                            hipCenter: c, leftHip: c, rightHip: c, leftKnee: c, rightKnee: c,
                            feet: CGPoint(x: bbox.midX, y: bbox.maxY), leftHand: c, rightHand: c)
        return Rig(strokes: strokes, skeleton: skel, confidence: 0, articulated: false)
    }

    // MARK: - Geometry helpers

    private static func isClosed(_ pts: [CGPoint]) -> Bool {
        guard pts.count > 6 else { return false }
        var per: CGFloat = 0
        for i in 1..<pts.count { per += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
        guard per > 0 else { return false }
        return hypot(pts.first!.x - pts.last!.x, pts.first!.y - pts.last!.y) < per * 0.18
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// Distance from `p` to the segment a→b (the trunk line for shoulder snapping).
    private static func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0.001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / len2, 0), 1)
        return hypot(p.x - (a.x + abx * t), p.y - (a.y + aby * t))
    }

    /// Is this stroke a 2D "blob" (an outline limb whose two walls double back) rather than a
    /// thin 1D line? Two tests must BOTH pass. (1) Minor/major principal-axis spread (PCA):
    /// a line is ~0, an outline tube/loop is ~0.3+. (2) The path must DOUBLE BACK along its
    /// major axis: 2D spread alone can't tell an outline from a plain BENT line — both arms
    /// drawn in one ∧/∩ stroke (or both legs as one ∧) spread widely on both axes too, and
    /// calling that stroke fat polygon-filled the arch solid, bound it rigid, and Step 7a then
    /// classified it whole as TORSO (its centroid sits on the spine) — both arms vanished.
    /// An outline's walls run the shape's length out AND back (travel ≈ 2× the extent along
    /// the major axis, like a loop); a bent line crosses its extent once (≈ 1×, wobble aside).
    /// Drives the rigid (indivisible) binding so an open outline limb rotates as one piece
    /// instead of tearing at the elbow, while a bent one-stroke limb pair keeps its per-point
    /// split (arm|torso|arm across the apex) and articulates both sides.
    private static func isFat(_ pts: [CGPoint]) -> Bool {
        guard pts.count >= 8 else { return false }
        let n = CGFloat(pts.count)
        var mx: CGFloat = 0, my: CGFloat = 0
        for p in pts { mx += p.x; my += p.y }
        mx /= n; my /= n
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in pts { let dx = p.x - mx, dy = p.y - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
        sxx /= n; syy /= n; sxy /= n
        let tr = sxx + syy
        let disc = max(0, tr * tr / 4 - (sxx * syy - sxy * sxy))
        let l1 = tr / 2 + sqrt(disc), l2 = tr / 2 - sqrt(disc)
        guard l1 > 0.0001, sqrt(max(0, l2) / l1) > 0.22 else { return false }
        // Major-axis eigenvector of the covariance (either row form; fall back to the wider
        // coordinate axis when the matrix is already diagonal).
        var ex = l1 - syy, ey = sxy
        if hypot(ex, ey) < 0.0001 { ex = sxy; ey = l1 - sxx }
        if hypot(ex, ey) < 0.0001 { ex = sxx >= syy ? 1 : 0; ey = sxx >= syy ? 0 : 1 }
        let elen = hypot(ex, ey)
        var tMin = CGFloat.greatestFiniteMagnitude, tMax = -CGFloat.greatestFiniteMagnitude
        var travel: CGFloat = 0, prevT: CGFloat = 0
        for (i, p) in pts.enumerated() {
            let t = (p.x * ex + p.y * ey) / elen
            tMin = min(tMin, t); tMax = max(tMax, t)
            if i > 0 { travel += abs(t - prevT) }
            prevT = t
        }
        let extent = tMax - tMin
        return extent > 0.0001 && travel >= extent * 1.6
    }

    private static func robustTopCenterX(_ points: [CGPoint], _ bbox: CGRect) -> CGFloat {
        let cutoff = bbox.minY + bbox.height * 0.22
        let xs = points.filter { $0.y <= cutoff }.map(\.x).sorted()
        guard !xs.isEmpty else { return bbox.midX }
        return xs[xs.count / 2]
    }

    private static func densify(_ pts: [CGPoint], maxStep: CGFloat = 4) -> [CGPoint] {
        guard pts.count > 1 else { return pts }
        var out: [CGPoint] = [pts[0]]
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let d = hypot(b.x - a.x, b.y - a.y)
            let n = max(1, Int(ceil(d / maxStep)))
            for k in 1...n {
                let f = CGFloat(k) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        return out
    }

    /// The visible width of one rendered stroke, in canvas points. Renders the single stroke to
    /// a bitmap, counts the painted (non-transparent) pixels for its area, and divides by the
    /// stroke's centreline length — area ≈ width × length, so area ÷ length ≈ the average width
    /// PencilKit actually paints. This matches the live PKCanvasView render (verified), and
    /// sidesteps PKStrokePoint.size, which DIFFERS from the painted width per ink (the pen paints
    /// wider than its nominal size, the marker narrower). Clamped; returns `fallback` on failure.
    ///
    /// The render scale matters: at a low scale the antialiased fringe inflates the pixel count
    /// and the stroke measures too thick, so we render at the screen's native scale where the
    /// measurement converges on the true on-screen width.
    private static func renderedWidth(_ stroke: PKStroke, fallback: CGFloat) -> CGFloat {
        let t = stroke.transform
        var length: CGFloat = 0
        var prev: CGPoint? = nil
        for sp in stroke.path {
            let p = sp.location.applying(t)
            if let q = prev { length += hypot(p.x - q.x, p.y - q.y) }
            prev = p
        }
        guard length > 1 else { return fallback }

        let drawing = PKDrawing(strokes: [stroke])
        let bounds = drawing.bounds.insetBy(dx: -4, dy: -4)
        guard bounds.width > 0.5, bounds.height > 0.5,
              bounds.width < 5000, bounds.height < 5000 else { return fallback }

        // Render at screen scale for an accurate measure; drop the scale only for a giant stroke
        // so the bitmap stays bounded (a fringe error there is negligible relative to the width).
        var scale: CGFloat = 3
        let maxDim = max(bounds.width, bounds.height)
        if maxDim * scale > 3000 { scale = 3000 / maxDim }
        let image = drawing.image(from: bounds, scale: scale)
        guard let cg = image.cgImage else { return fallback }

        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return fallback }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fallback }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var covered = 0
        var i = 3
        while i < pixels.count { if pixels[i] > 12 { covered += 1 }; i += 4 }
        guard covered > 0 else { return fallback }

        let areaPoints = CGFloat(covered) / (scale * scale)   // px → canvas pt²
        let width = areaPoints / length
        return max(2, min(width, 80))
    }

    private static func boundingBox(_ pts: [CGPoint]) -> CGRect? {
        guard let first = pts.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Occupancy grid + runs

/// One maximal horizontal occupied span in a grid row, with its world-space x extent.
private struct Run {
    var c0: Int, c1: Int
    var x0: CGFloat, x1: CGFloat
    var xMid: CGFloat, w: CGFloat
}

/// A coarse occupancy raster of the figure. Closed strokes are scanline-filled (so an outline
/// becomes a solid silhouette read as ONE run), open strokes are stamped as thick discs.
private struct RasterGrid {
    let rows: Int, cols: Int
    let cellSize: CGFloat
    let originX: CGFloat, originY: CGFloat
    var occ: [Bool]

    init(bbox: CGRect) {
        let pad = 2
        let targetRows = 80
        var cs = max(bbox.height, 1) / CGFloat(targetRows)
        var rws = targetRows + 2 * pad
        var cls = Int(ceil(bbox.width / cs)) + 2 * pad
        if rws * cls > 9000 {                                   // cap total cells
            let f = (CGFloat(rws * cls) / 9000).squareRoot()
            cs *= f
            rws = Int(ceil(bbox.height / cs)) + 2 * pad
            cls = Int(ceil(bbox.width / cs)) + 2 * pad
        }
        rows = max(rws, 8); cols = max(cls, 8); cellSize = cs
        originX = bbox.minX - CGFloat(pad) * cs
        originY = bbox.minY - CGFloat(pad) * cs
        occ = [Bool](repeating: false, count: rows * cols)
    }

    func col(_ x: CGFloat) -> Int { min(max(Int((x - originX) / cellSize), 0), cols - 1) }
    func row(_ y: CGFloat) -> Int { min(max(Int((y - originY) / cellSize), 0), rows - 1) }
    func cellX(_ c: Int) -> CGFloat { originX + (CGFloat(c) + 0.5) * cellSize }
    func cellY(_ r: Int) -> CGFloat { originY + (CGFloat(r) + 0.5) * cellSize }
    private mutating func set(_ r: Int, _ c: Int) { if r >= 0, r < rows, c >= 0, c < cols { occ[r * cols + c] = true } }

    mutating func stampPolyline(_ pts: [CGPoint], width: CGFloat) {
        let discR = max(1, Int(ceil((width / 2) / cellSize)))
        for p in pts {
            let r = row(p.y), c = col(p.x)
            for dr in -discR...discR { for dc in -discR...discR where dr * dr + dc * dc <= discR * discR { set(r + dr, c + dc) } }
        }
    }

    /// Scanline-fill the closed polygon `pts` (implicit last→first edge) into the grid.
    mutating func fillPolygon(_ pts: [CGPoint]) {
        let n = pts.count
        guard n >= 3 else { return }
        for r in 0..<rows {
            let y = cellY(r)
            var xs: [CGFloat] = []
            for i in 0..<n {
                let a = pts[i], b = pts[(i + 1) % n]
                if (a.y <= y && b.y > y) || (b.y <= y && a.y > y) {
                    let t = (y - a.y) / (b.y - a.y)
                    xs.append(a.x + t * (b.x - a.x))
                }
            }
            guard xs.count >= 2 else { continue }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                let c0 = col(xs[k]), c1 = col(xs[k + 1])
                if c0 <= c1 { for c in c0...c1 { set(r, c) } }
                k += 2
            }
        }
    }

    func runs(row r: Int) -> [Run] {
        var spans: [(Int, Int)] = []
        var c = 0
        while c < cols {
            if occ[r * cols + c] {
                var c1 = c
                while c1 + 1 < cols && occ[r * cols + c1 + 1] { c1 += 1 }
                spans.append((c, c1)); c = c1 + 1
            } else { c += 1 }
        }
        var merged: [(Int, Int)] = []
        for s in spans {
            if let last = merged.last, s.0 - last.1 - 1 < 2 { merged[merged.count - 1].1 = s.1 }
            else { merged.append(s) }
        }
        return merged.map { s in
            let x0 = originX + CGFloat(s.0) * cellSize
            let x1 = originX + CGFloat(s.1 + 1) * cellSize
            return Run(c0: s.0, c1: s.1, x0: x0, x1: x1, xMid: (x0 + x1) / 2, w: x1 - x0)
        }
    }
}
