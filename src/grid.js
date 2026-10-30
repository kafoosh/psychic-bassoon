// Port of ValueGrid.swift — the VALUE half of the input. The paper below the toolbar is
// split into a 4×4 grid, ruled like a sketchbook so it reads as page texture, not a keypad:
//
//      ┌────┬────┬────┬────┐
//      │ A  │ 2  │ 3  │ 4  │   row 0
//      │ 5  │ 6  │ 7  │ 8  │   row 1
//      │ 9  │ 10 │ J  │ Q  │   row 2
//      │ K  │ K  │ K  │ K  │   row 3 — the whole row is King
//      └────┴────┴────┴────┘
//
// Geometry + hit math live ONLY here, shared by the capture and the ruling.

import { LG } from './palette.js';

export const ROWS = 4, COLS = 4;

export class ValueGrid {
  /// `rect` = {x, y, width, height} in SCREEN coordinates.
  constructor(rect) { this.rect = rect; }

  get cellW() { return this.rect.width / COLS; }
  get cellH() { return this.rect.height / ROWS; }

  /// The card value (1…13) a touch at `p` selects, or null outside the grid.
  valueAt(p) {
    const r = this.rect;
    if (!(r.width > 0 && r.height > 0)) return null;
    if (p.x < r.x || p.x > r.x + r.width || p.y < r.y || p.y > r.y + r.height) return null;
    const col = Math.min(Math.trunc((p.x - r.x) / this.cellW), COLS - 1);
    const row = Math.min(Math.trunc((p.y - r.y) / this.cellH), ROWS - 1);
    return row === ROWS - 1 ? 13 : row * COLS + col + 1;
  }
}

/// The ruled sketchbook page (ValueGridBackground): a faint minor grid over the whole sheet,
/// with the 4×4 value lines a hair stronger and continued edge to edge, so nothing on the
/// page singles out where the grid ends or that the bottom row is King.
export function drawRuling(ctx, size, grid) {
  const r = grid.rect;
  if (!(r.width > 0 && r.height > 0)) return;
  const cellW = grid.cellW, cellH = grid.cellH;
  const minor = cellW / 4;
  // Minor rows per cell rounded so the major lines land ON a minor line.
  const minorRows = Math.max(1, Math.round(cellH / minor));
  const minorH = cellH / minorRows;

  ctx.save();
  ctx.strokeStyle = LG.decor;
  ctx.globalAlpha = 0.07;
  ctx.lineWidth = 0.5;
  ctx.beginPath();
  // Verticals across the whole sheet, phase-aligned to the grid.
  for (let x = r.x % minor; x <= size.width; x += minor) { ctx.moveTo(x, 0); ctx.lineTo(x, size.height); }
  // Horizontals, phase-aligned to the grid top.
  for (let y = r.y % minorH; y <= size.height; y += minorH) { ctx.moveTo(0, y); ctx.lineTo(size.width, y); }
  ctx.stroke();

  // The major lines CONTINUE across the whole sheet at the same pitch — verticals top to
  // bottom, horizontals repeating above and below the value rows.
  ctx.globalAlpha = 0.08;
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let c = 1; c < COLS; c++) {
    const gx = r.x + c * cellW;
    ctx.moveTo(gx, 0); ctx.lineTo(gx, size.height);
  }
  for (let gy = r.y % cellH; gy <= size.height; gy += cellH) { ctx.moveTo(0, gy); ctx.lineTo(size.width, gy); }
  ctx.stroke();
  ctx.restore();
}

/// The paper's touch surface (GridInputCatcher): a 1-finger TAP, or the touch-down point of
/// a 1-finger DRAG → `onValuePoint` (live on the first touch). A second finger joining the
/// same gesture cancels it (the Swift pan caps at one touch), restoring the prior capture.
export function attachCatcher(el, { onValuePoint, onCancel }) {
  const active = new Set();
  let token = null;
  el.addEventListener('pointerdown', (e) => {
    active.add(e.pointerId);
    if (active.size === 1) {
      token = onValuePoint({ x: e.clientX, y: e.clientY });
    } else if (token !== null) {
      onCancel(token);
      token = null;
    }
  });
  const up = (e) => { active.delete(e.pointerId); if (active.size === 0) token = null; };
  el.addEventListener('pointerup', up);
  el.addEventListener('pointercancel', up);
}
