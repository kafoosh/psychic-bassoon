// Port of LittleGuyStage.swift — renders the rigged drawing, animated, on a transparent
// overlay aligned to the drawing canvas so the figure starts right where it was drawn.
//
// A requestAnimationFrame loop drives the redraw while the choreography plays (pose once
// per frame → every stroke mapped through worldPoint → drawProps). The instant it ends the
// loop STOPS and the final frame is drawn once — no timeline stays alive while idle.

import { worldPoint } from '../rig/model.js';

/// Draw one frame at the given (clamped) time.
export function drawFrame(ctx, t, rig, routine, originOffset, payload, paper) {
  const pose = routine.pose(t);
  for (const stroke of rig.strokes) {
    if (stroke.points.length < 2) continue;
    ctx.beginPath();
    stroke.points.forEach((p, i) => {
      const wp = worldPoint(rig, p, stroke.parts[i], pose);
      const x = wp.x - originOffset.x, y = wp.y - originOffset.y;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    });
    ctx.strokeStyle = stroke.color;
    ctx.lineWidth = stroke.width;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.stroke();
  }
  routine.drawProps(ctx, t, pose, originOffset, payload, paper);
}

export class Stage {
  /// `canvas` is the stage <canvas>; the context is expected to be pre-scaled to CSS pixels.
  constructor(canvas, getCtx) {
    this.canvas = canvas;
    this.getCtx = getCtx;
    this.raf = 0;
    this.show = null;      // { rig, routine, payload, paper, t }
  }

  /// Play `routine` from t=0; calls `onFinished` once, after drawing the final frame.
  play(rig, routine, payload, paper, onFinished) {
    this.stop();
    this.show = { rig, routine, payload, paper, t: 0 };
    const start = performance.now();
    const tick = (now) => {
      const show = this.show;
      if (!show) return;
      const elapsed = (now - start) / 1000;
      show.t = Math.min(elapsed, show.routine.totalDuration);
      this.redraw();
      if (elapsed >= show.routine.totalDuration) {
        this.raf = 0;
        onFinished();
        return;
      }
      this.raf = requestAnimationFrame(tick);
    };
    this.raf = requestAnimationFrame(tick);
  }

  /// Swap in a re-laid-out rig + routine (the page was resized). The clock carries on, and
  /// a held final frame is redrawn once.
  replace(rig, routine) {
    if (!this.show) return;
    this.show.rig = rig;
    this.show.routine = routine;
    this.show.t = Math.min(this.show.t, routine.totalDuration);
    if (!this.raf) this.redraw();
  }

  redraw() {
    const ctx = this.getCtx();
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    ctx.restore();
    const s = this.show;
    if (s) drawFrame(ctx, s.t, s.rig, s.routine, { x: 0, y: 0 }, s.payload, s.paper);
  }

  stop() {
    if (this.raf) cancelAnimationFrame(this.raf);
    this.raf = 0;
  }

  clear() {
    this.stop();
    this.show = null;
    this.redraw();
  }
}
