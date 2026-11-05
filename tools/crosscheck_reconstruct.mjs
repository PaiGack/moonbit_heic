#!/usr/bin/env node
// Development-time cross-check (NOT a CI stage -- it needs a Go toolchain and
// a clone of the upstream). Holds tools/reconstruct_golden.json -- produced by
// the REAL upstream Go functions (buildMinTbAddr 6.5.2, available 6.4.1,
// predictQP 8.6.1, gatherRef 8.4.4.2.2) -- against an independent, from-the-
// spec JS transcription of those same derivations. Zero differences is the
// trust root for the geometry half of this increment.
//
// The reconstruction half (reconstructPlane -> real pixels) is cross-checked
// differently: tools/reconstruct_golden.json carries the upstream Go decoder's
// output, and hevc/reconstruct/reconstruct_test.mbt asserts the MoonBit port,
// built from the independently byte-exact-checked @recon / @residual / @cabac
// kernels, reproduces it sample for sample. Two decoders, one truth.
//
// Usage:
//   node tools/crosscheck_reconstruct.mjs [path/to/reconstruct_golden.json]

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const jsonPath = process.argv[2] || path.join(root, 'tools/reconstruct_golden.json');
if (!fs.existsSync(jsonPath)) {
  console.error(`no upstream dump at ${jsonPath}`);
  process.exit(2);
}
const G = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));

// ---- independent transcription of 6.5.2 / 6.4.1 / 8.6.1 / 8.4.4.2.2 ----

// 6.5.2 MinTbAddrZs: for a single-tile picture rsToTs is the identity, so
// ctb = (x>>ctbLog2) + ctbsW*(y>>ctbLog2) and the z-scan address interleaves
// the low bits of the min-TB coordinates into ctb<<(2*shift).
function minTbAddrTable(ctbsW, ctbsH, ctbLog2, minTbLog2) {
  const shift = ctbLog2 - minTbLog2;
  const minTbW = ctbsW << shift;
  const minTbH = ctbsH << shift;
  const out = new Array(minTbW * minTbH);
  for (let y = 0; y < minTbH; y++) {
    for (let x = 0; x < minTbW; x++) {
      const tbX = x >> shift, tbY = y >> shift;
      const ctb = tbY * ctbsW + tbX;
      let v = ctb << (shift * 2);
      for (let i = 0; i < shift; i++) {
        const m = 1 << i;
        if (m & x) v += m * m;
        if (m & y) v += 2 * m * m;
      }
      out[y * minTbW + x] = v;
    }
  }
  return out;
}

function availFromTable(addr, minTbW, minTbH, ctbLog2, minTbLog2,
                        picW, picH, xCurr, yCurr, xN, yN) {
  if (xN < 0 || yN < 0 || xN >= picW || yN >= picH) return false;
  const idx = (x, y) => (y >> minTbLog2) * minTbW + (x >> minTbLog2);
  // simpleAvail = true (single slice, no tiles): neighbour must precede in z-scan.
  return addr[idx(xN, yN)] < addr[idx(xCurr, yCurr)];
}

// 8.6.1 qPY_PRED: average of available left/above QP, else qpYPrev.
function predictQP(qpPrev, qpA, qpB, ctbLog2, x, y, leftOK, topOK,
                   leftInCtb, topInCtb) {
  let a = qpPrev, b = qpPrev;
  const mask = ~( (1 << ctbLog2) - 1 );
  if (leftOK && ((x - 1) & mask) === (x & mask)) a = qpA;
  if (topOK && ((y - 1) & mask) === (y & mask)) b = qpB;
  return (a + b + 1) >> 1;
}

// 8.4.4.2.2 gatherRef: derive avail[] and ref.s[] (after substitute).
function gatherRef(x, y, n, cIdx, plane, cplane, stride, cstride,
                   picW, picH, cw, ch, addr, minTbW, ctbLog2, minTbLog2) {
  const sw = cIdx > 0 ? 2 : 1, sh = cIdx > 0 ? 2 : 1;
  const pl = cIdx > 0 ? cplane : plane;
  const st = cIdx > 0 ? cstride : stride;
  const w = cIdx > 0 ? cw : picW, h = cIdx > 0 ? ch : picH;
  const size = 4 * n + 1;
  const avail = new Array(size);
  const s = new Array(size).fill(0);
  let lastTb = -1, lastOK = false;
  const tbIndex = (nx, ny) => (ny >> minTbLog2) * minTbW + (nx >> minTbLog2);
  for (let i = 0; i < size; i++) {
    let nx, ny;
    if (i < 2 * n) { nx = x - 1; ny = y + 2 * n - 1 - i; }
    else if (i === 2 * n) { nx = x - 1; ny = y - 1; }
    else { nx = x + i - 2 * n - 1; ny = y - 1; }
    let ok = nx >= 0 && ny >= 0 && nx < w && ny < h;
    if (ok) {
      const tb = tbIndex(nx * sw, ny * sh);
      if (tb !== lastTb) {
        lastTb = tb;
        lastOK = availFromTable(addr, minTbW, 0, ctbLog2, minTbLog2,
          picW, picH, x * sw, y * sh, nx * sw, ny * sh);
      }
      ok = lastOK;
    }
    avail[i] = ok;
    if (ok) s[i] = pl[ny * st + nx];
  }
  // substitute
  let first = -1;
  for (let i = 0; i < size; i++) if (avail[i]) { first = i; break; }
  if (first < 0) {
    for (let i = 0; i < size; i++) s[i] = 128; // 1<<(8-1)
  } else {
    s[0] = s[first];
    for (let i = 1; i < size; i++) if (!avail[i]) s[i] = s[i - 1];
  }
  return { s, avail };
}

const b64 = s => Buffer.from(s, 'base64');
let total = 0, bad = 0;
const chkEq = (got, want, label) => {
  total++;
  if (got !== want) { if (bad < 20) console.error(`MISMATCH ${label}: ${got} != ${want}`); bad++; }
};
const chkArr = (got, want, label) => {
  for (let i = 0; i < want.length; i++) chkEq(got[i], want[i], `${label}[${i}]`);
};

// min_tb_addr
for (const c of G.min_tb_addr) {
  const got = minTbAddrTable(c.CtbsW, c.CtbsH, c.CtbLog2, c.MinTbLog2);
  chkArr(got, c.Addr, `min_tb_addr/${c.CtbsW}x${c.CtbsH}/${c.CtbLog2}/${c.MinTbLog2}`);
}

// available (64x64, ctbLog2=6, minTbLog2=2, single tile -> identity rsToTs)
{
  const ctbLog2 = 6, minTbLog2 = 2, ctbsW = 1, ctbsH = 1, picW = 64, picH = 64;
  const addr = minTbAddrTable(ctbsW, ctbsH, ctbLog2, minTbLog2);
  const minTbW = ctbsW << (ctbLog2 - minTbLog2);
  for (const c of G.available) {
    const got = availFromTable(addr, minTbW, 0, ctbLog2, minTbLog2,
      picW, picH, c.XCurr, c.YCurr, c.XN, c.YN);
    chkEq(got, c.Want, `available/${c.XCurr},${c.YCurr}/${c.XN},${c.YN}`);
  }
}

// predict_qp
for (const c of G.predict_qp) {
  // exporter predicts at (8,8) with ctbLog2=6; left=(4,8) above=(8,4) both
  // precede (8,8) in z-scan and are inside the same CTB.
  const got = predictQP(c.QpPrev, c.QpA, c.QpB, 6, 8, 8, true, true, true, true);
  chkEq(got, c.Want, `predict_qp/${c.QpPrev}/${c.QpA}/${c.QpB}`);
}

// gather_ref
for (let k = 0; k < G.gather_ref.length; k++) {
  const c = G.gather_ref[k];
  const plane = b64(c.Plane), cplane = b64(c.CPlane);
  const ctbLog2 = 6, minTbLog2 = 2, addr = minTbAddrTable(1, 1, 6, 2);
  const minTbW = 1 << (6 - 2);
  const got = gatherRef(c.X, c.Y, c.N, c.CIdx, plane, cplane,
    64, 32, 64, 64, 32, 32, addr, minTbW, ctbLog2, minTbLog2);
  chkArr(got.s, c.Ref, `gather_ref/${k}/s`);
  chkArr(got.avail.map(v => v ? 1 : 0), c.Avail.map(v => v ? 1 : 0), `gather_ref/${k}/avail`);
}

console.log(`cross-check: ${total} values, ${bad} mismatch against upstream Go`);
process.exit(bad === 0 ? 0 : 1);
