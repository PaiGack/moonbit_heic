#!/usr/bin/env node
// Cross-checks the independent JS transcription of the residual-coefficient
// syntax layer (tools/residual_lib.mjs) against the authoritative truth that
// the real upstream Go encoder produced (tools/residual_golden.json, generated
// by export_residual_golden_test.go from gen2brain/h265).
//
//   node tools/crosscheck_residual.mjs
//
// Every CABAC bitstream is decoded by the JS decoder; the resulting transform
// coefficient levels must equal the Go coefficients value-for-value, and the
// pure context derivations must equal the Go derivations over their full
// traversal. Zero differences is the bar, matching the M3 recon round.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import {
  CabacDecoder, scanIndex, lastSigCoeffCtx, sigCoeffCtx,
  newSigCtxSet, sigCtxSetAt, decodeResidual,
  scanDiag, scanHor, scanVer,
} from './residual_lib.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const g = JSON.parse(fs.readFileSync(path.join(root, 'tools/residual_golden.json'), 'utf8'));

let checks = 0;
function eq(got, want, what) {
  checks++;
  if (got !== want) throw new Error(`${what}: got ${got}, want ${want}`);
}

// ---- pure derivations, full traversal -----------------------------------
for (const t of g.scan_index)
  eq(scanIndex(t.Log2, t.CIdx, t.Mode, t.Intra, t.Chroma), t.Want,
    `scanIndex(${t.Log2},${t.CIdx},${t.Mode},${t.Intra},${t.Chroma})`);

for (const t of g.last_sig_coeff_ctx)
  eq(lastSigCoeffCtx(t.Log2, t.CIdx, t.Bin), t.Want,
    `lastSigCoeffCtx(${t.Log2},${t.CIdx},${t.Bin})`);

// sigCoeffCtx: fixed order log2=2..5, cIdx 0,1, scan 0..2, csbf 0..3, y, x.
let k = 0;
for (let log2 = 2; log2 <= 5; log2++) {
  const n = 1 << log2;
  for (const cIdx of [0, 1])
    for (let scan = 0; scan < 3; scan++)
      for (let csbf = 0; csbf < 4; csbf++)
        for (let y = 0; y < n; y++)
          for (let x = 0; x < n; x++)
            eq(sigCoeffCtx(x, y, log2, cIdx, scan, csbf), g.sig_coeff_ctx[k++],
              `sigCoeffCtx(${x},${y},${log2},${cIdx},${scan},${csbf})`);
}
eq(k, g.sig_coeff_ctx.length, 'sigCoeffCtx traversal length');

// sigCtxSet.at: log2 2..5, cIdx 0,1,2, scan 0..2, csbf 0..3, yS, xS, y, x.
k = 0;
for (const log2 of [2, 3, 4, 5]) {
  const n = 1 << log2;
  for (const cIdx of [0, 1, 2])
    for (let scan = 0; scan < 3; scan++)
      for (let csbf = 0; csbf < 4; csbf++)
        for (let yS = 0; yS < n / 4; yS++)
          for (let xS = 0; xS < n / 4; xS++) {
            const set = newSigCtxSet(xS, yS, log2, cIdx, scan, csbf, false);
            for (let y = 0; y < 4; y++)
              for (let x = 0; x < 4; x++)
                eq(sigCtxSetAt(set, x, y), g.sig_ctx_set[k++],
                  `sigCtxSet(${log2},${cIdx},${scan},${csbf},${yS},${xS}).at(${x},${y})`);
          }
}
eq(k, g.sig_ctx_set.length, 'sigCtxSet traversal length');

// ---- CABAC bitstreams: JS decoder vs Go encoder -------------------------
for (let ci = 0; ci < g.cases.length; ci++) {
  const c = g.cases[ci];
  const b = { log2Size: c.Log2, cIdx: c.CIdx, predModeIntra: c.PredMode,
              intra: c.Intra, maxTransformSkipSize: 0 };
  const bytes = Array.from(Buffer.from(c.Bytes, 'base64'));
  const d = new CabacDecoder(bytes);
  d.initContexts(26, 2); // qp 26, I slice
  const coef = new Array(c.Coef.length).fill(0);
  const stat = [0, 0, 0, 0];
  decodeResidual(d, coef, b, stat, false, 1, 0, c.SignHiding, false, false, false);
  for (let i = 0; i < coef.length; i++)
    eq(coef[i], c.Coef[i], `case ${ci} (log2=${c.Log2} cIdx=${c.CIdx} mode=${c.PredMode} hiding=${c.SignHiding}) coef[${i}]`);
  eq(d.decodeTerminate(), 1, `case ${ci} termination`);
}

console.log(`crosscheck_residual: ${checks} values, 0 differences`);
console.log(`  ${g.scan_index.length} scanIndex, ${g.last_sig_coeff_ctx.length} lastSigCoeffCtx,`);
console.log(`  ${g.sig_coeff_ctx.length} sigCoeffCtx, ${g.sig_ctx_set.length} sigCtxSet,`);
console.log(`  ${g.cases.length} CABAC bitstreams decoded value-for-value.`);
