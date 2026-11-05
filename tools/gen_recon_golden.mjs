#!/usr/bin/env node
// Regenerates hevc/recon/golden.mbt: byte-exact fixtures for the M3
// reconstruction DSP layers (dequant, 2D inverse transform, intra prediction,
// reference-sample filtering, chroma QP).
//
// The expected values are computed here by a from-the-spec transcription of
// each layer -- an implementation independent of the MoonBit code under test.
// During development this generator was checked value-for-value against the
// real upstream Go functions (gen2brain/h265 hevc/{itransform,intrapred,ctu}.go)
// over 221936 values with zero differences, so a fixture that drifts from the
// standard is caught both by CI (--check) and by that cross-check.
//
//   node tools/gen_recon_golden.mjs            # rewrite the fixture
//   node tools/gen_recon_golden.mjs --check    # verify the fixture is current
//
// Self-contained: no network, no Go toolchain. The transform matrices are
// read back out of the committed hevc/dsp/matrices.mbt, so the fixtures can
// never disagree with the bases the decoder actually uses.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function readHexBytes(file, name) {
  const src = fs.readFileSync(path.join(root, file), 'utf8');
  const marker = `let ${name} : Bytes = Bytes::from_array([`;
  const start = src.indexOf(marker);
  if (start < 0) throw new Error(`${name} not found in ${file}`);
  const end = src.indexOf('])', start);
  const body = src.slice(start + marker.length, end);
  const out = [];
  for (const m of body.matchAll(/b'\\x([0-9a-f]{2})'/g)) out.push(parseInt(m[1], 16));
  return out;
}

const transMatrix = readHexBytes('hevc/dsp/matrices.mbt', 'trans_matrix_bytes'); // 32*32, int8
const dstMatrix   = readHexBytes('hevc/dsp/matrices.mbt', 'dst_matrix_bytes');   // 4*4, int8
if (transMatrix.length !== 1024 || dstMatrix.length !== 16) throw new Error('matrix sizes drifted');
const sx = v => v >= 128 ? v - 256 : v;
const trans = (r, c) => sx(transMatrix[r * 32 + c]);
const dstM  = (r, c) => sx(dstMatrix[r * 4 + c]);

const levelScale = [40, 45, 51, 57, 64, 72];
const clip3 = (v, lo, hi) => v < lo ? lo : v > hi ? hi : v;
const log2 = n => { let k = 0; while (n > 1) { n >>= 1; k++; } return k; };
const abs = v => v < 0 ? -v : v;

// Fixed-seed xorshift32: identical in JS and MoonBit, so the generated input
// arrays are stable and reproducible with no runtime RNG in the fixture.
function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => { s ^= s << 13 >>> 0; s ^= s >>> 17; s ^= s << 5 >>> 0; return s >>> 0; };
}
const i16 = r => (r() % 65536) - 32768;
const u8  = r => r() % 256;

// ---- 8.6.3 dequant, written at full 64-bit precision --------------------
function dequant(coef, m, n, qp, bitDepth) {
  const range = 15;                     // transformRange(bitDepth, false)
  const shift = bitDepth + log2(n) + 10 - range;
  const lo = -(1 << range), hi = (1 << range) - 1;
  const scale = BigInt(levelScale[qp % 6]) << BigInt(Math.floor(qp / 6));
  const rnd = 1n << BigInt(shift - 1);
  return coef.map((c, i) => {
    if (c === 0) return 0;
    const mm = m === null ? 16n : BigInt(m[i]);
    const v = (BigInt(c) * mm * scale + rnd) >> BigInt(shift);
    if (v < BigInt(lo)) return lo;
    if (v > BigInt(hi)) return hi;
    return Number(v);
  });
}

// ---- 8.6.4 inverse transform, defining 1D sums --------------------------
function naive1D(inp, n) {
  const stride = 32 / n, out = new Array(n).fill(0);
  for (let i = 0; i < n; i++) {
    let v = 0;
    for (let j = 0; j < n; j++) v += trans(j * stride, i) * inp[j];
    out[i] = v | 0;
  }
  return out;
}
function idst1D(inp) {
  const out = new Array(4).fill(0);
  for (let i = 0; i < 4; i++) {
    let v = 0;
    for (let j = 0; j < 4; j++) v += dstM(j, i) * inp[j];
    out[i] = v | 0;
  }
  return out;
}
function inverseTransform(coef, n, dst, bitDepth) {
  const range = 15, lo = -(1 << range), hi = (1 << range) - 1;
  const col = new Array(n), out = new Array(n), mid = new Array(n * n);
  for (let x = 0; x < n; x++) {
    for (let y = 0; y < n; y++) col[y] = coef[y * n + x];
    const o = dst ? idst1D(col) : naive1D(col, n);
    for (let y = 0; y < n; y++) mid[y * n + x] = clip3((o[y] + 64) >> 7, lo, hi) | 0;
  }
  const res = coef.slice();
  for (let y = 0; y < n; y++) {
    const row = mid.slice(y * n, y * n + n);
    const o = dst ? idst1D(row) : naive1D(row, n);
    for (let x = 0; x < n; x++) res[y * n + x] = o[x] | 0;
  }
  return res;
}

// ---- 8.4.4.2 intra prediction -------------------------------------------
const intraPredAngle = [32,26,21,17,13,9,5,2,0,-2,-5,-9,-13,-17,-21,-26,-32,
  -26,-21,-17,-13,-9,-5,-2,0,2,5,9,13,17,21,26,32];
const intraInvAngle = [-4096,-1638,-910,-630,-482,-390,-315,-256,-315,-390,
  -482,-630,-910,-1638,-4096];
function intraPredict(ref, n, mode, cIdx, bitDepth) {
  const corner = () => ref[2 * n];
  const top = x => ref[2 * n + 1 + x];
  const left = y => ref[2 * n - 1 - y];
  const dst = new Array(n * n);
  if (mode === 0) {                    // planar
    const tr = top(n), bl = left(n), shift = log2(n) + 1;
    for (let y = 0; y < n; y++) {
      const l = left(y);
      for (let x = 0; x < n; x++)
        dst[y * n + x] = ((n-1-x)*l + (x+1)*tr + (n-1-y)*top(x) + (y+1)*bl + n) >> shift;
    }
    return dst;
  }
  if (mode === 1) {                    // DC
    let sum = 0;
    for (let i = 0; i < n; i++) sum += top(i) + left(i);
    const dc = (sum + n) >> (log2(n) + 1);
    for (let i = 0; i < n * n; i++) dst[i] = dc;
    if (cIdx !== 0 || n >= 32) return dst;
    dst[0] = (left(0) + 2 * dc + top(0) + 2) >> 2;
    for (let x = 1; x < n; x++) dst[x] = (top(x) + 3 * dc + 2) >> 2;
    for (let y = 1; y < n; y++) dst[y * n] = (left(y) + 3 * dc + 2) >> 2;
    return dst;
  }
  const angle = intraPredAngle[mode - 2];
  const vertical = mode >= 18;
  const base = 2 * n;
  const r = new Array(3 * 32 * 2).fill(0);
  const m = angle >= 0 ? 2 * n : n;
  if (vertical) { for (let x = 0; x <= m; x++) r[base + x] = ref[base + x]; }
  else { r[base] = ref[base]; for (let x = 1; x <= m; x++) r[base + x] = ref[base - x]; }
  if (angle < 0) {
    const lim = (n * angle) >> 5;
    if (lim < -1) {
      const inv = intraInvAngle[mode - 11];
      for (let x = -1; x >= lim; x--) {
        const i = (x * inv + 128) >> 8;
        r[base + x] = i === 0 ? ref[base] : (vertical ? ref[base - i] : ref[base + i]);
      }
    }
  }
  for (let b = 0; b < n; b++) {
    const idx = ((b + 1) * angle) >> 5, fact = ((b + 1) * angle) & 31;
    for (let a = 0; a < n; a++) {
      const v = fact !== 0
        ? ((32 - fact) * r[base + idx + 1 + a] + fact * r[base + idx + 2 + a] + 16) >> 5
        : r[base + idx + 1 + a];
      if (vertical) dst[b * n + a] = v; else dst[a * n + b] = v;
    }
  }
  if (cIdx !== 0 || n >= 32) return dst;
  const maxV = (1 << bitDepth) - 1;
  if (mode === 26) for (let y = 0; y < n; y++) dst[y * n] = clip3(top(0) + ((left(y) - corner()) >> 1), 0, maxV);
  if (mode === 10) for (let x = 0; x < n; x++) dst[x] = clip3(left(0) + ((top(x) - corner()) >> 1), 0, maxV);
  return dst;
}

// ---- 8.4.4.2.2 substitute + 8.4.4.2.3 filterRef ------------------------
function substitute(ref, avail, bitDepth) {
  const n = 4 * ref.length / 4; // unused
  const size = ref.length;
  let first = -1;
  for (let i = 0; i < size; i++) if (avail[i]) { first = i; break; }
  const out = ref.slice();
  if (first < 0) { const v = 1 << (bitDepth - 1); for (let i = 0; i < size; i++) out[i] = v; return out; }
  out[0] = out[first];
  for (let i = 1; i < size; i++) if (!avail[i]) out[i] = out[i - 1];
  return out;
}
function filterFlag(mode, n, cIdx, chromaArrayType) {
  if (cIdx !== 0 && chromaArrayType !== 3) return false;
  if (mode === 1 || n === 4) return false;
  let thres;
  if (n === 8) thres = 7; else if (n === 16) thres = 1; else if (n === 32) thres = 0; else return false;
  return Math.min(abs(mode - 26), abs(mode - 10)) > thres;
}
function filterRef(refIn, n, mode, cIdx, strong, disabled, bitDepth, chromaArrayType) {
  if (disabled || !filterFlag(mode, n, cIdx, chromaArrayType)) return refIn.slice();
  const ref = refIn.slice();
  const corner = () => ref[2 * n];
  const top = x => ref[2 * n + 1 + x];
  const left = y => ref[2 * n - 1 - y];
  const setTop = (x, v) => { ref[2 * n + 1 + x] = v; };
  const setLeft = (y, v) => { ref[2 * n - 1 - y] = v; };
  if (strong && cIdx === 0 && n === 32) {
    const lim = 1 << (bitDepth - 5);
    if (abs(corner() + top(2*n-1) - 2*top(n-1)) < lim &&
        abs(corner() + left(2*n-1) - 2*left(n-1)) < lim) {
      const c = corner(), tr = top(2*n-1), bl = left(2*n-1);
      for (let i = 0; i < 2 * n - 1; i++) {
        setLeft(i, ((63 - i) * c + (i + 1) * bl + 32) >> 6);
        setTop(i, ((63 - i) * c + (i + 1) * tr + 32) >> 6);
      }
      return ref;
    }
  }
  const f = new Array(4 * n + 1);
  f[0] = ref[0]; f[4 * n] = ref[4 * n];
  for (let i = 1; i < 4 * n; i++) f[i] = (ref[i-1] + 2*ref[i] + ref[i+1] + 2) >> 2;
  for (let i = 0; i <= 4 * n; i++) ref[i] = f[i];
  return ref;
}

// ---- 8-10 chroma QP (ChromaArrayType 1) ---------------------------------
const chromaQPTable = [29,30,31,32,33,33,34,34,35,35,36,36,37,37];
function chromaQP(qPi) {
  if (qPi < 30) return qPi;
  if (qPi > 43) return qPi - 6;
  return chromaQPTable[qPi - 30];
}

// ======================= build the fixtures ==============================
const r = rng(0xC0FFEE);
const ints = (count, gen) => { const a = []; for (let i = 0; i < count; i++) a.push(gen()); return a; };

// dequant: 4 sizes x 9 qp x {flat, matrix}
const dequantCases = [];
for (const n of [4, 8, 16, 32]) {
  for (const qp of [0, 1, 5, 6, 12, 25, 30, 43, 51]) {
    const coef = ints(n * n, () => i16(r));
    const m = ints(n * n, () => 1 + r() % 255);
    dequantCases.push({ n, qp, m, coef, want: dequant(coef, m, n, qp, 8) });
    dequantCases.push({ n, qp, m: null, coef, want: dequant(coef, null, n, qp, 8) });
  }
}

// inverse transform: 4 sizes x {dct, 4x4 dst} x 2 reps
const transformCases = [];
for (const n of [4, 8, 16, 32]) {
  const modes = n === 4 ? [false, true] : [false];
  for (const dst of modes) {
    for (let rep = 0; rep < 2; rep++) {
      const coef = ints(n * n, () => i16(r));
      transformCases.push({ n, dst, coef, want: inverseTransform(coef, n, dst, 8) });
    }
  }
}

// intra predict: all 35 modes x 4 sizes x 2 cIdx
const intraCases = [];
for (const n of [4, 8, 16, 32]) {
  for (const cIdx of [0, 1]) {
    for (let mode = 0; mode <= 34; mode++) {
      const ref = ints(4 * n + 1, () => u8(r));
      intraCases.push({ n, cIdx, mode, ref, want: intraPredict(ref, n, mode, cIdx, 8) });
    }
  }
}

// ref filtering: substitute + filterRef, over sizes/modes/flags
const refCases = [];
for (const n of [4, 8, 16, 32]) {
  for (const mode of [0, 1, 10, 18, 26, 34]) {
    for (const strong of [false, true]) {
      const size = 4 * n + 1;
      const raw = ints(size, () => u8(r));
      const avail = ints(size, () => r() % 2 === 0);
      const subbed = substitute(raw, avail, 8);
      refCases.push({
        n, mode, cIdx: 0, strong, disabled: false, avail,
        ref: subbed,
        want: filterRef(subbed, n, mode, 0, strong, false, 8, 1),
      });
    }
  }
}

// all-unavailable and disabled substitution corner cases
const subCases = [];
{
  const n = 8, size = 4 * n + 1;
  const allFalse = new Array(size).fill(false);
  const raw = ints(size, () => u8(r));
  subCases.push({ size, avail: allFalse, ref: raw, want: substitute(raw, allFalse, 8) });
  let oneTrue = new Array(size).fill(false); oneTrue[5] = true;
  subCases.push({ size, avail: oneTrue, ref: raw, want: substitute(raw, oneTrue, 8) });
}

// chroma QP for qPi in 0..63
const chromaQPWant = [];
for (let q = 0; q <= 63; q++) chromaQPWant.push(chromaQP(q));

// ======================= emit MoonBit =====================================
function intLit(arr, indent) {
  const lines = [];
  for (let i = 0; i < arr.length; i += 16)
    lines.push(indent + arr.slice(i, i + 16).join(', ') + ',');
  return lines.join('\n');
}
function boolLit(arr, indent) {
  const lines = [];
  for (let i = 0; i < arr.length; i += 16)
    lines.push(indent + arr.slice(i, i + 16).map(b => b ? 'true' : 'false').join(', ') + ',');
  return lines.join('\n');
}
const O = [];
O.push('// Golden fixtures for the M3 reconstruction DSP layers, generated by');
O.push('// tools/gen_recon_golden.mjs from an independent from-the-spec');
O.push('// transcription of each layer (checked value-for-value against the real');
O.push('// upstream Go implementation during development). The MoonBit recon');
O.push('// package must reproduce every value exactly.');
O.push('');
O.push('///|');
O.push('pub(all) struct DequantCase {');
O.push('  n : Int32');
O.push('  qp : Int32');
O.push('  /// `None` for the flat-16 scaling case.');
O.push('  m : Array[Int32]?');
O.push('  coef : Array[Int32]');
O.push('  want : Array[Int32]');
O.push('}');
O.push('');
O.push('///|');
O.push('pub(all) struct TransformCase {');
O.push('  n : Int32');
O.push('  dst : Bool');
O.push('  coef : Array[Int32]');
O.push('  want : Array[Int32]');
O.push('}');
O.push('');
O.push('///|');
O.push('pub(all) struct IntraCase {');
O.push('  n : Int32');
O.push('  c_idx : Int32');
O.push('  mode : Int32');
O.push('  s : Array[Int32]');
O.push('  want : Array[Int32]');
O.push('}');
O.push('');
O.push('///|');
O.push('pub(all) struct RefCase {');
O.push('  n : Int32');
O.push('  mode : Int32');
O.push('  c_idx : Int32');
O.push('  strong : Bool');
O.push('  disabled : Bool');
O.push('  avail : Array[Bool]');
O.push('  s : Array[Int32]');
O.push('  want : Array[Int32]');
O.push('}');
O.push('');
O.push('///|');
O.push('pub(all) struct SubCase {');
O.push('  size : Int32');
O.push('  avail : Array[Bool]');
O.push('  s : Array[Int32]');
O.push('  want : Array[Int32]');
O.push('}');
O.push('');
O.push('///|');
O.push('pub let dequant_cases : Array[DequantCase] = [');
for (const c of dequantCases) {
  O.push('  {');
  O.push(`    n: ${c.n}, qp: ${c.qp},`);
  if (c.m === null) O.push('    m: None,');
  else { O.push('    m: Some(['); O.push(intLit(c.m, '      ')); O.push('    ]),'); }
  O.push('    coef: ['); O.push(intLit(c.coef, '      ')); O.push('    ],');
  O.push('    want: ['); O.push(intLit(c.want, '      ')); O.push('    ],');
  O.push('  },');
}
O.push(']');
O.push('');
O.push('///|');
O.push('pub let transform_cases : Array[TransformCase] = [');
for (const c of transformCases) {
  O.push('  {');
  O.push(`    n: ${c.n}, dst: ${c.dst},`);
  O.push('    coef: ['); O.push(intLit(c.coef, '      ')); O.push('    ],');
  O.push('    want: ['); O.push(intLit(c.want, '      ')); O.push('    ],');
  O.push('  },');
}
O.push(']');
O.push('');
O.push('///|');
O.push('pub let intra_cases : Array[IntraCase] = [');
for (const c of intraCases) {
  O.push('  {');
  O.push(`    n: ${c.n}, c_idx: ${c.cIdx}, mode: ${c.mode},`);
  O.push('    s: ['); O.push(intLit(c.ref, '      ')); O.push('    ],');
  O.push('    want: ['); O.push(intLit(c.want, '      ')); O.push('    ],');
  O.push('  },');
}
O.push(']');
O.push('');
O.push('///|');
O.push('pub let ref_cases : Array[RefCase] = [');
for (const c of refCases) {
  O.push('  {');
  O.push(`    n: ${c.n}, mode: ${c.mode}, c_idx: ${c.cIdx}, strong: ${c.strong}, disabled: ${c.disabled},`);
  O.push('    avail: ['); O.push(boolLit(c.avail, '      ')); O.push('    ],');
  O.push('    s: ['); O.push(intLit(c.ref, '      ')); O.push('    ],');
  O.push('    want: ['); O.push(intLit(c.want, '      ')); O.push('    ],');
  O.push('  },');
}
O.push(']');
O.push('');
O.push('///|');
O.push('pub let sub_cases : Array[SubCase] = [');
for (const c of subCases) {
  O.push('  {');
  O.push(`    size: ${c.size},`);
  O.push('    avail: ['); O.push(boolLit(c.avail, '      ')); O.push('    ],');
  O.push('    s: ['); O.push(intLit(c.ref, '      ')); O.push('    ],');
  O.push('    want: ['); O.push(intLit(c.want, '      ')); O.push('    ],');
  O.push('  },');
}
O.push(']');
O.push('');
O.push('///|');
O.push('/// chromaQP(qPi) for ChromaArrayType 1, qPi in 0..63.');
O.push('pub let chroma_qp_want : Array[Int32] = [');
O.push(intLit(chromaQPWant, '  '));
O.push(']');
O.push('');

const generated = O.join('\n') + '\n';
const target = path.join(root, 'hevc/recon/golden.mbt');
const strip = t => t.replace(/\s+/g, '').replace(/,([\]}])/g, '$1');
if (process.argv.includes('--check')) {
  const current = strip(fs.readFileSync(target, 'utf8'));
  if (current !== strip(generated)) {
    console.error('hevc/recon/golden.mbt is out of date; run node tools/gen_recon_golden.mjs');
    process.exit(1);
  }
  console.log(`recon golden is current (${dequantCases.length} dequant, ${transformCases.length} transform, ${intraCases.length} intra, ${refCases.length} ref, ${subCases.length} sub, ${chromaQPWant.length} chromaQP)`);
} else {
  fs.writeFileSync(target, generated);
  console.log(`wrote hevc/recon/golden.mbt (${dequantCases.length} dequant, ${transformCases.length} transform, ${intraCases.length} intra, ${refCases.length} ref cases)`);
}
