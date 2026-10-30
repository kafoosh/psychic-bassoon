// The drawing surface (replaces PencilKit): pointer-event pen + eraser, a stroke model the
// fitter consumes directly, a snapshot undo stack, and quadratic-midpoint smoothed
// rendering. Only the first pointer draws; multi-touch is ignored.
//
// The eraser works on the vector strokes: it cuts away the points it passes over and
// splits a stroke where it was cut, so what is left is still plain polylines for the rig.

import { LG } from './palette.js';

export const PEN_WIDTH = 5;
const ERASER_R = 12;

export class Drawing {
  constructor(canvas, getCtx, { onChange } = {}) {
    this.canvas = canvas;
    this.getCtx = getCtx;
    this.onChange = onChange || (() => {});
    /** @type {{points:{x:number,y:number}[], width:number, color:string}[]} */
    this.strokes = [];
    this.history = [];          // snapshots of `strokes` before each change (undo)
    this.live = null;
    this.pointerId = null;
    this.enabled = false;
    this.tool = 'pen';          // pen | eraser
    this.color = LG.ink;
    this.scale = 1;             // page rescale since the page was cleared (pen width follows)
    this.eraserAt = null;

    canvas.addEventListener('pointerdown', (e) => this.down(e));
    canvas.addEventListener('pointermove', (e) => this.move(e));
    canvas.addEventListener('pointerup', (e) => this.up(e));
    canvas.addEventListener('pointercancel', (e) => this.up(e));
  }

  local(e) {
    const r = this.canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  snapshot() {
    this.history.push(this.strokes.map((s) => ({ ...s, points: s.points.slice() })));
    if (this.history.length > 200) this.history.shift();
  }

  down(e) {
    if (!this.enabled || this.pointerId !== null) return;     // first pointer only
    this.pointerId = e.pointerId;
    try { this.canvas.setPointerCapture(e.pointerId); } catch { /* synthetic events */ }
    const p = this.local(e);
    if (this.tool === 'eraser') {
      this.snapshot();
      this.erasedAny = false;
      this.lastErase = p;
      this.eraseAlong(p, p);
    } else {
      this.live = { points: [p], width: PEN_WIDTH * this.scale, color: this.color };
    }
    this.render();
  }

  move(e) {
    if (e.pointerId !== this.pointerId) return;
    const evs = typeof e.getCoalescedEvents === 'function' ? e.getCoalescedEvents() : [];
    for (const ce of (evs.length ? evs : [e])) {
      const p = this.local(ce);
      if (this.tool === 'eraser') {
        this.eraseAlong(this.lastErase, p);
        this.lastErase = p;
      } else if (this.live) {
        const last = this.live.points[this.live.points.length - 1];
        if (Math.hypot(p.x - last.x, p.y - last.y) >= 0.75) this.live.points.push(p);
      }
    }
    this.render();
  }

  up(e) {
    if (e.pointerId !== this.pointerId) return;
    this.pointerId = null;
    if (this.tool === 'eraser') {
      this.eraserAt = null;
      if (!this.erasedAny) this.history.pop();      // nothing was erased: no undo step
      this.render();
      if (this.erasedAny) this.onChange();
      return;
    }
    if (this.live) {
      if (e.type === 'pointerup') this.live.points.push(this.local(e));
      this.snapshot();
      this.strokes.push(this.live);
      this.live = null;
      this.render();
      this.onChange();
    }
  }

  /// Erase every stroke point within the eraser radius of the segment a→b, splitting
  /// strokes where they were cut. Strokes are densified first so a sparse fast line
  /// still gets cut where the eraser crosses it.
  eraseAlong(a, b) {
    this.eraserAt = b;
    const r = ERASER_R * Math.max(this.scale, 0.5);
    const near = (p) => distToSegment(p, a, b) <= r + 0.5;
    const out = [];
    let changed = false;
    for (const s of this.strokes) {
      const pts = densify(s.points, 2);
      if (!pts.some(near)) { out.push(s); continue; }
      changed = true;
      let run = [];
      for (const p of pts) {
        if (near(p)) { if (run.length > 1) out.push({ ...s, points: run }); run = []; }
        else run.push(p);
      }
      if (run.length > 1) out.push({ ...s, points: run });
    }
    if (changed) { this.strokes = out; this.erasedAny = true; }
  }

  /// Finish whatever the pointer is doing (mode change mid-stroke).
  cancelLive() {
    this.pointerId = null;
    this.eraserAt = null;
    if (this.live) { this.snapshot(); this.strokes.push(this.live); this.live = null; this.onChange(); }
    this.render();
  }

  undo() {
    if (this.history.length) { this.strokes = this.history.pop(); this.render(); this.onChange(); }
    else if (this.strokes.length) { this.strokes = []; this.render(); this.onChange(); }
  }

  clear() {
    this.strokes = [];
    this.history = [];
    this.live = null;
    this.pointerId = null;
    this.eraserAt = null;
    this.scale = 1;
    this.render();
    this.onChange();
  }

  setStrokes(strokes) { this.strokes = strokes; this.history = []; this.render(); this.onChange(); }

  /// Uniformly rescale the page content (the page was resized): p' = p·s + (dx, dy).
  transform(s, dx, dy) {
    const map = (st) => ({ ...st, width: st.width * s, points: st.points.map((p) => ({ x: p.x * s + dx, y: p.y * s + dy })) });
    this.strokes = this.strokes.map(map);
    this.history = this.history.map((snap) => snap.map(map));
    if (this.live) this.live = map(this.live);
    this.scale *= s;
    this.render();
  }

  render() {
    const ctx = this.getCtx();
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    ctx.restore();
    for (const s of this.strokes) strokeSmooth(ctx, s);
    if (this.live) strokeSmooth(ctx, this.live);
    if (this.eraserAt) {
      ctx.save();
      ctx.beginPath();
      ctx.arc(this.eraserAt.x, this.eraserAt.y, ERASER_R * Math.max(this.scale, 0.5), 0, Math.PI * 2);
      ctx.strokeStyle = 'rgba(28, 27, 25, 0.35)';
      ctx.lineWidth = 1.5;
      ctx.stroke();
      ctx.restore();
    }
  }
}

function densify(pts, step) {
  if (pts.length < 2) return pts;
  const out = [pts[0]];
  for (let i = 1; i < pts.length; i++) {
    const a = pts[i - 1], b = pts[i];
    const n = Math.max(1, Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) / step));
    for (let k = 1; k <= n; k++) out.push({ x: a.x + (b.x - a.x) * k / n, y: a.y + (b.y - a.y) * k / n });
  }
  return out;
}

function distToSegment(p, a, b) {
  const abx = b.x - a.x, aby = b.y - a.y;
  const len2 = abx * abx + aby * aby;
  if (len2 < 1e-6) return Math.hypot(p.x - a.x, p.y - a.y);
  const t = Math.min(Math.max(((p.x - a.x) * abx + (p.y - a.y) * aby) / len2, 0), 1);
  return Math.hypot(p.x - (a.x + abx * t), p.y - (a.y + aby * t));
}

/// Quadratic-midpoint smoothing: curve through the midpoints, using each sample as the
/// control point. A tap (all points within a pixel) is painted as a round dot — the canvas
/// drops zero-length segments, so a stroked "line" of coincident points would show nothing
/// while drawing yet appear once the rig renders it.
export function strokeSmooth(ctx, s) {
  const pts = s.points;
  if (!pts.length) return;
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  for (const p of pts) { minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x); minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y); }
  if (maxX - minX < 1 && maxY - minY < 1) {
    ctx.save();
    ctx.beginPath();
    ctx.arc((minX + maxX) / 2, (minY + maxY) / 2, s.width / 2, 0, Math.PI * 2);
    ctx.fillStyle = s.color;
    ctx.fill();
    ctx.restore();
    return;
  }
  ctx.save();
  ctx.strokeStyle = s.color;
  ctx.lineWidth = s.width;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.beginPath();
  ctx.moveTo(pts[0].x, pts[0].y);
  if (pts.length === 2) {
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
