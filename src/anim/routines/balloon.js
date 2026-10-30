// Port of BalloonRoutine.swift — drop → wave → walk to the roomier side → inflate a balloon
// beside his face (toward the open side) → it floats up → pops → the card appears and settles.

import { P, rect } from '../../rig/model.js';
import { Approach, restPose, easeOut, smooth, phase, lerp, worldHand, worldJoint, fitOnScreen } from '../support.js';
import { sketch, ovalPts, sparkles, cardFace } from '../sketchInk.js';
import { RoutineBase } from '../base.js';

const tHands = 4.7, tInflate = 5.6, tRelease = 8.0, tStrain = 9.6, tPop = 9.95, tCard = 10.1;

export class BalloonRoutine extends RoutineBase {
  constructor(s) { super(s); this.totalDuration = 12.2; }

  pose(t) {
    const ap = Approach.pose(t, this.skel, this.dropDistance, this.walkDX);
    if (ap) return ap;
    const p = restPose(this.skel);
    p.offset = { x: this.walkDX, y: this.dropDistance };
    const toward = this.sideSign;

    if (t < tInflate) {                               // bring hands up beside the face
      const r = smooth(phase(t, tHands, tInflate));
      p.leftArmAngle = 0.85 * r; p.rightArmAngle = -0.85 * r;
      p.leftForearmAngle = 1.2 * r; p.rightForearmAngle = -1.2 * r;
      p.headAngle = (0.16 * toward - 0.05) * r; p.rootAngle = 0.05 * r;
    } else if (t < tRelease) {                        // inflate — puffs
      let puff = 0;
      for (const c of [tInflate + 0.6, tInflate + 1.4, tInflate + 2.0]) {
        if (t > c - 0.18 && t < c + 0.18) puff += Math.sin((t - (c - 0.18)) / 0.36 * Math.PI);
      }
      p.scaleY = 1 - 0.05 * puff; p.scaleX = 1 + 0.05 * puff;
      p.leftArmAngle = 0.9; p.rightArmAngle = -0.9;
      p.leftForearmAngle = 1.1; p.rightForearmAngle = -1.1;
      p.headAngle = 0.16 * toward - 0.05 - 0.05 * puff; p.rootAngle = 0.05;
    } else if (t < tStrain) {                         // release & watch it rise
      const r = smooth(phase(t, tRelease, tRelease + 1.0));
      p.leftForearmAngle = lerp(1.1, 0.5, easeOut(phase(t, tRelease, tRelease + 0.3)));
      p.rightForearmAngle = lerp(-1.1, -0.5, easeOut(phase(t, tRelease, tRelease + 0.3)));
      const reach = Math.sin(phase(t, tRelease, tStrain) * Math.PI);
      p.leftArmAngle = 0.9 + (toward < 0 ? 0.7 : 0) * reach;
      p.rightArmAngle = -0.9 - (toward > 0 ? 0.7 : 0) * reach;
      p.headAngle = lerp(0.1 * toward, -0.42, r);
    } else if (t < tCard) {                           // strain & pop
      if (t < tPop) { p.leftArmAngle = 0.9; p.rightArmAngle = -0.9; p.headAngle = -0.42; }
      else {
        const r = easeOut(phase(t, tPop, tCard + 0.3));
        p.headAngle = lerp(-0.42, -0.18, r);
        p.leftArmAngle = lerp(0.9, 1.3, r); p.rightArmAngle = lerp(-0.9, -1.3, r);
        p.scaleX = 1 + 0.06 * Math.sin(phase(t, tPop, tCard) * Math.PI);
      }
    } else {                                          // present
      const r = smooth(phase(t, tCard, tCard + 0.8));
      p.leftArmAngle = lerp(1.3, 0.7, r); p.rightArmAngle = lerp(-1.3, -0.7, r);
      p.leftForearmAngle = 0.25; p.rightForearmAngle = -0.25;
      p.headAngle = lerp(-0.18, -0.28, r);
    }
    return p;
  }

  radius(t) {
    const ps = this.propScale;
    if (t < tInflate) return 0;
    if (t < tRelease) {
      const p = phase(t, tInflate, tRelease);
      let r;
      if (p < 0.22) r = lerp(0, 0.16, p / 0.22);
      else if (p < 0.55) r = lerp(0.16, 0.26, (p - 0.22) / 0.33);
      else if (p < 0.85) r = lerp(0.26, 0.34, (p - 0.55) / 0.30);
      else r = lerp(0.34, 0.36, (p - 0.85) / 0.15);
      return ps * r;
    }
    if (t < tPop) return ps * lerp(0.36, 0.40, easeOut(phase(t, tStrain, tPop)));
    return ps * 0.40;
  }

  // Float up to just below the header — NOT a fixed screen fraction, which sat behind the
  // top bar. 0.40 × the ~1.06 strain stretch the balloon reaches before the pop, so the top
  // of a fully-stretched balloon still clears the chrome.
  get floatEndY() { return Math.max(this.topInset + this.propScale * 0.425 + this.lw * 3, this.screenSize.height * 0.20); }

  balloonCenter(t, off, pose) {
    const { rig, skel, sideSign, propScale } = this;
    const head = worldJoint(rig, skel.headCenter, P.head, pose, off);
    const R = this.radius(Math.min(t, tPop));
    const beside = { x: head.x + sideSign * (skel.headRadius * 0.7 + R * 0.5), y: head.y - R * 0.35 };
    if (t < tRelease) return beside;
    const R8 = this.radius(tRelease);
    const start = { x: head.x + sideSign * (skel.headRadius * 0.7 + R8 * 0.5), y: head.y - R8 * 0.35 };
    const fp = smooth(phase(Math.min(t, tStrain), tRelease, tStrain));
    const x = start.x + sideSign * propScale * 0.08 * fp + Math.sin(fp * 2 * Math.PI * 1.2) * propScale * 0.04;
    const y = lerp(start.y, this.floatEndY, fp);
    return { x, y };
  }

  drawProps(ctx, t, pose, off, payload, paper) {
    const { rig, propScale, sideSign, screenSize, ink, lw } = this;
    const popCenter = this.balloonCenter(tPop, off, pose);

    if (t >= tInflate && t < tPop) {                  // balloon present
      const R = this.radius(t);
      if (!(R > 1)) return;
      const center = this.balloonCenter(t, off, pose);
      const stretch = t >= tStrain ? 1.06 : 1.0;
      sketch(ctx, ovalPts(center, R * 0.92, R * stretch), ink, lw, { closed: true, amp: lw * 0.9, seed: 51 });
      const knot = { x: center.x, y: center.y + R * stretch };
      sketch(ctx, [{ x: knot.x - lw, y: knot.y }, { x: knot.x, y: knot.y + lw * 2.5 }, { x: knot.x + lw, y: knot.y }],
        ink, lw, { closed: true, amp: lw * 0.4, seed: 52 });
      // string trails to the hand CLOSEST to the balloon (the open side) while
      // held, then dangles after release
      const nearHand = worldHand(rig, sideSign < 0, pose, off);
      const end = t < tRelease ? nearHand
        : { x: knot.x + Math.sin(t * 4) * R * 0.1, y: knot.y + R * 1.3 };
      const pts = [];
      for (let k = 0; k <= 8; k++) {
        const u = k / 8;
        pts.push({ x: lerp(knot.x, end.x, u) + Math.sin(u * Math.PI) * R * 0.1, y: lerp(knot.y, end.y, u) });
      }
      sketch(ctx, pts, ink, lw * 0.8, { amp: lw * 0.5, seed: 53 });
    } else if (t >= tPop && t < tCard + 0.3) {        // POP burst
      const q = easeOut(phase(t, tPop, tCard + 0.3));
      const R = this.radius(tPop);
      for (let i = 0; i < 8; i++) {
        const a = i / 8 * 2 * Math.PI + 0.3;
        const d = R * 0.2 + q * R * 1.4;
        const base = { x: popCenter.x + Math.cos(a) * d, y: popCenter.y + Math.sin(a) * d };
        const tip = { x: base.x + Math.cos(a) * R * 0.3, y: base.y + Math.sin(a) * R * 0.3 };
        sketch(ctx, [base, tip], ink, lw, { amp: lw * 0.6, seed: 60 + i, opacity: 1 - q });
      }
      sparkles(ctx, popCenter, R * 1.1, 0.9 * (1 - q), ink, lw);
    }

    if (t >= tCard) {                                 // card materializes & settles
      const cardW = propScale * 0.42, cardH = cardW * 1.4;
      const birth = easeOut(phase(t, tCard, tCard + 0.4));
      const scale = lerp(0, 1.12, birth) - lerp(0, 0.12, easeOut(phase(t, tCard + 0.4, tCard + 0.6)));
      const op = easeOut(Math.min(phase(t, tCard, tCard + 0.2), 1));
      const settleP = easeOut(phase(t, tCard + 0.4, tCard + 1.6));
      const targetY = Math.max(popCenter.y + propScale * 0.16, cardH / 2 + propScale * 0.06);
      const cy = lerp(popCenter.y, targetY, settleP);
      const spin = lerp(0.5, 0, easeOut(phase(t, tCard, tCard + 0.6)));
      const sway = 0.06 * Math.sin(phase(t, tCard + 0.4, tCard + 1.6) * 2 * Math.PI * 2) * (1 - settleP);
      const w = cardW * Math.max(scale, 0.02), h = cardH * Math.max(scale, 0.02);
      const center = fitOnScreen({ x: popCenter.x, y: cy }, cardW / 2, cardH / 2, screenSize, this.fitMargins);
      ctx.save();
      ctx.translate(center.x, center.y);
      ctx.rotate(spin + sway);
      ctx.translate(-center.x, -center.y);
      const r = rect(center.x - w / 2, center.y - h / 2, w, h);
      cardFace(ctx, r, op, ink, lw, paper, payload);
      ctx.restore();
      if (t < tCard + 0.6) {
        sparkles(ctx, center, cardW * 0.7, 0.4 * (1 - phase(t, tCard, tCard + 0.6)), ink, lw);
      }
    }
  }
}
