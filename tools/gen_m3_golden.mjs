#!/usr/bin/env node
// Regenerates hevc/cabac/golden.mbt: CABAC bitstreams used to hold the M3
// arithmetic decoder to a byte-exact standard.
//
// The tables are read back out of the committed tables.mbt / matrices.mbt, so
// this script is self-contained (no network, no Go toolchain) and the golden
// data can never drift from the tables the decoder actually uses.
//
//   node tools/gen_m3_golden.mjs            # rewrite the fixture
//   node tools/gen_m3_golden.mjs --check    # verify the fixture is current
//
// Each bitstream comes from a longhand H.265 arithmetic encoder (a JS port of
// gen2brain/h265 hevc/cabac_test.go's cabacEncoder) and is decoded bin-for-bin
// here by a JS port of the Go cabac.go decoder before being written, so a bad
// encoder cannot silently produce a bad fixture.

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

const rangeTabLPS = readHexBytes('hevc/cabac/tables.mbt', 'range_tab_lps'); // 64*4
const transIdxLPS = readHexBytes('hevc/cabac/tables.mbt', 'trans_idx_lps'); // 64
const initValues  = readHexBytes('hevc/cabac/tables.mbt', 'init_values');   // 3*179
const transMatrix = readHexBytes('hevc/dsp/matrices.mbt', 'trans_matrix_bytes'); // 32*32, int8
const dstMatrix   = readHexBytes('hevc/dsp/matrices.mbt', 'dst_matrix_bytes');   // 4*4, int8
const nContexts = 179;

if (rangeTabLPS.length !== 256 || transIdxLPS.length !== 64 || initValues.length !== 537 ||
    transMatrix.length !== 1024 || dstMatrix.length !== 16) {
  throw new Error('table sizes drifted from the standard');
}
const sx = v => v >= 128 ? v - 256 : v;   // int8 sign extension

function initType(t, cabacInit) {
  let n = 2 - t;                       // I=2, P=1, B=0
  if (cabacInit && t !== 2) n ^= 3;
  return n;
}
function initState(v, qp) {
  const m = (v >> 4) * 5 - 45;
  const n = (v & 0x0f) * 8 - 16;
  const q = qp < 0 ? 0 : qp > 51 ? 51 : qp;
  let s = 2 * (((m * q) >> 4) + n) - 127;
  s = s | 0;
  s = s ^ (s >> 31);                   // Go's s ^= s >> 31, arithmetic
  if (s > 124) s = 124 + (s & 1);
  return s & 0xff;
}

// Longhand encoder of 9.3.4.4, from gen2brain/h265 hevc/cabac_test.go.
class CabacEncoder {
  constructor(qp, st) {
    this.low = 0; this.rng = 510; this.outstanding = 0; this.firstBit = true;
    this.out = []; this.nbits = 0;
    const row = initType(st, false);
    this.pStateIdx = new Array(nContexts);
    this.valMps = new Array(nContexts);
    for (let i = 0; i < nContexts; i++) {
      const s = initState(initValues[row * nContexts + i], qp);
      this.pStateIdx[i] = s >> 1;
      this.valMps[i] = s & 1;
    }
  }
  writeBit(b) {
    if (this.nbits % 8 === 0) this.out.push(0);
    if (b !== 0) this.out[this.out.length - 1] |= 1 << (7 - this.nbits % 8);
    this.nbits++;
  }
  putBit(b) {
    if (this.firstBit) this.firstBit = false;
    else this.writeBit(b);
    for (let i = 0; i < this.outstanding; i++) this.writeBit(1 - b);
    this.outstanding = 0;
  }
  renorm() {
    while (this.rng < 256) {
      if (this.low < 256) this.putBit(0);
      else if (this.low >= 512) { this.low = (this.low - 512) | 0; this.putBit(1); }
      else { this.low = (this.low - 256) | 0; this.outstanding++; }
      this.rng = this.rng << 1 >>> 0;
      this.low = this.low << 1 >>> 0;
    }
  }
  encodeBin(ctx, bin) {
    const lps = rangeTabLPS[this.pStateIdx[ctx] * 4 + ((this.rng >> 6) & 3)];
    this.rng = (this.rng - lps) >>> 0;
    if (bin !== this.valMps[ctx]) {
      this.low = (this.low + this.rng) >>> 0;
      this.rng = lps;
      if (this.pStateIdx[ctx] === 0) this.valMps[ctx] = 1 - this.valMps[ctx];
      this.pStateIdx[ctx] = transIdxLPS[this.pStateIdx[ctx]];
    } else {
      this.pStateIdx[ctx] = this.pStateIdx[ctx] >= 62 ? this.pStateIdx[ctx] : this.pStateIdx[ctx] + 1;
    }
    this.renorm();
  }
  encodeBypass(bin) {
    this.low = (this.low << 1) >>> 0;
    if (bin !== 0) this.low = (this.low + this.rng) >>> 0;
    if (this.low >= 1024) { this.low = (this.low - 1024) >>> 0; this.putBit(1); }
    else if (this.low < 512) this.putBit(0);
    else { this.low = (this.low - 512) >>> 0; this.outstanding++; }
  }
  encodeBypassBits(v, n) {
    for (let i = n - 1; i >= 0; i--) this.encodeBypass((v >> i) & 1);
  }
  encodeTerminate(bin) {
    this.rng = (this.rng - 2) >>> 0;
    if (bin === 0) { this.renorm(); return; }
    this.low = (this.low + this.rng) >>> 0;
    this.rng = 2;
    this.renorm();
    this.putBit((this.low >> 9) & 1);
    this.writeBit((this.low >> 8) & 1);
    this.writeBit(1);
  }
  finish() { while (this.out.length < 8) this.out.push(0); return this.out; }
}

// JS port of gen2brain/h265 hevc/cabac.go, used to self-check every fixture.
class CabacDecoder {
  static T = (() => {
    const lpsRange = [];
    for (let g = 0; g < 4; g++) {
      const row = new Array(128);
      for (let st = 0; st < 64; st++) {
        row[2 * st] = rangeTabLPS[st * 4 + g];
        row[2 * st + 1] = rangeTabLPS[st * 4 + g];
      }
      lpsRange.push(row);
    }
    const transState = new Array(256).fill(0);
    for (let st = 0; st < 64; st++) {
      const mps = st >= 62 ? st : st + 1;
      const lps = transIdxLPS[st];
      for (let v = 0; v < 2; v++) {
        const s = 2 * st + v;
        transState[128 + s] = (2 * mps + v) & 0xff;
        transState[127 - s] = (2 * lps + (st === 0 ? 1 - v : v)) & 0xff;
      }
    }
    return { lpsRange, transState };
  })();
  constructor(data) {
    this.data = data; this.pos = 2;
    this.low = ((data[0] << 18) + (data[1] << 10) + (1 << 9)) >>> 0;
    this.rng = 0x1fe;
    this.state = new Array(nContexts).fill(0);
  }
  initContexts(qp, st) {
    const row = initType(st, false);
    for (let i = 0; i < nContexts; i++) this.state[i] = initState(initValues[row * nContexts + i], qp);
  }
  byteAt(i) { return i < this.data.length ? this.data[i] : 0; }
  refill() { this.low = (this.low + (this.byteAt(this.pos) << 9) + (this.byteAt(this.pos + 1) << 1) - 0xffff) >>> 0; this.pos += 2; }
  refillShifted() {
    const ctz = this.low === 0 ? 32 : 31 - Math.clz32(this.low & -this.low);
    const i = ctz - 16;
    const x = ((this.byteAt(this.pos) << 9) + (this.byteAt(this.pos + 1) << 1) - 0xffff) >>> 0;
    this.low = (this.low + (x << i >>> 0)) >>> 0; this.pos += 2;
  }
  decodeBin(ctx) {
    const T = CabacDecoder.T;
    const s = this.state[ctx];
    const lps = T.lpsRange[(this.rng >> 6) & 3][s];
    this.rng = (this.rng - lps) >>> 0;
    const scaled = (this.rng << 17) >>> 0;
    const mask = (((scaled - this.low) >>> 0 | 0) >> 31) >>> 0;
    this.low = (this.low - (scaled & mask)) >>> 0;
    this.rng = (this.rng + (((lps - this.rng) >>> 0) & mask)) >>> 0;
    const mInt = mask === 0 ? 0 : -1;
    const sg = (s ^ mInt) | 0;
    this.state[ctx] = T.transState[128 + sg];
    const shift = Math.clz32(this.rng) - 23;    // 9 - Len32(rng)
    this.rng = (this.rng << shift) >>> 0;
    this.low = (this.low << shift) >>> 0;
    if ((this.low & 0xffff) === 0) this.refillShifted();
    return sg & 1;
  }
  decodeBypass() {
    this.low = (this.low + this.low) >>> 0;
    if ((this.low & 0xffff) === 0) this.refill();
    const r = (this.rng << 17) >>> 0;
    if ((this.low >>> 0) < (r >>> 0)) return 0;
    this.low = (this.low - r) >>> 0; return 1;
  }
  decodeBypassBits(n) { let v = 0; for (let i = 0; i < n; i++) v = (v << 1 | this.decodeBypass()) >>> 0; return v >>> 0; }
  decodeTerminate() {
    this.rng = (this.rng - 2) >>> 0;
    if ((this.low >>> 0) >= ((this.rng << 17) >>> 0)) return 1;
    if (this.rng < 256) { this.rng = this.rng << 1 >>> 0; this.low = this.low << 1 >>> 0; if ((this.low & 0xffff) === 0) this.refill(); }
    return 0;
  }
}

const opBin = 0, opBypass = 1, opBypassBits = 2, opTerminate = 3;
function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => { s ^= s << 13 >>> 0; s ^= s >>> 17; s ^= s << 5 >>> 0; return s >>> 0; };
}
function genCase(qp, st, seed, nops) {
  const r = rng(seed * 7919 + qp * 131 + st * 17 + 1);
  const ops = [];
  for (let k = 0; k < nops; k++) {
    const pick = r() % 10;
    if (pick === 0 || pick === 1) ops.push({ kind: opBypass, val: r() & 1 });
    else if (pick === 2) { const n = 1 + (r() % 16); ops.push({ kind: opBypassBits, n, val: (r() & ((1 << n) - 1)) >>> 0 }); }
    else if (pick === 3) ops.push({ kind: opTerminate, val: 0 });
    else ops.push({ kind: opBin, ctx: r() % nContexts, val: r() & 1 });
  }
  const e = new CabacEncoder(qp, st);
  for (const op of ops) {
    if (op.kind === opBin) e.encodeBin(op.ctx, op.val);
    else if (op.kind === opBypass) e.encodeBypass(op.val);
    else if (op.kind === opBypassBits) e.encodeBypassBits(op.val, op.n);
    else e.encodeTerminate(0);
  }
  e.encodeTerminate(1);
  return { qp, st, seed, bytes: e.finish(), ops };
}
function selfCheck(c) {
  const d = new CabacDecoder(c.bytes);
  d.initContexts(c.qp, c.st);
  for (let i = 0; i < c.ops.length; i++) {
    const op = c.ops[i];
    let got;
    if (op.kind === opBin) got = d.decodeBin(op.ctx);
    else if (op.kind === opBypass) got = d.decodeBypass();
    else if (op.kind === opBypassBits) got = d.decodeBypassBits(op.n);
    else got = d.decodeTerminate();
    if (got !== op.val) throw new Error(`self-check failed: case ${c.qp}/${c.st}/${c.seed} op ${i}`);
  }
  if (d.decodeTerminate() !== 1) throw new Error(`self-check: missing final terminator ${c.qp}/${c.st}/${c.seed}`);
}

function bytesLit(arr, indent) {
  const lines = [];
  for (let i = 0; i < arr.length; i += 16)
    lines.push(indent + arr.slice(i, i + 16).map(b => `b'\\x${b.toString(16).padStart(2, '0')}'`).join(', ') + ',');
  return lines.join('\n');
}
function intLit(arr, indent) {
  const lines = [];
  for (let i = 0; i < arr.length; i += 16)
    lines.push(indent + arr.slice(i, i + 16).join(', ') + ',');
  return lines.join('\n');
}

const combos = [[0, 2], [26, 2], [51, 0], [12, 1], [37, 2], [26, 0], [1, 2], [26, 1]];
const cases = [];
for (const [qp, st] of combos)
  for (const seed of [0, 1, 2]) {
    const c = genCase(qp, st, seed, 350);
    selfCheck(c);
    const flat = [];
    for (const op of c.ops) {
      if (op.kind === opBin) flat.push(0, op.ctx, 0, op.val);
      else if (op.kind === opBypass) flat.push(1, 0, 0, op.val);
      else if (op.kind === opBypassBits) flat.push(2, op.n, op.val, op.val);
      else flat.push(3, 0, 0, 0);
    }
    cases.push({ qp, st, seed, bytes: c.bytes, flat });
  }

const out = [
  '// Golden CABAC bitstreams, generated by tools/gen_m3_golden.mjs from an',
  '// independent longhand H.265 arithmetic encoder (a JS port of',
  '// gen2brain/h265 hevc/cabac_test.go). Each bitstream is self-checked',
  '// against a JS port of the Go decoder before being shipped here; the',
  '// MoonBit decoder must reproduce every bin exactly.',
  '///|',
  'pub(all) struct GoldenCase {',
  '  qp : Int32',
  '  slice_type_code : Int32',
  '  seed : Int32',
  '  bytes : Bytes',
  '  /// Flat [kind, a, b, want] quadruples; kind 0=bin 1=bypass 2=bypassBits 3=terminate.',
  '  ops : Array[Int32]',
  '}',
  '',
  '///|',
  'pub let golden_cases : Array[GoldenCase] = [',
];
for (const c of cases) {
  out.push('  {');
  out.push(`    qp: ${c.qp}, slice_type_code: ${c.st}, seed: ${c.seed},`);
  out.push('    bytes: Bytes::from_array([');
  out.push(bytesLit(c.bytes, '      '));
  out.push('    ]),');
  out.push('    ops: [');
  out.push(intLit(c.flat, '      '));
  out.push('    ],');
  out.push('  },');
}
out.push(']');
const generated = out.join('\n') + '\n';


// The DSP 1D transform fixtures: naive_1d / naive_1d_dst4 checked against the
// committed matrices, so the expected values can never drift from them either.
function rng2(seed) {
  let s = seed >>> 0 || 1;
  return () => { s ^= s << 13 >>> 0; s ^= s >>> 17; s ^= s << 5 >>> 0; return (s >>> 0) % 65536 - 32768; };
}
function naive1d(input, n) {
  const stride = 32 / n, out = [];
  for (let i = 0; i < n; i++) {
    let v = 0;
    for (let j = 0; j < n; j++) v += sx(transMatrix[j * stride * 32 + i]) * input[j];
    out.push(v);
  }
  return out;
}
function naiveDst4(input) {
  const out = [];
  for (let i = 0; i < 4; i++) {
    let v = 0;
    for (let j = 0; j < 4; j++) v += sx(dstMatrix[j * 4 + i]) * input[j];
    out.push(v);
  }
  return out;
}
const dspCases = [];
for (const n of [4, 8, 16, 32]) {
  const r = rng2(n * 100 + 7);
  const input = [];
  for (let i = 0; i < n; i++) input.push(r());
  dspCases.push({ n, input, out: naive1d(input, n) });
}
const r2 = rng2(999);
const dstInput = [r2(), r2(), r2(), r2()];
const dstOut = naiveDst4(dstInput);

const dspOut = [
  '// Naive 1D inverse transform fixtures, generated by tools/gen_m3_golden.mjs',
  '// from the committed transform matrices. The MoonBit naive_1d /',
  '// naive_1d_dst4 must reproduce these exactly.',
  '///|',
  'pub(all) struct NaiveCase {',
  '  n : Int32',
  '  input : Array[Int32]',
  '  want : Array[Int32]',
  '}',
  '',
  '///|',
  'pub let naive_cases : Array[NaiveCase] = [',
];
for (const c of dspCases) {
  dspOut.push('  {');
  dspOut.push(`    n: ${c.n},`);
  dspOut.push(`    input: [${c.input.join(', ')}],`);
  dspOut.push(`    want: [${c.out.join(', ')}],`);
  dspOut.push('  },');
}
dspOut.push(']');
dspOut.push('');
dspOut.push('///|');
dspOut.push(`pub let dst4_input : Array[Int32] = [${dstInput.join(', ')}]`);
dspOut.push('');
dspOut.push('///|');
dspOut.push(`pub let dst4_want : Array[Int32] = [${dstOut.join(', ')}]`);
const dspGenerated = dspOut.join('\n') + '\n';

const target = path.join(root, 'hevc/cabac/golden.mbt');
const dspTarget = path.join(root, 'hevc/dsp/golden.mbt');
const strip = t => t
  .replace(/\s+/g, '')
  // moon fmt adds a trailing comma to a folded array; a single-line one has
  // none. Both are the same data, so ignore the comma just before a closer.
  .replace(/,([\]}])/g, '$1');
if (process.argv.includes('--check')) {
  const current = strip(fs.readFileSync(target, 'utf8'));
  const dspCurrent = strip(fs.readFileSync(dspTarget, 'utf8'));
  let bad = false;
  // moon fmt folds array literals and expands Int to Int32; comparing after
  // stripping whitespace keeps the check independent of the formatter's line
  // breaking while still catching any changed byte or number.
  if (current !== strip(generated)) { console.error('hevc/cabac/golden.mbt is out of date'); bad = true; }
  if (dspCurrent !== strip(dspGenerated)) { console.error('hevc/dsp/golden.mbt is out of date'); bad = true; }
  if (bad) { console.error('run node tools/gen_m3_golden.mjs'); process.exit(1); }
  console.log(`golden fixtures are current (${cases.length} CABAC cases, ${cases.reduce((a, c) => a + c.flat.length / 4, 0)} bins, ${dspCases.length} DSP cases)`);
} else {
  fs.writeFileSync(target, generated);
  fs.writeFileSync(dspTarget, dspGenerated);
  console.log(`wrote hevc/cabac/golden.mbt (${cases.length} cases, ${cases.reduce((a, c) => a + c.flat.length / 4, 0)} bins)`);
  console.log(`wrote hevc/dsp/golden.mbt (${dspCases.length} cases)`);
}
