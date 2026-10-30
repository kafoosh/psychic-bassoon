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
// Gochi Hand's cap height is ≈0.51 em; the bold system face the Swift reveal used is ≈0.66 em.
// Scale the font so a value glyph keeps the visible height the layout was tuned for, and
// centre each glyph on its cap height (not the em box).
const GOCHI_CAP = 0.51;
const GLYPH_SCALE = 0.66 / GOCHI_CAP;

/// Classic playing-card red, used for hearts/diamonds regardless of the figure's ink.
const CARD_RED = 'rgb(217, 41, 41)';    // rgb(0.85, 0.16, 0.16)
/// Playing-card black for clubs/spades — the Little Guy ink, whatever colour the figure is.
const CARD_BLACK = '#1C1B19';

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
  drawCard(ctx, r, payload);
  ctx.restore();
}

function drawCard(ctx, r, card) {
  // A real card's colours, whatever colour the figure was drawn in: hearts/diamonds red,
  // clubs/spades black — the value, the corner suits and the centre pip alike. (The card's
  // outline and the props stay in the figure's ink.)
  const pip = isRed(card.suit) ? CARD_RED : CARD_BLACK;
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
    ctx.font = `${sz * GLYPH_SCALE}px ${FONT_FAMILY}`;
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

  const px = size * GLYPH_SCALE;
  ctx.save();
  ctx.fillStyle = color;
  ctx.strokeStyle = color;
  ctx.lineWidth = px * 0.025;           // a touch of pen weight
  ctx.lineJoin = 'round';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'alphabetic';
  ctx.font = `${px}px ${FONT_FAMILY}`;
  let x = center.x - m.total / 2;
  m.items.forEach((item, i) => {
    const cx = x + item.w / 2;
    const jx = det(i, seed) * size * 0.05;
    const jy = det(i, seed + 3.3) * size * 0.06;
    const rot = det(i, seed + 7.1) * 0.14;     // ≈ ±4° per glyph
    ctx.save();
    ctx.translate(cx + jx, center.y + jy);
    ctx.rotate(rot);
    ctx.fillText(item.ch, 0, px * GOCHI_CAP / 2);
    ctx.strokeText(item.ch, 0, px * GOCHI_CAP / 2);
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
/// `size`; the drawn symbol is sized to match a glyph's visible height). The outline gets
/// a light det() wobble and is traced with midpoint curves, so the edge reads as a smooth
/// pen line rather than typeset — without looking shaky.
export function drawSuit(ctx, suit, center, size, color, seed) {
  const h = size * 0.66;
  const shapes = SUIT_SHAPES[suit];
  if (!shapes) return;
  const amp = 0.012;
  const rot = det(0, seed + 7.1) * 0.14;
  ctx.save();
  ctx.translate(center.x + det(0, seed) * size * 0.05, center.y + det(0, seed + 3.3) * size * 0.06);
  ctx.rotate(rot);
  ctx.scale(h, h);
  ctx.beginPath();
  shapes.forEach((pts, si) => {
    const q = pts.map((p, i) => ({
      x: p.x + det(i + si * 61, seed) * amp,
      y: p.y + det(i + si * 61, seed + 9.7) * amp,
    }));
    const n = q.length;
    const mid = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
    const m0 = mid(q[n - 1], q[0]);
    ctx.moveTo(m0.x, m0.y);
    for (let i = 0; i < n; i++) {
      const m = mid(q[i], q[(i + 1) % n]);
      ctx.quadraticCurveTo(q[i].x, q[i].y, m.x, m.y);
    }
    ctx.closePath();
  });
  ctx.fillStyle = color;
  ctx.strokeStyle = color;
  ctx.lineJoin = 'round';
  ctx.lineWidth = 0.04;
  ctx.fill('nonzero');
  ctx.stroke();
  ctx.restore();
}
