// Port of FishingRoutine.swift — drop → wave → walk to the roomier side → take out a rod
// (line dangling) → cast the line out to the OPEN side of the screen → bite & reel struggle
// → pull the card in from the side on the hook.

import { P, rect } from '../../rig/model.js';
import { Approach, restPose, easeOut, smooth, phase, lerp, worldHand, worldJoint, fitOnScreen } from '../support.js';
import { sketch, sparkles, cardFace } from '../sketchInk.js';
import { RoutineBase } from '../base.js';

// Action beats (after the shared approach at 4.7).
const tRod = 4.7, tCast = 5.8, tWait = 6.7, tBite = 7.6, tReel = 8.1, tPull = 9.9, tPresent = 11.4;

export class FishingRoutine extends RoutineBase {
  constructor(s) { super(s); this.totalDuration = 12.6; }
  get castLeft() { return this.sideSign < 0; }

  pose(t) {
    const ap = Approach.pose(t, this.skel, this.dropDistance, this.walkDX);
    if (ap) return ap;
    const p = restPose(this.skel);
    p.offset = { x: this.walkDX, y: this.dropDistance };
    const castLeft = this.castLeft;

    const arm = (upper, fore) => {
      if (castLeft) { p.leftArmAngle = upper; p.leftForearmAngle = fore; }
      else { p.rightArmAngle = -upper; p.rightForearmAngle = -fore; }
    };
    const toward = castLeft ? -1 : 1;

    if (t < tCast) {                                  // take out the rod, hold it up-out
      const r = smooth(phase(t, tRod, tCast));
      arm(1.15 * r, -0.25 * r); p.headAngle = 0.12 * toward * r;
    } else if (t < tWait) {                           // cast — flick out toward the side
      const r = easeOut(phase(t, tCast, tCast + 0.45));
      arm(lerp(1.15, 1.5, r), lerp(-0.25, -0.05, r));
      p.rootAngle = toward * 0.10 * Math.sin(phase(t, tCast, tWait) * Math.PI);
      p.headAngle = 0.2 * toward;
    } else if (t < tBite) {                           // watch the line
      arm(1.4 + 0.03 * Math.sin(2 * Math.PI * (t - tWait) / 0.8), -0.1);
      p.headAngle = 0.18 * toward;
    } else if (t < tReel) {                           // bite — yanked toward the side
      const r = easeOut(phase(t, tBite, tBite + 0.2));
      arm(lerp(1.4, 1.2, r), lerp(-0.1, 0.2, r));
      p.rootAngle = toward * lerp(0, 0.22, r); p.headAngle = 0.1 * toward;
    } else if (t < tPull) {                           // reel — lean BACK and tug
      const lean = easeOut(phase(t, tReel, tReel + 0.5));
      const tug = Math.sin(2 * Math.PI * (t - tReel - 0.5) / 0.5);
      p.rootAngle = -toward * lerp(0.22, 0.30, lean) + toward * 0.06 * tug;
      arm(1.45 + 0.30 * Math.sin(2 * Math.PI * (t - tReel) / 0.5),
        0.1 + 0.45 * Math.sin(2 * Math.PI * (t - tReel) / 0.5 + Math.PI));
      p.headAngle = 0.05 * toward + 0.06 * tug;
      p.leftLegAngle = 0.12 * toward; p.rightLegAngle = -0.12 * toward;
    } else if (t < tPresent) {                        // pull the card in
      const r = easeOut(phase(t, tPull, tPull + 0.9));
      p.rootAngle = -toward * lerp(0.30, 0.05, r);
      arm(lerp(1.45, 1.25, r), lerp(0.1, 0.15, r));
      p.headAngle = lerp(0.05 * toward, 0.08 * toward, r);
    } else {                                          // present & hold
      arm(1.2 + 0.02 * Math.sin(2 * Math.PI * (t - tPresent)), 0.15);
      p.headAngle = 0.08 * toward;
    }
    return p;
  }

  drawProps(ctx, t, pose, off, payload, paper) {
    if (t < tRod) return;
    const { rig, skel, propScale, sideSign, screenSize, ink, lw } = this;
    const hand = worldHand(rig, this.castLeft, pose, off);
    const shoulder = this.castLeft ? worldJoint(rig, skel.leftShoulder, P.torso, pose, off)
      : worldJoint(rig, skel.rightShoulder, P.torso, pose, off);
    let dx = hand.x - shoulder.x, dy = hand.y - shoulder.y;
    const m = Math.max(Math.hypot(dx, dy), 1); dx /= m; dy /= m;
    const rodTip = { x: hand.x + dx * propScale * 0.34, y: hand.y + dy * propScale * 0.34 };
    sketch(ctx, [hand, rodTip], ink, lw * 1.2, { amp: lw * 0.2, seed: 30 });

    const edgeX = sideSign < 0 ? -propScale * 0.12 : screenSize.width + propScale * 0.12;
    const castY = rodTip.y + propScale * 0.06;

    if (t < tCast) {                                  // line dangles from the rod tip
      const d = propScale * 0.22 * easeOut(phase(t, tRod, tCast));
      sketch(ctx, [rodTip, { x: rodTip.x + 2, y: rodTip.y + d }], ink, lw, { amp: 1.4, seed: 33 });
      this.drawHook(ctx, { x: rodTip.x + 2, y: rodTip.y + d });
    } else if (t < tPull) {                           // line out to the side edge
      const castP = easeOut(phase(t, tCast, tCast + 0.55));
      const hook = { x: lerp(rodTip.x, edgeX, castP), y: lerp(rodTip.y + propScale * 0.22, castY, castP) };
      let amp = 1.6;
      if (t >= tBite && t < tReel) {
        const jerk = Math.exp(-10 * (t - tBite - 0.02)) * Math.sin(2 * Math.PI * (t - tBite) / 0.12);
        hook.x -= sideSign * propScale * 0.05 * jerk; amp = 2.6;
      } else if (t >= tReel) {
        hook.x -= sideSign * propScale * 0.03 * Math.sin(2 * Math.PI * (t - tReel) / 0.5); amp = 2.2;
      } else if (t < tWait) { amp = 2.4; }
      const sag = { x: (rodTip.x + hook.x) / 2, y: Math.max(rodTip.y, castY) + propScale * 0.05 };
      sketch(ctx, [rodTip, sag, hook], ink, lw, { amp, seed: 33 });
    } else {                                          // pull the card in from the side
      const pullP = easeOut(phase(t, tPull, tPull + 1.0));
      const target = { x: rodTip.x + sideSign * propScale * 0.10, y: rodTip.y + propScale * 0.30 };
      const hook = { x: lerp(edgeX, target.x, pullP), y: lerp(castY, target.y, pullP) };
      sketch(ctx, [rodTip, hook], ink, lw, { amp: lerp(1.8, 1.2, pullP), seed: 33 });
      this.drawHook(ctx, hook);
      const cardW = propScale * 0.32, cardH = cardW * 1.4;
      const center = fitOnScreen({ x: hook.x, y: hook.y + cardH * 0.55 }, cardW / 2, cardH / 2,
        screenSize, this.fitMargins);
      const sway = 0.16 * Math.cos(2 * Math.PI * (t - tPull) / 0.5) * (1 - pullP)
        + 0.05 * Math.cos(2 * Math.PI * (t - tPull) / 0.9) * pullP;
      const op = easeOut(Math.min(phase(t, tPull, tPull + 0.2), 1));
      this.drawSwaying(ctx, center, cardW, cardH, sway, op, paper, payload);
      if (t >= tPresent && t < tPresent + 0.5) {
        sparkles(ctx, center, propScale * 0.5, 0.5 * Math.sin(phase(t, tPresent, tPresent + 0.5) * Math.PI), ink, lw);
      }
    }
  }

  drawHook(ctx, p) {
    const s = this.propScale / 200;
    const pts = [p, { x: p.x, y: p.y + 18 * s }, { x: p.x + 8 * s, y: p.y + 24 * s }, { x: p.x + 2 * s, y: p.y + 30 * s }];
    sketch(ctx, pts, this.ink, this.lw, { amp: 1.2, seed: 34 });
  }

  drawSwaying(ctx, center, w, h, angle, opacity, paper, payload) {
    ctx.save();
    ctx.translate(center.x, center.y);
    ctx.rotate(angle);
    ctx.translate(-center.x, -center.y);
    const r = rect(center.x - w / 2, center.y - h / 2, w, h);
    cardFace(ctx, r, opacity, this.ink, this.lw, paper, payload);
    ctx.restore();
  }
}
