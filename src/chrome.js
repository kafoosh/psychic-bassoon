// The Little Guy toolbar (GridToolbar.swift + StickerButtons.swift + LittleGuyChrome's
// sticker kit): four disguised "draw" bubbles in CHaSeD order, the Undo · Done ✓ row while
// drawing, the yellow ribbon and its long-press menu. Icons are ORIGINAL inline SVG
// look-alikes of drawing-app tools.

import { LG } from './palette.js';

const SVG = (body, extra = '') =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="${LG.ink}" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" ${extra}>${body}</svg>`;

// The bubble art per suit — the ONE table to edit to swap the icon set. Every one passes as
// an ordinary drawing-app tool; only the rightmost bubble is coloured in.
export const ICONS = {
  // ♣ — a paint palette (filled), its paint wells punched through in the sticker colour.
  clubs: (fill) => SVG(
    `<path d="M12 3.2c-5 0-9 3.5-9 8 0 4.3 3.4 7.6 7.5 7.6 1.3 0 2-.8 2-1.8 0-.5-.2-.9-.5-1.3-.3-.4-.4-.8-.4-1.2 0-1 .8-1.7 1.8-1.7h2.3c3 0 5.3-2 5.3-4.8 0-3.9-4-6.8-9-6.8z" fill="${LG.ink}" stroke-width="1.6"/>`
    + `<circle cx="7.3" cy="11.2" r="1.45" fill="${fill}" stroke="none"/>`
    + `<circle cx="9.3" cy="7.3" r="1.45" fill="${fill}" stroke="none"/>`
    + `<circle cx="13.9" cy="6.6" r="1.45" fill="${fill}" stroke="none"/>`
    + `<circle cx="17.4" cy="9.3" r="1.45" fill="${fill}" stroke="none"/>`),
  // ♥ — an eraser, outline only.
  hearts: () => SVG(
    '<path d="M14.4 4.3l5.3 5.3a1.7 1.7 0 010 2.4L11.6 20H7l-2.7-2.7a1.7 1.7 0 010-2.4L12 4.3a1.7 1.7 0 012.4 0z"/>'
    + '<path d="M8.4 10.2l5.4 5.4"/><path d="M11.6 20h8.2"/>'),
  // ♠ — a pencil over a scribble.
  spades: () => SVG(
    '<path d="M16.4 3.6l3 3-9.2 9.2-3.9 1 .9-3.9z"/><path d="M14.3 5.7l3 3"/>'
    + '<path d="M3.2 20.2c1.6-1.7 3-1.8 4-.7 1 1.1 2.2 1 3.4-.2 1.2-1.2 2.4-1.2 3.4-.2"/>'),
  // ♦ — a square with a pencil (the coloured-in one).
  diamonds: () => SVG(
    '<path d="M11 4.2H6.2a2 2 0 00-2 2v11.6a2 2 0 002 2h11.6a2 2 0 002-2V13"/>'
    + '<path d="M18.2 2.9l2.9 2.9-8.9 8.9-3.7.8.8-3.7z"/>'),
  undo: () => SVG('<path d="M9 14.5L4.3 9.8 9 5.1"/><path d="M4.6 9.8h10a5.2 5.2 0 010 10.4h-3.4"/>', 'stroke-width="2.6"'),
  done: () => SVG('<path d="M5 12.6l4.6 4.6L19.2 7.2"/>', 'stroke-width="3.1"'),
  newPage: () => SVG('<path d="M11 4.2H6.2a2 2 0 00-2 2v11.6a2 2 0 002 2h11.6a2 2 0 002-2V13"/><path d="M18.2 2.9l2.9 2.9-8.9 8.9-3.7.8.8-3.7z"/>', 'stroke-width="2"'),
};

export const SUIT_ORDER = ['clubs', 'hearts', 'spades', 'diamonds'];   // CHaSeD, left → right
const suitFill = (suit) => (suit === 'diamonds' ? LG.orange : LG.white);

/// `min(innerWidth, 430) / 8.5` — the one sizing formula (StickerMetrics.buttonSize).
export function buttonSize(width = window.innerWidth) {
  return Math.min(width, 430) / 8.5;
}

function sticker(iconSvg, fill, label) {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = 'sticker';
  b.setAttribute('aria-label', label);
  b.style.setProperty('--fill', fill);
  b.innerHTML = `<span class="sticker-back"></span><span class="sticker-face">${iconSvg}</span>`;
  return b;
}

/// Press feel + tap / optional long-press. Tap and long-press are mutually exclusive (the
/// 0.5s Undo reset can't also eat a stroke). Fires on release, inside the bubble.
function bindPress(el, { onTap, onLongPress, longMs = 500 }) {
  let id = null, timer = 0, longFired = false, start = null;
  const clear = () => { clearTimeout(timer); timer = 0; el.classList.remove('pressed'); id = null; };
  el.addEventListener('pointerdown', (e) => {
    if (id !== null) return;
    e.preventDefault();
    id = e.pointerId;
    start = { x: e.clientX, y: e.clientY };
    longFired = false;
    el.classList.add('pressed');
    try { el.setPointerCapture(e.pointerId); } catch { /* synthetic events */ }
    if (onLongPress) {
      timer = setTimeout(() => { longFired = true; timer = 0; navigator.vibrate?.(10); onLongPress(); }, longMs);
    }
  });
  el.addEventListener('pointermove', (e) => {
    if (e.pointerId !== id) return;
    const r = el.getBoundingClientRect();
    const inside = e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom;
    el.classList.toggle('pressed', inside && !longFired);
    if (Math.hypot(e.clientX - start.x, e.clientY - start.y) > 12) { clearTimeout(timer); timer = 0; }
  });
  el.addEventListener('pointerup', (e) => {
    if (e.pointerId !== id) return;
    const inside = el.classList.contains('pressed');
    const fired = longFired;
    clear();
    if (!fired && inside) onTap();
  });
  el.addEventListener('pointercancel', (e) => { if (e.pointerId === id) clear(); });
  // Keyboard activation (pointer taps are handled above; a click with detail 0 is a key).
  el.addEventListener('click', (e) => { if (e.detail === 0) onTap(); });
}

export class Toolbar {
  constructor({ onSuit, onUndo, onUndoLong, onDone, onNewPage }) {
    this.el = document.getElementById('toolbar');
    this.suitRow = document.getElementById('suit-row');
    this.drawRow = document.getElementById('draw-row');
    this.ribbon = document.getElementById('ribbon');
    this.menu = document.getElementById('menu');
    this.scrim = document.getElementById('menu-scrim');

    for (const suit of SUIT_ORDER) {
      const fill = suitFill(suit);
      const b = sticker(ICONS[suit](fill), fill, 'Draw');
      bindPress(b, { onTap: () => onSuit(suit) });
      this.suitRow.appendChild(b);
    }

    const undo = sticker(ICONS.undo(), LG.purple, 'Undo');
    bindPress(undo, { onTap: onUndo, onLongPress: onUndoLong });
    const done = sticker(ICONS.done(), LG.orange, 'Done');
    bindPress(done, { onTap: onDone });
    this.drawRow.append(undo, done);

    // Ribbon: a LONG-PRESS (~500ms) opens the performer menu. A plain tap does nothing.
    let lp = 0, lpStart = null;
    this.ribbon.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      lpStart = { x: e.clientX, y: e.clientY };
      clearTimeout(lp);
      lp = setTimeout(() => { lp = 0; navigator.vibrate?.(10); this.openMenu(); }, 500);
    });
    this.ribbon.addEventListener('pointermove', (e) => {
      if (lp && lpStart && Math.hypot(e.clientX - lpStart.x, e.clientY - lpStart.y) > 10) { clearTimeout(lp); lp = 0; }
    });
    const cancelLp = () => { clearTimeout(lp); lp = 0; };
    this.ribbon.addEventListener('pointerup', cancelLp);
    this.ribbon.addEventListener('pointercancel', cancelLp);
    this.ribbon.addEventListener('contextmenu', (e) => e.preventDefault());

    document.querySelector('#menu .menu-icon').innerHTML = ICONS.newPage();
    document.getElementById('menu-new-page').addEventListener('click', () => { this.closeMenu(); onNewPage(); });
    this.scrim.addEventListener('pointerdown', (e) => { e.preventDefault(); this.closeMenu(); });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape') this.closeMenu(); });
  }

  get menuOpen() { return !this.menu.hidden; }

  openMenu() {
    this.scrim.hidden = false;
    this.menu.hidden = false;
    const rr = this.ribbon.getBoundingClientRect();
    const mr = this.menu.getBoundingClientRect();
    const left = Math.min(Math.max(rr.left + rr.width / 2 - mr.width / 2, 12), window.innerWidth - mr.width - 12);
    this.menu.style.left = `${left}px`;
    this.menu.style.top = `${rr.bottom + 10}px`;
    document.getElementById('menu-new-page').focus({ preventScroll: true });
  }

  closeMenu() {
    this.menu.hidden = true;
    this.scrim.hidden = true;
  }

  /// Idle: the suit row + ribbon. Drawing: Undo · Done, the ribbon hidden (not removed) so
  /// the measured toolbar height never changes.
  setDrawing(drawing) {
    this.suitRow.hidden = drawing;
    this.drawRow.hidden = !drawing;
    if (drawing) this.closeMenu();
  }

  /// The measured bottom of the toolbar (incl. ribbon + padding), in screen coordinates.
  bottom() { return this.el.getBoundingClientRect().bottom; }
}
