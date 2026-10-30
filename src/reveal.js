// Port of RevealContent.swift (card path only) — draws the secret onto the conjured paper
// as a playing-card face in a handwriting-looking style:
//   • values in Gochi Hand, laid out per glyph by a port of `drawLooseText` (deterministic
//     position/rotation wobble, same seeds);
//   • suits (corner + centre pip) as HAND-SKETCHED vector paths — Gochi Hand has no
//     ♣♥♦♠ and a system-font fallback would look typed;
//   • the bottom-right index rotated 180° about its corner, like a real playing card.
// Pure Canvas 2D drawing so it composites into the same stage as the figure and props.

import { det } from './palette.js';

export const FONT_FAMILY = '"Gochi Hand"';

/// Classic playing-card red, used for hearts/diamonds regardless of the figure's ink.
const CARD_RED = 'rgb(217, 41, 41)';    // rgb(0.85, 0.16, 0.16)

export const SUITS = ['clubs', 'hearts', 'spades', 'diamonds'];   // CHaSeD
export const isRed = (suit) => suit === 'hearts' || suit === 'diamonds';

export function valueLabel(v) {
  switch (v) {
    case 1: return 'A';
    case 11: return 'J';
    case 12: return 'Q';
    case 13: return 'K';
    default: return String(v);
  }
}

/// `payload` = { value: 1…13, suit: 'clubs'|'hearts'|'spades'|'diamonds' }.
export function drawReveal(ctx, r, payload, ink, opacity) {
  ctx.save();
  ctx.globalAlpha *= opacity;
  drawCard(ctx, r, payload, ink);
  ctx.restore();
}

function drawCard(ctx, r, card, ink) {
  // Drawn in the figure's own ink (the whole reveal is "hand-drawn"), EXCEPT a red
  // suit (hearts/diamonds) is forced to playing-card red regardless of the drawing's colour.
  const pip = isRed(card.suit) ? CARD_RED : ink;
  const value = valueLabel(card.value);
  const cornerH = r.height * 0.15;

  // Top-left index (upright) and bottom-right index (rotated 180°, like a real card).
  const tl = { x: r.minX + r.width * 0.16, y: r.minY + r.height * 0.13 };
  const br = { x: r.maxX - r.width * 0.16, y: r.maxY - r.height * 0.13 };
  drawIndex(ctx, value, card.suit, tl, cornerH, pip, false);
  drawIndex(ctx, value, card.suit, br, cornerH, pip, true);

  // Big centre pip.
  drawSuit(ctx, card.suit, { x: r.midX, y: r.midY }, r.height * 0.44, pip, 11.2);
}

/// One corner index: the value over its suit. When `upsideDown`, the whole group is
/// rotated 180° about the corner — a faithful copy of the opposite corner.
function drawIndex(ctx, value, suit, corner, cornerH, color, upsideDown) {
  ctx.save();
  if (upsideDown) {
    ctx.translate(corner.x, corner.y);
    ctx.rotate(Math.PI);
    ctx.translate(-corner.x, -corner.y);
  }
  drawLooseText(ctx, value, corner, cornerH, color, 21.5);
  drawSuit(ctx, suit, { x: corner.x, y: corner.y + cornerH * 1.05 }, cornerH * 0.95, color, 24.9);
  ctx.restore();
}

/// Draws a string one character at a time, each glyph nudged and rotated by a small
/// deterministic amount so it reads as loosely hand-lettered. The wobble is keyed on
/// character index + seed, so it is stable frame-to-frame (no shimmer).
export function drawLooseText(ctx, s, center, size, color, seed, maxWidth = Infinity) {
  const chars = Array.from(s);
  if (!chars.length) return;

  // Measure each glyph at a given size, laid out horizontally.
  const resolve = (sz) => {
    const spacing = sz * 0.02;
    ctx.font = `${sz}px ${FONT_FAMILY}`;
    const items = chars.map((ch) => ({ ch, w: ctx.measureText(ch).width }));
    const total = items.reduce((a, it) => a + it.w + spacing, 0);
    return { items, total: total - spacing, spacing };
  };

  // Shrink to fit: the rendered width is linear in font size, so measure once at
  // the requested size, then re-resolve at the scaled-down size if it overflows.
  let m = resolve(size);
  if (m.total > maxWidth && m.total > 0) {
    size *= maxWidth / m.total;
    m = resolve(size);
  }

  ctx.save();
  ctx.fillStyle = color;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.font = `${size}px ${FONT_FAMILY}`;
  let x = center.x - m.total / 2;
  m.items.forEach((item, i) => {
    const cx = x + item.w / 2;
    const jx = det(i, seed) * size * 0.05;
    const jy = det(i, seed + 3.3) * size * 0.06;
    const rot = det(i, seed + 7.1) * 0.14;     // ≈ ±4° per glyph
    ctx.save();
    ctx.translate(cx + jx, center.y + jy);
    ctx.rotate(rot);
    ctx.fillText(item.ch, 0, 0);
    ctx.restore();
    x += item.w + m.spacing;
  });
  ctx.restore();
}

// MARK: - Hand-sketched suit symbols

// Outlines in a unit space: x ∈ [-0.5, 0.5]-ish, y ∈ [-0.5, 0.5], y down. Built once.
function heartPts(invert = false) {
  // The classic parametric heart: x = 16 sin³t, y = −(13 cos t − 5 cos 2t − 2 cos 3t − cos 4t).
  // y spans ≈ −12…17; normalise to a 1-high box.
  const out = [];
  const n = 36;
  for (let k = 0; k < n; k++) {
    const t = (k / n) * 2 * Math.PI;
    const x = 16 * Math.sin(t) ** 3;
    const y = -(13 * Math.cos(t) - 5 * Math.cos(2 * t) - 2 * Math.cos(3 * t) - Math.cos(4 * t));
    out.push({ x: x / 29, y: (invert ? -(y - 2.5) : (y - 2.5)) / 29 });
  }
  return out;
}
function edgePts(corners, per) {
  const out = [];
  for (let i = 0; i < corners.length; i++) {
    const a = corners[i], b = corners[(i + 1) % corners.length];
    for (let k = 0; k < per; k++) {
      const f = k / per;
      out.push({ x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f });
    }
  }
  return out;
}
function circlePts(cx, cy, r, n = 16) {
  const out = [];
  for (let k = 0; k < n; k++) {
    const a = (k / n) * 2 * Math.PI;
    out.push({ x: cx + r * Math.cos(a), y: cy + r * Math.sin(a) });
  }
  return out;
}
const STEM = [{ x: 0, y: 0.12 }, { x: 0.17, y: 0.5 }, { x: -0.17, y: 0.5 }];

// Each suit = a list of closed sub-shapes (filled together).
const SUIT_SHAPES = {
  hearts: [heartPts()],
  diamonds: [edgePts([{ x: 0, y: -0.5 }, { x: 0.36, y: 0 }, { x: 0, y: 0.5 }, { x: -0.36, y: 0 }], 5)],
  spades: [heartPts(true).map((p) => ({ x: p.x, y: p.y * 0.82 - 0.09 })), edgePts(STEM, 3)],
  clubs: [circlePts(0, -0.24, 0.215), circlePts(-0.235, 0.075, 0.215), circlePts(0.235, 0.075, 0.215),
    circlePts(0, 0.03, 0.12, 10), edgePts(STEM, 3)],
};

/// One suit symbol at a nominal glyph `size` (the Swift version drew ♣♥♦♠ at font size
/// `size`; the drawn symbol is sized to match a glyph's visible height). The outline is
/// jittered with det() like `SketchInk.sketch`, filled, then re-traced with a second
/// wobble so the edge reads as pen-drawn rather than typeset.
export function drawSuit(ctx, suit, center, size, color, seed) {
  const h = size * 0.66;
  const shapes = SUIT_SHAPES[suit];
  if (!shapes) return;
  const amp = 0.035;
  const rot = det(0, seed + 7.1) * 0.14;
  ctx.save();
  ctx.translate(center.x + det(0, seed) * size * 0.05, center.y + det(0, seed + 3.3) * size * 0.06);
  ctx.rotate(rot);
  ctx.scale(h, h);
  const trace = (s) => {
    ctx.beginPath();
    shapes.forEach((pts, si) => {
      pts.forEach((p, i) => {
        const k = i + si * 61;
        const x = p.x + det(k, seed + s) * amp, y = p.y + det(k, seed + s + 9.7) * amp;
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      });
      ctx.closePath();
    });
  };
  ctx.fillStyle = color;
  ctx.strokeStyle = color;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  trace(0);
  ctx.fill('nonzero');
  ctx.lineWidth = 0.05;
  ctx.stroke();
  trace(4.1);
  ctx.lineWidth = 0.035;
  ctx.stroke();
  ctx.restore();
}
