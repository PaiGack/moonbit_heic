#!/usr/bin/env node
// Second link of the M3 loop-filter trust chain: verify the upstream Go truth
// (tools/loopfilter_golden.json, produced by export_loopfilter_golden_test.go
// run against the real gen2brain/h265 deblock()/applySAO() with -tags noasm)
// against the independent from-the-spec JS transcription in loopfilter_lib.mjs.
// Exits non-zero and prints the first mismatch on any difference.
//
//   node tools/crosscheck_loopfilter.mjs
//
// Self-contained: no Go toolchain, no network.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import {
  clip3, betaTc, deblockLumaPlan, deblockLumaApply, chromaLine,
  saoBandRow, saoEdgeRow, deblockFrame, saoFrame,
} from './loopfilter_lib.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const g = JSON.parse(fs.readFileSync(path.join(root, 'tools/loopfilter_golden.json'), 'utf8'));
const dec = s => Array.from(Buffer.from(s, 'base64'));

let checks = 0;
function eq(got, want, where) {
  checks++;
  if (got !== want) {
    console.error(`MISMATCH ${where}: got ${got}, want ${want}`);
    process.exit(1);
  }
}
function arrEq(got, want, where) {
  checks++;
  if (got.length !== want.length) {
    console.error(`MISMATCH ${where}: length ${got.length} != ${want.length}`);
    process.exit(1);
  }
  for (let i = 0; i < got.length; i++) {
    checks++;
    if (got[i] !== want[i]) {
      console.error(`MISMATCH ${where}[${i}]: got ${got[i]}, want ${want[i]}`);
      process.exit(1);
    }
  }
}

// ---- betaTc ----
for (const c of g.beta_tc) {
  const { beta, tc } = betaTc(c.QP, c.BS, c.BetaOff, c.TcOff, 8);
  eq(beta, c.Beta, `betaTc qp=${c.QP} bs=${c.BS} bo=${c.BetaOff} to=${c.TcOff} beta`);
  eq(tc, c.Tc, `betaTc qp=${c.QP} bs=${c.BS} bo=${c.BetaOff} to=${c.TcOff} tc`);
}

// ---- luma plan + apply ----
for (let i = 0; i < g.luma.length; i++) {
  const c = g.luma[i];
  const pl = deblockLumaPlan(c.In, c.Beta, c.Tc);
  eq(pl.mode, c.PlanMode, `luma[${i}] plan mode`);
  eq(pl.nDp, c.NDp, `luma[${i}] nDp`);
  eq(pl.nDq, c.NDq, `luma[${i}] nDq`);
  const out = deblockLumaApply(c.In, pl, c.BitDepth, c.NoP, c.NoQ);
  arrEq(out, c.Out, `luma[${i}] apply`);
}

// ---- chroma ----
for (let i = 0; i < g.chroma.length; i++) {
  const c = g.chroma[i];
  const out = chromaLine(c.In, c.Tc, c.MaxV, c.NoP, c.NoQ);
  arrEq(out, c.Out, `chroma[${i}]`);
}

// ---- SAO band ----
for (let i = 0; i < g.sao_band.length; i++) {
  const c = g.sao_band[i];
  const out = saoBandRow(c.Src, c.Band, c.Offset, c.Shift, c.MaxV);
  arrEq(out, c.Dst, `sao_band[${i}]`);
}

// ---- SAO edge ----
for (let i = 0; i < g.sao_edge.length; i++) {
  const c = g.sao_edge[i];
  const out = saoEdgeRow(c.Src, c.Na, c.Nb, c.Offset, c.MaxV);
  arrEq(out, c.Dst, `sao_edge[${i}]`);
}

// ---- whole-picture deblock + SAO ----
for (const f of g.frames) {
  const planes = {
    y: dec(f.Y), cb: dec(f.Cb), cr: dec(f.Cr),
  };
  deblockFrame(planes, f);
  arrEq(planes.y, dec(f.DebY), `${f.Label} deblock Y`);
  arrEq(planes.cb, dec(f.DebCb), `${f.Label} deblock Cb`);
  arrEq(planes.cr, dec(f.DebCr), `${f.Label} deblock Cr`);
  saoFrame(planes, f);
  arrEq(planes.y, dec(f.SaoY), `${f.Label} sao Y`);
  arrEq(planes.cb, dec(f.SaoCb), `${f.Label} sao Cb`);
  arrEq(planes.cr, dec(f.SaoCr), `${f.Label} sao Cr`);
}

console.log(`loop-filter golden cross-check OK: ${checks} values, ` +
  `${g.beta_tc.length} betaTc, ${g.luma.length} luma, ${g.chroma.length} chroma, ` +
  `${g.sao_band.length} sao_band, ${g.sao_edge.length} sao_edge, ${g.frames.length} whole frames`);
