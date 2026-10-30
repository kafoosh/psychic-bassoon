// Rig regression gates (node --test). Ports RigHarness's scored populations:
//   • CLEAN set (≈1900 composed figures): ≥ 99% figures fully correct, 0 explosions,
//     0 validator demotions;
//   • PROPORTIONS set (short torso / long legs / λ body / thick pens): 0 explosions and
//     0 leg strokes partly labelled arm — the gate that matters there;
//   • hand-built user FIXTURES: all pass (labels + every routine without exploding).

import test from 'node:test';
import assert from 'node:assert/strict';
import { fit } from '../src/rig/fitter.js';
import { stabilizeSeams } from '../src/rig/seams.js';
import { makePose, worldPoint, rigIsConfident } from '../src/rig/model.js';
import { makeSetup, makeRoutine, SLOTS } from '../src/anim/setup.js';
import * as F from './figures.mjs';

function evaluate(specs) {
  const st = { figures: 0, ok: 0, strokeOK: 0, strokeTotal: 0, explode: 0, legSplitArm: 0,
    torsoAsArm: 0, outlineTorn: 0, demotions: 0, fps: 0, failing: [] };
  for (const spec of specs) {
    const { strokes, truth, outline } = F.build(spec);
    const rig = fit(strokes);
    const r = F.scoreFigure(rig, truth, outline);
    st.figures += 1;
    st.strokeOK += r.strokeOK; st.strokeTotal += r.strokeTotal;
    st.legSplitArm += r.legSplitArm; st.torsoAsArm += r.torsoAsArm; st.outlineTorn += r.outlineLimbTorn;
    st.demotions += r.validatorDemotions; st.fps += r.validatorFPs;
    if (r.figOK) st.ok += 1; else st.failing.push(spec.seed);
    if (F.explodedSlots(rig).length) st.explode += 1;
  }
  return st;
}

test('clean set: ≥99% figures correct, 0 explosions, 0 demotions', () => {
  const st = evaluate(F.cleanSpecs());
  const frac = st.ok / st.figures;
  console.log(`  clean: ${st.ok}/${st.figures} figures, ${st.strokeOK}/${st.strokeTotal} strokes, `
    + `explosions ${st.explode}, demotions ${st.demotions}, failing seeds: ${st.failing.join(' ')}`);
  assert.ok(frac >= 0.99, `figure accuracy ${(frac * 100).toFixed(1)}% < 99%`);
  assert.ok(st.strokeOK / st.strokeTotal >= 0.999, 'per-stroke accuracy');
  assert.equal(st.explode, 0, 'animation explosions');
  assert.equal(st.legSplitArm, 0, 'leg strokes partly labelled arm');
  assert.equal(st.outlineTorn, 0, 'outline limbs torn');
  assert.equal(st.demotions, 0, 'validator demotions on known-good figures');
});

test('proportions set: 0 explosions, 0 leg strokes partly labelled arm', () => {
  const st = evaluate(F.proportionSpecs());
  console.log(`  proportions: ${st.ok}/${st.figures} figures (${(100 * st.ok / st.figures).toFixed(0)}%), `
    + `explosions ${st.explode}, legSplitArm ${st.legSplitArm}, validator FPs ${st.fps}`);
  assert.equal(st.explode, 0, 'animation explosions');
  assert.equal(st.legSplitArm, 0, 'leg strokes partly labelled arm');
  assert.equal(st.fps, 0, 'validator false positives');
  assert.ok(st.ok / st.figures >= 0.88, 'proportions accuracy regressed');
});

test('user fixtures: all pass', () => {
  const failed = [];
  for (const f of F.userFixtures()) {
    const rig = fit(f.strokes);
    const r = F.scoreFigure(rig, f.truth);
    const ex = F.explodedSlots(rig);
    if (!r.figOK || ex.length) failed.push(`${f.name}: ${r.failParts.join(' ')} ${ex.join(',')}`);
  }
  assert.deepEqual(failed, []);
});

test('single-tap dots survive and ride the head', () => {
  const { strokes } = F.build(F.makeSpec({ head: 'circle', torso: 'spineLine', arm: 'lineDown', leg: 'lineStraight', seed: 3 }));
  const head = strokes[0].points;
  const cx = head.reduce((s, p) => s + p.x, 0) / head.length;
  const cy = head.reduce((s, p) => s + p.y, 0) / head.length;
  strokes.push({ points: [{ x: cx - 14, y: cy - 8 }], width: 5, color: '#000' });              // 1-point eye
  strokes.push({ points: [{ x: cx + 14, y: cy - 8 }, { x: cx + 14.1, y: cy - 8 }], width: 5, color: '#000' });
  const rig = fit(strokes);
  assert.equal(rig.strokes.length, strokes.length);
  for (const s of rig.strokes.slice(-2)) assert.ok(s.parts.every((p) => p === 'head'), 'dot bound to head');
});

test('every routine keeps the figure inside the playfield and finishes', () => {
  const bounds = { width: 390, height: 844 };
  const { strokes } = F.build(F.makeSpec({ head: 'circle', torso: 'spineLine', arm: 'lineDown', leg: 'lineStraight', seed: 7 }));
  const rig = fit(strokes);
  assert.ok(rig.articulated);
  for (const slot of SLOTS) {
    const setup = makeSetup(rig, bounds, { x: 0, y: 0 }, 120, 44);
    const routine = makeRoutine(slot, setup);
    assert.ok(routine.totalDuration > 10 && routine.totalDuration < 14);
    for (let t = 1.5; t <= routine.totalDuration; t += 0.25) {
      const pose = routine.pose(t);
      for (const s of rig.strokes) {
        s.points.forEach((p, j) => {
          const w = worldPoint(rig, p, s.parts[j], pose);
          assert.ok(w.x > -40 && w.x < bounds.width + 40, `${slot} x out of view at t=${t}`);
          assert.ok(w.y < bounds.height, `${slot} below the screen at t=${t}`);
        });
      }
    }
  }
});

test('FK keeps joints connected (rest pose is identity)', () => {
  const { strokes } = F.build(F.makeSpec({ head: 'circle', torso: 'spineLine', arm: 'bentLine', leg: 'lineStraight', seed: 9 }));
  const rig = fit(strokes);
  const pose = makePose();
  for (const s of rig.strokes) s.points.forEach((p, j) => {
    const w = worldPoint(rig, p, s.parts[j], pose);
    assert.ok(Math.abs(w.x - p.x) < 1e-9 && Math.abs(w.y - p.y) < 1e-9);
  });
});

test('confidence gate: little guys articulate, other drawings move as one piece', () => {
  for (const [name, specs, floor] of [['clean', F.cleanSpecs(), 0.99], ['proportions', F.proportionSpecs(), 0.9]]) {
    let n = 0;
    for (const spec of specs) if (rigIsConfident(stabilizeSeams(fit(F.build(spec).strokes)))) n += 1;
    assert.ok(n / specs.length >= floor, `only ${n}/${specs.length} ${name} figures articulate`);
  }
  for (const f of F.userFixtures()) assert.ok(rigIsConfident(fit(f.strokes)), `${f.name} should articulate`);

  const ln = (a, b, n = 14) => Array.from({ length: n + 1 }, (_, i) => ({ x: a.x + (b.x - a.x) * i / n, y: a.y + (b.y - a.y) * i / n }));
  const poly = (ps) => ps.slice(1).flatMap((p, i) => ln(ps[i], p, 10));
  const circ = (cx, cy, r, n = 32) => Array.from({ length: n + 1 }, (_, i) => ({ x: cx + r * Math.cos(i / n * 2 * Math.PI), y: cy + r * Math.sin(i / n * 2 * Math.PI) }));
  const mk = (points) => ({ points, width: 5, color: '#000' });
  const P = (x, y) => ({ x, y });

  // A big-headed figure whose arms are ONE stroke with a short left stub (the reported
  // drawing), with eye dots and a smile — it must articulate.
  const yellow = [circ(326, 137, 80, 40), [P(325, 136)], [P(359, 122)], poly([P(301, 147), P(325, 170), P(350, 176), P(372, 164)]),
    poly([P(327, 215), P(315, 295), P(295, 380), P(280, 450)]), ln(P(315, 295), P(360, 450)),
    poly([P(300, 259), P(370, 256), P(455, 251), P(457, 262)])].map(mk);
  assert.ok(rigIsConfident(stabilizeSeams(fit(yellow))), 'big-head figure with a stub arm should articulate');

  const junk = {
    house: [ln(P(100, 400), P(300, 400)), ln(P(300, 400), P(300, 600)), ln(P(300, 600), P(100, 600)), ln(P(100, 600), P(100, 400)),
      ln(P(100, 400), P(200, 300)), ln(P(200, 300), P(300, 400))],
    squiggle: [Array.from({ length: 80 }, (_, i) => P(100 + i * 3, 400 + Math.sin(i / 4) * 60))],
    flower: [circ(200, 300, 30), ln(P(200, 330), P(205, 600)), ln(P(203, 450), P(160, 420)), ln(P(203, 500), P(250, 470))],
    sun: [circ(200, 400, 60), ...Array.from({ length: 8 }, (_, k) => { const a = k / 8 * 2 * Math.PI;
      return ln(P(200 + 75 * Math.cos(a), 400 + 75 * Math.sin(a)), P(200 + 120 * Math.cos(a), 400 + 120 * Math.sin(a))); })],
    car: [ln(P(80, 450), P(320, 450)), ln(P(320, 450), P(320, 520)), ln(P(320, 520), P(80, 520)), ln(P(80, 520), P(80, 450)),
      ln(P(130, 450), P(160, 400)), ln(P(160, 400), P(250, 400)), ln(P(250, 400), P(280, 450)), circ(130, 525, 25), circ(270, 525, 25)],
    oneLegged: F.build(F.makeSpec({ head: 'circle', torso: 'spineLine', arm: 'lineDown', leg: 'lineStraight', oneLeg: true, seed: 5 })).strokes.map((s) => s.points),
  };
  for (const [name, strokes] of Object.entries(junk)) {
    assert.equal(rigIsConfident(stabilizeSeams(fit(strokes.map(mk)))), false, `${name} should move as one piece`);
  }
});

test('props are sized to the figure', () => {
  const small = fit(F.build(F.makeSpec({ head: 'circle', torso: 'spineLine', arm: 'lineDown', leg: 'lineStraight', scale: 0.5, seed: 2 })).strokes);
  const big = fit(F.build(F.makeSpec({ head: 'circle', torso: 'spineLine', arm: 'lineDown', leg: 'lineStraight', scale: 1.0, seed: 2 })).strokes);
  const bounds = { width: 390, height: 844 };
  const ps = (rig) => makeSetup(rig, bounds, { x: 0, y: 0 }, 120, 44).propScale;
  assert.ok(ps(small) <= small.skeleton.bbox.height * 0.8 + 1e-6);
  assert.ok(ps(small) < ps(big) * 0.7, `small ${ps(small)} vs big ${ps(big)}`);
});

test('no seam stretches: limbs never pull a stroke apart (crotch, hips, elbows)', () => {
  const bad = [];
  for (const [name, specs] of [['clean', F.cleanSpecs()], ['adversarial', F.adversarialSpecs()], ['proportions', F.proportionSpecs()]]) {
    for (const spec of specs) {
      const rig = stabilizeSeams(fit(F.build(spec).strokes));
      const s = F.seamStretch(rig);
      if (s > 0.05) bad.push(`${name}:${spec.seed} ${s.toFixed(2)}`);
    }
  }
  for (const f of F.userFixtures()) {
    const s = F.seamStretch(stabilizeSeams(fit(f.strokes)));
    if (s > 0.05) bad.push(`${f.name} ${s.toFixed(2)}`);
  }
  assert.deepEqual(bad, []);
});

test('seam pass keeps the labels (clean accuracy, fixtures)', () => {
  let ok = 0;
  const specs = F.cleanSpecs();
  for (const spec of specs) {
    const { strokes, truth, outline } = F.build(spec);
    if (F.scoreFigure(stabilizeSeams(fit(strokes)), truth, outline).figOK) ok += 1;
  }
  assert.ok(ok / specs.length >= 0.99);
  for (const f of F.userFixtures()) {
    const rig = stabilizeSeams(fit(f.strokes));
    assert.ok(F.scoreFigure(rig, f.truth).figOK && !F.explodedSlots(rig).length, f.name);
  }
});
