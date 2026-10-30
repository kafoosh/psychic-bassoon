// LGPalette (LittleGuyChrome.swift) + the shared deterministic wobble `det()`.

export const LG = Object.freeze({
  ink: '#1C1B19',      // near-black outline + glyph ink
  white: '#FFFDF8',    // sticker fill
  orange: '#EE7D2B',   // accent: decorations + Done tick
  purple: '#B6A2E8',   // undo sticker
  yellow: '#F4C740',   // ribbon
  paper: '#FBF6EA',    // cream sketchpad
  decor: '#EF8326',    // flower/sparkle tint (+ the ruling)
  decorDeep: '#C75A1E',
});

/// The conjured card's paper — `Color(.systemBackground)` in the (light-locked) app.
export const CARD_PAPER = '#FFFFFF';

/// Deterministic pseudo-noise in [-0.5, 0.5) keyed on an index (stable per frame).
export function det(i, seed) {
  const x = Math.sin(i * 127.1 + seed) * 43758.5453;
  return (x - Math.floor(x)) - 0.5;
}
