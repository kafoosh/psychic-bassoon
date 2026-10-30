// Port of TopHatRoutine.swift — drop → wave → walk to the roomier side → a hat falls from
// the sky onto his head → he lifts it off to the OPEN side, reaches the other hand in,
// rummages, and pulls the card out. No box.

import { P, rect } from '../../rig/model.js';
import { Approach, restPose, easeOut, easeIn, smooth, phase, lerp, worldHand, worldJoint, fitOnScreen } from '../support.js';
import { sketch, ovalPts, sparkles, cardFace } from '../sketchInk.js';
import { RoutineBase } from '../base.js';

const tFall = 4.7, tImpact = 5.8, tGrab = 6.1, tLift = 7.1, tReachIn = 8.1,
  tRummage = 9.3, tPull = 10.5, tPresent = 11.8;

export class TopHatRoutine extends RoutineBase {
  constructor(s) { super(s); this.totalDuration = 12.8; }
  get holdLeft() { return this.sideSign < 0; }      // holding hand = open side

  pose(t) {
    const ap = Approach.pose(t, this.skel, this.dropDistance, this.walkDX);
    if (ap) return ap;
    const p = restPose(this.skel);
    p.offset = { x: this.walkDX, y: this.dropDistance };
    const toward = this.sideSign;
    const holdLeft = this.holdLeft;

    if (t < tImpact) {                                // wait, look up at the falling hat
      p.headAngle = -0.10 * easeOut(phase(t, tFall + 0.6, tImpact));
    } else if (t < tGrab) {                           // hat impact squash
      const s = Math.sin(phase(t, tImpact, tGrab) * Math.PI);
      p.scaleY = 1 - 0.08 * s; p.scaleX = 1 + 0.06 * s;
      p.headAngle = -0.10 * (1 - phase(t, tImpact, tGrab));
    } else if (t < tLift) {                           // reach up, grab the hat
      const r = smooth(phase(t, tGrab, tLift - 0.1));
      p.leftArmAngle = 2.05 * r; p.rightArmAngle = -2.05 * r;
      p.leftForearmAngle = -0.5 * r; p.rightForearmAngle = 0.5 * r;
      p.headAngle = 0.05 * r;
    } else if (t < tReachIn) {                        // lift off, carry to the open side
      const r = smooth(phase(t, tLift, tReachIn - 0.1));
      if (holdLeft) {
        p.leftArmAngle = lerp(2.05, 1.25, r); p.leftForearmAngle = lerp(-0.5, -0.15, r);
        p.rightArmAngle = lerp(-2.05, -0.15, r); p.rightForearmAngle = lerp(0.5, 0, r);
      } else {
        p.rightArmAngle = lerp(-2.05, -1.25, r); p.rightForearmAngle = lerp(0.5, 0.15, r);
        p.leftArmAngle = lerp(2.05, 0.15, r); p.leftForearmAngle = lerp(-0.5, 0, r);
      }
      p.headAngle = -0.06 * toward * r;
    } else if (t < tRummage) {                        // reach the free hand into the hat
      const r = smooth(phase(t, tReachIn, tRummage - 0.1));
      this.holdArm(p, 1.25, -0.15);
      this.reachArm(p, lerp(0.15, 1.6, r), lerp(0, 1.5, r));
      p.rootAngle = 0.06 * toward * r; p.headAngle = lerp(-0.06 * toward, -0.14, r);
    } else if (t < tPull) {                           // rummage
      const w = Math.sin(2 * Math.PI * 2.0 * (t - tRummage));
      const amp = Math.sin(phase(t, tRummage, tPull) * Math.PI);
      this.holdArm(p, 1.25 + 0.06 * amp * w, -0.15);
      this.reachArm(p, 1.62 + 0.12 * amp * w, 1.5 + 0.1 * amp * Math.sin(2 * Math.PI * 2.0 * (t - tRummage) + 0.9));
      p.rootAngle = 0.06 * toward; p.headAngle = -0.14 + 0.05 * Math.sin(2 * Math.PI * 1.6 * (t - tRummage));
    } else if (t < tPresent) {                        // pull the card out & up
      const r = easeOut(phase(t, tPull, tPull + 1.0));
      this.holdArm(p, lerp(1.25, 0.55, r), lerp(-0.15, 0.1, r));
      this.reachArm(p, lerp(1.62, 1.15, r), lerp(1.5, 0.2, r));
      p.rootAngle = lerp(0.06 * toward, -0.03, r); p.headAngle = lerp(-0.14, 0.04, r);
    } else {                                          // present & hold
      this.holdArm(p, 0.55, 0.1);
      this.reachArm(p, 1.15, 0.2);
      const b = Math.sin(phase(t, tPresent, tPresent + 0.6) * Math.PI);
      p.scaleY = 1 + 0.02 * b; p.headAngle = 0.05 * b;
    }
    return p;
  }

  holdArm(p, upper, fore) {
    if (this.holdLeft) { p.leftArmAngle = upper; p.leftForearmAngle = fore; }
    else { p.rightArmAngle = -upper; p.rightForearmAngle = -fore; }
  }
  reachArm(p, upper, fore) {
    if (this.holdLeft) { p.rightArmAngle = -upper; p.rightForearmAngle = -fore; }
    else { p.leftArmAngle = upper; p.leftForearmAngle = fore; }
  }

  drawProps(ctx, t, pose, off, payload, paper) {
    if (t < tFall) return;
    const { rig, skel, propScale, sideSign, screenSize, ink, lw } = this;
    const head = worldJoint(rig, skel.headCenter, P.head, pose, off);
    const hr = skel.headRadius;
    const restBrim = { x: head.x, y: head.y - hr * 0.55 };
    const holdHand = worldHand(rig, this.holdLeft, pose, off);

    let brim;
    let flip = 0;
    if (t < tImpact) {
      const fp = easeIn(phase(t, tFall, tImpact));
      // Fall from just below the header (not off-screen above it), so the hat's whole
      // descent is visible instead of passing behind the top bar. Budget for the whole
      // hat (crown + its top oval + line width + jitter).
      const fallStartY = Math.max(this.topInset + propScale * 0.48 + lw * 2, restBrim.y - propScale * 0.5);
      brim = { x: head.x, y: lerp(fallStartY, restBrim.y, fp) };
    } else if (t < tLift) {
      brim = restBrim;
    } else {
      const bp = smooth(phase(t, tLift, tReachIn));
      brim = { x: lerp(restBrim.x, holdHand.x, bp), y: lerp(restBrim.y, holdHand.y, bp) };
      // The hat TUMBLES 180° while it's carried off the head, so it ends upside-down
      // in the hand — opening up.
      flip = smooth(phase(t, tLift + 0.15, tReachIn - 0.15));
    }

    // With the hat flipped, its OPENING sits one crown-height above the grip point —
    // the same spot the upright crown-top occupied.
    const crownH = propScale * 0.40;
    const brimW = propScale * 0.62, brimH = brimW * 0.22, crownW = brimW * 0.60;
    const mouth = { x: brim.x, y: brim.y - crownH };
    const mrx = crownW * 0.46, mry = brimH * 0.55;           // the opening (shared with the clip)

    this.drawHat(ctx, brim, flip, 1);

    // The opening's rim is split about the card: the FAR (back) arc behind it, the NEAR
    // (front) arc over it — so the card sits IN the hole, not behind or in front of it.
    const openingUp = flip > 0.9;
    if (openingUp) {
      sketch(ctx, arcPts(mouth, mrx, mry, Math.PI, 2 * Math.PI), ink, lw * 0.85, { amp: lw * 0.4, seed: 45 });
    }

    if (t >= tPull) {
      const r = easeOut(phase(t, tPull + 0.1, tPull + 1.0));
      // The card EXPANDS as it rises (0.72× → 1×) so it always fits through the opening.
      const grow = lerp(0.72, 1.0, r);
      const cardW = propScale * 0.34 * grow, cardH = cardW * 1.4;
      const cx = mouth.x + sideSign * cardW * 0.10;
      const cy = lerp(mouth.y + cardH * 0.20, mouth.y - cardH * 0.55, r);
      const op = easeOut(Math.min(phase(t, tPull, tPull + 0.3), 1));
      const center = fitOnScreen({ x: cx, y: cy }, cardW / 2, cardH / 2, screenSize, this.fitMargins);
      const cr = rect(center.x - cardW / 2, center.y - cardH / 2, cardW, cardH);
      // Visible only ABOVE the opening plane or THROUGH the hole — never below it.
      // rect ∪ ellipse: both sub-paths wind clockwise so the non-zero rule unions them.
      ctx.save();
      ctx.beginPath();
      ctx.rect(-2000, mouth.y - 4000, screenSize.width + 4000, 4000);
      ctx.moveTo(mouth.x + mrx, mouth.y);
      ctx.ellipse(mouth.x, mouth.y, mrx, mry, 0, 0, 2 * Math.PI, false);
      ctx.clip('nonzero');
      cardFace(ctx, cr, op, ink, lw, paper, payload);
      ctx.restore();
    }

    if (openingUp) {
      sketch(ctx, arcPts(mouth, mrx, mry, 0, Math.PI), ink, lw * 0.85, { amp: lw * 0.4, seed: 47 });
    }

    if (t >= tReachIn && t < tPull) {
      sparkles(ctx, mouth, propScale * 0.16, 0.5 * Math.sin(phase(t, tReachIn, tPull) * Math.PI), ink, lw);
    }
  }

  /// Draws the hat WIREFRAME in LOCAL space (brim plane at the origin, crown extending up
  /// to −crownH) under a rotation of `flip`·π about the hat's own centre, anchored at `grip`.
  drawHat(ctx, grip, flip, opacity) {
    const { propScale, ink, lw } = this;
    const brimW = propScale * 0.62, brimH = brimW * 0.22;
    const crownW = brimW * 0.60, crownH = propScale * 0.40;
    ctx.save();
    ctx.translate(grip.x, grip.y - crownH / 2);
    ctx.rotate(flip * Math.PI);
    ctx.translate(0, crownH / 2);
    const brim = { x: 0, y: 0 };
    const top = { x: 0, y: -crownH };
    sketch(ctx, ovalPts(brim, brimW / 2, brimH / 2), ink, lw, { closed: true, amp: lw * 0.7, seed: 41, opacity });
    sketch(ctx, [{ x: -crownW / 2, y: 0 }, { x: -crownW / 2, y: top.y }], ink, lw, { amp: lw * 0.5, seed: 42, opacity });
    sketch(ctx, [{ x: crownW / 2, y: 0 }, { x: crownW / 2, y: top.y }], ink, lw, { amp: lw * 0.5, seed: 43, opacity });
    sketch(ctx, ovalPts(top, crownW / 2, brimH * 0.55), ink, lw, { closed: true, amp: lw * 0.5, seed: 44, opacity });
    sketch(ctx, [{ x: -crownW / 2, y: -brimH * 0.4 }, { x: crownW / 2, y: -brimH * 0.4 }],
      ink, lw * 0.8, { amp: lw * 0.4, seed: 46, opacity });
    ctx.restore();
  }
}

function arcPts(center, rx, ry, a0, a1) {
  const out = [];
  for (let i = 0; i <= 20; i++) {
    const a = a0 + (a1 - a0) * i / 20;
    out.push({ x: center.x + rx * Math.cos(a), y: center.y + ry * Math.sin(a) });
  }
  return out;
}
