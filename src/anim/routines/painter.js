// Port of PainterRoutine.swift — drop → wave → walk to the roomier side → use the wand to
// draw the card into existence in mid-air on the OPEN side (progressive draw-on) → the face
// fills in → the card lifts to present.

import { P, rect } from '../../rig/model.js';
import { Approach, restPose, easeOut, smooth, phase, lerp, worldHand, worldJoint, fitOnScreen } from '../support.js';
import { sketch, sketchPartial, rectPts, star, sparkles, cardFace } from '../sketchInk.js';
import { RoutineBase } from '../base.js';

// Raise the wand → wave it (a flourish) → the magic beam reaches OUT to the card spot →
// draw the card on → fill → lift.
const tRaise = 4.7, tWave = 5.4, tReach = 6.3, tDraw = 6.9, tClose = 9.5, tFill = 9.9, tLift = 10.9, tHold = 11.8;

export class PainterRoutine extends RoutineBase {
  constructor(s) { super(s); this.totalDuration = 12.2; }
  get drawLeft() { return this.sideSign < 0; }

  pose(t) {
    const ap = Approach.pose(t, this.skel, this.dropDistance, this.walkDX);
    if (ap) return ap;
    const p = restPose(this.skel);
    p.offset = { x: this.walkDX, y: this.dropDistance };
    const drawLeft = this.drawLeft;

    const setArm = (upper, fore) => {
      if (drawLeft) { p.leftArmAngle = upper; p.leftForearmAngle = fore; }
      else { p.rightArmAngle = -upper; p.rightForearmAngle = -fore; }
    };

    if (t < tWave) {                                  // raise the wand hand
      const r = smooth(phase(t, tRaise, tWave));
      setArm(1.45 * r, 0.40 * r); p.headAngle = (drawLeft ? 0.16 : -0.16) * r;
    } else if (t < tReach) {                          // wave the wand (a flourish)
      const amp = Math.sin(phase(t, tWave, tReach) * Math.PI);     // ramp 0→1→0
      const wob = Math.sin(2 * Math.PI * 1.7 * (t - tWave));
      setArm(1.45 + 0.18 * amp * wob, 0.40 + 0.30 * amp * wob);
      p.headAngle = (drawLeft ? 0.18 : -0.18) + 0.06 * amp * wob;
    } else if (t < tDraw) {                           // settle, aim the wand at the card spot
      const r = smooth(phase(t, tReach, tDraw));
      setArm(lerp(1.45, 1.55, r), lerp(0.40, 0.50, r)); p.headAngle = (drawLeft ? 0.20 : -0.20);
    } else if (t < tClose) {                          // draw-on (hold, slight sway)
      const sway = 0.05 * Math.sin(2 * Math.PI * (t - tDraw) / 1.0);
      setArm(1.55 + sway, 0.50); p.headAngle = (drawLeft ? 0.20 : -0.20);
    } else if (t < tLift) {                           // close loop, present toward the card
      const r = smooth(phase(t, tClose, tLift));
      setArm(lerp(1.55, 1.1, r), lerp(0.50, 0.2, r)); p.headAngle = (drawLeft ? 0.10 : -0.10);
    } else if (t < tHold) {                           // lift & present
      const r = easeOut(phase(t, tLift, tHold));
      setArm(lerp(1.1, 1.5, r), lerp(0.2, 0.5, r)); p.headAngle = 0; p.rootAngle = 0;
    } else {
      setArm(1.45, 0.5);
    }
    return p;
  }

  drawProps(ctx, t, pose, off, payload, paper) {
    if (t < tRaise) return;
    const { rig, skel, propScale, sideSign, screenSize, ink, lw } = this;
    const feet = worldJoint(rig, skel.feet, P.torso, pose, off);
    const hand = worldHand(rig, this.drawLeft, pose, off);
    const shoulder = this.drawLeft ? worldJoint(rig, skel.leftShoulder, P.torso, pose, off)
      : worldJoint(rig, skel.rightShoulder, P.torso, pose, off);

    const w = propScale * 0.58, h = propScale * 0.82;
    const center = fitOnScreen({ x: feet.x + sideSign * propScale * 0.52, y: feet.y - propScale * 0.62 },
      w / 2, h / 2, screenSize, this.fitMargins);
    const baseRect = rect(center.x - w / 2, center.y - h / 2, w, h);
    const perim = rectPts(baseRect, 28);
    const cardStart = perim[0] || center;        // where the draw-on (and the reach) lands

    // The wand held in the hand, pointing away from the shoulder, swung by `swing`.
    const wandLen = propScale * 0.24;
    const wandTip = (swing) => {
      let dx = hand.x - shoulder.x, dy = hand.y - shoulder.y;
      const mag = Math.hypot(dx, dy); if (mag < 1) { dx = 0; dy = -1; } else { dx /= mag; dy /= mag; }
      const sa = Math.sin(swing), ca = Math.cos(swing);
      return { x: hand.x + (dx * ca - dy * sa) * wandLen, y: hand.y + (dx * sa + dy * ca) * wandLen };
    };
    // The wand STICK only (no tip star — the star is the travelling "magic point").
    const wandStick = (tip) => {
      const mid = { x: (hand.x + tip.x) / 2, y: (hand.y + tip.y) / 2 };
      sketch(ctx, [hand, mid, tip], ink, lw * 1.1, { amp: lw * 0.3, seed: 4.4 });
    };

    // ---- Before the draw-on: raise the wand → wave it → the magic reaches OUT to the card ----
    if (t < tDraw) {
      const waveAmp = Math.sin(phase(t, tWave, tReach) * Math.PI);   // 0→1→0 over the wave
      const swing = 0.45 * waveAmp * Math.sin(2 * Math.PI * 1.7 * (t - tWave));
      const tip = wandTip(swing);
      wandStick(tip);
      if (t >= tReach) {
        // a glowing beam extends from the wand tip out to where the card will be painted
        const reach = easeOut(phase(t, tReach, tDraw));
        const end = { x: lerp(tip.x, cardStart.x, reach), y: lerp(tip.y, cardStart.y, reach) };
        sketch(ctx, [tip, end], ink, lw * 0.85, { amp: lw * 0.4, seed: 14 });
        star(ctx, end, propScale * 0.05, ink, lw * 0.85);
        sparkles(ctx, end, propScale * 0.07, 0.7, ink, lw);
      } else {
        // raise + wave: the wand tip glows and flicks
        star(ctx, tip, propScale * 0.05, ink, lw * 0.85);
        sparkles(ctx, tip, propScale * 0.05, 0.4 + 0.5 * waveAmp, ink, lw);
      }
      return;
    }

    // ---- draw-on: the wand projects the card outline from a distance ----
    if (t < tClose) {
      const progress = smooth(phase(t, tDraw, tClose));
      const tip = sketchPartial(ctx, perim, progress, ink, lw, { closed: true, amp: lw * 0.6, seed: 7 });
      const wTip = wandTip(0);
      wandStick(wTip);
      sketch(ctx, [wTip, tip], ink, lw * 0.85, { amp: lw * 0.3, seed: 14 });
      star(ctx, tip, propScale * 0.05, ink, lw * 0.85);
      sparkles(ctx, tip, propScale * 0.05, 0.6, ink, lw);
      return;
    }

    const riseP = easeOut(phase(t, tLift, tHold));
    const dx = -sideSign * propScale * 0.06 * riseP;
    const dy = -propScale * 0.22 * riseP;
    const r = rect(baseRect.x + dx, baseRect.y + dy, baseRect.width, baseRect.height);

    // One card, one border: cardFace owns the outline from the moment the draw-on
    // completes, and `wipe` fills the face + secret in top-down.
    const wipe = t < tFill ? 0 : smooth(phase(t, tFill, tLift));
    cardFace(ctx, r, 1, ink, lw, paper, payload, wipe);
    if (t >= tClose && t < tFill) {
      sparkles(ctx, { x: r.midX, y: r.midY }, propScale * 0.5,
        0.8 * Math.sin(phase(t, tClose, tFill) * Math.PI), ink, lw);
    }
  }
}
