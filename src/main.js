// The app: a port of AppState + LittleGuyController + CanvasScreen for the Canvas Grid /
// playing-card path only.
//
// The covert flow: a tap (or the touch-down of a drag) on the ruled page picks the VALUE;
// one of the four "draw" bubbles picks the SUIT (CHaSeD) and opens the pen. The spectator
// draws a little guy; ✓ out of drawing mode ARMS (only with a secret + strokes), and after a
// fixed 4s the drawing auto-rigs, comes to life, performs a random routine and reveals the card.
//
// The secret lives in memory only — never persisted, logged, put in the URL, or printed.

import { LG, CARD_PAPER } from './palette.js';
import { ValueGrid, drawRuling, attachCatcher } from './grid.js';
import { drawBackdrop } from './backdrop.js';
import { Drawing } from './drawing.js';
import { Toolbar, buttonSize } from './chrome.js';
import { fit } from './rig/fitter.js';
import { makeSetup, makeRoutine, randomSlot, SLOTS } from './anim/setup.js';
import { Stage } from './anim/stage.js';
import { FONT_FAMILY } from './reveal.js';

const ARM_DELAY_MS = 4000;
const params = new URLSearchParams(location.search);
const forcedRoutine = SLOTS.includes(params.get('routine')) ? params.get('routine') : null;

// ---------------------------------------------------------------- canvases

const paperCanvas = document.getElementById('paper');
const inkCanvas = document.getElementById('ink');
const stageCanvas = document.getElementById('stage');
const catcher = document.getElementById('catcher');
const ctxOf = (c) => c.getContext('2d');

let dpr = 1;
function sizeCanvas(c) {
  const r = c.getBoundingClientRect();
  c.width = Math.max(1, Math.round(r.width * dpr));
  c.height = Math.max(1, Math.round(r.height * dpr));
  ctxOf(c).setTransform(dpr, 0, 0, dpr, 0, 0);
  return { width: r.width, height: r.height };
}

function safeInsets() {
  const cs = getComputedStyle(document.getElementById('safe-probe'));
  return { top: parseFloat(cs.paddingTop) || 0, bottom: parseFloat(cs.paddingBottom) || 0 };
}

// ---------------------------------------------------------------- AppState

const appState = {
  /** The committed secret the little guy will reveal: {value, suit} | null. */
  reveal: null,
  /** Partial capture: the value from a grid tap, consumed when a suit bubble is pressed. */
  capturedValue: null,

  captureValue(v) { this.capturedValue = Math.min(Math.max(v, 1), 13); },

  /// A suit bubble was pressed — lock in the grid-tapped value with this suit, then CONSUME
  /// the partial capture so a stale value never leaks into the next trick. No grid tap
  /// before the suit → NO secret: the bubble is then just a draw button and ✓ won't arm.
  commitCard(suit) {
    this.reveal = this.capturedValue !== null ? { value: this.capturedValue, suit } : null;
    this.capturedValue = null;
  },
};

// ---------------------------------------------------------------- LittleGuyController

const controller = {
  phase: 'idle',           // idle | armed | performing | done
  /// Once a performance has finished, the canvas is "spent": ✓ can't fire another
  /// performance until New Page or a suit press (auto-fresh) resets it.
  isSpent: false,
  rig: null,
  routine: null,
  armTimer: 0,
  onComeToLife: null,

  get canArm() { return this.phase === 'idle' && !this.isSpent; },
  get isOnStage() { return (this.phase === 'performing' || this.phase === 'done') && this.rig !== null; },

  /// Arm the trick. After `delay` ms the little guy comes to life.
  arm(delay) {
    if (!this.canArm) return;
    this.phase = 'armed';
    clearTimeout(this.armTimer);
    this.armTimer = setTimeout(() => {
      if (this.phase !== 'armed') return;
      this.phase = 'performing';
      this.onComeToLife?.();
    }, Math.max(0, delay));
  },

  /// The choreography ended: hold the final pose, and the canvas is spent.
  finish() {
    if (this.phase !== 'performing') return;
    this.phase = 'done';
    this.isSpent = true;
    sync();
  },

  /// Disarm and return to a fully clean, re-armable state.
  reset() {
    clearTimeout(this.armTimer);
    this.armTimer = 0;
    this.phase = 'idle';
    this.rig = null;
    this.routine = null;
    this.isSpent = false;
    stage.clear();
    sync();
  },
};

// ---------------------------------------------------------------- screen

let editorMode = 'idle';    // idle | drawing
let grid = new ValueGrid({ x: 0, y: 0, width: 0, height: 0 });
let insets = { top: 0, bottom: 0 };
let stageSize = { width: 0, height: 0 };

const stage = new Stage(stageCanvas, () => ctxOf(stageCanvas));
const drawing = new Drawing(inkCanvas, () => ctxOf(inkCanvas));
const toolbar = new Toolbar({
  onSuit: selectSuit,
  onUndo: () => drawing.undo(),
  onUndoLong: clearPage,            // long-press 0.5s: clear the page and reset the controller
  onDone: handleDone,
  onNewPage: clearPage,
});
controller.onComeToLife = comeToLife;

function sync() {
  document.body.classList.toggle('drawing', editorMode === 'drawing');
  document.body.classList.toggle('on-stage', controller.isOnStage);
  drawing.enabled = editorMode === 'drawing';
  toolbar.setDrawing(editorMode === 'drawing');
}

function layout() {
  dpr = Math.min(window.devicePixelRatio || 1, 3);
  document.documentElement.style.setProperty('--btn', `${buttonSize()}px`);
  insets = safeInsets();

  const size = sizeCanvas(paperCanvas);
  // The value grid: from the MEASURED bottom of the toolbar down to the bottom safe inset.
  const top = toolbar.bottom();
  const bottom = size.height - insets.bottom;
  grid = new ValueGrid({ x: 0, y: top, width: size.width, height: Math.max(bottom - top, 0) });
  const pctx = ctxOf(paperCanvas);
  pctx.fillStyle = LG.paper;
  pctx.fillRect(0, 0, size.width, size.height);
  drawRuling(pctx, size, grid);
  drawBackdrop(pctx, size);

  sizeCanvas(inkCanvas);
  drawing.render();
  stageSize = sizeCanvas(stageCanvas);
  if (controller.phase === 'done' && controller.rig) {
    stage.render(controller.rig, controller.routine, controller.routine.totalDuration,
      { x: 0, y: 0 }, appState.reveal, CARD_PAPER);
  }
}

/// The animation playfield's chrome insets in STAGE coordinates (the stage's top is the
/// safe-area top): the measured toolbar + ribbon above, the home indicator below.
function stageInsets() {
  return { top: toolbar.bottom() - insets.top + 10, bottom: insets.bottom + 10 };
}

// ---------------------------------------------------------------- actions

/// A grid tap / drag-start: record the value (the last touch before a suit wins). Never
/// while drawing. Works while idle, armed, performing or done. Returns an undo token.
function captureGridValue(point) {
  if (editorMode === 'drawing' || toolbar.menuOpen) return null;
  const value = grid.valueAt(point);
  if (value === null) return null;
  const prior = appState.capturedValue;
  appState.captureValue(value);
  navigator.vibrate?.(8);
  return { prior };
}

/// A suit bubble: commit the card (or clear it, if no grid value was tapped), then start
/// drawing. AUTO-FRESH — if a trick is pending, performing, or finished, the page is
/// cleared first so this is a brand-new performance; strokes on an idle page are kept.
function selectSuit(suit) {
  appState.commitCard(suit);
  if (controller.phase !== 'idle') clearPage();
  editorMode = 'drawing';
  sync();
}

/// Blank page, re-armable — leaves the committed secret alone.
function clearPage() {
  controller.reset();
  drawing.clear();
}

/// ✓ out of DRAWING mode with a drawing present is the covert arm — ONLY with a committed
/// secret. Otherwise it just closes the pen like an ordinary drawing app.
function handleDone() {
  const wasDrawing = editorMode === 'drawing';
  drawing.cancelLive();
  editorMode = 'idle';
  sync();
  if (wasDrawing && appState.reveal !== null && drawing.strokes.length > 0 && controller.canArm) {
    controller.arm(ARM_DELAY_MS);
  }
}

let fontReady = null;
function loadFont() {
  if (!fontReady) {
    const load = document.fonts?.load ? document.fonts.load(`48px ${FONT_FAMILY}`) : Promise.resolve();
    // Never let a slow font block the reveal for long.
    fontReady = Promise.race([load.catch(() => {}), new Promise((r) => setTimeout(r, 2500))]);
  }
  return fontReady;
}

/// The arm delay elapsed: auto-rig the drawing and perform a random routine.
async function comeToLife() {
  const strokes = drawing.strokes.map((s) => ({ points: s.points.slice(), width: s.width, color: s.color }));
  if (!strokes.length) { controller.finish(); return; }
  await loadFont();
  if (controller.phase !== 'performing') return;       // reset while the font loaded

  const rig = fit(strokes);
  const ins = stageInsets();
  const setup = makeSetup(rig, stageSize, { x: 0, y: 0 }, ins.top, ins.bottom);
  const routine = makeRoutine(forcedRoutine || randomSlot(), setup);
  controller.rig = rig;
  controller.routine = routine;
  sync();                                             // hide the static strokes
  stage.play(rig, routine, appState.reveal, CARD_PAPER, () => controller.finish());
}

// ---------------------------------------------------------------- input wiring

attachCatcher(catcher, {
  onValuePoint: captureGridValue,
  onCancel: (token) => { appState.capturedValue = token.prior; },
});

document.addEventListener('contextmenu', (e) => e.preventDefault());
document.addEventListener('gesturestart', (e) => e.preventDefault());   // iOS pinch
document.addEventListener('dblclick', (e) => e.preventDefault());

let resizeRaf = 0;
window.addEventListener('resize', () => {
  cancelAnimationFrame(resizeRaf);
  resizeRaf = requestAnimationFrame(layout);
});

// ---------------------------------------------------------------- debug demo (?demo=1)

/// Seeds a synthetic stick figure + a secret and auto-arms, like CanvasScreen's
/// walkthrough demo. Debug only — not linked anywhere.
function runDemo() {
  const w = stageSize.width, h = stageSize.height;
  const s = Math.min(w / 390, h / 760);
  const cx = w * 0.5, top = h * 0.24;
  const P = (x, y) => ({ x: cx + x * s, y: top + y * s });
  const line = (a, b, n = 14) => Array.from({ length: n + 1 }, (_, i) => ({ x: a.x + (b.x - a.x) * i / n, y: a.y + (b.y - a.y) * i / n }));
  const circle = (c, r) => Array.from({ length: 33 }, (_, i) => ({ x: c.x + r * s * Math.cos(i / 32 * 2 * Math.PI), y: c.y + r * s * Math.sin(i / 32 * 2 * Math.PI) }));
  const mk = (points) => ({ points, width: 5, color: LG.ink });
  drawing.setStrokes([
    mk(circle(P(0, 40), 40)),
    mk(line(P(0, 80), P(2, 200))),
    mk(line(P(1, 110), P(-60, 170))),
    mk(line(P(1, 110), P(62, 160))),
    mk(line(P(2, 200), P(-40, 300))),
    mk(line(P(2, 200), P(44, 302))),
    mk([P(-14, 32)]), mk([P(14, 32)]),
  ]);
  appState.capturedValue = 1 + Math.floor(Math.random() * 13);
  appState.commitCard(['clubs', 'hearts', 'spades', 'diamonds'][Math.floor(Math.random() * 4)]);
  editorMode = 'idle';
  sync();
  setTimeout(() => controller.arm(0), 500);
}

// ---------------------------------------------------------------- boot

sync();
layout();
loadFont();
if (document.fonts?.ready) document.fonts.ready.then(layout);   // ribbon text metrics settle the toolbar height
if (params.get('demo') === '1') runDemo();
