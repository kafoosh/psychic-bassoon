// Port of ClassicRoutine.swift — drop in → wave → walk to the roomier side → pull & flick a
// wand → a closed box floats in from the OPEN side → it opens → the paper rises out → it
// flips over to reveal the secret.

import { P, rect } from '../../rig/model.js';
import { Approach, restPose, easeOut, phase, lerp, worldHand, worldJoint, fitOnScreen } from '../support.js';
import { sketch, rectPts, wand, sparkles, cardFace, roundedRectPath, insetRect } from '../sketchInk.js';
import { RoutineBase } from '../base.js';

// Action beats (after the shared approach).
const tWand = 4.7, tFlick = 5.7, tBox = 6.5, tOpen = 8.1, tRise = 9.1, tFlip = 10.2;

export class ClassicRoutine extends RoutineBase {
  constructor(s) { super(s); this.totalDuration = 12.0; }
  get boxLeft() { return this.sideSign < 0; }

  pose(t) {
    const ap = Approach.pose(t, this.skel, this.dropDistance, this.walkDX);
    if (ap) return ap;
    const p = restPose(this.skel);
    p.offset = { x: this.walkDX, y: this.dropDistance };

    const raise = easeOut(phase(t, tWand, tFlick));
    const flick = Math.sin(Math.PI * phase(t, tFlick, tBox)) * 0.30;
    const idle = t > tBox ? 0.04 * Math.sin((t - tBox) * 2) : 0;
    const mag = 1.6 * raise + flick + idle;
    const fore = 0.25 * raise;
    if (this.boxLeft) {
      p.leftArmAngle = mag; p.leftForearmAngle = fore; p.headAngle = 0.14 * raise;
    } else {
      p.rightArmAngle = -mag; p.rightForearmAngle = -fore; p.headAngle = -0.14 * raise;
    }
    return p;
  }

  drawProps(ctx, t, pose, off, payload, paper) {
    if (t < tWand) return;
    const { rig, skel, propScale, sideSign, screenSize, ink, lw } = this;
    const hand = worldHand(rig, this.boxLeft, pose, off);
    const shoulder = this.boxLeft ? worldJoint(rig, skel.leftShoulder, P.torso, pose, off)
      : worldJoint(rig, skel.rightShoulder, P.torso, pose, off);
    const feet = worldJoint(rig, skel.feet, P.torso, pose, off);

    const wandOp = easeOut(phase(t, tWand, tWand + 0.3));
    wand(ctx, hand, shoulder, propScale * 0.30, 0, wandOp, ink, lw * 1.1);
    if (t >= tFlick && t < tBox) {
      const g = Math.sin(Math.PI * phase(t, tFlick, tBox));
      const dx = hand.x - shoulder.x, dy = hand.y - shoulder.y;
      const m = Math.max(Math.hypot(dx, dy), 1);
      const tip = { x: hand.x + dx / m * propScale * 0.30, y: hand.y + dy / m * propScale * 0.30 };
      sparkles(ctx, tip, propScale * 0.12, g, ink, lw);
    }

    if (t < tBox) return;

    const boxW = propScale * 0.42, boxH = propScale * 0.34;
    const targetX = feet.x + sideSign * propScale * 0.55;
    const targetY = feet.y - propScale * 0.28;
    const p1 = phase(t, tBox, tOpen);
    const startX = sideSign > 0 ? screenSize.width + boxW : -boxW;
    const boxCX = lerp(startX, targetX, easeOut(p1));
    const boxCY = targetY + Math.sin(p1 * Math.PI) * (-propScale * 0.05);
    const boxOp = easeOut(Math.min(p1 / 0.4, 1));
    const boxRect = rect(boxCX - boxW / 2, boxCY - boxH / 2, boxW, boxH);
    const lidOpen = easeOut(phase(t, tOpen, tRise));

    this.drawLid(ctx, boxRect, lidOpen, boxOp);

    if (t >= tRise) {
      const mouthY = boxRect.minY;
      const riseP = easeOut(phase(t, tRise, tFlip));
      const cardW = propScale * 0.30, cardH = propScale * 0.42;
      const cardCenter = fitOnScreen({ x: boxRect.midX, y: mouthY - riseP * propScale * 0.46 },
        cardW / 2, cardH / 2, screenSize, this.fitMargins);
      const cardCX = cardCenter.x;
      const cardCY = cardCenter.y;
      if (t < tFlip) {
        const sy = lerp(0.2, 1, easeOut(phase(t, tRise, tRise + 0.25)));
        const r = rect(cardCX - cardW / 2, cardCY - cardH * sy / 2, cardW, cardH * sy);
        this.drawBlankCard(ctx, r, 1, paper);
      } else {
        const p2 = phase(t, tFlip, tFlip + 1.2);
        const wf = Math.max(Math.abs(Math.cos(p2 * Math.PI)), 0.02);
        const r = rect(cardCX - cardW * wf / 2, cardCY - cardH / 2, cardW * wf, cardH);
        if (p2 < 0.5) {
          this.drawBlankCard(ctx, r, 1, paper);
        } else {
          cardFace(ctx, r, 1, ink, lw, paper, payload);
          if (p2 < 0.7) {
            sparkles(ctx, { x: cardCX, y: cardCY }, propScale * 0.22,
              Math.sin(Math.PI * (p2 - 0.5) / 0.2), ink, lw);
          }
        }
      }
    }

    this.drawBoxBody(ctx, boxRect, boxOp);
  }

  // MARK: Box / card drawing

  drawBoxBody(ctx, box, opacity) {
    const { ink, lw } = this;
    sketch(ctx, rectPts(box), ink, lw, { closed: true, amp: box.height * 0.05, seed: 3.1, opacity });
    sketch(ctx, [{ x: box.midX, y: box.minY }, { x: box.midX, y: box.maxY }],
      ink, lw * 0.8, { amp: box.height * 0.04, seed: 5.7, opacity });
  }

  drawLid(ctx, box, open, opacity) {
    const lidH = box.height * 0.30;
    const lift = box.height * (0.10 + open * 0.95);
    const w = box.width * 1.06;
    const bottomY = box.minY - lift;
    const pts = [{ x: box.midX - w / 2, y: bottomY }, { x: box.midX + w / 2, y: bottomY },
      { x: box.midX + w / 2, y: bottomY - lidH }, { x: box.midX - w / 2, y: bottomY - lidH }];
    const dense = [];
    for (let i = 0; i < 4; i++) {
      const a = pts[i], b = pts[(i + 1) % 4];
      for (let k = 0; k < 3; k++) { const f = k / 3; dense.push({ x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f }); }
    }
    sketch(ctx, dense, this.ink, this.lw, { closed: true, amp: box.height * 0.05, seed: 7.3, opacity });
  }

  drawBlankCard(ctx, r, opacity, paper) {
    if (!(r.width > 1)) return;
    const { ink, lw } = this;
    ctx.save();
    ctx.globalAlpha *= opacity;
    roundedRectPath(ctx, r, r.width * 0.08);
    ctx.fillStyle = paper;
    ctx.fill();
    ctx.restore();
    sketch(ctx, rectPts(r, 4), ink, lw, { closed: true, amp: r.width * 0.03, seed: 2.2, opacity });
    const inset = insetRect(r, r.width * 0.22, r.height * 0.3);
    sketch(ctx, [{ x: inset.minX, y: inset.minY }, { x: inset.maxX, y: inset.minY }],
      ink, lw * 0.7, { amp: r.width * 0.02, seed: 12.5, opacity: opacity * 0.7 });
    sketch(ctx, [{ x: inset.minX, y: inset.maxY }, { x: inset.maxX, y: inset.maxY }],
      ink, lw * 0.7, { amp: r.width * 0.02, seed: 13.1, opacity: opacity * 0.7 });
  }
}
