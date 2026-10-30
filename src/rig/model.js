// Port of RigModel.swift — body parts, rig strokes, skeleton, pose and the two-level FK.
// DOM-free so `node --test` can run it.

// The rigid parts a stickman is skinned into. Limbs split at the elbow / knee so a
// straight arm or leg can bend mid-way for a natural gait. A continuous stroke can
// span several parts (per-point assignment), so a one-stroke figure still articulates.
export const P = Object.freeze({
  torso: 'torso', head: 'head',
  leftArm: 'leftArm', rightArm: 'rightArm', leftForearm: 'leftForearm', rightForearm: 'rightForearm',
  leftLeg: 'leftLeg', rightLeg: 'rightLeg', leftShin: 'leftShin', rightShin: 'rightShin',
});

export const isArm = (p) => p === P.leftArm || p === P.rightArm;
export const isLeg = (p) => p === P.leftLeg || p === P.rightLeg;

// CGRect stand-in: an immutable rect with the derived edges the Swift code reads.
export function rect(x, y, width, height) {
  return {
    x, y, width, height,
    minX: x, minY: y, maxX: x + width, maxY: y + height,
    midX: x + width / 2, midY: y + height / 2,
  };
}
export const ZERO_RECT = rect(0, 0, 0, 0);

export function pt(x, y) { return { x, y }; }

// A single frame of motion. Angles are radians relative to the drawn rest pose
// (0 = as drawn). Forearm / shin angles are *local* to their parent limb. Root
// squash is about the feet; root rotation about the hips.
export function makePose(over = {}) {
  return Object.assign({
    offset: { x: 0, y: 0 },
    rootAngle: 0,
    scaleX: 1, scaleY: 1,
    headAngle: 0,
    leftArmAngle: 0, rightArmAngle: 0,
    leftForearmAngle: 0, rightForearmAngle: 0,
    leftLegAngle: 0, rightLegAngle: 0,
    leftShinAngle: 0, rightShinAngle: 0,
    opacity: 1,
  }, over);
}

export function copyPose(p) {
  return Object.assign({}, p, { offset: { x: p.offset.x, y: p.offset.y } });
}

/// A Rig: { strokes:[{points, parts, color, width, rigid}], skeleton, confidence,
/// articulated, demotions, leftHandPart, rightHandPart }.
export function makeRig(strokes, skeleton, confidence, articulated, demotions = [],
                        leftHandPart = P.torso, rightHandPart = P.torso) {
  return { strokes, skeleton, confidence, articulated, demotions, leftHandPart, rightHandPart };
}

/// A non-articulated copy: every stroke collapses to one rigid `.torso` sheet, so the whole
/// drawing moves as a SINGLE rigid sprite (kept for parity; the web build always auto-rigs).
export function nonArticulated(rig) {
  return {
    ...rig,
    strokes: rig.strokes.map((s) => ({ ...s, parts: s.points.map(() => P.torso), rigid: false })),
    articulated: false,
    leftHandPart: P.torso,
    rightHandPart: P.torso,
  };
}

/// Representative pen colour of the drawing (the longest stroke's) — used to draw
/// the conjured props in the same hand the figure was drawn in.
export function inkColor(rig) {
  let best = null;
  for (const s of rig.strokes) if (!best || best.points.length < s.points.length) best = s;
  return best ? best.color : '#1C1B19';
}

/// Representative pen width, so the props' line weight matches the figure.
export function inkWidth(rig) {
  const ws = rig.strokes.map((s) => s.width);
  return ws.length === 0 ? 4 : Math.max(3, ws.reduce((a, b) => a + b, 0) / ws.length);
}

/// The same rig, uniformly scaled + translated (p' = p·s + d) — used when the page is
/// resized. Labels, rigidity and joint angles are unchanged, so nothing re-classifies.
export function transformRig(rig, s, dx, dy) {
  const m = (p) => ({ x: p.x * s + dx, y: p.y * s + dy });
  const k = rig.skeleton;
  const skeleton = { ...k };
  for (const key of ['headCenter', 'neck', 'leftShoulder', 'rightShoulder', 'leftElbow', 'rightElbow',
    'hipCenter', 'leftHip', 'rightHip', 'leftKnee', 'rightKnee', 'feet', 'leftHand', 'rightHand']) {
    skeleton[key] = m(k[key]);
  }
  skeleton.headRadius = k.headRadius * s;
  skeleton.bbox = rect(k.bbox.x * s + dx, k.bbox.y * s + dy, k.bbox.width * s, k.bbox.height * s);
  return {
    ...rig,
    skeleton,
    strokes: rig.strokes.map((st) => ({ ...st, width: st.width * s, points: st.points.map(m) })),
  };
}

// Hierarchical forward kinematics. Each limb's lower segment bends about its
// elbow / knee first, then the whole limb swings about the shoulder / hip, then
// the root transform (squash about feet → lean about hips → translate). Because
// every joint a child rotates about is itself carried by the parent rotation,
// strokes crossing a joint stay connected — no tearing at shoulders/hips/knees.
export function worldPoint(rig, p, part, pose) {
  const s = rig.skeleton;
  let local = p;
  switch (part) {
    case P.torso: break;
    case P.head: local = rigRotate(p, s.neck, pose.headAngle); break;
    case P.leftArm: local = rigRotate(p, s.leftShoulder, pose.leftArmAngle); break;
    case P.rightArm: local = rigRotate(p, s.rightShoulder, pose.rightArmAngle); break;
    case P.leftForearm:
      local = rigRotate(p, s.leftElbow, pose.leftForearmAngle);
      local = rigRotate(local, s.leftShoulder, pose.leftArmAngle);
      break;
    case P.rightForearm:
      local = rigRotate(p, s.rightElbow, pose.rightForearmAngle);
      local = rigRotate(local, s.rightShoulder, pose.rightArmAngle);
      break;
    case P.leftLeg: local = rigRotate(p, s.leftHip, pose.leftLegAngle); break;
    case P.rightLeg: local = rigRotate(p, s.rightHip, pose.rightLegAngle); break;
    case P.leftShin:
      local = rigRotate(p, s.leftKnee, pose.leftShinAngle);
      local = rigRotate(local, s.leftHip, pose.leftLegAngle);
      break;
    case P.rightShin:
      local = rigRotate(p, s.rightKnee, pose.rightShinAngle);
      local = rigRotate(local, s.rightHip, pose.rightLegAngle);
      break;
  }
  let q = rigScaleAbout(local, s.feet, pose.scaleX, pose.scaleY);
  q = rigRotate(q, s.hipCenter, pose.rootAngle);
  return { x: q.x + pose.offset.x, y: q.y + pose.offset.y };
}

// MARK: - Point math

export function rigRotate(p, c, a) {
  if (a === 0) return p;
  const s = Math.sin(a), co = Math.cos(a);
  const dx = p.x - c.x, dy = p.y - c.y;
  return { x: c.x + dx * co - dy * s, y: c.y + dx * s + dy * co };
}

export function rigScaleAbout(p, c, sx, sy) {
  return { x: c.x + (p.x - c.x) * sx, y: c.y + (p.y - c.y) * sy };
}
