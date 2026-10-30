// Port of RigPlausibility.swift — post-fit plausibility validation, the outlier SAFETY NET.
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
// Runs INSIDE fit, after refineJoints and BEFORE the forearm split — so only whole-arm/leg
// labels exist, and the downstream leftHandPart/rightHandPart computation automatically
// resolves a demoted side to `.torso` (props ride the root via the estimated-hand semantics).
//
// TUNING STANCE: every threshold clears the worst LEGITIMATE geometry the harness generates
// by a wide margin. If a healthy figure ever trips a check, WIDEN that one threshold — never
// add compensating logic.

import { P, isLeg } from './model.js';

// Worst legitimate values (harness): lowAttach shoulder snap ≈ 0.45·trunk, asymArms
// junction snap ≈ 0.59·trunk → band tops out at 0.72. A hanging arm's tip may dip past
// the hip but its majority never does. A single mitten arm ≈ 28% of non-head ink. A
// T-pose arm's lever ≈ 0.25·extent.
const shoulderBandLo = -0.10;   // × trunkLen, above the neck
const shoulderBandHi = 0.72;    // × trunkLen, below the neck
// An arm attached low on a SHORT outlined torso only gets its first ARM label where it
// exits the outline (its inside points read torso), so the labelled root sits deep —
// the proportions sweep's legitimate worst ≈ 0.88. Hip clusters root at ≥ 1.0.
const armRootDepthMax = 0.92;   // topmost arm point, × trunkLen below the neck
const belowHipFracMax = 0.60;   // arm mass allowed below the hip band
const sideInkFracMax = 0.45;    // one side's arm ink ÷ non-head ink
const leverExtentMax = 0.72;    // shoulder→farthest-point ÷ figure extent
// A SHORT torso makes any normal arm long relative to the trunk (an arm ≈ 2u on a 1.5u
// trunk ≈ 1.4, the harness's short-torso worst ≈ 2.3) — the fling test proper is the
// extent-relative lever above; this one only backstops a whole-body "arm".
const leverTrunkMax = 3.2;      // shoulder→farthest-point ÷ trunk length
const escalateMassFrac = 0.50;  // demoted ink ÷ non-head ink → full fallback

function majority(ps) {
  const counts = new Map();
  for (const p of ps) counts.set(p, (counts.get(p) || 0) + 1);
  let best = P.torso, bestN = -1;
  for (const [k, v] of counts) if (v > bestN) { bestN = v; best = k; }
  return best;
}

/// Inspect the labelled figure; demote implausible limbs to `.torso` in place (`parts` is
/// mutated). Appends one demotion record per frozen limb to `demotions`.
/// Returns 'ok' | 'demoted' (re-refine the skeleton) | 'fullFallback' (force all-torso).
export function validate(parts, points, skeleton, bbox, demotions) {
  const neck = skeleton.neck, hip = skeleton.hipCenter;
  const trunkLen = Math.max(hip.y - neck.y, 1);
  const bodyLen = Math.max(bbox.maxY - neck.y, 1);
  const extent = Math.max(bbox.width, bbox.height);

  // Per-stroke pre-demotion majorities — recorded on every demotion (including the
  // full-fallback ones) so the harness's false-positive metric can see what a demotion
  // undid.
  const strokeMajorities = () => parts.map(majority);
  const allIdx = () => parts.map((_, i) => i);

  // ---- global tripwire: the trunk geometry itself is corrupt ----
  if (hip.y < neck.y + bodyLen * 0.15 || hip.y > bbox.maxY - bodyLen * 0.02) {
    demotions.push({ side: 'all', reason: 'hip-sanity', strokes: allIdx(), preMajorities: strokeMajorities() });
    return 'fullFallback';
  }

  // ---- gather per-side stats (pre-split labels: whole arms/legs only) ----
  const lArm = [], rArm = [];
  let lLegN = 0, lLegHigh = 0, rLegN = 0, rLegHigh = 0;
  let nonHead = 0;
  const chestY = neck.y + bodyLen * 0.25;
  for (let i = 0; i < parts.length; i++) {
    for (let j = 0; j < parts[i].length; j++) {
      const part = parts[i][j];
      if (part !== P.head) nonHead += 1;
      switch (part) {
        case P.leftArm: lArm.push(points[i][j]); break;
        case P.rightArm: rArm.push(points[i][j]); break;
        case P.leftLeg: lLegN += 1; if (points[i][j].y < chestY) lLegHigh += 1; break;
        case P.rightLeg: rLegN += 1; if (points[i][j].y < chestY) rLegHigh += 1; break;
      }
    }
  }
  if (!(nonHead > 0)) return 'ok';

  // Signed mean offset of a point set vs the lean-tracking neck→hip centreline.
  function meanOffset(pts) {
    if (!pts.length) return null;
    let sum = 0;
    for (const p of pts) {
      const f = Math.min(Math.max((p.y - neck.y) / trunkLen, 0), 1);
      sum += p.x - (neck.x + (hip.x - neck.x) * f);
    }
    return sum / pts.length;
  }

  // ---- per-side arm checks (any hit demotes that side) ----
  function armProblem(pts, shoulder) {
    if (!pts.length) return null;
    // Arms attach on the UPPER trunk, so a genuine arm always has points near its
    // attachment. An "arm" whose TOPMOST point sits down by the hip is a mislabelled
    // hip/waist cluster (belt, tail, leg top) — the classic "hip extends out" fling.
    let minY = Number.MAX_VALUE;
    for (const p of pts) minY = Math.min(minY, p.y);
    const rootDepth = (minY - neck.y) / trunkLen;
    if (rootDepth > armRootDepthMax) return `arm-root-depth(${rootDepth.toFixed(2)})`;
    const sy = (shoulder.y - neck.y) / trunkLen;
    if (sy < shoulderBandLo || sy > shoulderBandHi) return `shoulder-band(${sy.toFixed(2)})`;
    let below = 0;
    for (const p of pts) if (p.y > hip.y + bodyLen * 0.10) below += 1;
    if (below > pts.length * belowHipFracMax) return 'arm-below-hip';
    if (pts.length > nonHead * sideInkFracMax) return 'arm-ink-cap';
    let lever = 0;
    for (const p of pts) lever = Math.max(lever, Math.hypot(p.x - shoulder.x, p.y - shoulder.y));
    if (lever > extent * leverExtentMax) return `fling-lever(${Math.trunc(lever)}/${Math.trunc(extent)})`;
    if (lever > trunkLen * leverTrunkMax) return 'arm-vs-trunk';
    return null;
  }

  const toDemote = [];
  const rl = armProblem(lArm, skeleton.leftShoulder);
  if (rl) toDemote.push({ part: P.leftArm, side: 'Larm', reason: rl });
  const rr = armProblem(rArm, skeleton.rightShoulder);
  if (rr) toDemote.push({ part: P.rightArm, side: 'Rarm', reason: rr });

  // Both "arms" occupying the SAME side of the body: exactly one label contradicts the
  // side it actually occupies — freeze that one.
  const lm = meanOffset(lArm), rm = meanOffset(rArm);
  if (lm !== null && rm !== null) {
    const thresh = Math.max(6, bbox.width * 0.08);
    if (lm > thresh && rm > thresh && !toDemote.some((d) => d.part === P.leftArm)) {
      toDemote.push({ part: P.leftArm, side: 'Larm', reason: 'side-contradiction' });
    } else if (lm < -thresh && rm < -thresh && !toDemote.some((d) => d.part === P.rightArm)) {
      toDemote.push({ part: P.rightArm, side: 'Rarm', reason: 'side-contradiction' });
    }
  }

  // A "leg" whose mass sits up in the chest is not a leg.
  if (lLegN > 0 && lLegHigh * 2 > lLegN) toDemote.push({ part: P.leftLeg, side: 'Lleg', reason: 'leg-in-chest' });
  if (rLegN > 0 && rLegHigh * 2 > rLegN) toDemote.push({ part: P.rightLeg, side: 'Rleg', reason: 'leg-in-chest' });

  // LEGS GO DOWN: a leg-majority stroke that neither reaches toward the ground nor
  // descends is hip-lateral body ink (a tail, a skirt curl, a belt end below the
  // crotch) — riding a leg it would wiggle with the walk and drag the hip-raise around.
  const legFreezeStrokes = [];
  for (let i = 0; i < parts.length; i++) {
    if (!parts[i].length) continue;
    let legN = 0;
    for (const p of parts[i]) if (isLeg(p)) legN += 1;
    if (!(legN * 2 > parts[i].length)) continue;
    let minX = Number.MAX_VALUE, maxX = -Number.MAX_VALUE;
    let minY = Number.MAX_VALUE, maxY = -Number.MAX_VALUE;
    for (const p of points[i]) {
      minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
      minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
    }
    const reachesGround = maxY >= bbox.maxY - bodyLen * 0.25;
    const descends = (maxY - minY) >= (maxX - minX) * 1.2;
    if (!reachesGround && !descends) legFreezeStrokes.push(i);
  }

  if (!toDemote.length && !legFreezeStrokes.length) return 'ok';

  // ---- apply: freeze each flagged limb to .torso (recording pre-demotion majorities) ----
  const preMajor = strokeMajorities();
  let demotedMass = 0;
  for (const d of toDemote) {
    const strokes = [];
    for (let i = 0; i < parts.length; i++) {
      let hit = false;
      for (let j = 0; j < parts[i].length; j++) {
        if (parts[i][j] === d.part) { parts[i][j] = P.torso; demotedMass += 1; hit = true; }
      }
      if (hit) strokes.push(i);
    }
    demotions.push({ side: d.side, reason: d.reason, strokes, preMajorities: strokes.map((s) => preMajor[s]) });
  }
  if (legFreezeStrokes.length) {
    for (const i of legFreezeStrokes) {
      for (let j = 0; j < parts[i].length; j++) {
        if (isLeg(parts[i][j])) { parts[i][j] = P.torso; demotedMass += 1; }
      }
    }
    demotions.push({ side: 'leg', reason: 'leg-not-grounded', strokes: legFreezeStrokes,
      preMajorities: legFreezeStrokes.map((s) => preMajor[s]) });
  }

  // Escalate only when the demotions consumed most of the body — the segmentation is
  // globally wrong, so the proven whole-figure fallback beats a half-frozen chimera.
  if (demotedMass > nonHead * escalateMassFrac) {
    demotions.push({ side: 'all', reason: `mass(${demotedMass}/${nonHead})`, strokes: allIdx(), preMajorities: preMajor });
    return 'fullFallback';
  }
  return 'demoted';
}
