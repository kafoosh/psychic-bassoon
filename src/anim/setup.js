// Port of AnimationRoutine.swift — RoutineSetup.make (chrome-aware floor + capped
// propScale) and AnimationFactory. A routine is an object with
// `{ totalDuration, pose(t), drawProps(ctx, t, pose, originOffset, payload, paper) }`.

import { ClassicRoutine } from './routines/classic.js';
import { TopHatRoutine } from './routines/topHat.js';
import { FishingRoutine } from './routines/fishing.js';
import { PainterRoutine } from './routines/painter.js';
import { BalloonRoutine } from './routines/balloon.js';

/// The concrete, directly-playable routines. (The web build always plays a random one.)
export const SLOTS = ['classic', 'topHat', 'fishing', 'painter', 'balloon'];

/// Build the setup from the rigged figure and the live canvas geometry, so prop
/// sizing/placement is computed in exactly one place.
///
/// Key idea: after the figure walks to the roomier side, props are drawn on the
/// OPPOSITE (open) side, offset from the figure's feet. So `propScale` is sized to the
/// room actually left between the *planted* feet and the open-side edge — guaranteeing
/// the reveal fits the screen no matter where (or how big) the figure was drawn.
export function makeSetup(rig, canvasBounds, contentOffset = { x: 0, y: 0 },
                          topInset = 56, bottomInset = 90) {
  const width = canvasBounds.width;
  const offX = contentOffset.x;

  // Drop from the drawn spot to a floor just above the bottom chrome (so the planted
  // feet + scissoring legs clear it). Floor is chrome-aware, not a hardcoded 96.
  const viewport = canvasBounds.height;
  const footClear = 6;
  const floorScreenY = Math.max(viewport * 0.5, viewport - bottomInset - footClear);
  const floorY = contentOffset.y + floorScreenY;
  const drop = Math.max(0, floorY - rig.skeleton.bbox.maxY);

  // Walk to the roomier side; perform toward the opposite (open) side.
  const figCenterX = rig.skeleton.bbox.midX;
  const leftRoom = figCenterX - offX;
  const rightRoom = (offX + width) - figCenterX;
  const goRight = rightRoom >= leftRoom;
  const sideSign = goRight ? -1 : 1;                 // open side = opposite the walk
  const targetX = offX + width * (goRight ? 0.68 : 0.32);
  const walkDX = targetX - figCenterX;

  // Size the props so they fit BOTH ways:
  //  • horizontally — room from the planted FEET to the open-side edge (props reach out
  //    sideways by up to ~0.90·propScale);
  //  • vertically — headroom from the feet up to the header (the reveal card rises by up
  //    to ~1.15·propScale).
  const feetScreenX = rig.skeleton.feet.x + walkDX - offX;
  const openRoom = goRight ? feetScreenX : (width - feetScreenX);
  const margin = 14;
  const hReach = 0.90;                               // worst-case sideways prop reach / propScale
  const vReach = 1.15;                               // worst-case upward card reach / propScale
  const headroom = floorScreenY - topInset;
  const hCap = (openRoom - margin) / hReach;
  const vCap = (headroom - margin) / vReach;
  const maxProp = width * 0.80;
  // Web edition: props are sized to the FIGURE (≈0.8 × its drawn height), so a small little
  // guy gets a small wand / hat / card and a big one a big one — still capped by the room
  // left on the open side and the headroom, so they always fit the playfield.
  // (A floor keeps the revealed card legible on a tiny drawing.)
  const figureCap = Math.max(rig.skeleton.bbox.height * 0.8, 110);
  const propScale = Math.max(40, Math.min(maxProp, hCap, vCap, figureCap));

  return {
    rig, dropDistance: drop, walkDX, sideSign, propScale,
    screenSize: { width: canvasBounds.width, height: canvasBounds.height },
    topInset, bottomInset,
  };
}

/// `AnimationFactory.make(slot, setup)`.
export function makeRoutine(slot, setup) {
  switch (slot) {
    case 'classic': return new ClassicRoutine(setup);
    case 'topHat': return new TopHatRoutine(setup);
    case 'fishing': return new FishingRoutine(setup);
    case 'painter': return new PainterRoutine(setup);
    case 'balloon': return new BalloonRoutine(setup);
    default: return makeRoutine(randomSlot(), setup);   // re-rolls a concrete routine each reveal
  }
}

export function randomSlot() {
  return SLOTS[Math.floor(Math.random() * SLOTS.length)];
}
