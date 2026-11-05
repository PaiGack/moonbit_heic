// Independent, from-the-spec JS transcription of the H.265 CTU-level CABAC
// syntax layer (7.3.8.2..7.3.8.10, 8.4.2, 8.6.1, 9.3.2.2) plus the pure
// context/derivation functions. Shared by crosscheck_syntax.mjs (which holds
// it against the real upstream Go code's output in tools/syntax_golden.json)
// and gen_syntax_golden.mjs (which bakes verified fixtures into
// hevc/syntax/golden.mbt). The CABAC arithmetic decoder is reused from
// residual_lib.mjs so there is exactly one transcription of 9.3.4 in tools/.

import { CabacDecoder } from './residual_lib.mjs';

export { CabacDecoder };

// Context offsets, Table 9-4 / 9.3.2.2 (from the spec, not from a port).
export const CTX = {
  SAOMergeFlag: 0, SAOTypeIDX: 1, SplitCodingUnitFlag: 2,
  CUTransquantBypassFlag: 5, SkipFlag: 6, CUQPDelta: 9, PredModeFlag: 12,
  PartMode: 13, PrevIntraLumaPredFlag: 17, IntraChromaPredMode: 18,
  SplitTransformFlag: 37, CBFLuma: 40, CBFCBCR: 42,
  CUChromaQPOffsetFlag: 177, CUChromaQPOffsetIDX: 178,
};

export const intraPlanar = 0, intraDC = 1, intraHor = 10, intraVer = 26;

// 8.4.2: derive the three most probable modes from neighbour luma modes A/B.
// absentA / absentB mean the neighbour is not intra (contributes intraDC) or
// sits above the current CTB row.
export function mpmCand(candA, candB) {
  let a = candA, b = candB;
  let cand;
  if (a === b && a < 2) {
    cand = [intraPlanar, intraDC, intraVer];
  } else if (a === b) {
    cand = [a, 2 + (a + 29) % 32, 2 + (a - 2 + 1) % 32];
  } else {
    cand = [a, b, 0];
    if (a !== intraPlanar && b !== intraPlanar) cand[2] = intraPlanar;
    else if (a !== intraDC && b !== intraDC) cand[2] = intraDC;
    else cand[2] = intraVer;
  }
  return cand;
}

// 9.3.4.2.2 split_cu_flag ctx: left/above neighbour CB depth > current depth.
export function splitCuCtx(leftDepth, aboveDepth, depth) {
  let ctx = 0;
  if (leftDepth > depth) ctx++;
  if (aboveDepth > depth) ctx++;
  return ctx;
}

// 7.4.9.11 ctxInc for split_transform_flag: 5 - log2Size.
export function splitTfCtx(log2Size) { return CTX.SplitTransformFlag + 5 - log2Size; }
// cbf_luma ctx: + (trafoDepth == 0 ? 0 : 1).
export function cbfLumaCtx(depth) { return CTX.CBFLuma + (depth === 0 ? 1 : 0); }
// cbf_cb/cbf_cr ctx: + trafoDepth.
export function cbfCbCrCtx(depth) { return CTX.CBFCBCR + depth; }

// Table 8-3 (4:2:2 chroma mode remap).
const chroma422Map = [
  0, 1, 2, 2, 2, 2, 3, 5, 7, 8, 10, 12, 13, 15, 17, 18, 19, 20,
  21, 22, 23, 23, 24, 24, 25, 25, 26, 27, 27, 28, 28, 29, 29, 30, 31,
];
export function chroma422(mode) { return chroma422Map[mode]; }

// Table 8-10 chromaQP for ChromaArrayType 1, qPi 0..57.
const chromaQPTable = [29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37];
export function chromaQP(qPi, chromaArrayType) {
  if (chromaArrayType !== 1) return Math.min(qPi, 51);
  if (qPi < 30) return qPi;
  if (qPi > 43) return qPi - 6;
  return chromaQPTable[qPi - 30];
}

// 8.6.1 QP wrap (8-bit: off = 0, m = 52).
export function qpWrap(pred, delta, bitDepth = 8) {
  const off = 6 * (bitDepth - 8);
  const m = 52 + off;
  return (((pred + delta + 52 + 2 * off) % m) + m) % m - off;
}

// sao_offset_abs cMax = 1 << (min(bitDepth,10)-5) - 1 (7.3.8.3).
export function saoOffsetCMax(bitDepth) {
  return (1 << (Math.min(bitDepth, 10) - 5)) - 1;
}

// 7.3.8.5 prev_intra_luma_pred_flag + rem_intra_luma_pred_mode -> mode.
export function decodeIntraLumaMode(c, cand) {
  const prev = c.decodeBin(CTX.PrevIntraLumaPredFlag) !== 0;
  if (prev) {
    let idx = 0;
    if (c.decodeBypass() !== 0) {
      idx = 1;
      if (c.decodeBypass() !== 0) idx = 2;
    }
    return cand[idx];
  }
  const sorted = [...cand].sort((x, y) => x - y);
  let mode = c.decodeBypassBits(5);
  for (const m of sorted) if (mode >= m) mode++;
  return mode;
}

// 7.3.8.5 intra_chroma_pred_mode -> chroma mode (Table 8-2), then 8-3 for 4:2:2.
export function decodeIntraChromaMode(c, luma, chromaFormatIDC = 1) {
  let mode = luma;
  if (c.decodeBin(CTX.IntraChromaPredMode) !== 0) {
    const idx = c.decodeBypassBits(2);
    mode = [intraPlanar, intraVer, intraHor, intraDC][idx];
    if (mode === luma) mode = 34;
  }
  if (chromaFormatIDC === 2) mode = chroma422(mode);
  return mode;
}

// 7.3.8.9 cu_qp_delta_abs / cu_qp_delta_sign_flag -> signed delta.
export function decodeCuQPDelta(c) {
  let prefix = 0;
  for (; prefix < 5; prefix++) {
    const ctx = prefix === 0 ? 0 : 1;
    if (c.decodeBin(CTX.CUQPDelta + ctx) === 0) break;
  }
  let v = prefix;
  if (prefix > 4) {
    let k = 0;
    for (; k < 6; k++) if (c.decodeBypass() === 0) break;
    v = 5 + ((1 << k) - 1) + c.decodeBypassBits(k);
  }
  if (v !== 0 && c.decodeBypass() !== 0) v = -v;
  return v;
}

// 7.3.8.10 cu_chroma_qp_offset_flag / idx -> cb/cr offsets from pps lists.
export function decodeCuChromaQPOffset(c, listLen, cbList, crList) {
  if (c.decodeBin(CTX.CUChromaQPOffsetFlag) === 0) return { cb: 0, cr: 0 };
  let idx = 0;
  const cMax = listLen - 1;
  for (; idx < cMax; idx++) {
    if (c.decodeBin(CTX.CUChromaQPOffsetIDX) === 0) break;
  }
  return { cb: cbList[idx], cr: crList[idx] };
}

// 7.3.8.5 part_mode, intra branch only (one bin: 1 => 2Nx2N, 0 => NxN).
export function decodePartModeIntra(c) {
  return c.decodeBin(CTX.PartMode) !== 0 ? 0 : 3; // partMode2Nx2N / partModeNxN
}

// 7.3.8.3 SAO: single CTB (0,0), no merge bins, 4:2:0 (3 components).
// Returns [ {typeIdx, offset[4], band, class} x 3 ], matching the upstream Go
// parseSAO's per-CTB sao array.
export function decodeSAO(c, bitDepth = 8, scaleLuma = 0, scaleChroma = 0) {
  const nComp = 3;
  const cMax = saoOffsetCMax(bitDepth);
  const out = [];
  const saoType = [0, 0];
  let eoClass = [0, 0];
  for (let cIdx = 0; cIdx < nComp; cIdx++) {
    const p = { typeIdx: 0, offset: [0, 0, 0, 0], band: 0, class: 0 };
    let typeIdx = 0;
    if (cIdx !== 2) {
      if (c.decodeBin(CTX.SAOTypeIDX) !== 0) {
        typeIdx = 1; // band
        if (c.decodeBypass() !== 0) typeIdx = 2; // edge
      }
      saoType[cIdx] = typeIdx;
    } else {
      typeIdx = saoType[1];
    }
    p.typeIdx = typeIdx;
    if (typeIdx === 0) { out.push(p); continue; }
    const offAbs = [0, 0, 0, 0];
    for (let i = 0; i < 4; i++) {
      let v = 0;
      while (v < cMax && c.decodeBypass() !== 0) v++;
      offAbs[i] = v;
    }
    const scale = cIdx > 0 ? scaleChroma : scaleLuma;
    if (typeIdx === 1) { // band
      for (let i = 0; i < 4; i++) {
        p.offset[i] = offAbs[i] << scale;
        if (offAbs[i] !== 0 && c.decodeBypass() !== 0) p.offset[i] = -p.offset[i];
      }
      p.band = c.decodeBypassBits(5);
    } else { // edge
      for (let i = 0; i < 4; i++) {
        p.offset[i] = offAbs[i] << scale;
        if (i >= 2) p.offset[i] = -p.offset[i];
      }
      if (cIdx !== 2) eoClass[cIdx] = c.decodeBypassBits(2);
      p.class = eoClass[Math.min(cIdx, 1)];
    }
    out.push(p);
  }
  return out;
}

export function newDecoder(bytes) {
  const c = new CabacDecoder(bytes);
  c.initContexts(26, 2, false); // qp 26, I slice
  return c;
}
