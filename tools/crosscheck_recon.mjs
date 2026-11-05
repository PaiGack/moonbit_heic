#!/usr/bin/env node
// Development-time cross-check (NOT a CI stage -- it needs a Go toolchain and
// a clone of the upstream). Verifies that the independent JS transcription in
// gen_recon_golden.mjs reproduces the REAL upstream Go functions value for
// value. This is the trust root of the golden fixtures:
//
//   upstream Go  --(this script)-->  JS transcription  --(gen)-->  MoonBit
//   functions        221936 exact       golden.mbt          assert_eq
//
// Usage:
//   git clone --depth 1 https://github.com/gen2brain/h265 /tmp/h265_up
//   cp tools/export_recon_golden_test.go /tmp/h265_up/hevc/zz_export_test.go
//   (cd /tmp/h265_up/hevc && go test -run TestExportGolden -count=1 .)
//   node tools/crosscheck_recon.mjs /tmp/recon_golden.json
//
// The exporter writes inputs and the upstream Want values as JSON; this
// script re-derives each Want with the same formulas the generator emits and
// requires zero differences.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const jsonPath = process.argv[2] || '/tmp/recon_golden.json';
if (!fs.existsSync(jsonPath)) {
  console.error(`no upstream dump at ${jsonPath}; see the header of this script`);
  process.exit(2);
}
const G = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));

function readHex(file, name) {
  const src = fs.readFileSync(path.join(root, file), 'utf8');
  const mk = `let ${name} : Bytes = Bytes::from_array([`;
  const a = src.indexOf(mk), b = src.indexOf('])', a);
  return [...src.slice(a + mk.length, b).matchAll(/b'\\x([0-9a-f]{2})'/g)].map(m => parseInt(m[1], 16));
}
const tm = readHex('hevc/dsp/matrices.mbt', 'trans_matrix_bytes');
const dm = readHex('hevc/dsp/matrices.mbt', 'dst_matrix_bytes');
const sx = v => v >= 128 ? v - 256 : v;
const trans = (r, c) => sx(tm[r * 32 + c]);
const dstM = (r, c) => sx(dm[r * 4 + c]);
const levelScale = [40, 45, 51, 57, 64, 72];
const clip3 = (v, lo, hi) => v < lo ? lo : v > hi ? hi : v;
const log2 = n => { let k = 0; while (n > 1) { n >>= 1; k++; } return k; };
const abs = v => v < 0 ? -v : v;
const intraPredAngle = [32,26,21,17,13,9,5,2,0,-2,-5,-9,-13,-17,-21,-26,-32,-26,-21,-17,-13,-9,-5,-2,0,2,5,9,13,17,21,26,32];
const intraInvAngle = [-4096,-1638,-910,-630,-482,-390,-315,-256,-315,-390,-482,-630,-910,-1638,-4096];
const chromaQPTable = [29,30,31,32,33,33,34,34,35,35,36,36,37,37];

function dequant(coef, m, n, qp, bd) {
  const range = 15, shift = bd + log2(n) + 10 - range;
  const lo = -(1 << range), hi = (1 << range) - 1;
  const scale = BigInt(levelScale[qp % 6]) << BigInt(Math.floor(qp / 6));
  const rnd = 1n << BigInt(shift - 1);
  return coef.map((c, i) => {
    if (c === 0) return 0;
    const mm = m === null ? 16n : BigInt(m[i]);
    const v = (BigInt(c) * mm * scale + rnd) >> BigInt(shift);
    return v < BigInt(lo) ? lo : v > BigInt(hi) ? hi : Number(v);
  });
}
function naive1D(inp, n) {
  const stride = 32 / n, out = new Array(n).fill(0);
  for (let i = 0; i < n; i++) { let v = 0; for (let j = 0; j < n; j++) v += trans(j * stride, i) * inp[j]; out[i] = v | 0; }
  return out;
}
function idst1D(inp) {
  const out = new Array(4).fill(0);
  for (let i = 0; i < 4; i++) { let v = 0; for (let j = 0; j < 4; j++) v += dstM(j, i) * inp[j]; out[i] = v | 0; }
  return out;
}
function inverseTransform(coef, n, dst, bd) {
  const range = 15, lo = -(1 << range), hi = (1 << range) - 1;
  const col = new Array(n), out = new Array(n), mid = new Array(n * n);
  for (let x = 0; x < n; x++) {
    for (let y = 0; y < n; y++) col[y] = coef[y * n + x];
    const o = dst ? idst1D(col) : naive1D(col, n);
    for (let y = 0; y < n; y++) mid[y * n + x] = clip3((o[y] + 64) >> 7, lo, hi) | 0;
  }
  const res = coef.slice();
  for (let y = 0; y < n; y++) { const o = dst ? idst1D(mid.slice(y * n, y * n + n)) : naive1D(mid.slice(y * n, y * n + n), n); for (let x = 0; x < n; x++) res[y * n + x] = o[x] | 0; }
  return res;
}
function intraPredict(ref, n, mode, cIdx, bd) {
  const corner = () => ref[2 * n], top = x => ref[2 * n + 1 + x], left = y => ref[2 * n - 1 - y];
  const dst = new Array(n * n);
  if (mode === 0) {
    const tr = top(n), bl = left(n), shift = log2(n) + 1;
    for (let y = 0; y < n; y++) { const l = left(y); for (let x = 0; x < n; x++) dst[y * n + x] = ((n-1-x)*l+(x+1)*tr+(n-1-y)*top(x)+(y+1)*bl+n)>>shift; }
    return dst;
  }
  if (mode === 1) {
    let sum = 0; for (let i = 0; i < n; i++) sum += top(i) + left(i);
    const dc = (sum + n) >> (log2(n) + 1);
    for (let i = 0; i < n * n; i++) dst[i] = dc;
    if (cIdx !== 0 || n >= 32) return dst;
    dst[0] = (left(0) + 2 * dc + top(0) + 2) >> 2;
    for (let x = 1; x < n; x++) dst[x] = (top(x) + 3 * dc + 2) >> 2;
    for (let y = 1; y < n; y++) dst[y * n] = (left(y) + 3 * dc + 2) >> 2;
    return dst;
  }
  const angle = intraPredAngle[mode - 2], vertical = mode >= 18, base = 2 * n;
  const r = new Array(3 * 32 * 2).fill(0), m = angle >= 0 ? 2 * n : n;
  if (vertical) { for (let x = 0; x <= m; x++) r[base + x] = ref[base + x]; }
  else { r[base] = ref[base]; for (let x = 1; x <= m; x++) r[base + x] = ref[base - x]; }
  if (angle < 0) {
    const lim = (n * angle) >> 5;
    if (lim < -1) { const inv = intraInvAngle[mode - 11];
      for (let x = -1; x >= lim; x--) { const i = (x * inv + 128) >> 8; r[base + x] = i === 0 ? ref[base] : (vertical ? ref[base - i] : ref[base + i]); } }
  }
  for (let b = 0; b < n; b++) {
    const idx = ((b + 1) * angle) >> 5, fact = ((b + 1) * angle) & 31;
    for (let a = 0; a < n; a++) {
      const v = fact !== 0 ? ((32 - fact) * r[base + idx + 1 + a] + fact * r[base + idx + 2 + a] + 16) >> 5 : r[base + idx + 1 + a];
      if (vertical) dst[b * n + a] = v; else dst[a * n + b] = v;
    }
  }
  if (cIdx !== 0 || n >= 32) return dst;
  const maxV = (1 << bd) - 1;
  if (mode === 26) for (let y = 0; y < n; y++) dst[y * n] = clip3(top(0) + ((left(y) - corner()) >> 1), 0, maxV);
  if (mode === 10) for (let x = 0; x < n; x++) dst[x] = clip3(left(0) + ((top(x) - corner()) >> 1), 0, maxV);
  return dst;
}
function filterFlag(mode, n, cIdx) {
  if (cIdx !== 0) return false;
  if (mode === 1 || n === 4) return false;
  let thres; if (n === 8) thres = 7; else if (n === 16) thres = 1; else if (n === 32) thres = 0; else return false;
  return Math.min(abs(mode - 26), abs(mode - 10)) > thres;
}
function filterRef(refIn, n, mode, cIdx, strong, disabled, bd) {
  if (disabled || !filterFlag(mode, n, cIdx)) return refIn.slice();
  const ref = refIn.slice();
  const corner = () => ref[2 * n], top = x => ref[2 * n + 1 + x], left = y => ref[2 * n - 1 - y];
  const setTop = (x, v) => { ref[2 * n + 1 + x] = v; }, setLeft = (y, v) => { ref[2 * n - 1 - y] = v; };
  if (strong && cIdx === 0 && n === 32) {
    const lim = 1 << (bd - 5);
    if (abs(corner() + top(2*n-1) - 2*top(n-1)) < lim && abs(corner() + left(2*n-1) - 2*left(n-1)) < lim) {
      const c = corner(), tr = top(2*n-1), bl = left(2*n-1);
      for (let i = 0; i < 2*n-1; i++) { setLeft(i, ((63-i)*c+(i+1)*bl+32)>>6); setTop(i, ((63-i)*c+(i+1)*tr+32)>>6); }
      return ref;
    }
  }
  const f = new Array(4*n+1); f[0] = ref[0]; f[4*n] = ref[4*n];
  for (let i = 1; i < 4*n; i++) f[i] = (ref[i-1]+2*ref[i]+ref[i+1]+2)>>2;
  for (let i = 0; i <= 4*n; i++) ref[i] = f[i];
  return ref;
}
function chromaQP(qPi) { if (qPi < 30) return qPi; if (qPi > 43) return qPi - 6; return chromaQPTable[qPi - 30]; }

let total = 0, bad = 0;
const chk = (got, want, label) => { for (let i = 0; i < want.length; i++) { total++; if (got[i] !== want[i]) { if (bad < 10) console.error(`MISMATCH ${label}[${i}]: ${got[i]} != ${want[i]}`); bad++; } } };
for (const c of G.dequant) chk(dequant(c.Coef, c.M === null ? null : c.M, c.N, c.QP, c.BitDepth), c.Want, `dequant/${c.N}/${c.QP}`);
for (const c of G.inverse_transform) chk(inverseTransform(c.Coef.slice(), c.N, c.Dst, c.BitDepth), c.Want, `it/${c.N}/${c.Dst}`);
for (const c of G.intra_predict) chk(intraPredict(c.Ref, c.N, c.Mode, c.CIdx, 8), c.Want, `ip/${c.N}/${c.Mode}`);
for (const c of G.ref_filter) chk(filterRef(c.Ref, c.N, c.Mode, c.CIdx, c.Strong, c.Disabled, 8), c.Want, `rf/${c.N}/${c.Mode}`);
for (let q = 0; q < G.chroma_qp.length; q++) { total++; if (chromaQP(q) !== G.chroma_qp[q]) { if (bad < 10) console.error(`MISMATCH chromaQP[${q}]`); bad++; } }
console.log(`cross-check: ${total} values, ${bad} mismatch against upstream Go`);
process.exit(bad === 0 ? 0 : 1);
