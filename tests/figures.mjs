// Port of a representative subset of RigHarness.swift: the swappable part library
// (heads / torsos / arms / legs in LINE and OUTLINE forms + decorations), the seeded
// CLEAN and PROPORTIONS populations, the hand-built user fixtures with ground truth, the
// per-figure scorer and the animated-bbox explosion test. DOM-free.

import { P } from '../src/rig/model.js';
import { worldPoint } from '../src/rig/model.js';
import { makeSetup, makeRoutine, SLOTS } from '../src/anim/setup.js';

// ---- Deterministic RNG (reproducible figures) — the Swift UInt64 LCG, in BigInt ----
const MASK = (1n << 64n) - 1n;
const MUL = 6364136223846793005n, INC = 1442695040888963407n;
export class LCG {
  constructor(seed) { this.state = (BigInt(seed) * MUL + INC) & MASK; }
  next() { this.state = (this.state * MUL + INC) & MASK; return this.state; }
  unit() { return Number(this.next() >> 11n) / 2 ** 53; }
  range(a, b) { return a + (b - a) * this.unit(); }
  bool(p = 0.5) { return this.unit() < p; }
  pick(xs) { return xs[Number(this.next() % BigInt(xs.length))]; }
}

// ---- low-level point generators ----
const pt = (x, y) => ({ x, y });
function ellipse(c, rx, ry, a0 = 0, a1 = 2 * Math.PI, n = 28) {
  const out = [];
  for (let i = 0; i <= n; i++) { const a = a0 + (a1 - a0) * i / n; out.push(pt(c.x + rx * Math.cos(a), c.y + ry * Math.sin(a))); }
  return out;
}
function line(a, b, n = 12) {
  const out = [];
  for (let i = 0; i <= n; i++) { const f = i / n; out.push(pt(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)); }
  return out;
}
function polyline(pts, n = 8) {
  if (pts.length <= 1) return pts;
  const out = [];
  for (let i = 1; i < pts.length; i++) out.push(...line(pts[i - 1], pts[i], n));
  return out;
}
function rectLoop(x0, y0, x1, y1) {
  return polyline([pt(x0, y0), pt(x1, y0), pt(x1, y1), pt(x0, y1), pt(x0, y0)], 10);
}
/// A closed tapered "tube" (capsule) from `a` to `b` with half-widths `wa`/`wb` and a
/// rounded tip at `b` — used for OUTLINE arms/legs.
function tube(a, b, wa, wb) {
  const dx = b.x - a.x, dy = b.y - a.y;
  const len = Math.max(Math.hypot(dx, dy), 0.001);
  const nx = -dy / len, ny = dx / len;
  const pts = [];
  pts.push(...line(pt(a.x + nx * wa, a.y + ny * wa), pt(b.x + nx * wb, b.y + ny * wb), 10));
  const tipAng0 = Math.atan2(ny, nx);
  for (let i = 1; i <= 8; i++) { const t = tipAng0 - Math.PI * i / 8; pts.push(pt(b.x + wb * Math.cos(t), b.y + wb * Math.sin(t))); }
  pts.push(...line(pt(b.x - nx * wb, b.y - ny * wb), pt(a.x - nx * wa, a.y - ny * wa), 10));
  pts.push(pts[0]);
  return pts;
}

// ---- variants ----
export const coreHeads = ['circle', 'bigCircle', 'smallCircle', 'wideOval', 'tallOval', 'openArc'];
export const coreTorsos = ['spineLine', 'rectOutline', 'roundedBlob', 'trapezoid', 'ovalBody'];
export const coreArms = ['lineDown', 'lineT', 'outlineMitten', 'bentLine', 'lowAttach'];
export const coreLegs = ['lineStraight', 'lineSplay', 'outlineTapered', 'bentLine', 'sideways', 'crossed', 'steepSplay', 'sideOutline'];
const armIsOutline = (a) => a === 'outlineMitten';
const legIsOutline = (l) => l === 'outlineTapered' || l === 'sideOutline' || l === 'monoTube';

const LS = (points, part, truth = null) => ({ points, part, truth });

function head(v, m) {
  const c = m.headCenter;
  const pts = v === 'openArc'
    ? ellipse(c, m.headRX, m.headRY, -Math.PI / 2 + 0.5, 1.5 * Math.PI - 0.2)
    : ellipse(c, m.headRX, m.headRY);
  return [LS(pts, P.head)];
}

function torso(v, m) {
  const cx = m.cx, hw = m.shoulderHalfW;
  let pts;
  switch (v) {
    case 'spineLine': pts = line(pt(cx, m.neckY), pt(cx, m.hipY)); break;
    case 'rectOutline': pts = rectLoop(cx - hw, m.shoulderY, cx + hw, m.hipY); break;
    case 'roundedBlob': pts = tube(pt(cx, m.shoulderY), pt(cx, m.hipY), hw, hw * 0.85); break;
    case 'trapezoid':
      pts = polyline([pt(cx - hw, m.shoulderY), pt(cx + hw, m.shoulderY),
        pt(cx + hw * 0.6, m.hipY), pt(cx - hw * 0.6, m.hipY), pt(cx - hw, m.shoulderY)], 10);
      break;
    case 'ovalBody': pts = ellipse(pt(cx, (m.shoulderY + m.hipY) / 2), hw, (m.hipY - m.shoulderY) / 2); break;
    case 'openTaperOutline':
      pts = polyline([pt(cx - hw, m.shoulderY), pt(cx - hw * 0.62, m.hipY - m.u * 0.15),
        pt(cx, m.hipY + m.u * 0.12), pt(cx + hw * 0.62, m.hipY - m.u * 0.15), pt(cx + hw, m.shoulderY)], 12);
      break;
    case 'hourglass': {
      const midY = (m.shoulderY + m.hipY) / 2;
      pts = polyline([pt(cx - hw, m.shoulderY), pt(cx + hw, m.shoulderY), pt(cx + hw * 0.45, midY),
        pt(cx + hw * 0.95, m.hipY), pt(cx - hw * 0.95, m.hipY), pt(cx - hw * 0.45, midY), pt(cx - hw, m.shoulderY)], 8);
      break;
    }
  }
  return [LS(pts, P.torso)];
}

function arm(v, side, m) {
  const part = side < 0 ? P.leftArm : P.rightArm;
  const sh = pt(m.cx + side * m.shoulderHalfW, m.shoulderY);
  const u = m.u;
  let pts;
  switch (v) {
    case 'lineDown': pts = line(sh, pt(sh.x + side * u * 1.1, sh.y + u * 1.7)); break;
    case 'lineT': pts = line(sh, pt(sh.x + side * u * 1.9, sh.y + u * 0.15)); break;
    case 'outlineMitten': pts = tube(sh, pt(sh.x + side * u * 1.0, sh.y + u * 1.7), u * 0.32, u * 0.42); break;
    case 'bentLine': {
      const elbow = pt(sh.x + side * u * 0.9, sh.y + u * 0.9);
      pts = polyline([sh, elbow, pt(elbow.x + side * u * 0.2, elbow.y + u * 1.0)]);
      break;
    }
    case 'lowAttach': {
      const root = pt(m.cx + side * m.shoulderHalfW * 0.5, m.shoulderY + Math.min(u * 1.1, (m.hipY - m.shoulderY) * 0.45));
      pts = line(root, pt(root.x + side * u * 1.2, root.y + u * 1.1));
      break;
    }
    case 'handOnHip': {
      const elbow = pt(sh.x + side * u * 0.85, sh.y + u * 0.85);
      const hand = pt(m.cx + side * Math.max(m.shoulderHalfW * 0.6, u * 0.12), m.hipY - u * 0.12);
      pts = polyline([sh, elbow, hand]);
      break;
    }
    case 'raisedFist': {
      const fistC = pt(sh.x + side * u * 0.8, m.headCenter.y);
      return [LS(line(sh, fistC), part), LS(ellipse(fistC, u * 0.16, u * 0.16), part)];
    }
    case 'twoStroke': {
      const elbow = pt(sh.x + side * u * 0.8, sh.y + u * 0.8);
      const hand = pt(elbow.x + side * u * 0.3, elbow.y + u * 0.9);
      return [LS(line(sh, elbow), part), LS(line(elbow, hand), part)];
    }
    case 'crossBody': {
      const elbow = pt(sh.x + side * u * 0.5, sh.y + u * 0.7);
      const hand = pt(m.cx - side * Math.max(m.shoulderHalfW * 0.7, u * 0.35), m.hipY - u * 0.25);
      pts = polyline([sh, elbow, hand]);
      break;
    }
  }
  return [LS(pts, part)];
}

function leg(v, side, m) {
  const part = side < 0 ? P.leftLeg : P.rightLeg;
  const hip = pt(m.cx + side * m.legHalfW, m.hipY);
  const u = m.u;
  let pts;
  switch (v) {
    case 'lineStraight': pts = line(hip, pt(hip.x + side * u * 0.15, m.footY)); break;
    case 'lineSplay': pts = line(hip, pt(hip.x + side * u * 0.8, m.footY)); break;
    case 'outlineTapered': pts = tube(hip, pt(hip.x + side * u * 0.25, m.footY), u * 0.32, u * 0.26); break;
    case 'bentLine': {
      const knee = pt(hip.x + side * u * 0.2, (hip.y + m.footY) / 2);
      pts = polyline([hip, knee, pt(knee.x + side * u * 0.3, m.footY)]);
      break;
    }
    case 'sideways': pts = line(hip, pt(hip.x - u * 0.95, m.footY)); break;
    case 'crossed': pts = line(hip, pt(m.cx - side * u * 0.85, m.footY)); break;
    case 'steepSplay': pts = line(hip, pt(hip.x + side * u * 1.5, m.footY)); break;
    case 'sideOutline': pts = tube(hip, pt(hip.x - u * 0.85, m.footY), u * 0.30, u * 0.24); break;
    case 'monoTube': {
      if (side > 0) return [];
      const top = pt(m.cx, m.hipY);
      const w = Math.max(m.legHalfW * 1.4, u * 0.7);
      const p = tube(top, pt(m.cx + u * 0.1, m.footY), w, w * 0.9);
      p.pop();
      return [LS(p, P.leftLeg)];
    }
    case 'twoStroke': {
      const knee = pt(hip.x + side * u * 0.25, (hip.y + m.footY) / 2);
      return [LS(line(hip, knee), part), LS(line(knee, pt(knee.x + side * u * 0.2, m.footY)), part)];
    }
  }
  return [LS(pts, part)];
}

function decorations(d, m, spec) {
  const out = [];
  const c = m.headCenter, u = m.u;
  if (d.ears) {
    const lx = c.x - m.headRX * 0.6, rx = c.x + m.headRX * 0.6, ty = c.y - m.headRY;
    out.push(LS(polyline([pt(lx - u * 0.2, ty + u * 0.1), pt(lx, ty - u * 0.6), pt(lx + u * 0.2, ty + u * 0.05)]), P.head));
    out.push(LS(polyline([pt(rx - u * 0.2, ty + u * 0.05), pt(rx, ty - u * 0.6), pt(rx + u * 0.2, ty + u * 0.1)]), P.head));
  }
  if (d.face) {
    out.push(LS(ellipse(pt(c.x - m.headRX * 0.35, c.y - m.headRY * 0.15), u * 0.06, u * 0.06), P.head));
    out.push(LS(ellipse(pt(c.x + m.headRX * 0.35, c.y - m.headRY * 0.15), u * 0.06, u * 0.06), P.head));
    out.push(LS(polyline([pt(c.x - m.headRX * 0.45, c.y + m.headRY * 0.3), pt(c.x - m.headRX * 0.15, c.y + m.headRY * 0.5),
      pt(c.x + m.headRX * 0.15, c.y + m.headRY * 0.5), pt(c.x + m.headRX * 0.45, c.y + m.headRY * 0.3)]), P.head));
  }
  if (d.hair) {
    const ty = c.y - m.headRY;
    for (let k = -1; k <= 1; k++) {
      const x = c.x + k * m.headRX * 0.4;
      out.push(LS(line(pt(x, ty + u * 0.1), pt(x + k * u * 0.2, ty - u * 0.5)), P.head));
    }
  }
  if (d.neck) {
    out.push(LS(line(pt(c.x, c.y + m.headRY - u * 0.05), pt(c.x, m.shoulderY + u * 0.15)), P.torso));
  }
  if (d.hands && spec.arm !== 'handOnHip' && spec.arm !== 'raisedFist') {
    for (const side of [-1, 1]) {
      const sh = pt(m.cx + side * m.shoulderHalfW, m.shoulderY);
      const hand = pt(sh.x + side * u * 1.0, sh.y + u * 1.7);
      out.push(LS(ellipse(hand, u * 0.18, u * 0.18), side < 0 ? P.leftArm : P.rightArm));
    }
  }
  if (d.feet && spec.leg !== 'monoTube') {
    for (const side of [-1, 1]) {
      if (spec.oneLeg && side > 0) continue;
      const hip = pt(m.cx + side * m.legHalfW, m.hipY);
      const foot = pt(hip.x + side * u * 0.25, m.footY);
      out.push(LS(line(foot, pt(foot.x + side * u * 0.5, foot.y)), side < 0 ? P.leftLeg : P.rightLeg));
    }
  }
  if (d.belt) {
    const bw = Math.max(m.shoulderHalfW * 0.65, u * 0.5);
    const y = m.hipY - u * 0.35;
    out.push(LS(line(pt(m.cx - bw, y), pt(m.cx + bw, y)), P.torso));
  }
  if (d.tail) {
    out.push(LS(polyline([pt(m.cx + m.shoulderHalfW * 0.4, m.hipY - u * 0.1),
      pt(m.cx + m.shoulderHalfW * 0.4 + u * 0.75, m.hipY + u * 0.2),
      pt(m.cx + m.shoulderHalfW * 0.4 + u * 1.2, m.hipY - u * 0.3)]), P.torso));
  }
  if (d.hat) {
    const ty = c.y - m.headRY - u * 0.05;
    out.push(LS(line(pt(c.x - m.headRX * 0.9, ty), pt(c.x + m.headRX * 0.9, ty)), P.head));
    out.push(LS(polyline([pt(c.x - m.headRX * 0.5, ty), pt(c.x - m.headRX * 0.45, ty - u * 0.8),
      pt(c.x + m.headRX * 0.45, ty - u * 0.8), pt(c.x + m.headRX * 0.5, ty)]), P.head));
  }
  return out;
}

export function makeSpec(o) {
  return Object.assign({
    deco: {}, lean: 0, scale: 1, wobble: 0, seed: 1, penScale: 1, oneLeg: false,
    torsoLen: 3.0, legLen: 2.6, lambdaLeg: false,
  }, o);
}

export function specTags(s) {
  const t = [`head:${s.head}`, `torso:${s.torso}`, `arm:${s.arm}`, `leg:${s.leg}`];
  for (const k of ['ears', 'face', 'hands', 'feet', 'hair', 'neck', 'belt', 'tail', 'hat']) if (s.deco[k]) t.push(`deco:${k}`);
  if (Math.abs(s.lean) > 0.04) t.push('lean');
  if (s.wobble > 1.5) t.push('wobble');
  if (s.penScale > 1.5) t.push('thickPen');
  if (s.oneLeg) t.push('oneLeg');
  const crotchFrac = (s.torsoLen + 0.3) / (s.torsoLen + 0.3 + s.legLen);
  if (crotchFrac < 0.42) t.push('shortTorso'); else if (crotchFrac > 0.62) t.push('longTorso');
  if (s.lambdaLeg) t.push('lambdaLeg');
  return t;
}

function metrics(spec, canvas) {
  const u = 46 * spec.scale;
  let headRX = u, headRY = u;
  switch (spec.head) {
    case 'circle': headRX = u * 1.0; headRY = u * 1.0; break;
    case 'bigCircle': headRX = u * 1.7; headRY = u * 1.7; break;
    case 'smallCircle': headRX = u * 0.6; headRY = u * 0.6; break;
    case 'wideOval': headRX = u * 1.6; headRY = u * 0.95; break;
    case 'tallOval': headRX = u * 0.85; headRY = u * 1.4; break;
    case 'openArc': headRX = u * 1.0; headRY = u * 1.0; break;
  }
  const cx = canvas.width * 0.5;
  const topY = canvas.height * 0.16;
  const headCenter = pt(cx, topY + headRY);
  const neckY = headCenter.y + headRY;
  const shoulderY = neckY + u * 0.3;
  const shoulderHalfW = spec.torso === 'spineLine' ? u * 0.12 : u * 0.95;
  const hipY = shoulderY + u * spec.torsoLen;
  const legHalfW = u * 0.5;
  const footY = hipY + u * spec.legLen;
  return { cx, headCenter, headRX, headRY, neckY, shoulderY, shoulderHalfW, hipY, legHalfW, footY, u };
}

/// Build the figure: the strokes fed to the fitter + per-stroke ground truth (index-aligned).
/// Truth is { part } | { kind: 'armPair' | 'legPair' | 'spineLeg' }.
export function build(spec, canvas = { width: 390, height: 844 }) {
  const m = metrics(spec, canvas);
  const labeled = [];
  labeled.push(...head(spec.head, m));
  const torsoStrokes = torso(spec.torso, m);
  const leftLeg = leg(spec.leg, -1, m);
  if (spec.lambdaLeg && spec.torso === 'spineLine' && torsoStrokes.length === 1 && leftLeg.length === 1 && !legIsOutline(spec.leg)) {
    labeled.push(LS(torsoStrokes[0].points.concat(leftLeg[0].points), P.torso, { kind: 'spineLeg' }));
  } else {
    labeled.push(...torsoStrokes, ...leftLeg);
  }
  labeled.push(...arm(spec.arm, -1, m), ...arm(spec.arm, 1, m));
  if (!spec.oneLeg) labeled.push(...leg(spec.leg, 1, m));
  labeled.push(...decorations(spec.deco, m, spec));

  // Apply lean (horizontal shear about the head) + hand-drawn wobble.
  const rng = new LCG(spec.seed);
  const pivotY = m.headCenter.y;
  const width = Math.max(m.u * 0.12, 4) * spec.penScale;
  const strokes = [], truth = [];
  for (const ls of labeled) {
    const pts = ls.points.map((p) => {
      const q = { x: p.x, y: p.y };
      q.x += spec.lean * (q.y - pivotY);
      if (spec.wobble > 0) {
        q.x += rng.range(-spec.wobble, spec.wobble);
        q.y += rng.range(-spec.wobble, spec.wobble);
      }
      return q;
    });
    strokes.push({ points: pts, width, color: '#F24521' });
    truth.push(ls.truth || { part: ls.part });
  }
  return { strokes, truth, outline: truth.map((t) => !!t.part && isOutlinePart(spec, t.part)) };
}

function isOutlinePart(spec, part) {
  if (part === P.leftArm || part === P.rightArm) return armIsOutline(spec.arm);
  if (part === P.leftLeg || part === P.rightLeg) return legIsOutline(spec.leg);
  return false;
}

// ---- populations ----

export function cleanSpecs() {
  const specs = [];
  let sid = 1;
  for (const h of coreHeads) for (const t of coreTorsos) for (const a of coreArms) for (const l of coreLegs) {
    specs.push(makeSpec({ head: h, torso: t, arm: a, leg: l, lean: 0.02, wobble: 1.5, seed: sid })); sid += 1;
  }
  const rng = new LCG(0xA11CE);
  for (let k = 0; k < 700; k++) {
    const deco = {};
    if (rng.bool(0.5)) deco.face = true;
    if (rng.bool(0.25)) deco.ears = true;
    if (rng.bool(0.3)) deco.hands = true;
    if (rng.bool(0.3)) deco.feet = true;
    if (rng.bool(0.2)) deco.hair = true;
    if (rng.bool(0.3)) deco.neck = true;
    const headV = rng.pick(coreHeads), torsoV = rng.pick(coreTorsos), armV = rng.pick(coreArms), legV = rng.pick(coreLegs);
    const lean = rng.range(-0.18, 0.18);
    const scale = rng.range(0.75, 1.45);
    const wobble = rng.bool(0.5) ? rng.range(0, 4) : 0;
    specs.push(makeSpec({ head: headV, torso: torsoV, arm: armV, leg: legV, deco, lean, scale, wobble, seed: sid })); sid += 1;
  }
  return specs;
}

export function proportionSpecs() {
  const specs = [];
  const rng = new LCG(0x5151A7);
  let sid = 200000;
  const legs = ['lineStraight', 'lineSplay', 'bentLine', 'sideways', 'crossed', 'steepSplay', 'outlineTapered', 'twoStroke'];
  const arms = coreArms.concat(['twoStroke', 'crossBody']);
  for (let k = 0; k < 600; k++) {
    const deco = {};
    if (rng.bool(0.4)) deco.face = true;
    if (rng.bool(0.2)) deco.hands = true;
    if (rng.bool(0.2)) deco.feet = true;
    if (rng.bool(0.2)) deco.neck = true;
    const headV = rng.pick(coreHeads);
    const torsoV = rng.bool(0.6) ? 'spineLine' : rng.pick(coreTorsos);
    const armV = rng.pick(arms), legV = rng.pick(legs);
    const lean = rng.range(-0.12, 0.12);
    const scale = rng.range(0.45, 1.4);
    const wobble = rng.bool(0.5) ? rng.range(0, 3) : 0;
    const spec = makeSpec({ head: headV, torso: torsoV, arm: armV, leg: legV, deco, lean, scale, wobble, seed: sid });
    spec.torsoLen = rng.range(1.2, 3.6);
    spec.legLen = rng.range(2.0, 4.6);
    if (rng.bool(0.3)) spec.penScale = rng.range(1.6, 2.8);
    if (rng.bool(0.35)) spec.lambdaLeg = true;
    specs.push(spec); sid += 1;
  }
  return specs;
}

// ---- hand-built user fixtures (with ground truth) ----

export function userFixtures() {
  const mk = (pts) => ({ points: pts, width: 7, color: '#F24521' });
  const ell = (c, rx, ry, gap = 0) => {
    const span = 2 * Math.PI - gap;
    const out = [];
    // stride(from: 0, through: span, by: span / 30)
    for (let i = 0; i <= 30; i++) { const a = span * i / 30; out.push(pt(c.x + rx * Math.cos(a), c.y + ry * Math.sin(a))); }
    return out;
  };
  const ln = (a, b, n = 14) => { const o = []; for (let i = 0; i <= n; i++) { const f = i / n; o.push(pt(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)); } return o; };
  const poly = (ps) => { const o = []; for (let i = 1; i < ps.length; i++) o.push(...ln(ps[i - 1], ps[i], 8)); return o; };
  const tb = (a, b, w, closed = true) => {
    const dx = b.x - a.x, dy = b.y - a.y, len = Math.max(Math.hypot(dx, dy), 0.001), nx = -dy / len, ny = dx / len;
    const p = ln(pt(a.x + nx * w, a.y + ny * w), pt(b.x + nx * w, b.y + ny * w), 10);
    const t0 = Math.atan2(ny, nx);
    for (let i = 1; i <= 8; i++) { const t = t0 - Math.PI * i / 8; p.push(pt(b.x + w * Math.cos(t), b.y + w * Math.sin(t))); }
    p.push(...ln(pt(b.x - nx * w, b.y - ny * w), pt(a.x - nx * w, a.y - ny * w), 10));
    if (closed) p.push(p[0]);
    return p;
  };
  const T = (part) => ({ part });
  const armPair = { kind: 'armPair' }, legPair = { kind: 'legPair' };
  const std = [T(P.head), T(P.torso), T(P.leftArm), T(P.rightArm), T(P.leftLeg), T(P.rightLeg)];
  const fx = (name, strokes, truth) => ({ name, strokes: strokes.map(mk), truth });
  return [
    fx('user1', [ell(pt(197, 232), 66, 74), poly([pt(204, 305), pt(202, 420), pt(206, 545)]),
      ln(pt(202, 345), pt(132, 418)), ln(pt(210, 345), pt(286, 400)),
      ln(pt(206, 545), pt(150, 660)), ln(pt(206, 545), pt(258, 665))], std),
    fx('user2', [ell(pt(196, 232), 78, 82, 0.4), tb(pt(204, 362), pt(204, 520), 46),
      tb(pt(172, 372), pt(150, 512), 22), tb(pt(240, 372), pt(268, 500), 22),
      tb(pt(186, 515), pt(182, 675), 22), tb(pt(226, 515), pt(236, 685), 22)], std),
    fx('user2open', [ell(pt(196, 232), 78, 82, 0.4), tb(pt(204, 362), pt(204, 520), 44, false),
      tb(pt(158, 375), pt(142, 512), 20, false), tb(pt(254, 375), pt(272, 500), 20, false),
      tb(pt(180, 518), pt(176, 688), 18, false), tb(pt(240, 518), pt(248, 688), 18, false)], std),
    fx('neckThin', [ell(pt(200, 215), 58, 60), ln(pt(200, 276), pt(202, 330)), tb(pt(202, 335), pt(202, 500), 44),
      tb(pt(168, 345), pt(150, 500), 20), tb(pt(236, 345), pt(256, 490), 20),
      tb(pt(182, 498), pt(178, 660), 18), tb(pt(224, 498), pt(230, 662), 18)],
    [T(P.head), T(P.torso), T(P.torso), T(P.leftArm), T(P.rightArm), T(P.leftLeg), T(P.rightLeg)]),
    fx('neckFat', [ell(pt(200, 215), 58, 60), tb(pt(200, 278), pt(200, 332), 13), tb(pt(202, 336), pt(202, 500), 44),
      tb(pt(168, 346), pt(150, 500), 20), tb(pt(236, 346), pt(256, 490), 20),
      tb(pt(182, 498), pt(178, 660), 18), tb(pt(224, 498), pt(230, 662), 18)],
    [T(P.head), T(P.torso), T(P.torso), T(P.leftArm), T(P.rightArm), T(P.leftLeg), T(P.rightLeg)]),
    fx('sideLegX', [ell(pt(210, 286), 62, 70), ln(pt(212, 354), pt(214, 540)),
      ln(pt(214, 388), pt(112, 470)), ln(pt(210, 386), pt(300, 432)),
      ln(pt(230, 514), pt(150, 672)), ln(pt(202, 532), pt(292, 648))], std),
    fx('sideLegLean', [ell(pt(200, 270), 60, 66), ln(pt(202, 334), pt(204, 520)),
      ln(pt(204, 366), pt(120, 452)), ln(pt(200, 364), pt(286, 432)),
      ln(pt(196, 520), pt(120, 668)), ln(pt(214, 520), pt(150, 672))], std),
    fx('offsetArm', [ell(pt(200, 232), 55, 52), ln(pt(202, 285), pt(204, 420)),
      ln(pt(201, 330), pt(140, 368)), poly([pt(203, 345), pt(188, 364), pt(256, 392)]),
      ln(pt(204, 420), pt(186, 528)), ln(pt(206, 420), pt(214, 526))], std),
    fx('archArms', [ell(pt(200, 250), 55, 65), ln(pt(202, 316), pt(204, 560)),
      poly([pt(135, 470), pt(150, 420), pt(172, 380), pt(200, 355), pt(228, 378), pt(252, 420), pt(270, 480)]),
      ln(pt(204, 560), pt(158, 700)), ln(pt(206, 560), pt(252, 700))],
    [T(P.head), T(P.torso), armPair, T(P.leftLeg), T(P.rightLeg)]),
    fx('archArmsVLegs', [ell(pt(200, 250), 55, 65), ln(pt(202, 316), pt(204, 555)),
      poly([pt(135, 470), pt(172, 380), pt(200, 355), pt(228, 378), pt(270, 480)]),
      poly([pt(152, 705), pt(204, 556), pt(254, 710)])],
    [T(P.head), T(P.torso), armPair, legPair]),
    fx('steepArchArms', [ell(pt(200, 250), 55, 65), ln(pt(202, 316), pt(204, 560)),
      poly([pt(140, 540), pt(155, 430), pt(178, 372), pt(200, 352), pt(226, 370), pt(246, 432), pt(262, 545)]),
      ln(pt(204, 560), pt(158, 700)), ln(pt(206, 560), pt(252, 700))],
    [T(P.head), T(P.torso), armPair, T(P.leftLeg), T(P.rightLeg)]),
    fx('asymArms', [ell(pt(200, 250), 52, 62), ln(pt(202, 314), pt(204, 560)),
      poly([pt(128, 300), pt(156, 342), pt(180, 380), pt(203, 420), pt(226, 462), pt(258, 532)]),
      ln(pt(204, 560), pt(158, 700)), ln(pt(206, 560), pt(252, 700))],
    [T(P.head), T(P.torso), armPair, T(P.leftLeg), T(P.rightLeg)]),
    fx('checkArms', [ell(pt(200, 250), 52, 62), ln(pt(202, 314), pt(204, 560)),
      poly([pt(138, 478), pt(164, 428), pt(186, 388), pt(204, 366), pt(244, 360), pt(300, 348)]),
      ln(pt(204, 560), pt(158, 700)), ln(pt(206, 560), pt(252, 700))],
    [T(P.head), T(P.torso), armPair, T(P.leftLeg), T(P.rightLeg)]),
    fx('vArmsUp', [ell(pt(200, 250), 52, 62), ln(pt(202, 314), pt(204, 560)),
      poly([pt(150, 470), pt(176, 428), pt(203, 388), pt(246, 362), pt(288, 338)]),
      ln(pt(204, 560), pt(158, 700)), ln(pt(206, 560), pt(252, 700))],
    [T(P.head), T(P.torso), armPair, T(P.leftLeg), T(P.rightLeg)]),
    fx('floatSideArms', [ell(pt(200, 250), 52, 62), ln(pt(202, 314), pt(204, 560)),
      ln(pt(186, 362), pt(130, 398)), ln(pt(222, 432), pt(280, 472)),
      ln(pt(204, 560), pt(158, 700)), ln(pt(206, 560), pt(252, 700))], std),
    fx('narrowVLegs', [ell(pt(200, 250), 52, 62), ln(pt(202, 314), pt(204, 560)),
      ln(pt(202, 340), pt(62, 330)), ln(pt(206, 340), pt(344, 334)),
      poly([pt(170, 700), pt(204, 562), pt(240, 706)])],
    [T(P.head), T(P.torso), T(P.leftArm), T(P.rightArm), legPair]),
    fx('smallHigh', [ell(pt(196, 150), 26, 28), ln(pt(196, 178), pt(197, 250)),
      ln(pt(196, 196), pt(158, 232)), ln(pt(197, 196), pt(236, 232)),
      ln(pt(197, 250), pt(172, 312)), ln(pt(197, 250), pt(222, 312))], std),
  ];
}

// ---- scoring ----

function group(p) {
  switch (p) {
    case P.head: return 'head';
    case P.torso: return 'torso';
    case P.leftArm: case P.leftForearm: return 'Larm';
    case P.rightArm: case P.rightForearm: return 'Rarm';
    case P.leftLeg: case P.leftShin: return 'Lleg';
    default: return 'Rleg';
  }
}
function limb(g) {
  if (g === 'Larm' || g === 'Rarm') return 'arm';
  if (g === 'Lleg' || g === 'Rleg') return 'leg';
  return g;
}

/// Score one fitted rig against ground truth (RigHarness.scoreFigure).
export function scoreFigure(rig, truth, outline = []) {
  const res = { strokeTotal: 0, strokeOK: 0, figOK: true, mismatch: false, failParts: [],
    torsoStrokes: 0, torsoAsArm: 0, legStrokes: 0, legAsArm: 0, legSplitArm: 0,
    outlineLimbStrokes: 0, outlineLimbTorn: 0, validatorDemotions: rig.demotions.length, validatorFPs: 0 };
  for (const d of rig.demotions) {
    for (let k = 0; k < d.strokes.length; k++) {
      const si = d.strokes[k];
      if (si >= truth.length || k >= d.preMajorities.length) continue;
      const t = truth[si];
      const intended = t.part ? limb(group(t.part)) : (t.kind === 'armPair' ? 'arm' : t.kind === 'legPair' ? 'leg' : 'torso');
      if ((intended === 'arm' || intended === 'leg') && limb(group(d.preMajorities[k])) === intended) { res.validatorFPs += 1; break; }
    }
  }
  if (rig.strokes.length !== truth.length) { res.mismatch = true; res.figOK = false; return res; }
  rig.strokes.forEach((rs, i) => {
    res.strokeTotal += 1;
    const counts = new Map();
    for (const p of rs.parts) { const g = group(p); counts.set(g, (counts.get(g) || 0) + 1); }
    let majority = 'torso', mN = -1;
    for (const [k, v] of counts) if (v > mN) { mN = v; majority = k; }
    const n = Math.max(rs.parts.length, 1);
    const c = (k) => counts.get(k) || 0;
    const concentration = c(majority) / n;
    let correct, key;
    const t = truth[i];
    if (t.part) {
      const intended = group(t.part);
      key = intended;
      const midY = rs.points.reduce((s, p) => s + p.y, 0) / Math.max(rs.points.length, 1);
      const inNeckZone = midY < rig.skeleton.bbox.minY + rig.skeleton.bbox.height * 0.42;
      const neckOK = inNeckZone && ((intended === 'torso' && majority === 'head') || (intended === 'head' && majority === 'torso'));
      correct = (limb(majority) === limb(intended) && concentration >= 0.55) || neckOK;
      if (t.part === P.torso) { res.torsoStrokes += 1; if (limb(majority) === 'arm') res.torsoAsArm += 1; }
      if (t.part === P.leftLeg || t.part === P.rightLeg) {
        res.legStrokes += 1;
        if (limb(majority) === 'arm') res.legAsArm += 1;
        if ((c('Larm') + c('Rarm')) * 12 > n) res.legSplitArm += 1;
      }
      if ([P.leftArm, P.rightArm, P.leftLeg, P.rightLeg].includes(t.part) && outline[i]) {
        res.outlineLimbStrokes += 1;
        if (concentration < 0.7) res.outlineLimbTorn += 1;
      }
    } else if (t.kind === 'armPair') {
      key = 'armP';
      const l = c('Larm'), r = c('Rarm'), armN = l + r;
      correct = armN * 2 >= n && Math.min(l, r) * 4 >= armN && c('head') * 10 <= n && (c('Lleg') + c('Rleg')) * 10 <= n;
    } else if (t.kind === 'legPair') {
      key = 'legP';
      const l = c('Lleg'), r = c('Rleg'), legN = l + r;
      correct = legN * 2 >= n && Math.min(l, r) * 4 >= legN && c('head') * 10 <= n && (c('Larm') + c('Rarm')) * 10 <= n;
    } else {
      key = 'spLeg';
      const legN = c('Lleg') + c('Rleg'), armN = c('Larm') + c('Rarm');
      res.legStrokes += 1;
      if (armN * 12 > n) res.legSplitArm += 1;
      if (limb(majority) === 'arm') res.legAsArm += 1;
      correct = legN * 5 >= n && armN * 12 <= n;
    }
    if (correct) res.strokeOK += 1; else { res.figOK = false; res.failParts.push(`${key}->${majority}`); }
  });
  return res;
}

export const EXPLOSION_INSETS = { top: 130, bottom: 96 };   // worst-case chrome

/// Worst animated-bbox extent ÷ rest extent across one routine (the fling detector).
export function explosionRatio(rig, slot, bounds = { width: 390, height: 844 },
                               topInset = EXPLOSION_INSETS.top, bottomInset = EXPLOSION_INSETS.bottom) {
  const origExtent = Math.max(rig.skeleton.bbox.width, rig.skeleton.bbox.height);
  if (!(origExtent > 1)) return 1;
  const setup = makeSetup(rig, bounds, { x: 0, y: 0 }, topInset, bottomInset);
  const routine = makeRoutine(slot, setup);
  let worst = 1;
  for (let t = 0; t <= routine.totalDuration + 0.001; t += 0.5) {
    const pose = routine.pose(t);
    let lx = Infinity, ly = Infinity, hx = -Infinity, hy = -Infinity;
    for (const s of rig.strokes) {
      s.points.forEach((p, j) => {
        const w = worldPoint(rig, p, s.parts[j], pose);
        if (w.x < lx) lx = w.x; if (w.y < ly) ly = w.y; if (w.x > hx) hx = w.x; if (w.y > hy) hy = w.y;
      });
    }
    worst = Math.max(worst, Math.max(hx - lx, hy - ly) / origExtent);
  }
  return worst;
}

export function explodedSlots(rig, bounds) {
  return SLOTS.filter((slot) => explosionRatio(rig, slot, bounds) > 2.2);
}
