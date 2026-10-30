// Port of RigFitter.swift — turns the participant's pen strokes into a rigged figure.
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
// graceful whole-body fallback.
//
// Web notes: input strokes are `{points:[{x,y}], width, color}`. The pen width is known
// exactly on the web, so it replaces PencilKit's `renderedWidth` raster measurement
// (same clamp). Colours are plain CSS strings — no appearance resolution needed.

import { P, isArm, isLeg, rect, ZERO_RECT, makeRig } from './model.js';
import { validate } from './plausibility.js';

const hypot = Math.hypot;
const INF = Number.MAX_VALUE;

/// Harness-only step trace: when non-null, `fit` appends a per-stroke label histogram after
/// each labelling step so a mislabel can be pinned to the pass that made it.
export const debug = { trace: null };

export function fit(inputStrokes) {
  function traceStep(name, parts, extra = '') {
    if (debug.trace === null) return;
    let line = `  [${name}]${extra}\n`;
    parts.forEach((ps, i) => {
      const counts = new Map();
      for (const p of ps) counts.set(p, (counts.get(p) || 0) + 1);
      line += `    s${i}: ` + [...counts.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))
        .map(([k, v]) => `${k}:${v}`).join(' ') + '\n';
    });
    debug.trace += line;
  }

  // ---- Step 0: sample → densified polylines, flag closed loops ----
  const raw = [];
  for (const stroke of inputStrokes) {
    let pts = densify(stroke.points.map((p) => ({ x: p.x, y: p.y })));
    // A single-tap DOT (an eye, a nose, a freckle) samples as ONE control point — or a
    // tight cluster with no real extent — so it died on the guard below and face details
    // vanished the moment the figure came to life. Keep it: give the point a sliver of
    // length so its bbox is real (the detail-folding pass then binds it to the head) and
    // so the stage's round line cap paints it (a zero-length path can render as nothing).
    if (pts.length === 1) pts.push({ x: pts[0].x, y: pts[0].y });
    const bb = boundingBox(pts);
    if (bb && Math.max(bb.width, bb.height) < 0.7) {
      const c = { x: bb.midX, y: bb.midY };
      pts = [{ x: c.x - 0.35, y: c.y }, { x: c.x + 0.35, y: c.y }];
    }
    if (pts.length < 2) continue;
    // The visible pen weight. On the web it is known exactly (no raster measure needed);
    // same clamp as the Swift `renderedWidth`.
    const w = Math.max(2, Math.min(stroke.width > 0 ? stroke.width : 4, 80));
    // `closed` = a tight loop; `fat` = a 2D outline (incl. an OPEN "U") — both are
    // silhouette outlines that must be FILLED when rasterized and bound RIGIDLY.
    raw.push({ points: pts, color: stroke.color, width: w, closed: isClosed(pts), fat: isFat(pts) });
  }

  const allPoints = raw.flatMap((r) => r.points);
  const bbox = boundingBox(allPoints) || ZERO_RECT;
  if (!(bbox.width > 1 && bbox.height > 1 && raw.length > 0)) {
    return allTorsoFallback(raw, bbox);
  }
  const avgInkW = raw.reduce((a, r) => a + r.width, 0) / raw.length;

  // ---- Step 1: rasterize (closed → filled polygon, open → thick stamped line) ----
  const grid = new RasterGrid(bbox);
  for (const r of raw) {
    // Fill any outline (closed loop OR open 2D "U"); else a hollow outline reads as two
    // runs with a gap and is mistaken for two legs / a split torso.
    if (r.closed || r.fat) grid.fillPolygon(r.points);
    grid.stampPolyline(r.points, r.width);
  }
  // NB: no morphological close — polygon-fill already solidifies outlines, and a close
  // would bridge the narrow inseam between two closely-drawn legs into one blob (defeating
  // crotch detection). Touching strokes don't need bridging: runs are read per row.

  // ---- Step 2: per-row occupied runs ----
  const rowRuns = [];
  for (let r = 0; r < grid.rows; r++) rowRuns.push(grid.runs(r));
  let topRow = -1, botRow = -1;
  for (let r = 0; r < grid.rows; r++) if (rowRuns[r].length) { topRow = r; break; }
  for (let r = grid.rows - 1; r >= 0; r--) if (rowRuns[r].length) { botRow = r; break; }
  if (topRow < 0 || botRow < 0) return allTorsoFallback(raw, bbox);

  // ---- Step 3: head (largest centred top-band blob), neck, spine track ----
  const topCenterX = robustTopCenterX(allPoints, bbox);
  const headDet = detectHead(raw.map((r) => r.points), bbox, topCenterX, avgInkW);
  const headIndex = headDet ? headDet.index : -1;
  const headCenter = headDet ? headDet.center
    : { x: robustTopCenterX(allPoints, bbox), y: bbox.minY + 0.13 * bbox.height };
  const headRadius = headDet ? headDet.radius : Math.max(0.10 * bbox.height, 14);
  // The neck sits at the head's actual BOTTOM edge, not headCenter+radius — a wide oval
  // head's radius (= width/2) would otherwise reach well below it and swallow the
  // shoulders/arm-tops into the head zone.
  const headBottom = headDet ? headDet.bottom : (headCenter.y + headRadius);
  const neckY = Math.min(headBottom, bbox.minY + 0.55 * bbox.height);
  const neckRow = grid.row(neckY);

  // Spine x per row: follow the run nearest the previous spine x, seeded at the head.
  // Robust to lean (the centreline tracks the body down) and to splayed limbs.
  const spineX = new Array(grid.rows).fill(headCenter.x);
  let prev = headCenter.x;
  const maxSpineStep = Math.max(2, grid.cellSize * 0.5);
  for (let r = topRow; r <= botRow; r++) {
    const rs = rowRuns[r];
    if (rs.length === 0) { spineX[r] = prev; continue; }
    // Prefer the run that still CONTAINS the spine; else the nearest. Then move toward
    // its centre only a little per row — the spine is near-vertical, so a big jump means
    // an arm merged into the run, and we must NOT let the centreline drift onto the arm
    // (which would mislabel that arm as torso and the spine as an arm).
    const cr = rs.find((q) => q.x0 <= prev && prev <= q.x1) || minBy(rs, (q) => Math.abs(q.xMid - prev));
    spineX[r] = prev + Math.max(-maxSpineStep, Math.min(maxSpineStep, cr.xMid - prev));
    prev = spineX[r];
  }
  for (let r = 0; r < topRow; r++) spineX[r] = spineX[topRow];

  // ---- Step 4: crotch via the band gap-walk, run-aware (immune to lean) ----
  // Walking UP from the feet: a leg band has two runs split by a wide gap; the crotch
  // is the top of the feet-connected two-run region (where the legs merge). We stop at
  // the single-run torso, so the ARMS (a higher multi-run band) are never read as legs.
  const gapThresh = Math.max(grid.cellSize * 2, bbox.height * 0.025);   // closely-spaced filled legs still split
  const scanTopRow = grid.row(neckY + (bbox.maxY - neckY) * 0.30);
  let crotchRow = grid.row(neckY + (bbox.maxY - neckY) * 0.55);         // fallback
  let crotchX = spineX[Math.min(crotchRow, grid.rows - 1)];
  // A thick pen fills ≈ inkWidth/cellSize rows solid where the legs meet, so the walk
  // must tolerate that many merged rows before concluding the crotch — a fixed 1-row
  // tolerance stopped a fat-pen walk far below the true crotch (the too-low crotch that
  // strands leg ink in the arm band). Capped so the walk can't tunnel through the torso.
  const missCap = Math.min(6, Math.max(2, Math.ceil(avgInkW / Math.max(grid.cellSize, 1))));
  // The band above the legs is read as "still legs" only while it LOOKS like two legs:
  // once a row holds ≥3 runs (spine + arms, or arms hanging beside the leg tops on a
  // short torso) or the gap's midpoint jumps sideways (the widest gap switched from
  // between-the-legs to between-an-arm-and-the-spine), the walk has reached the arm
  // band and stops. Without this a short-torso figure's hanging arms were walked
  // straight through — the crotch landed at the SHOULDERS and both arms became legs.
  // (Feet — a dash or blob at each leg tip — add runs too, so the stops only apply
  // above the bottom 30% of the body; the arm band is never that low.)
  let legIdx = -1, misses = 0;
  let lastMid = null;
  const midJump = Math.max(grid.cellSize * 2.5, bbox.width * 0.06);
  const feetBandY = bbox.maxY - (bbox.maxY - neckY) * 0.30;
  for (let r = botRow; r >= scanTopRow; r--) {
    const [two, mid] = twoLegged(rowRuns[r], gapThresh);
    if (two) {
      if (legIdx >= 0 && grid.cellY(r) < feetBandY) {
        if (rowRuns[r].length >= 3) break;
        if (lastMid !== null && Math.abs(mid - lastMid) > midJump) break;
      }
      legIdx = r; crotchX = mid; misses = 0; lastMid = mid;
    } else if (legIdx >= 0) { misses += 1; if (misses > missCap) break; }
  }
  if (legIdx >= 0) {
    crotchRow = legIdx;
  } else {                                  // no gap → legs drawn straight down / touching
    const widthThresh = Math.max(grid.cellSize * 4, bbox.width * 0.30);
    for (let r = botRow; r >= scanTopRow; r--) {
      const cr = central(rowRuns[r], spineX[r]);
      if (cr && cr.w <= widthThresh) { crotchRow = r; crotchX = cr.xMid; break; }
    }
  }
  crotchRow = Math.min(Math.max(crotchRow, neckRow + 1), botRow);
  let crotchY = grid.cellY(crotchRow);

  // ---- Step 5: torso width MEASURED from the central run (the anti-edge-as-arm fix) ----
  // Measure over the MIDDLE of the torso (35–90% neck→crotch) where arms don't reach, so
  // a merged-in arm at the shoulders can't inflate it. This width is then used to TRIM the
  // torso: anything in the central run beyond it is an arm (handles arms that touch the
  // torso — Character 1's corner arms, Character 2's attached loops — uniformly).
  const halfs = [];
  if (crotchRow > neckRow + 1) {
    for (let r = neckRow + 1; r < crotchRow; r++) {
      const cr = central(rowRuns[r], spineX[r]);
      if (cr) halfs.push(cr.w / 2);
    }
  }
  // A 30th-percentile of central-run half-widths over the whole torso gives the un-merged
  // torso "waist": an arm touching the torso only ADDS width (high percentile), so a low
  // percentile can't be inflated by a merged arm. The torso (a closed stroke) survives
  // any over-trim via its majority vote; the arm gets correctly peeled off.
  const sortedHalfs = halfs.slice().sort((a, b) => a - b);
  const measuredHalf = sortedHalfs.length === 0 ? Math.max(avgInkW, 8)
    : sortedHalfs[Math.floor(sortedHalfs.length * 0.30)];
  // Floor is just a small absolute guard against a degenerate zero-width torso — NOT
  // head-relative (a big head must not widen the torso band and swallow arm roots on a
  // thin-spine stick figure). The measured waist already carries the true torso width.
  const torsoHalfW = Math.min(Math.max(measuredHalf, 6), bbox.width * 0.45);
  const torsoReach = torsoHalfW * 1.25;     // taper/wobble tolerance before calling it an arm
  const bodyLen = Math.max(bbox.maxY - neckY, 1);

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
  // WHAT COUNTS AS A LEG STROKE (the anti-"leg top swings as an arm" gates): a thin
  // descending stroke is a leg if it roots in the lower body OR REACHES THE GROUND — a
  // hanging arm ends well above the feet whatever the proportions, a leg always lands
  // there. Legs drawn thigh+shin are CHAINED: a descending stroke whose foot sits on a
  // detected leg's root (the knee) is that leg's upper segment, so the hip still rises
  // to the thigh roots.
  const shoulderBandY = neckY + bodyLen * 0.18;
  const hipBandY = neckY + bodyLen * 0.40;
  const groundY = bbox.maxY - bodyLen * 0.20;
  const legSide = new Array(raw.length).fill(null);
  let legStrokesDetected = false;
  {
    const legStrokes = [];
    const isLegStroke = new Array(raw.length).fill(false);
    const candidates = [];
    for (let i = 0; i < raw.length; i++) {
      if (raw[i].closed || raw[i].fat) continue;
      const bb = boundingBox(raw[i].points) || ZERO_RECT;
      if (bb.midY < neckY) continue;                        // an upper / head-zone stroke
      const { root, foot } = strokeRoot(raw[i].points);
      if (!(root.y >= shoulderBandY &&                      // whole stroke hangs below the shoulders
            foot.y - root.y > bodyLen * 0.08)) continue;    // real vertical descent (not a dash / horizontal)
      candidates.push({ i, root, foot });
      // Reaches the ground, or roots low AND is leg-long: a two-stroke arm's FOREARM
      // also roots in the lower body on a short torso, but it is short and ends in
      // mid-air; a leg is the longest thing hanging off the figure.
      if (foot.y - root.y > bodyLen * 0.12 &&
          (foot.y >= groundY || (root.y > hipBandY && foot.y - root.y > bodyLen * 0.25))) {
        isLegStroke[i] = true;
        legStrokes.push({ i, rootX: root.x, rootY: root.y });
      }
    }
    // Chain upper segments (thigh above a detected shin): foot ON a leg root.
    const joinR = Math.max(avgInkW * 2.5, bodyLen * 0.05);
    let grew = true;
    while (grew) {
      grew = false;
      for (const c of candidates) {
        if (isLegStroke[c.i]) continue;
        const touches = legStrokes.some((ls) => ls.i !== c.i && hypot(c.foot.x - ls.rootX, c.foot.y - ls.rootY) <= joinR);
        if (touches) {
          isLegStroke[c.i] = true;
          legStrokes.push({ i: c.i, rootX: c.root.x, rootY: c.root.y });
          grew = true;
        }
      }
    }
    if (legStrokes.length >= 2) {
      legStrokesDetected = true;
      // Hip x = the median root x (even counts average the middle pair, so two legs
      // meet in between and thigh+shin pairs don't bias it onto one leg).
      const xs = legStrokes.map((l) => l.rootX).sort((a, b) => a - b);
      const h = Math.floor(xs.length / 2);
      const hipX = xs.length % 2 === 1 ? xs[h] : (xs[h - 1] + xs[h]) / 2;
      if (legStrokes.length === 2) {
        const [lo, hi] = legStrokes[0].rootX <= legStrokes[1].rootX
          ? [legStrokes[0], legStrokes[1]] : [legStrokes[1], legStrokes[0]];
        legSide[lo.i] = P.leftLeg;
        legSide[hi.i] = P.rightLeg;
      } else {
        for (const ls of legStrokes) legSide[ls.i] = ls.rootX < hipX ? P.leftLeg : P.rightLeg;
      }
      const topRootY = legStrokes.length ? Math.min(...legStrokes.map((l) => l.rootY)) : crotchY;
      const hipY = Math.min(Math.max(topRootY, neckY + bodyLen * 0.20), bbox.maxY - bbox.height * 0.10);
      crotchX = hipX;
      crotchY = hipY;
      crotchRow = Math.min(Math.max(grid.row(hipY), neckRow + 1), botRow);
    } else if (legStrokes.length === 1) {
      // ONE detached leg stroke (the other leg is the spine's own continuation — the
      // λ body — or the figure is one-legged): it is still a WHOLE leg, sided by the
      // way it goes from its root. The hip stays on the legacy path (gap-walk + the
      // leg-silhouette hip-raise), which needs ≥2 roots to converge.
      const only = legStrokes[0];
      const { root, foot } = strokeRoot(raw[only.i].points);
      const dx = foot.x - root.x;
      const side = Math.abs(dx) > avgInkW ? (dx < 0 ? P.leftLeg : P.rightLeg)
        : (root.x < spineX[grid.row(root.y)] ? P.leftLeg : P.rightLeg);
      legSide[only.i] = side;
      // Its root still says where the hip IS — never let the gap-walk's crotch sit
      // ABOVE it (that is the walk having climbed into the arm band).
      const hipY = Math.min(Math.max(root.y, neckY + bodyLen * 0.20), bbox.maxY - bbox.height * 0.10);
      if (hipY < crotchY) {
        crotchY = hipY;
        crotchRow = Math.min(Math.max(grid.row(hipY), neckRow + 1), botRow);
        crotchX = (root.x + spineX[crotchRow]) / 2;
      }
    }
  }

  // ---- Step 6: label every occupied cell. The central run is trimmed to the torso slab;
  //              its lateral overhang and any separate side run become arms. ----
  const label = new Array(grid.rows * grid.cols).fill(null);
  for (let r = topRow; r <= botRow; r++) {
    const rs = rowRuns[r];
    const cx = spineX[r];
    const centralRun = central(rs, cx);
    for (const run of rs) {
      if (r <= neckRow) {
        for (let c = run.c0; c <= run.c1; c++) label[r * grid.cols + c] = P.head;
      } else if (r >= crotchRow) {
        const part = run.xMid < crotchX ? P.leftLeg : P.rightLeg;
        for (let c = run.c0; c <= run.c1; c++) label[r * grid.cols + c] = part;
      } else if (centralRun && centralRun.c0 === run.c0 && centralRun.c1 === run.c1) {
        for (let c = run.c0; c <= run.c1; c++) {
          const x = grid.cellX(c);
          const part = x < cx - torsoReach ? P.leftArm : (x > cx + torsoReach ? P.rightArm : P.torso);
          label[r * grid.cols + c] = part;
        }
      } else {
        // A separate side run between neck and crotch is an arm — but only in the
        // UPPER body. A side run deeper than ~55% of the body, NEAR the crotch
        // laterally, is leg ink that a too-low crotch stranded above crotchRow
        // (thick pens / a merged inseam): labelling it arm is the "hip area
        // extends out" fling. The lateral gate keeps a LONG hanging arm's hand —
        // which can reach this deep but hangs far out from the crotch — an arm.
        const deep = grid.cellY(r) > neckY + bodyLen * 0.55
          && Math.abs(run.xMid - crotchX) < Math.max(torsoHalfW * 2, bbox.width * 0.18);
        const part = deep ? (run.xMid < crotchX ? P.leftLeg : P.rightLeg)
          : (run.xMid < cx ? P.leftArm : P.rightArm);
        for (let c = run.c0; c <= run.c1; c++) label[r * grid.cols + c] = part;
      }
    }
  }

  // Geometry fallback for points whose cell has no label (wobble outside the silhouette).
  const neckX = spineX[neckRow];
  function centerAt(y) {
    const y0 = neckY, y1 = crotchY;
    if (!(y1 > y0 + 1)) return crotchX;
    const t = Math.min(Math.max((y - y0) / (y1 - y0), 0), 1);
    return neckX + (crotchX - neckX) * t;
  }
  function geomFallback(p) {
    if (hypot(p.x - headCenter.x, p.y - headCenter.y) <= headRadius * 1.2 || p.y < neckY) return P.head;
    const cx = centerAt(p.y);
    if (p.y >= crotchY) return p.x < cx ? P.leftLeg : P.rightLeg;
    if (Math.abs(p.x - cx) < torsoHalfW) return P.torso;
    return p.x < cx ? P.leftArm : P.rightArm;
  }
  function labelAt(p) {
    const c = grid.col(p.x), r = grid.row(p.y);
    const l0 = label[r * grid.cols + c];
    if (l0 !== null) return l0;
    for (let rad = 1; rad <= 2; rad++) {
      for (let dr = -rad; dr <= rad; dr++) {
        for (let dc = -rad; dc <= rad; dc++) {
          const rr = r + dr, cc = c + dc;
          if (rr >= 0 && rr < grid.rows && cc >= 0 && cc < grid.cols) {
            const l = label[rr * grid.cols + cc];
            if (l !== null) return l;
          }
        }
      }
    }
    return geomFallback(p);
  }

  // ---- Step 7: skin each stroke (closed loop → ONE rigid part; line → per-point) ----
  const regionParts = [];
  const rigidFlags = [];
  const foldHeadFlags = [];
  for (const r0 of raw) {
    const bb = boundingBox(r0.points) || ZERO_RECT;
    // Detail-folding: a small stroke inside the head disc (eyes/mouth/dots/hair/horns)
    // rides the head — it must never spawn a phantom limb near the shoulder.
    // (…and nothing of it below the neck: a raised arm beside a WIDE head — whose
    // "radius" is its half-width — sits inside that generous disc, but it is rooted
    // at the shoulder; face details, hair and ears never reach below the neck.)
    const foldHead = bb.midY < neckY + headRadius * 0.2
      && Math.max(bb.width, bb.height) < headRadius * 1.5
      && hypot(bb.midX - headCenter.x, bb.midY - headCenter.y) < headRadius * 1.25
      && bb.maxY <= neckY + avgInkW;
    // A stroke is RIGID (indivisible, one body part) if it's a closed loop OR a "fat"
    // 2D blob — an OUTLINE limb drawn as an open "U" (two walls that double back) is fat
    // even though it isn't closed, so it still rotates as one piece instead of tearing.
    // A thin line stays non-rigid and still splits arm→forearm for the wave.
    const rigid = !foldHead && (r0.closed || r0.fat);
    let parts = r0.points.map((p) => (foldHead ? P.head : labelAt(p)));
    if (foldHead) {
      // all head already
    } else if (rigid) {
      const win = majorityPart(parts);            // an outline is indivisible
      parts = parts.map(() => win);
    } else {
      parts = smoothParts(parts);                 // kill 1–2-point flips on open lines
      // A hand RAISED to head height lives in rows the silhouette calls HEAD, so a
      // raised arm's tip gets glued to the head and tears off when the arm swings.
      parts = reclaimRaisedTips(parts, r0.points, headCenter, headRadius);
    }
    regionParts.push(parts);
    rigidFlags.push(rigid);
    foldHeadFlags.push(foldHead);
  }

  // ---- Step 7g: a RAISED arm is not head ----
  // Rows above the neck are HEAD in the silhouette, so an arm raised beside the head
  // (shoulder → fist at head height) reads as head unless its root rows happened to get
  // arm labels for the tip-reclaim to extend. A thin, un-folded, head-majority stroke
  // that is not the head itself, ATTACHES at the trunk top (its lower end is below the
  // neck, near the trunk centreline) and reaches out BESIDE the head is a raised arm.
  // Hair, ears, a hat brim and face details never reach below the neck; a drawn neck
  // line sits on the centreline, not beside the head.
  for (let i = 0; i < raw.length; i++) {
    if (rigidFlags[i] || foldHeadFlags[i] || i === headIndex) continue;
    const ps = regionParts[i], pts = raw[i].points;
    if (pts.length < 4) continue;
    const headN = countWhere(ps, (p) => p === P.head);
    if (!(headN * 2 > ps.length)) continue;
    const a = pts[0], b = pts[pts.length - 1];
    const low = a.y >= b.y ? a : b;
    if (!(low.y > neckY + avgInkW * 0.5 &&
          Math.abs(low.x - neckX) <= Math.max(torsoHalfW * 1.5, 10) + avgInkW)) continue;
    let lateral = 0, n = 0;
    pts.forEach((p, j) => { if (ps[j] === P.head) { lateral += Math.abs(p.x - headCenter.x); n += 1; } });
    if (!(n > 0 && lateral / n > headRadius * 0.35)) continue;
    const meanX = pts.reduce((s, p) => s + p.x, 0) / pts.length;
    regionParts[i] = ps.map(() => (meanX < neckX ? P.leftArm : P.rightArm));
  }

  traceStep('7 skin', regionParts, ` crotch=(${Math.trunc(crotchX)},${Math.trunc(crotchY)}) neck=${Math.trunc(neckY)} torsoHalfW=${Math.trunc(torsoHalfW)} legDetected=${legStrokesDetected}`);
  // Detected leg strokes are WHOLE rigid legs, sided by their root. Override whatever
  // per-point labels the silhouette produced — this rescues a leg-top mislabeled as an
  // arm (veer-to-side) and makes the stroke indivisible so the scissor walk can't tear it
  // (crossed legs). Done here so the position-based fat-stroke pass (7a) can't re-decide them.
  for (let i = 0; i < raw.length; i++) {
    if (legSide[i] !== null) regionParts[i] = raw[i].points.map(() => legSide[i]);
  }

  // ---- Step 7a: classify FAT (outline) strokes as WHOLE limbs by position ----
  // Outline limbs that touch the torso MERGE into one silhouette blob, so per-row runs
  // can't separate them (no torso-only rows to measure a waist from). But each is a
  // distinct stroke, so classify it whole: the most-central UPPER fat stroke is the torso;
  // other upper fat strokes are arms; lower fat strokes are legs. Thin strokes are left to
  // the silhouette per-point labels above — stick figures are untouched.
  const bodyMid = neckY + bodyLen * 0.55;
  // A fat stroke is TRUNK (torso or a drawn neck — both sit on the spine) if its centroid
  // is near the centreline AT ITS OWN HEIGHT (`spineX`, which tracks a lean); otherwise
  // it's a lateral limb. Comparing to the lean-tracking spine — not the head x — keeps a
  // leaned torso central, while the tight threshold keeps an arm hanging beside a wide
  // torso lateral. So a drawn neck rides with the torso instead of becoming an arm.
  const trunkThreshold = Math.max(torsoHalfW * 0.6, bbox.width * 0.10);
  // Strokes split as a LIMB PAIR (both arms / both legs in one stroke) at their drawn
  // fold. That split is authoritative: 7b/7c must not re-split them at the noisy
  // pre-consolidation crotch/arm axes.
  const pairHandled = new Array(raw.length).fill(false);
  // A genuine limb PAIR folds at the TOP of its stroke — the crotch apex / shoulder
  // fold — with both branches hanging DOWN from it. The impostors cross the spine at
  // their BOTTOM: an open leg tube's rounded far tip, an open ∪ torso outline's hip
  // bottom. Splitting one of those tears the drawing into two counter-rotating halves
  // (the reported "body splits open"), so a junction in the lower stroke is a veto.
  function junctionNearTop(pts, j) {
    let lo = INF, hi = -INF;
    for (const p of pts) { lo = Math.min(lo, p.y); hi = Math.max(hi, p.y); }
    return pts[j].y <= lo + (hi - lo) * 0.45;
  }
  const spineAt = (p) => spineX[grid.row(p.y)];
  const upperFat = [];
  for (let i = 0; i < raw.length; i++) {
    if (!(rigidFlags[i] && legSide[i] === null)) continue;
    if (majorityPart(regionParts[i]) === P.head) continue;   // leave the head alone
    const pts = raw[i].points;
    const cx = pts.reduce((s, p) => s + p.x, 0) / pts.length;
    const cy = pts.reduce((s, p) => s + p.y, 0) / pts.length;
    const axis = spineX[grid.row(cy)];
    if (cy >= bodyMid) {
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
      const margin = Math.max(torsoHalfW * 0.5, 8);
      const pair = !raw[i].closed ? limbPairJunction(pts, spineAt, margin) : null;
      if (pair && junctionNearTop(pts, pair.j)) {
        const first = pair.firstIsLeft ? P.leftLeg : P.rightLeg;
        const second = pair.firstIsLeft ? P.rightLeg : P.leftLeg;
        regionParts[i] = pts.map((_, k) => (k <= pair.j ? first : second));
        rigidFlags[i] = false;
        pairHandled[i] = true;
      } else {
        regionParts[i] = pts.map(() => (cx < axis ? P.leftLeg : P.rightLeg));
      }
    } else {
      upperFat.push({ i, cx, axis });
    }
  }
  for (const f of upperFat) {
    const pts = raw[f.i].points;
    // BOTH arms drawn in one ∧/∩ stroke, STEEPER than wide: the major axis is vertical
    // and the path doubles back along it, so isFat's travel gate can't clear it (a wide
    // arch is cleared there). Its centroid sits ON the spine, so the trunk test below
    // would swallow both arms as torso. Same limb-pair discriminator as the legs:
    // free ends far out on OPPOSITE sides, each branch labelled whole from the junction.
    const reach = Math.max(torsoReach * 1.5, bbox.width * 0.12);
    const pair = !raw[f.i].closed ? limbPairJunction(pts, spineAt, reach) : null;
    if (pair) {
      if (junctionNearTop(pts, pair.j)) {
        const first = pair.firstIsLeft ? P.leftArm : P.rightArm;
        const second = pair.firstIsLeft ? P.rightArm : P.leftArm;
        regionParts[f.i] = pts.map((_, k) => (k <= pair.j ? first : second));
        rigidFlags[f.i] = false;
        pairHandled[f.i] = true;
      } else {
        // Structurally a pair but folded at the BOTTOM: an open ∪ torso outline,
        // or both arms RAISED in one ∨ stroke. Ambiguous — so freeze it as TRUNK.
        // For the ∪ that is simply correct; for a raised ∨ it is the graceful
        // lesser evil (the centroid fallback below would make the whole two-arm
        // stroke ONE arm and swing the far branch about the wrong shoulder).
        regionParts[f.i] = pts.map(() => P.torso);
      }
    } else if (Math.abs(f.cx - f.axis) < trunkThreshold) {
      regionParts[f.i] = pts.map(() => P.torso);
    } else {
      regionParts[f.i] = pts.map(() => (f.cx < f.axis ? P.leftArm : P.rightArm));
    }
  }

  traceStep('7a fat', regionParts);
  // ---- Step 7b: consolidate THIN leg strokes + raise the hip to the leg junction ----
  // The gap-based crotch sits too LOW when the legs meet at a point (inverted-V) or thick
  // strokes overlap near the join, so the leg TOPS get mislabeled as arms — which drags
  // the elbow/hand down the body and flings the limb when it animates. A one-sided
  // leg-dominated stroke becomes one whole leg; a centre-crossing one keeps its split.
  // Then the hip rises to the topmost leg point so the leg pivots where it really attaches.
  for (let i = 0; i < raw.length; i++) {
    if (rigidFlags[i]) continue;               // fat legs already handled in 7a
    if (legSide[i] !== null) continue;         // detected leg strokes: already whole by root, never split
    if (pairHandled[i]) continue;              // a limb pair is already split at its junction
    const legN = countWhere(regionParts[i], isLeg);
    if (!(legN * 2 > regionParts[i].length)) continue;
    const pts = raw[i].points;
    // A leg-majority stroke ROOTED AT THE NECK is the spine running on into a leg (the
    // λ body, leg-heavy on a short torso) — consolidating it would make the whole
    // spine a leg and drag the hip up to the neck. It keeps its torso|leg split.
    if (strokeRoot(pts).root.y < shoulderBandY) continue;
    const minX = pts.length ? Math.min(...pts.map((p) => p.x)) : 0;
    const maxX = pts.length ? Math.max(...pts.map((p) => p.x)) : 0;
    const margin = Math.max(torsoHalfW, 8);
    if (minX < crotchX - margin && maxX > crotchX + margin) {
      regionParts[i] = pts.map((p) => (p.x < crotchX ? P.leftLeg : P.rightLeg));   // inverted-V in one stroke
    } else {
      const cx = pts.reduce((s, p) => s + p.x, 0) / pts.length;
      regionParts[i] = pts.map(() => (cx < crotchX ? P.leftLeg : P.rightLeg));
    }
  }
  traceStep('7b legs', regionParts);
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
  for (let i = 0; i < raw.length; i++) {
    if (rigidFlags[i] || pairHandled[i]) continue;
    const parts = regionParts[i];
    const n = parts.length;
    const torsoN = countWhere(parts, (p) => p === P.torso);
    if (!(torsoN * 2 > n)) continue;
    const healed = parts.slice();
    let k = 0;
    while (k < n) {
      if (healed[k] === P.torso) { k += 1; continue; }
      let e = k;
      while (e + 1 < n && healed[e + 1] === healed[k]) e += 1;
      const len = e - k + 1;
      const interior = k > 0 && e < n - 1 && healed[k - 1] === P.torso && healed[e + 1] === P.torso;
      if ((interior && len <= Math.max(4, Math.floor(n / 5))) || (!interior && len <= 2)) {
        for (let m = k; m <= e; m++) healed[m] = P.torso;
      }
      k = e + 1;
    }
    regionParts[i] = healed;
  }

  traceStep('7c heal', regionParts);
  // ---- Step 7e: a thin stroke is NEVER half arm, half leg ----
  // An arm and a leg don't share a pen stroke, so a thin stroke carrying BOTH labels is
  // one limb cut by a misplaced crotch: (a) the TOP of a leg stranded in the arm band —
  // the hinge at the hip that swings up like an arm (the reported indecent rig); (b) a
  // hanging arm whose hand dips below the crotch on a short torso — its tip scissors with
  // the legs while the arm waves. Decide the WHOLE stroke by what a leg is: it reaches
  // the ground, or roots in the lower body, or (the λ body: spine → hip → foot in one
  // stroke) its arm run is sandwiched between the trunk and the leg. Otherwise it's an
  // arm whole. Detected legs and pair-split strokes are already whole and left alone.
  for (let i = 0; i < raw.length; i++) {
    if (rigidFlags[i] || pairHandled[i] || legSide[i] !== null) continue;
    const ps = regionParts[i];
    let lArm = 0, rArm = 0, lLeg = 0, rLeg = 0;
    for (const p of ps) {
      if (p === P.leftArm) lArm += 1;
      else if (p === P.rightArm) rArm += 1;
      else if (p === P.leftLeg) lLeg += 1;
      else if (p === P.rightLeg) rLeg += 1;
    }
    const armN = lArm + rArm, legN = lLeg + rLeg;
    const pts = raw[i].points;
    const { root, foot } = strokeRoot(pts);
    const torsoN = countWhere(ps, (p) => p === P.torso);
    if (armN === 0 && legN > 0 && torsoN > 0 && foot.y < groundY && root.y <= hipBandY) {
      // torso|leg with no arm labels: an arm that starts INSIDE a wide torso outline
      // and dips below the crotch (or any upper-rooted dangle). It's not a leg — it
      // ends in mid-air — and the leg tail would scissor with the walk while the
      // rest stays put, tearing the stroke at the crotch line. Ride the root.
      regionParts[i] = ps.map((p) => (isLeg(p) ? P.torso : p));
      continue;
    }
    if (!(armN > 0 && legN > 0)) continue;
    // λ shape: in PATH order the labels go torso … arm … leg (or the reverse) — and
    // the torso run is the SPINE: it spans most of the trunk's height. A hanging arm
    // that starts inside a wide torso outline and ends below the crotch shows the
    // same torso|arm|leg sequence, but its torso run is a short stretch at the root.
    let sandwiched = false;
    let tLo = INF, tHi = -INF;
    ps.forEach((p, j) => { if (p === P.torso) { tLo = Math.min(tLo, pts[j].y); tHi = Math.max(tHi, pts[j].y); } });
    if (torsoN * 10 >= ps.length * 3 && tHi - tLo >= (crotchY - neckY) * 0.6) {
      const seq = ps.map((p) => (isArm(p) ? 1 : (isLeg(p) ? 2 : (p === P.torso ? 0 : 3))));
      let k = 0;
      while (k < seq.length) {
        if (seq[k] !== 1) { k += 1; continue; }
        let e = k;
        while (e + 1 < seq.length && seq[e + 1] === 1) e += 1;
        const before = k > 0 ? seq[k - 1] : -1, after = e + 1 < seq.length ? seq[e + 1] : -1;
        if ((before === 0 && after === 2) || (before === 2 && after === 0)) sandwiched = true;
        k = e + 1;
      }
    }
    const legLike = foot.y >= groundY || root.y > hipBandY || sandwiched;
    const out = ps.slice();
    if (legLike) {
      const side = lLeg >= rLeg ? P.leftLeg : P.rightLeg;
      for (let j = 0; j < out.length; j++) if (isArm(out[j])) out[j] = side;
    } else {
      const side = lArm >= rArm ? P.leftArm : P.rightArm;
      for (let j = 0; j < out.length; j++) if (isLeg(out[j])) out[j] = side;
    }
    regionParts[i] = out;
  }

  traceStep('7e mixed', regionParts);
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
  for (let i = 0; i < raw.length; i++) {
    if (rigidFlags[i]) continue;
    if (legSide[i] !== null) continue;
    if (pairHandled[i]) continue;              // a limb pair is already split at its junction
    let leftN = 0, rightN = 0, legN = 0, torsoN = 0;
    for (const part of regionParts[i]) {
      if (part === P.leftArm) leftN += 1;
      else if (part === P.rightArm) rightN += 1;
      else if (isLeg(part)) legN += 1;
      else if (part === P.torso) torsoN += 1;
    }
    const armN = leftN + rightN;
    const count = regionParts[i].length;
    // ≥3 arm points: 1–2 stray labels must never promote a whole stroke to an arm.
    if (!(armN >= 3 && armN > legN * 3)) continue;
    const pts = raw[i].points;
    // Root must sit in the UPPER body — and, when the crotch is high (short trunk),
    // strictly ABOVE the hip: 0.40·bodyLen is measured to the FEET, so on a leggy
    // figure it can land at hip height, and a hip-rooted lateral stroke consolidated
    // here becomes the "hip extends out" arm.
    if (!(strokeRoot(pts).root.y < Math.min(neckY + bodyLen * 0.40, crotchY - bodyLen * 0.05))) continue;
    const axis = spineX[grid.row(pts.reduce((s, p) => s + p.y, 0) / pts.length)];
    const reachL = axis - (pts.length ? Math.min(...pts.map((p) => p.x)) : axis);
    const reachR = (pts.length ? Math.max(...pts.map((p) => p.x)) : axis) - axis;
    // Arm-DOMINATED — or an upper-body stroke that clearly EXITS the torso band on one
    // side: an arm rooted inside a WIDE torso overlaps the torso band for most of its
    // length, so a majority test alone misses it. The exit evidence is the ARM-LABELLED
    // POINT COUNT itself — the trim line already sits 25% beyond the measured torso
    // wall, so a run of points past it is a limb, not wobble (smoothParts has killed
    // 1–2-point noise). A distance margin on top double-counts and misses real arms.
    const armish = armN * 2 > count
      || (armN + torsoN >= Math.floor(count * 8 / 10) && armN >= Math.max(5, Math.floor(count / 5)));
    if (!armish) continue;
    // Both-arms-in-one-stroke: genuine limb REACH past the torso band on EACH side
    // keeps the per-side split — whatever hangs left of the body is the left arm,
    // right of it the right arm, however UNEQUAL the two branches are. (A single arm
    // dipping a little across the spine already fails the REACH test — its far-side
    // excursion is shallow — and is consolidated whole. The tiny count floor just
    // rejects 1–3-point noise.)
    const bothArms = Math.min(leftN, rightN) >= Math.max(4, Math.floor(count / 12))
      && Math.min(reachL, reachR) > Math.max(torsoReach * 2, bbox.width * 0.12);
    if (bothArms) continue;
    const side = leftN === rightN
      ? (reachL > reachR ? P.leftArm : P.rightArm)
      : (leftN > rightN ? P.leftArm : P.rightArm);
    regionParts[i] = regionParts[i].map(() => side);
  }

  // ---- Step 7h: a dangling segment rides the limb it hangs from ----
  // Arms drawn as upper arm + forearm: on a short torso the forearm ROOTS at an elbow
  // that is already below the hip, so the silhouette calls it a leg — and a "leg" that
  // ends in mid-air at the elbow scissors beside the real legs while the upper arm
  // waves off without it. A thin limb stroke that does not reach the ground and whose
  // root sits ON the END of an arm stroke is that arm's continuation. Legs reach the
  // ground, so no real leg is ever re-classed; detected legs are skipped outright.
  {
    const joinR = Math.max(avgInkW * 2.5, bodyLen * 0.05);
    for (let i = 0; i < raw.length; i++) {
      if (rigidFlags[i] || pairHandled[i] || legSide[i] !== null) continue;
      const ps = regionParts[i], pts = raw[i].points;
      if (pts.length < 3) continue;
      const legN = countWhere(ps, isLeg);
      if (!(legN * 10 >= ps.length * 9)) continue;
      const { root, foot } = strokeRoot(pts);
      if (!(foot.y < groundY)) continue;
      let adopt = null;
      let bestD = joinR;
      for (let k = 0; k < raw.length; k++) {
        if (k === i || rigidFlags[k] || raw[k].points.length < 4) continue;
        const kp = raw[k].points, kl = regionParts[k];
        for (const [e, part] of [[0, kl[0]], [kp.length - 1, kl[kp.length - 1]]]) {
          if (!isArm(part)) continue;
          const d = dist(root, kp[e]);
          if (d <= bestD) { bestD = d; adopt = part; }
        }
      }
      if (adopt !== null) regionParts[i] = ps.map(() => adopt);
    }
  }

  traceStep('7d arms', regionParts);
  // ---- Step 7f: a small blob at a limb's TIP rides that limb ----
  // Hands and feet are often a little loop at the end of the arm/leg line. 7a classes
  // every outline by POSITION, and a hand hanging below the body's midpoint on a short
  // torso is "a lower fat stroke" → leg: the hand then stays with the legs while the arm
  // waves away from it. A small closed stroke whose centre sits on the END of a thin
  // stroke takes that end's label, whatever its height.
  // (A fist raised beside the head was folded INTO the head by the detail pass — it is
  // within the head's reach — so a head-majority blob is also eligible when it lies
  // outside the head disc and tips an ARM; eyes/ears sit inside the disc.)
  for (let i = 0; i < raw.length; i++) {
    if (!(raw[i].closed && !(foldHeadFlags[i] && regionParts[i].length < 4))) continue;
    const bb = boundingBox(raw[i].points) || ZERO_RECT;
    const size = Math.max(bb.width, bb.height);
    if (!(size < Math.max(headRadius * 0.9, bodyLen * 0.12))) continue;
    const c = { x: bb.midX, y: bb.midY };
    const headMajority = majorityPart(regionParts[i]) === P.head;
    if (headMajority && hypot(c.x - headCenter.x, c.y - headCenter.y) <= headRadius * 1.05) continue;
    const snap = Math.max(size * 0.9, avgInkW * 2);
    let best = null;
    for (let k = 0; k < raw.length; k++) {
      if (k === i || rigidFlags[k] || raw[k].points.length < 4) continue;
      const pts = raw[k].points, ps = regionParts[k];
      for (const [e, part] of [[0, ps[0]], [pts.length - 1, ps[pts.length - 1]]]) {
        if (part === P.torso || part === P.head) continue;
        if (headMajority && !isArm(part)) continue;
        const d = dist(c, pts[e]);
        if (d <= snap && (best === null || d < best.d)) best = { d, part };
      }
    }
    if (best !== null) regionParts[i] = raw[i].points.map(() => best.part);
  }

  traceStep('7f blobs', regionParts);
  // Hip-raise from the leg silhouette — only on the LEGACY path. When Step 5b detected the
  // legs, the hip is already at the root convergence; the feet/upper-band median below would
  // drift it toward the veer side and re-corrupt the clean central hip, so skip it.
  if (!legStrokesDetected) {
    const legPts = [];
    for (let i = 0; i < raw.length; i++) {
      raw[i].points.forEach((p, j) => { if (isLeg(regionParts[i][j])) legPts.push(p); });
    }
    // ~6th-percentile topmost leg point, not the single min: one stray leg label used
    // to drag the hip up the body (and its median-x sideways) all by itself.
    const legYs = legPts.map((p) => p.y).sort((a, b) => a - b);
    if (legYs.length) {
      const topLegY = legYs[Math.min(legYs.length - 1, Math.floor(legYs.length / 16))];
      const raised = Math.min(Math.max(topLegY, neckY + bodyLen * 0.20), bbox.maxY - bbox.height * 0.10);
      if (raised < crotchY) {
        crotchY = raised;
        const upper = legPts.filter((p) => p.y <= crotchY + bodyLen * 0.15).map((p) => p.x).sort((a, b) => a - b);
        if (upper.length) crotchX = upper[Math.floor(upper.length / 2)];

        // The cell labels were assigned against the ORIGINAL (lower) crotch, and the
        // hip just moved UP past some of them — points in that stale band that sat in
        // a side run were labelled ARM and would now be "arms" rooted below the hip
        // (the reported "hip area extends out" fling). Re-side them as legs: a thin
        // stroke rooted in the lower body whose mass sits below the raised crotch is
        // leg ink whole; otherwise only the stale arm-labelled END runs below the
        // crotch move (an arm TIP that merely dips past the hip keeps its arm).
        for (let i = 0; i < raw.length; i++) {
          if (rigidFlags[i] || pairHandled[i] || legSide[i] !== null) continue;
          const pts = raw[i].points;
          const ps = regionParts[i].slice();
          const armN = countWhere(ps, isArm);
          if (!(armN > 0)) continue;
          const root = strokeRoot(pts).root;
          const meanY = pts.reduce((s, p) => s + p.y, 0) / pts.length;
          if (root.y > neckY + bodyLen * 0.45 && meanY > crotchY) {
            const cxm = pts.reduce((s, p) => s + p.x, 0) / pts.length;
            regionParts[i] = ps.map(() => (cxm < crotchX ? P.leftLeg : P.rightLeg));
          } else if (armN * 2 <= ps.length) {
            // Stale TAIL re-siding is for MINORITY-arm strokes only: an
            // arm-MAJORITY stroke here is a genuine (likely consolidated) arm
            // rooted high, and a hanging hand that merely dips below the raised
            // crotch must keep its arm — or the tip would scissor with the legs
            // while the arm waves.
            let j = 0;
            while (j < ps.length && isArm(ps[j]) && pts[j].y >= crotchY) {
              ps[j] = pts[j].x < crotchX ? P.leftLeg : P.rightLeg; j += 1;
            }
            let k = ps.length - 1;
            while (k >= 0 && isArm(ps[k]) && pts[k].y >= crotchY) {
              ps[k] = pts[k].x < crotchX ? P.leftLeg : P.rightLeg; k -= 1;
            }
            regionParts[i] = ps;
          }
        }
      }
    }
  }

  traceStep('hip-raise', regionParts, ` crotch=(${Math.trunc(crotchX)},${Math.trunc(crotchY)})`);
  // ---- Step 8: skeleton joints + elbow/knee/hand/foot refinement ----
  function baseSkeleton() {
    const shoulderY = neckY + (crotchY - neckY) * 0.10;
    const leftShoulder = { x: neckX - torsoHalfW, y: shoulderY };
    const rightShoulder = { x: neckX + torsoHalfW, y: shoulderY };
    const hipCenter = { x: crotchX, y: crotchY };
    return {
      bbox, headCenter, headRadius,
      neck: { x: neckX, y: neckY },
      leftShoulder, rightShoulder,
      leftElbow: leftShoulder, rightElbow: rightShoulder,
      hipCenter, leftHip: hipCenter, rightHip: hipCenter,
      leftKnee: hipCenter, rightKnee: hipCenter,
      feet: { x: crotchX, y: bbox.maxY },
      leftHand: leftShoulder, rightHand: rightShoulder,
      leftShinStraighten: 0, rightShinStraighten: 0,
    };
  }
  const rawPoints = raw.map((r) => r.points);
  let skeleton = refineJoints(baseSkeleton(), rawPoints, regionParts);

  // ---- Step 8b: plausibility net — freeze geometrically implausible limbs ----
  // (See RigPlausibility. Runs BEFORE the forearm split so a demotion is a plain
  // whole-arm/leg relabel, and before the hand-part computation so a demoted side's
  // props automatically ride the root.)
  const demotions = [];
  let forceFallback = false;
  switch (validate(regionParts, rawPoints, skeleton, bbox, demotions)) {
    case 'ok':
      break;
    case 'demoted':
      // The surviving joints — and the demoted side's ESTIMATED hand — must be derived
      // from the FINAL labels, so re-refine against them.
      skeleton = refineJoints(baseSkeleton(), rawPoints, regionParts);
      break;
    case 'fullFallback':
      // Wipe the labels HERE (not just in Step 9) and re-refine: with no arm points
      // left, refineJoints estimates the hands from the drawing's lateral extremes —
      // otherwise the hand anchors (and every conjured prop) would sit wherever the
      // discarded implausible labels had put them.
      forceFallback = true;
      for (let i = 0; i < regionParts.length; i++) regionParts[i] = regionParts[i].map(() => P.torso);
      skeleton = refineJoints(baseSkeleton(), rawPoints, regionParts);
      break;
  }

  traceStep('8b validate', regionParts, ` demotions=[${demotions.map((d) => `${d.side}:${d.reason}`).join(', ')}]`);
  // ---- Step 9: build strokes (rigid-aware forearm split), confidence, fallback ----
  const strokes = raw.map((r0, i) => ({
    points: r0.points,
    parts: r0.points.map((p, j) => splitSegment(p, regionParts[i][j], rigidFlags[i], skeleton)),
    color: r0.color,
    width: r0.width,
    rigid: rigidFlags[i],
  }));

  const confidence = score(strokes, skeleton, headDet !== null);
  const articulated = confidence >= 0.5 && !forceFallback;
  if (!articulated) {
    for (const s of strokes) { s.parts = s.points.map(() => P.torso); s.rigid = false; }
  }
  // Held-prop carrying parts (see Rig.leftHandPart): the forearm only if some final
  // stroke point actually articulates as that arm; an estimated hand rides the root.
  let leftHandPart = P.torso, rightHandPart = P.torso;
  for (const s of strokes) {
    for (const p of s.parts) {
      if (p === P.leftArm || p === P.leftForearm) leftHandPart = P.leftForearm;
      if (p === P.rightArm || p === P.rightForearm) rightHandPart = P.rightForearm;
    }
  }
  return makeRig(strokes, skeleton, confidence, articulated, demotions, leftHandPart, rightHandPart);
}

// MARK: - Run classification

/// Largest-gap test for a leg band: ≥2 runs split by a wide gap. Returns the gap midpoint
/// (the lean-invariant crotch x) — measured per band, so it never references a global axis.
function twoLegged(runs, gapThresh) {
  if (runs.length < 2) return [false, runs.length ? runs[0].xMid : 0];
  let bestGap = 0, mid = runs[0].xMid;
  for (let i = 1; i < runs.length; i++) {
    const gap = runs[i].x0 - runs[i - 1].x1;
    if (gap > bestGap) { bestGap = gap; mid = (runs[i - 1].x1 + runs[i].x0) / 2; }
  }
  return [bestGap >= gapThresh, mid];
}

/// The torso slice at a row: the run straddling the spine, else the run nearest it.
function central(runs, spineX) {
  return runs.find((r) => r.x0 <= spineX && spineX <= r.x1)
    || minBy(runs, (r) => Math.abs(r.xMid - spineX));
}

/// The ROOT (topmost / min-y point) and FOOT (bottommost / max-y point) of a stroke —
/// pen-direction-agnostic. A standing limb attaches at its root; the leg-stroke pass sides
/// and locates the hip from the ROOT, never the foot, so a leg drawn to one side, crossed,
/// or steeply splayed still attaches at the right place (and a leg drawn foot-up still roots).
function strokeRoot(pts) {
  let root = pts[0], foot = pts[0];
  for (const p of pts) {
    if (p.y < root.y) root = p;
    if (p.y > foot.y) foot = p;
  }
  return { root, foot };
}

/// A LIMB PAIR drawn as ONE open stroke (both arms as a ∧/∩ arch or a check-mark, both
/// legs as a ∧): both ENDPOINTS are free limb tips on OPPOSITE sides of the body
/// centreline, each well clear of it. A genuine outline tube fails on the endpoints —
/// they sit TOGETHER at its root (same side, no clearance) — and a torso outline's ends
/// hug the centreline. The JUNCTION (where the pair attaches to the body) is the path
/// point NEAREST the tracked spine at its own height. NO symmetry is assumed. Returns the
/// junction's path index + the FIRST branch's side, so the caller labels each BRANCH whole
/// by path order. The junction must be interior (both branches substantial).
function limbPairJunction(pts, spineAt, clearance) {
  if (pts.length < 8) return null;
  const a = pts[0], b = pts[pts.length - 1];
  const offA = a.x - spineAt(a), offB = b.x - spineAt(b);
  if (!(offA * offB < 0 && Math.min(Math.abs(offA), Math.abs(offB)) > clearance)) return null;
  let jIdx = 0;
  let best = INF;
  pts.forEach((p, i) => {
    const d = Math.abs(p.x - spineAt(p));
    if (d < best) { best = d; jIdx = i; }
  });
  const minBranch = Math.max(3, Math.floor(pts.length / 8));
  if (!(jIdx >= minBranch && jIdx <= pts.length - 1 - minBranch)) return null;
  return { j: jIdx, firstIsLeft: offA < 0 };
}

/// Reclaim a raised arm TIP from the head: a contiguous head-labelled run at a stroke
/// END, adjacent to ARM labels, whose tip point is clearly OUTSIDE the head disc, is a
/// hand drawn up at head height (arms at different heights) — it belongs to that arm,
/// not the head, or the tip stays behind when the arm waves. Decoration strokes are
/// untouched: they are majority-head with no adjacent arm labels (or were folded to the
/// head whole), and an arm ROOT that merely brushes the head band fails the distance
/// test (it sits at the neck, inside the disc), so the baseline figures are unchanged.
function reclaimRaisedTips(parts, pts, headCenter, headRadius) {
  const n = parts.length;
  if (n < 4) return parts;
  const out = parts.slice();
  const farR = headRadius * 1.15;
  if (out[0] === P.head) {
    let e = 0;
    while (e + 1 < n && out[e + 1] === P.head) e += 1;
    if (e + 1 < n && isArm(out[e + 1]) &&
        hypot(pts[0].x - headCenter.x, pts[0].y - headCenter.y) > farR) {
      for (let m = 0; m <= e; m++) out[m] = out[e + 1];
    }
  }
  if (out[n - 1] === P.head) {
    let s = n - 1;
    while (s > 0 && out[s - 1] === P.head) s -= 1;
    if (s > 0 && isArm(out[s - 1]) &&
        hypot(pts[n - 1].x - headCenter.x, pts[n - 1].y - headCenter.y) > farR) {
      for (let m = s; m < n; m++) out[m] = out[s - 1];
    }
  }
  return out;
}

// Majority vote. (Swift iterates a hashed dictionary, so its tie order is arbitrary; here
// ties go to the part seen first — deterministic.)
export function majorityPart(parts) {
  const counts = new Map();
  for (const p of parts) counts.set(p, (counts.get(p) || 0) + 1);
  let best = P.torso, bestN = -1;
  for (const [k, v] of counts) if (v > bestN) { bestN = v; best = k; }
  return best;
}

/// Smooth out isolated 1–2-point label flips on an OPEN stroke (a sliding-window majority),
/// so a single pen path that genuinely spans a joint reads as two clean segments.
function smoothParts(parts) {
  if (parts.length < 5) return parts;
  const out = parts.slice();
  for (let i = 2; i < parts.length - 2; i++) {
    out[i] = majorityPart(parts.slice(i - 2, i + 3));
  }
  return out;
}

// MARK: - Head detection (used for headCenter/radius + the confidence bonus)

function detectHead(strokePoints, figure, centerX, inkWidth) {
  if (!(figure.height > 0)) return null;
  const tinyFloor = Math.max(14, figure.height * 0.05);
  // The ROOT (topmost point) of every stroke that reaches the GROUND. A blob with TWO
  // such roots spread along its bottom edge has legs hanging off it — it is the TORSO,
  // however head-like its shape. This separates a small head on a short, wide outlined
  // body (the body out-sizes the head and reaches into the top band) from a hat on a
  // head: nothing roots along a hat's bottom but the head's own top, and only the
  // spine roots at a head's bottom. Grounded strokes only — outline arms rooted at
  // the shoulders of a small head sit on its bottom edge too, but end in mid-air.
  const groundY = figure.maxY - figure.height * 0.25;
  const roots = [];
  for (const pts of strokePoints) {
    const b = boundingBox(pts);
    if (!b || !(Math.max(b.width, b.height) >= figure.height * 0.08) || !(b.maxY >= groundY)) continue;
    roots.push(minBy(pts, (p) => p.y));
  }
  function hasLegs(b) {
    const tol = inkWidth * 0.5 + Math.max(b.width, b.height) * 0.05;
    const xs = roots.filter((r) => Math.abs(r.y - b.maxY) <= tol && r.x >= b.minX - tol && r.x <= b.maxX + tol).map((r) => r.x);
    if (xs.length < 2) return false;
    return Math.max(...xs) - Math.min(...xs) >= b.width * 0.25;
  }
  // The head is a roundish top-band blob that is BIG, near the TOP, and near the figure's
  // top-centre. Score = size − topOffset − centreOffset. This beats: small ears/horns/hair
  // (too small), a fat outlined ARM in the top band (too far off-centre), and a torso (too
  // low, also excluded by the tight top band + aspect gate). Works for closed/open/big/small
  // heads. The head's BOTTOM edge (maxY) anchors the neck, not its size-radius.
  let best = null, fallback = null;
  strokePoints.forEach((pts, i) => {
    const b = boundingBox(pts);
    if (!b || !(b.width > 0) || !(b.height > 0)) return;
    const aspect = b.width / b.height;
    const size = Math.max(b.width, b.height);
    const inTopBand = b.midY < figure.minY + figure.height * 0.35;
    const compact = size < figure.height * 0.6;
    const roundish = aspect > 0.5 && aspect < 2.1;     // excludes elongated limbs
    if (!(inTopBand && compact && roundish && size >= tinyFloor)) return;
    const sc = size - 0.6 * (b.minY - figure.minY) - 1.0 * Math.abs(b.midX - centerX);
    const cand = { center: { x: b.midX, y: b.midY }, radius: size / 2, score: sc, bottom: b.maxY, index: i };
    if (fallback === null || sc > fallback.score) fallback = cand;
    if (hasLegs(b)) return;                            // a torso, not a head
    if (best === null || sc > best.score) best = cand;
  });
  return best || fallback;
}

// MARK: - Joint refinement (legs stay whole rigid segments; arms get an elbow for the wave)

function refineJoints(s, points, parts) {
  const leftArm = [], rightArm = [], leftLeg = [], rightLeg = [];
  points.forEach((pts, i) => {
    pts.forEach((p, j) => {
      switch (parts[i][j]) {
        case P.leftArm: leftArm.push(p); break;
        case P.rightArm: rightArm.push(p); break;
        case P.leftLeg: leftLeg.push(p); break;
        case P.rightLeg: rightLeg.push(p); break;
      }
    });
  });
  const out = { ...s };
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
  const trunkLen = Math.max(s.hipCenter.y - s.neck.y, 1);
  const snapBandMaxY = s.neck.y + trunkLen * 0.65;
  const lArmUpper = leftArm.filter((p) => p.y <= snapBandMaxY);
  const rArmUpper = rightArm.filter((p) => p.y <= snapBandMaxY);
  out.leftShoulder = minBy(lArmUpper, (p) => distToSegment(p, s.neck, s.hipCenter)) || s.leftShoulder;
  out.rightShoulder = minBy(rArmUpper, (p) => distToSegment(p, s.neck, s.hipCenter)) || s.rightShoulder;
  out.leftElbow = midToFarthest(out.leftShoulder, leftArm) || out.leftShoulder;
  out.rightElbow = midToFarthest(out.rightShoulder, rightArm) || out.rightShoulder;
  out.leftHand = farthest(out.leftShoulder, leftArm) || out.leftShoulder;
  out.rightHand = farthest(out.rightShoulder, rightArm) || out.rightShoulder;

  // No labelled arm points on a side (a one-stroke outline body, an all-torso fallback,
  // or Auto-Rig off): the hand anchor stays AT the shoulder, so a conjured prop (wand /
  // rod / brush / hat) floats at the TOP of the arm. Estimate the hand instead: the drawn
  // point most laterally past the torso edge on that side, inside the ARM BAND — below
  // the neck, down to a little past the hip (a hand hanging past the hip still counts;
  // legs are only lateral near the FEET, far below the band, so they can't win).
  const bodyLen = Math.max(s.bbox.maxY - s.neck.y, 1);
  const bandTop = s.neck.y + bodyLen * 0.06;
  const bandBot = s.hipCenter.y + bodyLen * 0.15;
  function estimateHand(side) {          // side: -1 left, +1 right
    const shoulderHalf = Math.abs((side < 0 ? s.leftShoulder.x : s.rightShoulder.x) - s.neck.x);
    let best = null;
    let bestOff = Math.max(shoulderHalf * 1.25, 10);          // must clear the torso edge
    for (const pts of points) {
      for (const p of pts) {
        if (!(p.y >= bandTop && p.y <= bandBot)) continue;
        const f = Math.min(Math.max((p.y - s.neck.y) / Math.max(s.hipCenter.y - s.neck.y, 1), 0), 1);
        const cx = s.neck.x + (s.hipCenter.x - s.neck.x) * f;   // lean-tracking centreline
        const off = (p.x - cx) * side;
        if (off > bestOff) { bestOff = off; best = p; }
      }
    }
    return best;
  }
  if (leftArm.length === 0) {
    const h = estimateHand(-1);
    if (h) {
      out.leftHand = h;
      out.leftElbow = { x: (out.leftShoulder.x + h.x) / 2, y: (out.leftShoulder.y + h.y) / 2 };
    }
  }
  if (rightArm.length === 0) {
    const h = estimateHand(1);
    if (h) {
      out.rightHand = h;
      out.rightElbow = { x: (out.rightShoulder.x + h.x) / 2, y: (out.rightShoulder.y + h.y) / 2 };
    }
  }

  const leftFoot = farthest(s.leftHip, leftLeg);
  const rightFoot = farthest(s.rightHip, rightLeg);
  out.leftKnee = (leftFoot && bendVertex(leftLeg, s.leftHip, leftFoot))
    || midToFarthest(s.leftHip, leftLeg) || s.leftHip;
  out.rightKnee = (rightFoot && bendVertex(rightLeg, s.rightHip, rightFoot))
    || midToFarthest(s.rightHip, rightLeg) || s.rightHip;
  out.leftShinStraighten = straightenAngle(s.leftHip, out.leftKnee, leftFoot);
  out.rightShinStraighten = straightenAngle(s.rightHip, out.rightKnee, rightFoot);
  return out;
}

function bendVertex(pts, a, b) {
  const abx = b.x - a.x, aby = b.y - a.y;
  const len = hypot(abx, aby);
  if (!(len > 1)) return null;
  let best = null, bestD = 0;
  for (const p of pts) {
    const perp = Math.abs((p.x - a.x) * aby - (p.y - a.y) * abx) / len;
    if (perp > bestD) { bestD = perp; best = p; }
  }
  return bestD > len * 0.08 ? best : null;
}

function straightenAngle(hip, knee, foot) {
  if (!foot) return 0;
  const tx = knee.x - hip.x, ty = knee.y - hip.y;
  const sx = foot.x - knee.x, sy = foot.y - knee.y;
  if (!(hypot(tx, ty) > 1 && hypot(sx, sy) > 1)) return 0;
  return Math.atan2(sx * ty - sy * tx, sx * tx + sy * ty);
}

function farthest(joint, pts) {
  return maxBy(pts, (p) => dist(p, joint));
}
function midToFarthest(joint, pts) {
  const far = maxBy(pts, (p) => dist(p, joint));
  if (!far) return null;
  if (!(dist(far, joint) > 8)) return null;
  return { x: (joint.x + far.x) / 2, y: (joint.y + far.y) / 2 };
}

/// An ARM point past the elbow becomes a forearm (so the arm bends for the wave). A
/// closed-loop (rigid) limb is INDIVISIBLE — both walls keep one part and swing about the
/// shoulder/hip as one piece. Legs are never split.
function splitSegment(p, part, rigid, s) {
  if (rigid) return part;
  switch (part) {
    case P.leftArm: return beyond(p, s.leftShoulder, s.leftElbow) ? P.leftForearm : P.leftArm;
    case P.rightArm: return beyond(p, s.rightShoulder, s.rightElbow) ? P.rightForearm : P.rightArm;
    default: return part;
  }
}
function beyond(p, joint, mid) {
  const dMid = dist(mid, joint);
  return dMid > 1 && dist(p, joint) > dMid;
}

// MARK: - Confidence + fallback

function score(strokes, skeleton, headFound) {
  const present = new Set();
  for (const s of strokes) for (const part of s.parts) present.add(part);
  const hasLeftArm = present.has(P.leftArm) || present.has(P.leftForearm);
  const hasRightArm = present.has(P.rightArm) || present.has(P.rightForearm);
  const hasLeftLeg = present.has(P.leftLeg) || present.has(P.leftShin);
  const hasRightLeg = present.has(P.rightLeg) || present.has(P.rightShin);
  let c = 0;
  if (headFound) c += 0.4;
  if (skeleton.bbox.height >= skeleton.bbox.width) c += 0.2;
  if (hasLeftArm && hasRightArm) c += 0.2;
  if (hasLeftLeg && hasRightLeg) c += 0.2;
  return c;
}

function allTorsoFallback(raw, bbox) {
  const strokes = raw.map((r) => ({ points: r.points, parts: r.points.map(() => P.torso), color: r.color, width: r.width, rigid: false }));
  const c = { x: bbox.midX, y: bbox.midY };
  const skel = {
    bbox, headCenter: { x: bbox.midX, y: bbox.minY }, headRadius: Math.max(bbox.height * 0.1, 10),
    neck: c, leftShoulder: c, rightShoulder: c, leftElbow: c, rightElbow: c,
    hipCenter: c, leftHip: c, rightHip: c, leftKnee: c, rightKnee: c,
    feet: { x: bbox.midX, y: bbox.maxY }, leftHand: c, rightHand: c,
    leftShinStraighten: 0, rightShinStraighten: 0,
  };
  return makeRig(strokes, skel, 0, false);
}

// MARK: - Geometry helpers

function isClosed(pts) {
  if (!(pts.length > 6)) return false;
  let per = 0;
  for (let i = 1; i < pts.length; i++) per += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
  if (!(per > 0)) return false;
  const a = pts[0], b = pts[pts.length - 1];
  return hypot(a.x - b.x, a.y - b.y) < per * 0.18;
}

function dist(a, b) { return hypot(a.x - b.x, a.y - b.y); }

/// Distance from `p` to the segment a→b (the trunk line for shoulder snapping).
function distToSegment(p, a, b) {
  const abx = b.x - a.x, aby = b.y - a.y;
  const len2 = abx * abx + aby * aby;
  if (!(len2 > 0.001)) return hypot(p.x - a.x, p.y - a.y);
  const t = Math.min(Math.max(((p.x - a.x) * abx + (p.y - a.y) * aby) / len2, 0), 1);
  return hypot(p.x - (a.x + abx * t), p.y - (a.y + aby * t));
}

/// Is this stroke a 2D "blob" (an outline limb whose two walls double back) rather than a
/// thin 1D line? Two tests must BOTH pass. (1) Minor/major principal-axis spread (PCA):
/// a line is ~0, an outline tube/loop is ~0.3+. (2) The path must DOUBLE BACK along its
/// major axis: 2D spread alone can't tell an outline from a plain BENT line — both arms
/// drawn in one ∧/∩ stroke (or both legs as one ∧) spread widely on both axes too.
/// An outline's walls run the shape's length out AND back (travel ≈ 2× the extent along
/// the major axis, like a loop); a bent line crosses its extent once (≈ 1×, wobble aside).
function isFat(pts) {
  if (pts.length < 8) return false;
  const n = pts.length;
  let mx = 0, my = 0;
  for (const p of pts) { mx += p.x; my += p.y; }
  mx /= n; my /= n;
  let sxx = 0, syy = 0, sxy = 0;
  for (const p of pts) { const dx = p.x - mx, dy = p.y - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy; }
  sxx /= n; syy /= n; sxy /= n;
  const tr = sxx + syy;
  const disc = Math.max(0, tr * tr / 4 - (sxx * syy - sxy * sxy));
  const l1 = tr / 2 + Math.sqrt(disc), l2 = tr / 2 - Math.sqrt(disc);
  if (!(l1 > 0.0001 && Math.sqrt(Math.max(0, l2) / l1) > 0.22)) return false;
  // Major-axis eigenvector of the covariance (either row form; fall back to the wider
  // coordinate axis when the matrix is already diagonal).
  let ex = l1 - syy, ey = sxy;
  if (hypot(ex, ey) < 0.0001) { ex = sxy; ey = l1 - sxx; }
  if (hypot(ex, ey) < 0.0001) { ex = sxx >= syy ? 1 : 0; ey = sxx >= syy ? 0 : 1; }
  const elen = hypot(ex, ey);
  let tMin = INF, tMax = -INF;
  let travel = 0, prevT = 0;
  pts.forEach((p, i) => {
    const t = (p.x * ex + p.y * ey) / elen;
    tMin = Math.min(tMin, t); tMax = Math.max(tMax, t);
    if (i > 0) travel += Math.abs(t - prevT);
    prevT = t;
  });
  const extent = tMax - tMin;
  return extent > 0.0001 && travel >= extent * 1.6;
}

function robustTopCenterX(points, bbox) {
  const cutoff = bbox.minY + bbox.height * 0.22;
  const xs = points.filter((p) => p.y <= cutoff).map((p) => p.x).sort((a, b) => a - b);
  if (xs.length === 0) return bbox.midX;
  return xs[Math.floor(xs.length / 2)];
}

export function densify(pts, maxStep = 4) {
  if (pts.length <= 1) return pts;
  const out = [pts[0]];
  for (let i = 1; i < pts.length; i++) {
    const a = pts[i - 1], b = pts[i];
    const d = hypot(b.x - a.x, b.y - a.y);
    const n = Math.max(1, Math.ceil(d / maxStep));
    for (let k = 1; k <= n; k++) {
      const f = k / n;
      out.push({ x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f });
    }
  }
  return out;
}

export function boundingBox(pts) {
  if (!pts.length) return null;
  let minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y;
  for (const p of pts) {
    if (p.x < minX) minX = p.x; if (p.x > maxX) maxX = p.x;
    if (p.y < minY) minY = p.y; if (p.y > maxY) maxY = p.y;
  }
  return rect(minX, minY, maxX - minX, maxY - minY);
}

function countWhere(arr, f) { let n = 0; for (const x of arr) if (f(x)) n += 1; return n; }

// Swift `min(by:)` / `max(by:)` semantics: the FIRST extreme element wins ties.
function minBy(arr, key) {
  let best = null, bk = INF;
  for (const x of arr) { const k = key(x); if (best === null || k < bk) { best = x; bk = k; } }
  return best;
}
function maxBy(arr, key) {
  let best = null, bk = -INF;
  for (const x of arr) { const k = key(x); if (best === null || k > bk) { best = x; bk = k; } }
  return best;
}

// MARK: - Occupancy grid + runs

/// A coarse occupancy raster of the figure. Closed strokes are scanline-filled (so an outline
/// becomes a solid silhouette read as ONE run), open strokes are stamped as thick discs.
class RasterGrid {
  constructor(bbox) {
    const pad = 2;
    const targetRows = 80;
    let cs = Math.max(bbox.height, 1) / targetRows;
    let rws = targetRows + 2 * pad;
    let cls = Math.ceil(bbox.width / cs) + 2 * pad;
    if (rws * cls > 9000) {                                   // cap total cells
      const f = Math.sqrt((rws * cls) / 9000);
      cs *= f;
      rws = Math.ceil(bbox.height / cs) + 2 * pad;
      cls = Math.ceil(bbox.width / cs) + 2 * pad;
    }
    this.rows = Math.max(rws, 8); this.cols = Math.max(cls, 8); this.cellSize = cs;
    this.originX = bbox.minX - pad * cs;
    this.originY = bbox.minY - pad * cs;
    this.occ = new Uint8Array(this.rows * this.cols);
  }

  // Swift `Int(_:)` truncates toward zero before the clamp.
  col(x) { return Math.min(Math.max(Math.trunc((x - this.originX) / this.cellSize), 0), this.cols - 1); }
  row(y) { return Math.min(Math.max(Math.trunc((y - this.originY) / this.cellSize), 0), this.rows - 1); }
  cellX(c) { return this.originX + (c + 0.5) * this.cellSize; }
  cellY(r) { return this.originY + (r + 0.5) * this.cellSize; }
  set(r, c) { if (r >= 0 && r < this.rows && c >= 0 && c < this.cols) this.occ[r * this.cols + c] = 1; }

  stampPolyline(pts, width) {
    const discR = Math.max(1, Math.ceil((width / 2) / this.cellSize));
    for (const p of pts) {
      const r = this.row(p.y), c = this.col(p.x);
      for (let dr = -discR; dr <= discR; dr++) {
        for (let dc = -discR; dc <= discR; dc++) {
          if (dr * dr + dc * dc <= discR * discR) this.set(r + dr, c + dc);
        }
      }
    }
  }

  /// Scanline-fill the closed polygon `pts` (implicit last→first edge) into the grid.
  fillPolygon(pts) {
    const n = pts.length;
    if (n < 3) return;
    for (let r = 0; r < this.rows; r++) {
      const y = this.cellY(r);
      const xs = [];
      for (let i = 0; i < n; i++) {
        const a = pts[i], b = pts[(i + 1) % n];
        if ((a.y <= y && b.y > y) || (b.y <= y && a.y > y)) {
          const t = (y - a.y) / (b.y - a.y);
          xs.push(a.x + t * (b.x - a.x));
        }
      }
      if (xs.length < 2) continue;
      xs.sort((p, q) => p - q);
      for (let k = 0; k + 1 < xs.length; k += 2) {
        const c0 = this.col(xs[k]), c1 = this.col(xs[k + 1]);
        for (let c = c0; c <= c1; c++) this.set(r, c);
      }
    }
  }

  /// One maximal horizontal occupied span per entry, with its world-space x extent.
  runs(r) {
    const spans = [];
    let c = 0;
    const cols = this.cols, occ = this.occ;
    while (c < cols) {
      if (occ[r * cols + c]) {
        let c1 = c;
        while (c1 + 1 < cols && occ[r * cols + c1 + 1]) c1 += 1;
        spans.push([c, c1]); c = c1 + 1;
      } else { c += 1; }
    }
    const merged = [];
    for (const s of spans) {
      const last = merged[merged.length - 1];
      if (last && s[0] - last[1] - 1 < 2) last[1] = s[1];
      else merged.push([s[0], s[1]]);
    }
    return merged.map(([c0, c1]) => {
      const x0 = this.originX + c0 * this.cellSize;
      const x1 = this.originX + (c1 + 1) * this.cellSize;
      return { c0, c1, x0, x1, xMid: (x0 + x1) / 2, w: x1 - x0 };
    });
  }
}
