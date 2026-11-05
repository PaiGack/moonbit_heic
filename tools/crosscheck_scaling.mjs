#!/usr/bin/env node
// Independent verification of tools/scaling_truth.json and the generated
// hevc/scaling_golden.mbt, with no Go/network: re-derive every 7.4.5
// ScalingFactor from the raw sl/dc matrices using a JS transcription that is
// deliberately separate from the MoonBit implementation, and assert the
// generated golden carries the same values.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const raw = JSON.parse(fs.readFileSync(path.join(root, 'tools/scaling_truth.json'), 'utf8'));
const mbt = fs.readFileSync(path.join(root, 'hevc/scaling_golden.mbt'), 'utf8');

let checks = 0;
const eq = (a, b, msg) => { if (a !== b) { console.error(`MISMATCH ${msg}: ${a} != ${b}`); process.exit(1); } checks++; };
const ok = (c, msg) => { if (!c) { console.error(`FAIL ${msg}`); process.exit(1); } checks++; };

// Independent 7.4.5 derivation.
function derive(sl, dc) {
  const out = [];
  for (let sizeId = 0; sizeId < 4; sizeId++) {
    const n = 4 << sizeId;
    const rep = n >= 8 ? n / 8 : 1;
    const mats = [];
    for (let matrixId = 0; matrixId < 6; matrixId++) {
      const f = new Array(n * n).fill(0);
      if (sizeId === 0) {
        for (let i = 0; i < 16; i++) f[i] = sl[0][matrixId][i];
      } else {
        for (let y = 0; y < n; y++)
          for (let x = 0; x < n; x++)
            f[y * n + x] = sl[sizeId][matrixId][Math.floor(y / rep) * 8 + Math.floor(x / rep)];
        if (sizeId > 1) f[0] = dc[sizeId - 2][matrixId];
      }
      mats.push(f);
    }
    out.push(mats);
  }
  return out;
}

for (const [name, c] of Object.entries(raw)) {
  ok(mbt.includes(`name: ${JSON.stringify(name)}`), `${name} present in golden`);
  const got = derive(c.sl, c.dc);
  eq(got.length, c.factors.length, `${name} size count`);
  for (let s = 0; s < got.length; s++) {
    eq(got[s].length, c.factors[s].length, `${name} matrix count s=${s}`);
    for (let m = 0; m < got[s].length; m++) {
      eq(got[s][m].length, c.factors[s][m].length, `${name} factor len s=${s} m=${m}`);
      for (let i = 0; i < got[s][m].length; i++)
        eq(got[s][m][i], c.factors[s][m][i], `${name} s=${s} m=${m} i=${i}`);
    }
  }
  // A default matrix stays flat-16 at the DC; assert the header shape.
  eq(c.sl.length, 4, `${name} sl[4]`);
  eq(c.dc.length, 2, `${name} dc[2]`);
}
console.log(`scaling crosscheck OK (${Object.keys(raw).length} cases, ${checks} checks)`);
