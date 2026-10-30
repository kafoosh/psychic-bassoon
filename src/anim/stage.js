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
  /// `canvas` is the stage <canvas>; `clear()` and `dpr` handling are the caller's
  /// sizing — the context is expected to be pre-scaled to CSS pixels.
  constructor(canvas, getCtx) {
    this.canvas = canvas;
    this.getCtx = getCtx;
    this.raf = 0;
  }

  /// Play `routine` from t=0; calls `onFinished` once, after drawing the final frame.
  play(rig, routine, payload, paper, onFinished) {
    this.stop();
    const start = performance.now();
    const origin = { x: 0, y: 0 };
    const tick = (now) => {
      const elapsed = (now - start) / 1000;
      const t = Math.min(elapsed, routine.totalDuration);
      this.render(rig, routine, t, origin, payload, paper);
      if (elapsed >= routine.totalDuration) {
        this.raf = 0;
        onFinished();
        return;
      }
      this.raf = requestAnimationFrame(tick);
    };
    this.raf = requestAnimationFrame(tick);
  }

  render(rig, routine, t, origin, payload, paper) {
    const ctx = this.getCtx();
    const w = this.canvas.width, h = this.canvas.height;
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, w, h);
    ctx.restore();
    drawFrame(ctx, t, rig, routine, origin, payload, paper);
  }

  stop() {
    if (this.raf) cancelAnimationFrame(this.raf);
    this.raf = 0;
  }

  clear() {
    this.stop();
    const ctx = this.getCtx();
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    ctx.restore();
  }
}
