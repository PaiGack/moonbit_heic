// Independent, from-the-spec JS transcription of the H.265 residual-coefficient
// syntax layer (7.3.8.11) plus the CABAC arithmetic decoder (9.3.4). Shared by
// crosscheck_residual.mjs (which holds it against the real upstream Go encoder
// output) and gen_residual_golden.mjs (which bakes the verified fixtures into
// hevc/residual/golden.mbt). It reads the committed tables.mbt / matrices.mbt
// so its arithmetic can never drift from the MoonBit decoder's tables.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export function readHexBytes(file, name) {
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

export const rangeTabLPS = readHexBytes('hevc/cabac/tables.mbt', 'range_tab_lps'); // 64*4
export const transIdxLPS = readHexBytes('hevc/cabac/tables.mbt', 'trans_idx_lps'); // 64
export const initValues  = readHexBytes('hevc/cabac/tables.mbt', 'init_values');   // 3*179
export const nContexts = 179;

if (rangeTabLPS.length !== 256 || transIdxLPS.length !== 64 || initValues.length !== 537)
  throw new Error('CABAC table sizes drifted from the standard');

function initType(t, cabacInit) {
  let n = 2 - t;
  if (cabacInit && t !== 2) n ^= 3;
  return n;
}
function initState(v, qp) {
  const m = (v >> 4) * 5 - 45;
  const n = (v & 0x0f) * 8 - 16;
  const q = qp < 0 ? 0 : qp > 51 ? 51 : qp;
  let s = 2 * (((m * q) >> 4) + n) - 127;
  s = s | 0;
  s = s ^ (s >> 31);
  if (s > 124) s = 124 + (s & 1);
  return s & 0xff;
}

// JS port of gen2brain/h265 hevc/cabac.go (the decoder under test's shape).
export class CabacDecoder {
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
    if (data.length < 2) throw new Error('short CABAC init word');
    this.data = data;
    this.pos = 2;
    this.low = ((data[0] << 18) + (data[1] << 10) + (1 << 9)) >>> 0;
    this.rng = 0x1fe;
    this.state = new Array(nContexts).fill(0);
  }
  initContexts(qp, st) {
    const row = initType(st, false);
    for (let i = 0; i < nContexts; i++)
      this.state[i] = initState(initValues[row * nContexts + i], qp);
  }
  byteAt(i) { return i < this.data.length ? this.data[i] : 0; }
  refill() {
    this.low = (this.low + (this.byteAt(this.pos) << 9) + (this.byteAt(this.pos + 1) << 1) - 0xffff) >>> 0;
    this.pos += 2;
  }
  refillShifted() {
    const ctz = this.low === 0 ? 32 : 31 - Math.clz32(this.low & -this.low);
    const i = ctz - 16;
    const x = ((this.byteAt(this.pos) << 9) + (this.byteAt(this.pos + 1) << 1) - 0xffff) >>> 0;
    this.low = (this.low + (x << i >>> 0)) >>> 0;
    this.pos += 2;
  }
  decodeBin(ctx) {
    if (ctx < 0 || ctx >= nContexts) throw new Error('bad context ' + ctx);
    const T = CabacDecoder.T;
    const s = this.state[ctx];
    const lps = T.lpsRange[(this.rng >> 6) & 3][s];
    this.rng = (this.rng - lps) >>> 0;
    const scaled = (this.rng << 17) >>> 0;
    const mask = ((((scaled - this.low) >>> 0) | 0) >> 31) >>> 0;
    this.low = (this.low - (scaled & mask)) >>> 0;
    this.rng = (this.rng + ((((lps - this.rng) >>> 0) & mask))) >>> 0;
    const mInt = mask === 0 ? 0 : -1;
    const sg = (s ^ mInt) | 0;
    this.state[ctx] = T.transState[128 + sg];
    const shift = Math.clz32(this.rng) - 23;
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
    this.low = (this.low - r) >>> 0;
    return 1;
  }
  decodeBypassBits(n) {
    let v = 0;
    for (let i = 0; i < n; i++) v = (v << 1 | this.decodeBypass()) >>> 0;
    return v >>> 0;
  }
  decodeTerminate() {
    this.rng = (this.rng - 2) >>> 0;
    if ((this.low >>> 0) >= ((this.rng << 17) >>> 0)) return 1;
    if (this.rng < 256) {
      this.rng = (this.rng << 1) >>> 0;
      this.low = (this.low << 1) >>> 0;
      if ((this.low & 0xffff) === 0) this.refill();
    }
    return 0;
  }
}

// ---- 6.5 scan orders, built from the definition (not a table) -----------
export const scanDiag = 0, scanHor = 1, scanVer = 2;
export function buildDiagScan(size) {
  const out = [];
  for (let d = 0; d < 2 * size - 1; d++) {
    const ys = Math.min(d, size - 1), ye = Math.max(0, d - size + 1);
    for (let y = ys; y >= ye; y--) out.push([d - y, y]);
  }
  return out;
}
export function buildHorScan(size) {
  const out = [];
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) out.push([x, y]);
  return out;
}
export function buildVerScan(size) {
  const out = [];
  for (let x = 0; x < size; x++) for (let y = 0; y < size; y++) out.push([x, y]);
  return out;
}
export function scanOrder(log2, idx) {
  const size = 1 << log2;
  if (idx === scanDiag) return buildDiagScan(size);
  if (idx === scanHor) return buildHorScan(size);
  return buildVerScan(size);
}

// ---- 7.4.9.11 / 9.3.4.2 pure context derivations ----------------------
export function scanIndex(log2Size, cIdx, predModeIntra, intra, chromaArrayType) {
  if (!intra) return scanDiag;
  if (log2Size !== 2 && !(log2Size === 3 && (cIdx === 0 || chromaArrayType === 3)))
    return scanDiag;
  if (predModeIntra >= 6 && predModeIntra <= 14) return scanVer;
  if (predModeIntra >= 22 && predModeIntra <= 30) return scanHor;
  return scanDiag;
}
export function lastSigCoeffCtx(log2Size, cIdx, binIdx) {
  if (cIdx === 0)
    return (binIdx >> ((log2Size + 1) >> 2)) + 3 * (log2Size - 2) + ((log2Size - 1) >> 2);
  return (binIdx >> (log2Size - 2)) + 15;
}

export const sigCtxMap4x4 = [0, 1, 4, 5, 2, 3, 4, 5, 6, 6, 8, 8, 7, 7, 8, 8];
export const sigCtxByCsbf = (() => {
  const t = [];
  for (let csbf = 0; csbf < 4; csbf++) {
    const row = new Array(16).fill(0);
    for (let yP = 0; yP < 4; yP++) for (let xP = 0; xP < 4; xP++) {
      let sig = 0;
      if (csbf === 0) {
        if (xP + yP === 0) sig = 2;
        else if (xP + yP < 3) sig = 1;
      } else if (csbf === 1) {
        if (yP === 0) sig = 2;
        else if (yP === 1) sig = 1;
      } else if (csbf === 2) {
        if (xP === 0) sig = 2;
        else if (xP === 1) sig = 1;
      } else sig = 2;
      row[yP * 4 + xP] = sig;
    }
    t.push(row);
  }
  return t;
})();

export function sigCoeffCtx(xC, yC, log2Size, cIdx, scanIdx, prevCsbf) {
  let sig;
  if (log2Size === 2) {
    sig = sigCtxMap4x4[(yC << 2) + xC];
  } else if (xC + yC === 0) {
    sig = 0;
  } else {
    sig = sigCtxByCsbf[prevCsbf][(yC & 3) * 4 + (xC & 3)];
    if (cIdx === 0) {
      if ((xC >> 2) + (yC >> 2) > 0) sig += 3;
      if (log2Size === 3) sig += scanIdx === scanDiag ? 9 : 15;
      else sig += 21;
    } else {
      if (log2Size === 3) sig += 9;
      else sig += 12;
    }
  }
  return cIdx === 0 ? sig : 27 + sig;
}

// Context base constants of 9.3.2.2 (cabac_tables.go).
export const ctxTransformSkipFlag = 47;
export const ctxLastSigX = 53, ctxLastSigY = 71;
export const ctxSigGroup = 89;
export const ctxSigFlag = 93;
export const ctxGreater1 = 137;
export const ctxGreater2 = 161;

// ---- 9.3.3.11 / 9.3.4.2 syntax element helpers -------------------------
export function lastSigCoeffPrefix(c, base, log2Size, cIdx) {
  const cMax = log2Size * 2 - 1;
  let v = 0;
  while (v < cMax && c.decodeBin(base + lastSigCoeffCtx(log2Size, cIdx, v)) !== 0) v++;
  return v;
}
export function lastSigCoeffSuffix(c, prefix) {
  if (prefix <= 3) return prefix;
  const n = (prefix >> 1) - 1;
  const suffix = c.decodeBypassBits(n);
  return (1 << n) * (2 + (prefix & 1)) + suffix;
}
export function coeffAbsLevelRemaining(c, rice, rng) {
  const limit = rng > 0 ? 32 - rng : 32;
  let prefix = 0;
  while (prefix < limit && c.decodeBypass() !== 0) prefix++;
  if (prefix < 3) return (prefix << rice) + c.decodeBypassBits(rice);
  const k = prefix - 3;
  if (rng > 0 && prefix === limit)
    return ((1 << k) + 2) * (1 << rice) + c.decodeBypassBits(rng);
  return ((1 << k) + 2) * (1 << rice) + c.decodeBypassBits(k + rice);
}

// newSigCtxSet / at, the per-sub-block significance context of 9.3.4.2.5.
export function newSigCtxSet(xS, yS, log2Size, cIdx, scanIdx, prevCsbf, flat) {
  const c = { prevCsbf, is4x4: log2Size === 2, sbDC: (xS | yS) === 0, flat,
              base: 0, dc: 0, small: 0 };
  if (flat) {
    c.base = cIdx !== 0 ? 27 + 16 : 42;
    return c;
  }
  if (cIdx !== 0) {
    c.dc = 27; c.small = 27;
    c.base = 27 + (log2Size === 3 ? 9 : 12);
    return c;
  }
  if (xS + yS > 0) c.base = 3;
  if (log2Size === 3) c.base += scanIdx === scanDiag ? 9 : 15;
  else c.base += 21;
  return c;
}
export function sigCtxSetAt(c, x, y) {
  if (c.flat) return c.base;
  if (c.is4x4) return c.small + sigCtxMap4x4[y * 4 + x];
  if (c.sbDC && (x | y) === 0) return c.dc;
  return c.base + sigCtxByCsbf[c.prevCsbf][(y & 3) * 4 + (x & 3)];
}

const numSbCoeff = 16;
const anyTrue = v => v.some(Boolean);

export function updateStatCoeff(stat, i, rem) {
  if (rem >= 3 << (stat[i] / 4)) stat[i]++;
  else if (2 * rem < 1 << (stat[i] / 4) && stat[i] > 0) stat[i]--;
}

// decodeResidual, 7.3.8.11, transcribed from the spec/upstream. Returns
// { transformSkip, coef }. All sizes stay in JS numbers (32-bit clean here).
export function decodeResidual(c, coef, b, statCoeff,
                               persistentRiceAdaptation = false,
                               chromaArrayType = 1,
                               coeffRange = 0,
                               signDataHiding = false,
                               transformSkipEnabled = false,
                               transformSkipContext = false,
                               transquantBypass = false) {
  const n = 1 << b.log2Size;
  let transformSkip = false;
  if (transformSkipEnabled && !transquantBypass && b.log2Size <= b.maxTransformSkipSize)
    transformSkip = c.decodeBin(ctxTransformSkipFlag + Math.min(b.cIdx, 1)) !== 0;
  const flatCtx = transformSkipContext && (transformSkip || transquantBypass);
  const scanIdx = scanIndex(b.log2Size, b.cIdx, b.predModeIntra, b.intra, chromaArrayType);
  const xPrefix = lastSigCoeffPrefix(c, ctxLastSigX, b.log2Size, b.cIdx);
  const yPrefix = lastSigCoeffPrefix(c, ctxLastSigY, b.log2Size, b.cIdx);
  let lastX = lastSigCoeffSuffix(c, xPrefix);
  let lastY = lastSigCoeffSuffix(c, yPrefix);
  if (scanIdx === scanVer) { const t = lastX; lastX = lastY; lastY = t; }
  if (lastX >= n || lastY >= n) throw new Error('invalid last sig coeff');

  const sbLog2 = b.log2Size - 2;
  const sbScan = scanOrder(sbLog2, scanIdx);
  const coeffScan = scanOrder(2, scanIdx);
  let lastSubBlock = sbScan.length - 1;
  let lastScanPos = numSbCoeff;
  for (;;) {
    if (lastScanPos === 0) {
      lastScanPos = numSbCoeff;
      lastSubBlock--;
      if (lastSubBlock < 0) throw new Error('invalid last sub-block');
    }
    lastScanPos--;
    const [sx, sy] = sbScan[lastSubBlock];
    const [px, py] = coeffScan[lastScanPos];
    if (sx * 4 + px === lastX && sy * 4 + py === lastY) break;
  }

  const csbf = new Array(64).fill(false);
  const st = { started: false, greater1Ctx: 0, lastGreater1: false };
  const sbWidth = 1 << sbLog2;
  const sig = new Array(numSbCoeff).fill(false);

  for (let i = lastSubBlock; i >= 0; i--) {
    const [sx, sy] = sbScan[i];
    const xS = sx, yS = sy;
    let inferSbDcSig = false;
    if (i < lastSubBlock && i > 0) {
      let ctx = 0;
      if (xS + 1 < sbWidth && csbf[yS * sbWidth + xS + 1]) ctx++;
      if (yS + 1 < sbWidth && csbf[(yS + 1) * sbWidth + xS]) ctx++;
      const base = ctxSigGroup + (b.cIdx > 0 ? 2 : 0);
      csbf[yS * sbWidth + xS] = c.decodeBin(base + Math.min(ctx, 1)) !== 0;
      inferSbDcSig = true;
    } else {
      csbf[yS * sbWidth + xS] = true;
    }
    if (!csbf[yS * sbWidth + xS]) continue;
    let prevCsbf = 0;
    if (xS + 1 < sbWidth && csbf[yS * sbWidth + xS + 1]) prevCsbf++;
    if (yS + 1 < sbWidth && csbf[(yS + 1) * sbWidth + xS]) prevCsbf += 2;
    let start = numSbCoeff - 1;
    if (i === lastSubBlock) start = lastScanPos - 1;
    sig.fill(false);
    if (i === lastSubBlock) sig[lastScanPos] = true;
    const sigSet = newSigCtxSet(xS, yS, b.log2Size, b.cIdx, scanIdx, prevCsbf, flatCtx);
    for (let k = start; k >= 0; k--) {
      if (k === 0 && inferSbDcSig && !anyTrue(sig.slice(1))) { sig[0] = true; continue; }
      const [px, py] = coeffScan[k];
      const ctx = sigCtxSetAt(sigSet, px, py);
      sig[k] = c.decodeBin(ctxSigFlag + ctx) !== 0;
    }
    decodeSubBlockLevels(c, b, coef, sbScan[i], coeffScan, sig, i, n,
                         statCoeff, st, signDataHiding, persistentRiceAdaptation,
                         coeffRange, transquantBypass);
  }
  return transformSkip;
}

function decodeSubBlockLevels(c, b, coef, sb, coeffScan, sig, subBlock, n,
                              statCoeff, st, signDataHiding,
                              persistentRiceAdaptation, rng, transquantBypass) {
  const [xS, yS] = sb;
  let ctxSet = 0;
  if (subBlock > 0 && b.cIdx === 0) ctxSet = 2;
  let lastCtx = 1;
  if (st.started) {
    lastCtx = st.greater1Ctx;
    if (lastCtx > 0) lastCtx = st.lastGreater1 ? 0 : lastCtx + 1;
  }
  if (lastCtx === 0) ctxSet++;
  st.started = true;
  const pos = [];
  for (let k = numSbCoeff - 1; k >= 0; k--) if (sig[k]) pos.push(k);
  if (pos.length === 0) return;
  const firstSig = pos[pos.length - 1], lastSig = pos[0];
  let lastGreater1 = -1;
  const greater1 = new Array(numSbCoeff).fill(false);
  let numGreater1 = 0, greater1Ctx = 1;
  for (const k of pos) {
    if (numGreater1 < 8) {
      let ctx = ctxSet * 4 + Math.min(3, greater1Ctx);
      if (b.cIdx > 0) ctx += 16;
      greater1[k] = c.decodeBin(ctxGreater1 + ctx) !== 0;
      numGreater1++;
      st.greater1Ctx = greater1Ctx;
      st.lastGreater1 = greater1[k];
      if (greater1[k]) {
        greater1Ctx = 0;
        if (lastGreater1 < 0) lastGreater1 = k;
      } else if (greater1Ctx > 0) greater1Ctx++;
    }
  }
  let greater2 = false;
  if (lastGreater1 >= 0) {
    const ctx = ctxSet + (b.cIdx > 0 ? 4 : 0);
    greater2 = c.decodeBin(ctxGreater2 + ctx) !== 0;
  }
  const signHidden = lastSig - firstSig > 3 && !transquantBypass;
  const signs = new Array(numSbCoeff).fill(false);
  for (const k of pos) {
    if (signDataHiding && signHidden && k === firstSig) continue;
    signs[k] = c.decodeBypass() !== 0;
  }
  let rice = 0;
  if (persistentRiceAdaptation) rice = Math.floor(statCoeff[b.cIdx === 0 ? 0 : 2] / 4);
  let numSig = 0, sumAbs = 0, firstRemaining = true;
  for (const k of pos) {
    let base = 1;
    if (greater1[k]) base++;
    if (k === lastGreater1 && greater2) base++;
    let want = 1;
    if (numSig < 8) { want = 2; if (k === lastGreater1) want = 3; }
    let level = base;
    if (base === want) {
      const rem = coeffAbsLevelRemaining(c, rice, rng);
      level = base + rem;
      if (persistentRiceAdaptation && firstRemaining) {
        updateStatCoeff(statCoeff, b.cIdx === 0 ? 0 : 2, rem);
        firstRemaining = false;
      }
      if (level > 3 << rice) rice = Math.min(rice + 1, 4);
    }
    sumAbs += level;
    if (signs[k]) level = -level;
    if (signDataHiding && signHidden && k === firstSig && sumAbs % 2 === 1) level = -level;
    const [px, py] = coeffScan[k];
    const xC = xS * 4 + px, yC = yS * 4 + py;
    coef[yC * n + xC] = level;
    numSig++;
  }
}
