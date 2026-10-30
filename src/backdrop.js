// Port of LittleGuyBackdrop (LittleGuyChrome.swift) — a static scatter of orange flowers,
// four-point sparkles and little sunbursts behind the paper. Drawn once (no timeline).

import { LG } from './palette.js';

// Normalised positions (x,y in 0…1), absolute radii in points, kept to the periphery so
// the centre stays clean for the drawing; a couple of faint ones drift inward for texture.
const DECOS = [
  { kind: 'flower', x: 0.12, y: 0.27, r: 28, opacity: 0.50, rot: 0 },
  { kind: 'sparkle', x: 0.88, y: 0.25, r: 24, opacity: 0.50, rot: 12 },
  { kind: 'flower', x: 0.92, y: 0.45, r: 20, opacity: 0.42, rot: 0 },
  { kind: 'sparkle', x: 0.06, y: 0.40, r: 16, opacity: 0.40, rot: 8 },
  { kind: 'burst', x: 0.14, y: 0.82, r: 30, opacity: 0.48, rot: 0 },
  { kind: 'sparkle', x: 0.85, y: 0.75, r: 28, opacity: 0.52, rot: -10 },
  { kind: 'flower', x: 0.33, y: 0.92, r: 22, opacity: 0.45, rot: 0 },
  { kind: 'sparkle', x: 0.63, y: 0.55, r: 14, opacity: 0.28, rot: 0 },
  { kind: 'sparkle', x: 0.20, y: 0.62, r: 12, opacity: 0.26, rot: 0 },
];

export function drawBackdrop(ctx, size) {
  ctx.save();
  for (const d of DECOS) {
    const c = { x: d.x * size.width, y: d.y * size.height };
    ctx.globalAlpha = d.opacity;
    if (d.kind === 'flower') flower(ctx, c, d.r);
    else if (d.kind === 'sparkle') sparkle(ctx, c, d.r, d.rot);
    else burst(ctx, c, d.r);
  }
  ctx.restore();
}

function disc(ctx, c, r, color) {
  ctx.beginPath();
  ctx.arc(c.x, c.y, r, 0, Math.PI * 2);
  ctx.fillStyle = color;
  ctx.fill();
}

function flower(ctx, c, r) {
  const petal = r * 0.55, ring = r * 0.60;
  for (let i = 0; i < 5; i++) {
    const a = i / 5 * 2 * Math.PI - Math.PI / 2;
    disc(ctx, { x: c.x + Math.cos(a) * ring, y: c.y + Math.sin(a) * ring }, petal, LG.decor);
  }
  disc(ctx, c, r * 0.50, LG.decor);
  disc(ctx, c, r * 0.26, LG.decorDeep);
}

function sparkle(ctx, c, r, rotDeg) {
  const inner = r * 0.30;
  const rot = rotDeg * Math.PI / 180;
  ctx.beginPath();
  for (let i = 0; i < 8; i++) {
    const a = rot + i * (Math.PI / 4) - Math.PI / 2;
    const rad = (i % 2 === 0) ? r : inner;
    const x = c.x + Math.cos(a) * rad, y = c.y + Math.sin(a) * rad;
    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  }
  ctx.closePath();
  ctx.fillStyle = LG.decor;
  ctx.fill();
}

function burst(ctx, c, r) {
  const n = 12, inner = r * 0.34, outer = r, halfW = r * 0.085;
  ctx.fillStyle = LG.decor;
  for (let i = 0; i < n; i++) {
    const a = i / n * 2 * Math.PI;
    const dx = Math.cos(a), dy = Math.sin(a), px = -Math.sin(a), py = Math.cos(a);
    ctx.beginPath();
    ctx.moveTo(c.x + dx * inner + px * halfW, c.y + dy * inner + py * halfW);
    ctx.lineTo(c.x + dx * outer, c.y + dy * outer);
    ctx.lineTo(c.x + dx * inner - px * halfW, c.y + dy * inner - py * halfW);
    ctx.closePath();
    ctx.fill();
  }
  disc(ctx, c, r * 0.30, LG.decor);
}
