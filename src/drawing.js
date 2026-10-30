// The drawing surface (replaces PencilKit): pointer-event pen input, a stroke model the
// fitter consumes directly, an undo stack, and quadratic-midpoint smoothed rendering.
// Only the first pointer draws; multi-touch is ignored.

import { LG } from './palette.js';

export const PEN_WIDTH = 5;

export class Drawing {
  constructor(canvas, getCtx, { onChange } = {}) {
    this.canvas = canvas;
    this.getCtx = getCtx;
    this.onChange = onChange || (() => {});
    /** @type {{points:{x:number,y:number}[], width:number, color:string}[]} */
    this.strokes = [];
    this.live = null;
    this.pointerId = null;
    this.enabled = false;

    canvas.addEventListener('pointerdown', (e) => this.down(e));
    canvas.addEventListener('pointermove', (e) => this.move(e));
    canvas.addEventListener('pointerup', (e) => this.up(e));
    canvas.addEventListener('pointercancel', (e) => this.up(e));
  }

  local(e) {
    const r = this.canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  down(e) {
    if (!this.enabled || this.pointerId !== null) return;     // first pointer only
    this.pointerId = e.pointerId;
    try { this.canvas.setPointerCapture(e.pointerId); } catch { /* synthetic events */ }
    this.live = { points: [this.local(e)], width: PEN_WIDTH, color: LG.ink };
    this.render();
  }

  move(e) {
    if (e.pointerId !== this.pointerId || !this.live) return;
    const evs = typeof e.getCoalescedEvents === 'function' ? e.getCoalescedEvents() : [];
    for (const ce of (evs.length ? evs : [e])) {
      const p = this.local(ce);
      const last = this.live.points[this.live.points.length - 1];
      if (Math.hypot(p.x - last.x, p.y - last.y) >= 0.75) this.live.points.push(p);
    }
    this.render();
  }

  up(e) {
    if (e.pointerId !== this.pointerId) return;
    this.pointerId = null;
    if (this.live) {
      if (e.type === 'pointerup') this.live.points.push(this.local(e));
      this.strokes.push(this.live);
      this.live = null;
      this.render();
      this.onChange();
    }
  }

  /// Abandon an in-progress stroke (mode change mid-stroke).
  cancelLive() {
    this.pointerId = null;
    if (this.live) { this.strokes.push(this.live); this.live = null; this.render(); this.onChange(); }
  }

  undo() {
    if (this.strokes.length) { this.strokes.pop(); this.render(); this.onChange(); }
  }

  clear() {
    this.strokes = [];
    this.live = null;
    this.pointerId = null;
    this.render();
    this.onChange();
  }

  setStrokes(strokes) { this.strokes = strokes; this.render(); this.onChange(); }

  render() {
    const ctx = this.getCtx();
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    ctx.restore();
    for (const s of this.strokes) strokeSmooth(ctx, s);
    if (this.live) strokeSmooth(ctx, this.live);
  }
}

/// Quadratic-midpoint smoothing: curve through the midpoints, using each sample as the
/// control point. A one-point stroke is painted as a dot by the round cap.
export function strokeSmooth(ctx, s) {
  const pts = s.points;
  if (!pts.length) return;
  ctx.save();
  ctx.strokeStyle = s.color;
  ctx.lineWidth = s.width;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.beginPath();
  ctx.moveTo(pts[0].x, pts[0].y);
  if (pts.length === 1) {
    ctx.lineTo(pts[0].x + 0.01, pts[0].y);
  } else if (pts.length === 2) {
    ctx.lineTo(pts[1].x, pts[1].y);
  } else {
    for (let i = 1; i < pts.length - 1; i++) {
      const mx = (pts[i].x + pts[i + 1].x) / 2, my = (pts[i].y + pts[i + 1].y) / 2;
      ctx.quadraticCurveTo(pts[i].x, pts[i].y, mx, my);
    }
    const last = pts[pts.length - 1];
    ctx.lineTo(last.x, last.y);
  }
  ctx.stroke();
  ctx.restore();
}
