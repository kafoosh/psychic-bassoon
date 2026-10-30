// Seam safety (web edition, runs after `fit`). A SEAM is where one pen stroke changes body
// part (torso → arm, arm → forearm, leg ↔ leg …). A seam is only safe at the joint the two
// parts turn about; anywhere else it is pulled apart when the limb swings, and the drawing
// visibly STRETCHES — worst at the crotch, where a hand drawn on the hip (or a belt / tail /
// leg-pair apex) would be dragged out of the body by an arm wave or the walk. This pass:
//   1. moves each elbow pivot onto the drawn arm, at its arm→forearm seam;
//   2. tests every seam against extreme routine poses, and where one would pull apart, the
//      stroke's loose END run adopts its neighbour's part (a hand rides its arm, a belt end
//      rides the body); a run sandwiched inside a stroke goes with the longer neighbour.
// The result never tears: every stroke moves as connected pieces.

import { P, makePose, worldPoint } from './model.js';

const STRESS = [
  { leftArmAngle: 2.05, leftForearmAngle: 1.5, rightArmAngle: -2.05, rightForearmAngle: -1.5 },
  { leftArmAngle: -1.0, leftForearmAngle: -0.5, rightArmAngle: 1.0, rightForearmAngle: 0.5 },
  { leftArmAngle: 1.3, leftForearmAngle: 0.5, rightArmAngle: -1.3, rightForearmAngle: -0.5,
    leftLegAngle: 0.34, rightLegAngle: -0.34, headAngle: 0.42 },
  { leftLegAngle: -0.34, rightLegAngle: 0.34, headAngle: -0.42 },
];

export function stabilizeSeams(rig) {
  if (!rig.articulated) return rig;
  const out = {
    ...rig,
    skeleton: { ...rig.skeleton },
    strokes: rig.strokes.map((s) => ({ ...s, parts: s.parts.slice() })),
  };
  snapElbows(out);

  const k = out.skeleton;
  const bodyLen = Math.max(k.bbox.maxY - k.neck.y, 1);
  const inkW = out.strokes.reduce((a, s) => a + s.width, 0) / Math.max(out.strokes.length, 1);
  const tolerance = Math.max(bodyLen * 0.05, inkW * 2);
  const poses = STRESS.map((o) => makePose({ ...o, leftShinAngle: k.leftShinStraighten, rightShinAngle: k.rightShinStraighten }));

  for (const s of out.strokes) {
    if (s.rigid) continue;
    for (let pass = 0; pass < 8; pass++) {
      const runs = runsOf(s.parts);
      if (runs.length < 2) break;
      let fix = -1;
      for (let r = 0; r + 1 < runs.length && fix < 0; r++) {
        const i = runs[r].end;                     // seam between points i and i+1
        if (seamStretch(out, s, i, poses) > tolerance) fix = r;
      }
      if (fix < 0) break;
      const a = runs[fix], b = runs[fix + 1];
      const aEnd = fix === 0, bEnd = fix + 1 === runs.length - 1;
      // The loose END adopts its neighbour; otherwise the shorter run gives way.
      let victim, part;
      if (aEnd && !bEnd) { victim = a; part = b.part; }
      else if (bEnd && !aEnd) { victim = b; part = a.part; }
      else if (a.end - a.start <= b.end - b.start) { victim = a; part = b.part; }
      else { victim = b; part = a.part; }
      for (let j = victim.start; j <= victim.end; j++) s.parts[j] = part;
    }
  }

  // The held-prop carrying parts follow the final labels (see Rig.leftHandPart).
  out.leftHandPart = P.torso; out.rightHandPart = P.torso;
  for (const s of out.strokes) {
    for (const p of s.parts) {
      if (p === P.leftArm || p === P.leftForearm) out.leftHandPart = P.leftForearm;
      if (p === P.rightArm || p === P.rightForearm) out.rightHandPart = P.rightForearm;
    }
  }
  return out;
}

/// Put each elbow ON the drawn arm: at the arm→forearm seam of that side's longest split
/// stroke. (The fitter's elbow is the midpoint of shoulder→farthest arm point, which sits
/// off a bent arm — or off the line entirely when a separate hand blob is farthest.)
function snapElbows(rig) {
  for (const [arm, fore, key] of [[P.leftArm, P.leftForearm, 'leftElbow'], [P.rightArm, P.rightForearm, 'rightElbow']]) {
    let best = null, bestN = 0;
    for (const s of rig.strokes) {
      if (s.rigid) continue;
      for (let i = 0; i + 1 < s.points.length; i++) {
        const pair = [s.parts[i], s.parts[i + 1]];
        if ((pair[0] === arm && pair[1] === fore) || (pair[0] === fore && pair[1] === arm)) {
          const n = s.parts.filter((p) => p === arm || p === fore).length;
          if (n > bestN) {
            bestN = n;
            best = { x: (s.points[i].x + s.points[i + 1].x) / 2, y: (s.points[i].y + s.points[i + 1].y) / 2 };
          }
        }
      }
    }
    if (best) rig.skeleton[key] = best;
  }
}

function seamStretch(rig, s, i, poses) {
  const a = s.points[i], b = s.points[i + 1];
  const rest = Math.hypot(a.x - b.x, a.y - b.y);
  let worst = 0;
  for (const pose of poses) {
    const wa = worldPoint(rig, a, s.parts[i], pose), wb = worldPoint(rig, b, s.parts[i + 1], pose);
    worst = Math.max(worst, Math.hypot(wa.x - wb.x, wa.y - wb.y) - rest);
  }
  return worst;
}

function runsOf(parts) {
  const runs = [];
  for (let i = 0; i < parts.length; i++) {
    const last = runs[runs.length - 1];
    if (last && last.part === parts[i]) last.end = i;
    else runs.push({ part: parts[i], start: i, end: i });
  }
  return runs;
}
