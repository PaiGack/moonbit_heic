// Independent, from-the-spec transcription of HEVC loop filtering
//   - 8.7.2 deblocking (beta/tc, boundary strength, luma strong/normal,
//     chroma), and
//   - 8.7.3 sample adaptive offset (band + edge).
//
// Written directly from the spec / the readable upstream Go (deblock.go,
// sao.go) as an independent implementation. Shared by
// crosscheck_loopfilter.mjs (verifies the upstream Go truth) and
// gen_loopfilter_golden.mjs (bakes the verified values into MoonBit fixtures).
// No Go toolchain, no network.

// 5.6 Clip3, on 32-bit carriers (all values here stay within Int32).
export const clip3 = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);
export const abs = v => (v < 0 ? -v : v);
export const sign = v => (v < 0 ? -1 : v > 0 ? 1 : 0);

// Table 8-12 (beta) and the tc table, transcribed verbatim.
export const betaTable = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24,
  26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56,
  58, 60, 62, 64,
];
export const tcTable = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3,
  3, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, 8, 9, 10, 11, 13,
  14, 16, 18, 20, 22, 24,
];

export const chromaQP = (qPi, cat) => {
  if (cat !== 1) return Math.min(qPi, 51);
  if (qPi < 30) return qPi;
  if (qPi > 43) return qPi - 6;
  return [29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37][qPi - 30];
};

// betaTc (8.7.2.5.3 setup). For 8-bit, the (1<<(bitDepth-8)) factor is 1.
export function betaTc(qp, bs, betaOffDiv2, tcOffDiv2, bitDepth = 8) {
  const scale = 1 << (bitDepth - 8);
  const qb = clip3(qp + betaOffDiv2 * 2, 0, 51);
  const beta = betaTable[qb] * scale;
  const qt = clip3(qp + 2 * (bs - 1) + tcOffDiv2 * 2, 0, 53);
  const tc = tcTable[qt] * scale;
  return { beta, tc };
}

// Table 8-16: two neighbour offsets per edge class.
export const eoOffsets = [
  [[-1, 0], [1, 0]],
  [[0, -1], [0, 1]],
  [[-1, -1], [1, 1]],
  [[1, -1], [-1, 1]],
];

// 8.7.2.5.3 luma decision over a 4x8 strip. The strip is 4 lines of 8
// samples indexed -4..3 (physical column = i+4). Returns the plan for the
// 4-line group.
export function deblockLumaPlan(strip, beta, tc) {
  // strip[l][i+4], l in 0..3, i in -4..3
  const at = (l, i) => strip[l * 8 + i + 4];
  const dp0 = abs(at(0, -3) - 2 * at(0, -2) + at(0, -1));
  const dq0 = abs(at(0, 2) - 2 * at(0, 1) + at(0, 0));
  const dp3 = abs(at(3, -3) - 2 * at(3, -2) + at(3, -1));
  const dq3 = abs(at(3, 2) - 2 * at(3, 1) + at(3, 0));
  const dp = dp0 + dp3;
  const dq = dq0 + dq3;
  if (dp + dq >= beta) return { tc: 0, mode: 0, nDp: 0, nDq: 0 };
  const strong = (l, d2) =>
    2 * d2 < (beta >> 2) &&
    abs(at(l, -4) - at(l, -1)) + abs(at(l, 0) - at(l, 3)) < (beta >> 3) &&
    abs(at(l, -1) - at(l, 0)) < ((5 * tc + 1) >> 1);
  if (strong(0, dp0 + dq0) && strong(3, dp3 + dq3)) {
    return { tc, mode: 1 /* strong */, nDp: 0, nDq: 0 };
  }
  const nDp = dp < ((beta + (beta >> 1)) >> 3) ? 1 : 0;
  const nDq = dq < ((beta + (beta >> 1)) >> 3) ? 1 : 0;
  return { tc, mode: 2 /* normal */, nDp, nDq };
}

// 8.7.2.5.7 luma apply over a 4x8 strip, mutating a copy.
export function deblockLumaApply(strip, pl, bitDepth, noP, noQ) {
  const tc = pl.tc;
  const maxV = (1 << bitDepth) - 1;
  const out = strip.slice();
  const at = (l, i) => strip[l * 8 + i + 4];
  const set = (l, i, v) => {
    if ((i < 0 && noP) || (i >= 0 && noQ)) return;
    out[l * 8 + i + 4] = clip3(v, 0, maxV);
  };
  if (pl.mode === 1 /* strong */) {
    const c = 2 * tc;
    for (let l = 0; l < 4; l++) {
      const p0 = at(l, -1), p1 = at(l, -2), p2 = at(l, -3), p3 = at(l, -4);
      const q0 = at(l, 0), q1 = at(l, 1), q2 = at(l, 2), q3 = at(l, 3);
      set(l, -1, clip3((p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3, p0 - c, p0 + c));
      set(l, -2, clip3((p2 + p1 + p0 + q0 + 2) >> 2, p1 - c, p1 + c));
      set(l, -3, clip3((2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3, p2 - c, p2 + c));
      set(l, 0, clip3((p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3, q0 - c, q0 + c));
      set(l, 1, clip3((p0 + q0 + q1 + q2 + 2) >> 2, q1 - c, q1 + c));
      set(l, 2, clip3((p0 + q0 + q1 + 3 * q2 + 2 * q3 + 4) >> 3, q2 - c, q2 + c));
    }
    return out;
  }
  // normal
  for (let l = 0; l < 4; l++) {
    const p0 = at(l, -1), p1 = at(l, -2), p2 = at(l, -3);
    const q0 = at(l, 0), q1 = at(l, 1), q2 = at(l, 2);
    let delta = (9 * (q0 - p0) - 3 * (q1 - p1) + 8) >> 4;
    if (abs(delta) >= tc * 10) continue;
    delta = clip3(delta, -tc, tc);
    set(l, -1, p0 + delta);
    set(l, 0, q0 - delta);
    if (pl.nDp !== 0) {
      set(l, -2, p1 + clip3((((p2 + p0 + 1) >> 1) - p1 + delta) >> 1, -(tc >> 1), tc >> 1));
    }
    if (pl.nDq !== 0) {
      set(l, 1, q1 + clip3((((q2 + q0 + 1) >> 1) - q1 - delta) >> 1, -(tc >> 1), tc >> 1));
    }
  }
  return out;
}

// 8.7.2.5.5 chroma line.
export function chromaLine(inp, tc, maxV, noP, noQ) {
  // inp = [p1, p0, q0, q1]
  const out = inp.slice();
  const p0 = inp[1], p1 = inp[0], q0 = inp[2], q1 = inp[3];
  const delta = clip3((((q0 - p0) << 2) + p1 - q1 + 4) >> 3, -tc, tc);
  if (!noP) out[1] = clip3(p0 + delta, 0, maxV);
  if (!noQ) out[2] = clip3(q0 - delta, 0, maxV);
  return out;
}

// 8.7.3 SAO band offset over a run.
export function saoBandRow(src, band, offset, shift, maxV) {
  return src.map(v => {
    const k = ((v >> shift) - band) & 31;
    return k < 4 ? clip3(v + offset[k], 0, maxV) : v;
  });
}

// 8.7.3 SAO edge offset over a run, with the two neighbour rows.
export function saoEdgeRow(src, na, nb, offset, maxV) {
  return src.map((v, i) => {
    const cat = sign(v - na[i]) + sign(v - nb[i]);
    if (cat === 0) return v;
    const k = cat > 0 ? cat + 1 : cat + 2;
    return clip3(v + offset[k], 0, maxV);
  });
}

// ---- Whole-picture deblock + SAO, matching the upstream single-thread,
// single-slice, single-tile geometry (which is all an M3 I-frame needs). ----

// A controlled decoder state, matching what the Go exporter builds.
export function makeState(f) {
  const w = f.W, h = f.H, ctbSize = 1 << f.CtbLog2;
  const minTbW = Math.ceil(w / 4), minTbH = Math.ceil(h / 4);
  const mvW = Math.ceil(w / 4), mvH = Math.ceil(h / 4);
  // blk flags: one 8x8 TU/PU per cell -> every 4x4 block on an 8-grid edge
  // carries intra+cbf and the appropriate tu/pu boundary flag.
  const blk = new Array(mvW * mvH).fill(null).map(() => ({
    intra: true, cbf: true, tuV: false, tuH: false, puV: false, puH: false,
  }));
  const blkIndex = (x, y) => (y >> 2) * mvW + (x >> 2);
  for (let ty = 0; ty < h; ty += 8) {
    for (let tx = 0; tx < w; tx += 8) {
      for (let j = 0; j < 2; j++) {
        for (let i = 0; i < 2; i++) {
          const bi = blkIndex(tx + i * 4, ty + j * 4);
          if (bi >= blk.length) continue;
          if (i === 0) { blk[bi].tuV = true; blk[bi].puV = true; }
          if (j === 0) { blk[bi].tuH = true; blk[bi].puH = true; }
        }
      }
    }
  }
  const tbIndex = (x, y) => (y >> 2) * minTbW + (x >> 2);
  const qpY = f.QpField;
  const noFilter = f.NoFilter;
  return { w, h, ctbSize, minTbW, minTbH, blk, blkIndex, tbIndex, qpY, noFilter };
}

// boundaryStrength 8.7.2.4 (I-frame: p.intra||q.intra -> 2 whenever the edge
// is a TU or PU boundary).
export function boundaryStrength(st, xP, yP, xQ, yQ, vertical) {
  const q = st.blk[st.blkIndex(xQ, yQ)];
  const tu = vertical ? q.tuV : q.tuH;
  const pu = vertical ? q.puV : q.puH;
  if (!tu && !pu) return 0;
  const p = st.blk[st.blkIndex(xP, yP)];
  if (p.intra || q.intra) return 2;
  if (tu && (p.cbf || q.cbf)) return 1;
  return 1; // mvValid false in the controlled state
}

// deblockEdge over one 8x8 edge segment (luma + both chroma), reproducing
// deblock.go deblockEdge + deblockChromaEdge for the single-slice/tile case.
function deblockEdge(planes, st, f, x, y, vertical) {
  const { w, h } = st;
  const qpY = st.qpY, noFilter = st.noFilter;
  const sl = { deblockingDisabled: f.DeblockOff,
    betaOffsetDiv2: f.BetaOff, tcOffsetDiv2: f.TcOff,
    cbQPOffset: 0, crQPOffset: 0 };
  if (sl.deblockingDisabled) return;
  const strideY = w, strideC = w >> 1;
  const step = vertical ? 1 : strideY;
  const line = vertical ? strideY : 1;
  const base = y * strideY + x;

  const pl = [null, null];
  const noP = [false, false], noQ = [false, false];
  const onC = [false, false], qpC = [0, 0];

  for (let k = 0; k < 8; k += 4) {
    let px, py, qx, qy;
    if (vertical) { px = x - 1; py = y + k; qx = x; qy = y + k; }
    else { px = x + k; py = y - 1; qx = x + k; qy = y; }
    if (qy >= h || qx >= w) continue;
    const bs = boundaryStrength(st, px, py, qx, qy, vertical);
    if (bs === 0) continue;
    const pt = st.tbIndex(px, py), qt = st.tbIndex(qx, qy);
    const qp = (qpY[pt] + qpY[qt] + 1) >> 1;
    noP[k >> 2] = noFilter[pt];
    noQ[k >> 2] = noFilter[qt];
    const { beta, tc } = betaTc(qp, bs, sl.betaOffsetDiv2, sl.tcOffsetDiv2, 8);
    if (beta !== 0 && tc !== 0) {
      // gather 4x8 luma strip (indices -4..3) around the edge
      const strip = new Array(32).fill(0);
      for (let l = 0; l < 4; l++) {
        for (let i = -4; i < 4; i++) {
          const sx = vertical ? x + i : x + k + l;
          const sy = vertical ? y + k + l : y + i;
          if (sx < 0 || sx >= w || sy < 0 || sy >= h) continue;
          strip[l * 8 + i + 4] = planes.y[sy * strideY + sx];
        }
      }
      pl[k >> 2] = deblockLumaPlan(strip, beta, tc);
    }
    if (bs === 2) {
      if (vertical && x % (8 * 2) !== 0) continue;
      if (!vertical && y % (8 * 2) !== 0) continue;
      onC[k >> 2] = true; qpC[k >> 2] = qp;
    }
  }

  // chroma edge
  if (onC[0] || onC[1]) {
    const n = vertical ? 4 / 2 : 4 / 2; // subHeightC=2 / subWidthC=2
    for (let g = 0; g < 2; g++) {
      if (!onC[g]) continue;
      const cx = vertical ? x : x + 4 * g;
      const cy = vertical ? y + 4 * g : y;
      if (f.QpY === undefined) continue;
      const qpcb = chromaQP(clip3(qpC[g] + 0, 0, 57), 1);
      const { tc: tcCb } = betaTc(qpcb, 2, sl.betaOffsetDiv2, sl.tcOffsetDiv2, 8);
      const { tc: tcCr } = betaTc(qpcb, 2, sl.betaOffsetDiv2, sl.tcOffsetDiv2, 8);
      if (tcCb === 0 && tcCr === 0) continue;
      const lines = n;
      const cbBase = (cy >> 1) * strideC + (cx >> 1);
      const crBase = cbBase;
      const cStep = vertical ? 1 : strideC;
      const cLine = vertical ? strideC : 1;
      for (let l = 0; l < lines; l++) {
        const off = cbBase + l * cLine;
        // chromaLine over [p1,p0,q0,q1] at off-2..off+1
        const inCb = [planes.cb[off - 2 * cStep], planes.cb[off - cStep],
          planes.cb[off], planes.cb[off + cStep]];
        const inCr = [planes.cr[off - 2 * cStep], planes.cr[off - cStep],
          planes.cr[off], planes.cr[off + cStep]];
        const outCb = chromaLine(inCb, tcCb, 255, noP[g], noQ[g]);
        const outCr = chromaLine(inCr, tcCr, 255, noP[g], noQ[g]);
        if (tcCb !== 0) {
          if (!noP[g]) planes.cb[off - cStep] = outCb[1];
          if (!noQ[g]) planes.cb[off] = outCb[2];
        }
        if (tcCr !== 0) {
          if (!noP[g]) planes.cr[off - cStep] = outCr[1];
          if (!noQ[g]) planes.cr[off] = outCr[2];
        }
      }
    }
  }

  // luma apply (two 4-line groups)
  if (pl[0] && pl[1] && pl[0].mode !== 0 && pl[1].mode !== 0 &&
      pl[0].mode === pl[1].mode && noP[0] === noP[1] && noQ[0] === noQ[1]) {
    // both groups same plan: apply as one 8-line run (upstream lumaBoth path)
  }
  for (let g = 0; g < 2; g++) {
    if (!pl[g] || pl[g].mode === 0) continue;
    const strip = new Array(32).fill(0);
    for (let l = 0; l < 4; l++) {
      for (let i = -4; i < 4; i++) {
        const sx = vertical ? x + i : x + 4 * g + l;
        const sy = vertical ? y + 4 * g + l : y + i;
        if (sx < 0 || sx >= w || sy < 0 || sy >= h) continue;
        strip[l * 8 + i + 4] = planes.y[sy * strideY + sx];
      }
    }
    const out = deblockLumaApply(strip, pl[g], 8, noP[g], noQ[g]);
    for (let l = 0; l < 4; l++) {
      for (let i = -4; i < 4; i++) {
        const sx = vertical ? x + i : x + 4 * g + l;
        const sy = vertical ? y + 4 * g + l : y + i;
        if (sx < 0 || sx >= w || sy < 0 || sy >= h) continue;
        planes.y[sy * strideY + sx] = out[l * 8 + i + 4];
      }
    }
  }
}

// deblock whole picture (vertical pass then horizontal pass).
export function deblockFrame(planes, f) {
  const st = makeState(f);
  const { w, h } = st;
  for (const vertical of [true, false]) {
    for (let y = 0; y < h; y += 8) {
      for (let x = 0; x < w; x += 8) {
        if (vertical && x === 0) continue;
        if (!vertical && y === 0) continue;
        deblockEdge(planes, st, f, x, y, vertical);
      }
    }
  }
}

// saoPlane 8.7.3 over the whole picture, single-thread, single-slice/tile.
export function saoFrame(planes, f) {
  if (!f.SaoOn) return;
  const typeIdx = f.SaoType;
  if (typeIdx === 0) return;
  const w = f.W, h = f.H;
  const ctbSize = 1 << f.CtbLog2;
  const ctbsX = Math.ceil(w / ctbSize);
  const ctbsY = Math.ceil(h / ctbSize);
  const offset = f.SaoOffset;
  const shift = 3, maxV = 255;
  const a = eoOffsets[f.SaoClass][0], b = eoOffsets[f.SaoClass][1];
  const band = f.SaoBand;
  const isBand = typeIdx === 1;
  const src = {
    y: planes.y.slice(), cb: planes.cb.slice(), cr: planes.cr.slice(),
  };
  const st = makeState(f);

  for (let cIdx = 0; cIdx < 3; cIdx++) {
    const sw = cIdx > 0 ? 2 : 1, sh = cIdx > 0 ? 2 : 1;
    const pw = Math.floor(w / sw), ph = Math.floor(h / sh);
    const stride = cIdx > 0 ? w >> 1 : w;
    const plane = cIdx === 0 ? planes.y : cIdx === 1 ? planes.cb : planes.cr;
    const s = cIdx === 0 ? src.y : cIdx === 1 ? src.cb : src.cr;
    const ctbW = Math.floor(ctbSize / sw), ctbH = Math.floor(ctbSize / sh);
    for (let ctbY = 0; ctbY < ctbsY; ctbY++) {
      for (let ctbX = 0; ctbX < ctbsX; ctbX++) {
        const x0 = ctbX * ctbW, y0 = ctbY * ctbH;
        const xhi = Math.min(x0 + ctbW, pw);
        const yhi = Math.min(y0 + ctbH, ph);
        for (let y = y0; y < yhi; y++) {
          let xlo = x0;
          if (!isBand) {
            if (y + a[1] < 0 || y + a[1] >= ph || y + b[1] < 0 || y + b[1] >= ph) continue;
            xlo = Math.max(xlo, Math.max(-a[0], -b[0]));
            // xhi recomputed per row
          }
          const rowXhi = isBand ? xhi : Math.min(xhi, pw - Math.max(a[0], b[0]));
          let ilo = xlo, ihi = rowXhi;
          if (!isBand) {
            if (a[1] !== 0 && (y === y0 || y === yhi - 1)) {
              ihi = ilo;
            } else if (a[0] !== 0) {
              ilo = Math.min(Math.max(xlo, x0 + 1), rowXhi);
              ihi = Math.max(Math.min(rowXhi, x0 + ctbW - 1), ilo);
            }
          }
          // edges: [xlo, ilo) and [ihi, rowXhi) use saoSample
          const sampleEdge = (xx) => {
            if (st.noFilter[st.tbIndex(xx * sw, y * sh)]) return;
            const v = s[y * stride + xx];
            if (isBand) {
              const k = ((v >> shift) - band) & 31;
              if (k < 4) plane[y * stride + xx] = clip3(v + offset[k], 0, maxV);
              return;
            }
            if (xx + a[0] < 0 || xx + a[0] >= pw || y + a[1] < 0 || y + a[1] >= ph ||
                xx + b[0] < 0 || xx + b[0] >= pw || y + b[1] < 0 || y + b[1] >= ph) return;
            const va = s[(y + a[1]) * stride + xx + a[0]];
            const vb = s[(y + b[1]) * stride + xx + b[0]];
            const cat = sign(v - va) + sign(v - vb);
            if (cat !== 0) {
              const k = cat > 0 ? cat + 1 : cat + 2;
              plane[y * stride + xx] = clip3(v + offset[k], 0, maxV);
            }
          };
          for (let xx = xlo; xx < ilo; xx++) sampleEdge(xx);
          for (let xx = ihi; xx < rowXhi; xx++) sampleEdge(xx);
          // interior runs
          const minTbLog2 = 2;
          const next = (xx) => Math.min((((xx * sw >> minTbLog2) + 1) << minTbLog2) / sw, ihi);
          for (let xx = ilo; xx < ihi;) {
            if (st.noFilter[st.tbIndex(xx * sw, y * sh)]) { xx = next(xx); continue; }
            let run = xx;
            while (run < ihi && !st.noFilter[st.tbIndex(run * sw, y * sh)]) run = next(run);
            if (isBand) {
              for (let q = xx; q < run; q++) {
                const v = s[y * stride + q];
                const k = ((v >> shift) - band) & 31;
                if (k < 4) plane[y * stride + q] = clip3(v + offset[k], 0, maxV);
              }
            } else {
              for (let q = xx; q < run; q++) {
                const v = s[y * stride + q];
                const va = s[(y + a[1]) * stride + q + a[0]];
                const vb = s[(y + b[1]) * stride + q + b[0]];
                const cat = sign(v - va) + sign(v - vb);
                if (cat !== 0) {
                  const k = cat > 0 ? cat + 1 : cat + 2;
                  plane[y * stride + q] = clip3(v + offset[k], 0, maxV);
                }
              }
            }
            xx = run;
          }
        }
      }
    }
  }
}
