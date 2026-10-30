// Port of RoutineSupport.swift — shared easing + helpers for the animation routines.

import { makePose, worldPoint } from '../rig/model.js';

export const lerp = (a, b, t) => a + (b - a) * t;
export const clamp01 = (x) => Math.min(Math.max(x, 0), 1);
/// Smoothstep on [0,1] — the routines' default easeInOut.
export function smooth(x) { const t = Math.min(Math.max(x, 0), 1); return t * t * (3 - 2 * t); }
/// Decelerating ease (fast→slow).
export function easeOut(x) { const t = clamp01(x); return 1 - (1 - t) * (1 - t); }
/// Accelerating ease (slow→fast) — gravity.
export function easeIn(x) { const t = clamp01(x); return t * t; }

/// Normalized progress through a [start, end] window, clamped to 0…1.
export function phase(t, start, end) {
  if (!(end > start)) return t >= end ? 1 : 0;
  return clamp01((t - start) / (end - start));
}

/// A rest pose with the legs straightened (the routines build on this so legs are
/// always rigid straight segments). (`FigurePose.rest` in AnimationRoutine.swift.)
export function restPose(s) {
  return makePose({ leftShinAngle: s.leftShinStraighten, rightShinAngle: s.rightShinStraighten });
}

/// Project a drawing-space point to screen space at the given pose (minus the canvas offset).
export function worldJoint(rig, p, part, pose, off) {
  const w = worldPoint(rig, p, part, pose);
  return { x: w.x - off.x, y: w.y - off.y };
}

/// The held-prop anchor for one side: the hand under its CARRYING part (see Rig.leftHandPart —
/// the forearm when the drawn arm articulates so the prop rides the animated hand; the torso
/// when the hand was only estimated, so the prop stays ON the static drawn arm instead of
/// swinging away on an invisible arm's FK). Every routine anchors its apparatus through this.
export function worldHand(rig, left, pose, off) {
  return left ? worldJoint(rig, rig.skeleton.leftHand, rig.leftHandPart, pose, off)
    : worldJoint(rig, rig.skeleton.rightHand, rig.rightHandPart, pose, off);
}

/// Keep a prop fully on screen: translate `center` so a box of the given half-extents sits
/// within the screen minus margins. Only SHIFTS — never resizes — so the prop keeps the
/// size the routine chose. If the prop is wider/taller than the available span it's centred
/// on that axis.
export function fitOnScreen(center, halfW, halfH, screen,
                            { sideMargin = 12, topMargin = 56, bottomMargin = 12 } = {}) {
  let x = center.x, y = center.y;
  const loX = sideMargin + halfW, hiX = screen.width - sideMargin - halfW;
  x = loX <= hiX ? Math.min(Math.max(x, loX), hiX) : screen.width / 2;
  const loY = topMargin + halfH, hiY = screen.height - bottomMargin - halfH;
  y = loY <= hiY ? Math.min(Math.max(y, loY), hiY) : (loY + hiY) / 2;
  return { x, y };
}

// The shared opening every routine uses: the figure drops straight down from where it
// was drawn to the floor, lands with a squash, and settles. Mutates `p` in place.
export class DropLand {
  constructor(fall, land, ground, flailArms = true) {
    this.fall = fall; this.land = land; this.ground = ground; this.flailArms = flailArms;
  }
  get done() { return this.fall + this.land; }
  apply(p, t) {
    if (t < this.fall) {
      const f = t / this.fall;
      p.offset.y = this.ground * f * f;               // accelerate
      if (this.flailArms) {
        const drag = easeOut(f);
        p.leftArmAngle = 1.3 * drag;
        p.rightArmAngle = -1.3 * drag;
        p.leftForearmAngle = 0.5 * drag;
        p.rightForearmAngle = -0.5 * drag;
      }
      p.headAngle = -0.15 * f;
    } else if (t < this.fall + this.land) {
      p.offset.y = this.ground;
      const u = (t - this.fall) / this.land;          // 0…1
      const squash = Math.sin(Math.min(u, 1) * Math.PI);  // 0→1→0
      p.scaleY = 1 - 0.20 * squash;
      p.scaleX = 1 + 0.14 * squash;
      const settle = 1 - u;
      p.leftArmAngle = 1.3 * settle * 0.25;
      p.rightArmAngle = -1.3 * settle * 0.25;
      p.headAngle = -0.15 * settle + 0.10 * squash;
    } else {
      p.offset.y = this.ground;
    }
  }
}

// The shared opening EVERY routine plays: drop in → settle → wave hello → WALK to the
// roomier side of the screen. Each routine then performs its trick toward the OPPOSITE
// (now-open) side, starting at `Approach.done`. Returns the pose during the approach, or
// null once it's over (the routine takes over, with the figure planted at `walkDX`).
export const Approach = {
  dropDone: 1.3,      // fall 0.85 + land 0.45
  standDone: 1.8,
  waveDone: 3.0,
  done: 4.7,          // walk ends here; actions start

  pose(t, skel, ground, walkDX) {
    const { dropDone, standDone, waveDone, done } = Approach;
    const p = restPose(skel);
    const drop = new DropLand(0.85, 0.45, ground);
    if (t < drop.done) { drop.apply(p, t); return p; }
    p.offset.y = ground;
    const waveLeft = walkDX < 0;

    if (t < standDone) {
      p.headAngle = 0.05 * Math.sin(phase(t, dropDone, standDone) * Math.PI);
      return p;
    }
    if (t < waveDone) {                                   // wave hello (toward travel side)
      const raise = easeOut(phase(t, standDone, standDone + 0.35));
      const down = 1 - easeIn(phase(t, waveDone - 0.2, waveDone));
      const mag = 2.0 * raise * down;
      const osc = 0.45 * Math.sin(2 * Math.PI * 2.0 * (t - standDone - 0.35)) * down;
      if (waveLeft) { p.leftArmAngle = mag; p.leftForearmAngle = osc; p.headAngle = 0.12 * raise; }
      else { p.rightArmAngle = -mag; p.rightForearmAngle = -osc; p.headAngle = -0.12 * raise; }
      return p;
    }
    if (t < done) {                                       // walk to the roomier side
      const prog = smooth(phase(t, waveDone, done));
      p.offset.x = walkDX * prog;
      const wp = t - waveDone;
      const ramp = smooth(phase(t, waveDone, waveDone + 0.3)) * (1 - smooth(phase(t, done - 0.2, done)));
      const s = Math.sin(2 * Math.PI * 1.5 * wp);
      p.leftLegAngle = 0.34 * ramp * s;
      p.rightLegAngle = -0.34 * ramp * s;
      p.leftArmAngle = -0.34 * ramp * s;
      p.rightArmAngle = 0.34 * ramp * s;
      p.offset.y = ground - 6 * Math.abs(Math.sin(2 * Math.PI * 1.5 * wp)) * ramp;
      p.rootAngle = (walkDX >= 0 ? 0.06 : -0.06) * ramp;
      return p;
    }
    return null;
  },
};
