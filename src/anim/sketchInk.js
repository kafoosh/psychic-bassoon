// Port of SketchInk.swift — shared hand-drawn drawing primitives, used by every animation
// routine so all props read as loose outlines in the figure's OWN ink colour. The wobble is
// deterministic (keyed on vertex index + seed) so it's stable frame-to-frame — no shimmer.
//
// Canvas 2D notes: a SwiftUI `var c = ctx; c.opacity = x` copy becomes save() / multiply
// globalAlpha / restore(), so nested opacities multiply like they do in a GraphicsContext.

import { rect as mkRect } from '../rig/model.js';
import { det } from '../palette.js';
import { drawReveal } from '../reveal.js';

export { det };

export function roundedRectPath(ctx, r, radius) {
  const rad = Math.max(0, Math.min(radius, r.width / 2, r.height / 2));
  ctx.beginPath();
  ctx.moveTo(r.x + rad, r.y);
  ctx.lineTo(r.x + r.width - rad, r.y);
  ctx.arcTo(r.x + r.width, r.y, r.x + r.width, r.y + rad, rad);
  ctx.lineTo(r.x + r.width, r.y + r.height - rad);
  ctx.arcTo(r.x + r.width, r.y + r.height, r.x + r.width - rad, r.y + r.height, rad);
  ctx.lineTo(r.x + rad, r.y + r.height);
  ctx.arcTo(r.x, r.y + r.height, r.x, r.y + r.height - rad, rad);
  ctx.lineTo(r.x, r.y + rad);
  ctx.arcTo(r.x, r.y, r.x + rad, r.y, rad);
  ctx.closePath();
}

/// Stroke a polyline (or closed polygon) with a small hand-drawn wobble.
export function sketch(ctx, pts, ink, lw, { closed = false, amp = 0, seed = 1, opacity = 1 } = {}) {
  if (pts.length < 2) return;
  ctx.save();
  ctx.globalAlpha *= opacity;
  const j = (i, p) => [p.x + det(i, seed) * amp, p.y + det(i, seed + 9.7) * amp];
  ctx.beginPath();
  ctx.moveTo(...j(0, pts[0]));
  for (let i = 1; i < pts.length; i++) ctx.lineTo(...j(i, pts[i]));
  if (closed) ctx.lineTo(...j(0, pts[0]));
  ctx.strokeStyle = ink;
  ctx.lineWidth = lw;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.stroke();
  ctx.restore();
}

/// A partially-drawn polyline: only the first `progress` (0…1) of its length is shown.
/// Used for "draw-on" reveals (the Painter routine). Returns the drawn tip.
export function sketchPartial(ctx, pts, progress, ink, lw, { closed = false, amp = 0, seed = 1 } = {}) {
  const full = pts.slice();
  if (closed && pts.length) full.push(pts[0]);
  if (full.length < 2) return pts[0] || { x: 0, y: 0 };
  // total length
  const seg = [];
  let total = 0;
  for (let i = 1; i < full.length; i++) {
    const d = Math.hypot(full[i].x - full[i - 1].x, full[i].y - full[i - 1].y);
    seg.push(d); total += d;
  }
  const target = Math.max(0, Math.min(progress, 1)) * total;
  let acc = 0;
  const out = [full[0]];
  let tip = full[0];
  for (let i = 1; i < full.length; i++) {
    const d = seg[i - 1];
    if (acc + d <= target) {
      out.push(full[i]); tip = full[i]; acc += d;
    } else {
      const f = d > 0 ? (target - acc) / d : 0;
      tip = { x: full[i - 1].x + (full[i].x - full[i - 1].x) * f,
        y: full[i - 1].y + (full[i].y - full[i - 1].y) * f };
      out.push(tip);
      break;
    }
  }
  sketch(ctx, out, ink, lw, { closed: false, amp, seed });
  return tip;
}

export function rectPts(r, perEdge = 3) {
  const corners = [{ x: r.minX, y: r.minY }, { x: r.maxX, y: r.minY },
    { x: r.maxX, y: r.maxY }, { x: r.minX, y: r.maxY }];
  const pts = [];
  for (let i = 0; i < 4; i++) {
    const a = corners[i], b = corners[(i + 1) % 4];
    for (let k = 0; k < perEdge; k++) {
      const f = k / perEdge;
      pts.push({ x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f });
    }
  }
  return pts;
}

/// Points of an N-sided circle/ellipse (for sketchy round shapes).
export function ovalPts(center, rx, ry, n = 20) {
  const out = [];
  for (let k = 0; k < n; k++) {
    const a = k / n * 2 * Math.PI;
    out.push({ x: center.x + rx * Math.cos(a), y: center.y + ry * Math.sin(a) });
  }
  return out;
}

export function star(ctx, center, radius, ink, lw, opacity = 1) {
  const inner = radius * 0.4;
  const pts = [];
  for (let i = 0; i < 8; i++) {
    const r = (i % 2 === 0) ? radius : inner;
    const a = -Math.PI / 2 + i * (Math.PI / 4);
    pts.push({ x: center.x + r * Math.cos(a), y: center.y + r * Math.sin(a) });
  }
  sketch(ctx, pts, ink, lw, { closed: true, amp: radius * 0.10, seed: 6.6, opacity });
}

export function sparkles(ctx, c, spread, g, ink, lw) {
  const offs = [[-0.5, -0.2], [0.45, -0.35], [0.1, -0.62], [-0.28, 0.22], [0.55, 0.12], [-0.6, -0.5]];
  ctx.save();
  ctx.globalAlpha *= g;
  ctx.strokeStyle = ink;
  ctx.lineWidth = Math.max(1.5, lw * 0.5);
  ctx.lineCap = 'round';
  offs.forEach(([ox, oy], i) => {
    const p = { x: c.x + ox * spread, y: c.y + oy * spread };
    const r = spread * 0.10 * (0.6 + 0.4 * Math.sin(i * 1.7));
    const d = r * 0.6;
    ctx.beginPath();
    ctx.moveTo(p.x - r, p.y); ctx.lineTo(p.x + r, p.y);
    ctx.moveTo(p.x, p.y - r); ctx.lineTo(p.x, p.y + r);
    ctx.moveTo(p.x - d, p.y - d); ctx.lineTo(p.x + d, p.y + d);
    ctx.moveTo(p.x - d, p.y + d); ctx.lineTo(p.x + d, p.y - d);
    ctx.stroke();
  });
  ctx.restore();
}

/// A wand from `hand`, pointing away from `shoulder`, with a star tip.
export function wand(ctx, hand, shoulder, length, swing, opacity, ink, lw) {
  let dx = hand.x - shoulder.x, dy = hand.y - shoulder.y;
  const mag = Math.hypot(dx, dy);
  if (mag < 1) { dx = 0; dy = -1; } else { dx /= mag; dy /= mag; }
  const sa = Math.sin(swing), ca = Math.cos(swing);
  const rdx = dx * ca - dy * sa, rdy = dx * sa + dy * ca;
  const tip = { x: hand.x + rdx * length, y: hand.y + rdy * length };
  const mid = { x: hand.x + rdx * length * 0.5, y: hand.y + rdy * length * 0.5 };
  sketch(ctx, [hand, mid, tip], ink, lw, { amp: length * 0.03, seed: 4.4, opacity });
  star(ctx, tip, length * 0.17, ink, lw * 0.85, opacity);
}

export function insetRect(r, dx, dy) {
  return mkRect(r.x + dx, r.y + dy, r.width - dx * 2, r.height - dy * 2);
}

/// The conjured paper + the secret on it. Masks whatever is behind with the canvas
/// colour so the figure doesn't show through, then sketches the outline and content.
/// `wipe` (0…1) reveals the paper + secret top-down (the Painter's fill-in) while the
/// border always draws whole — a partially-materialized card still has ONE outline.
export function cardFace(ctx, r, opacity, ink, lw, paper, payload, wipe = 1) {
  const clipWipe = () => {
    ctx.beginPath();
    ctx.rect(r.minX - lw, r.minY - lw, r.width + lw * 2, (r.height + lw * 2) * Math.max(wipe, 0));
    ctx.clip();
  };
  if (wipe > 0) {
    ctx.save();
    ctx.globalAlpha *= opacity;
    if (wipe < 1) clipWipe();
    roundedRectPath(ctx, r, r.width * 0.06);
    ctx.fillStyle = paper;
    ctx.fill();
    ctx.restore();
  }
  sketch(ctx, rectPts(r, 4), ink, lw, { closed: true, amp: r.width * 0.025, seed: 2.2, opacity });
  if (payload && wipe > 0) {
    ctx.save();
    if (wipe < 1) clipWipe();
    const inner = insetRect(r, r.width * 0.09, r.height * 0.07);
    drawReveal(ctx, inner, payload, ink, opacity);
    ctx.restore();
  }
}
