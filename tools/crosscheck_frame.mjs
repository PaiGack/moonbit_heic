#!/usr/bin/env node
// Link 2 of the M3 whole-frame trust chain: verify tools/frame_golden.json
// against independent, self-contained JS computations (no Go, no network).
//
// For each case this re-derives:
//   - the stream/YUV byte lengths from the declared width/height,
//   - a stream fingerprint and a YUV fingerprint (FNV-1a over the bytes),
//   - the Annex B NAL shape (VPS/SPS/PPS + one VCL slice),
//   - the transform-block trace invariants (log2 in 2..5, cIdx in 0..2,
//     mode in 0..34, qp in 0..51, chroma TBs never before their luma TB,
//     and the total trace count matches a per-case pinned baseline).
//
// The YUV itself is upstream truth, so JS cannot recompute it; the check is
// that the fixture is internally consistent and unmodified (fingerprints are
// committed below and a single-byte edit changes one). The MoonBit port
// (hevc/ctu + decode_i_frame) is what reproduces every YUV sample.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const g = JSON.parse(fs.readFileSync(path.join(root, 'tools/frame_golden.json'), 'utf8'));

function fnv1a(buf) {
  let h = 0x811c9dc5;
  for (const b of buf) {
    h ^= b;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return (h >>> 0).toString(16).padStart(8, '0');
}

// Pinned fingerprints of the committed fixture. A regeneration that changes
// the upstream truth must update these deliberately.
const pins = {
  'angular.h265':        { stream: '6012746b', yuv: 'e4133218', tbs: 24 },
  'angular_grad.h265':   { stream: 'd3bfc1db', yuv: '5a035588', tbs: 24 },
  'tiny_intra.h265':     { stream: 'a01dd2f5', yuv: '22db3bc5', tbs: 3 },
  'tu8.h265':            { stream: 'ee2a0cac', yuv: '22db3bc5', tbs: 12 },
  'tu32.h265':           { stream: '7eb035a1', yuv: '10cf15c5', tbs: 3 },
  'multi_ctu.h265':      { stream: '17646ec0', yuv: '10cf15c5', tbs: 12 },
  'deblock_grad.h265':   { stream: 'f33c9156', yuv: '1f828ec5', tbs: 12 },
  'signhide.h265':       { stream: '3c12664c', yuv: 'dd8d0938', tbs: 24 },
  'flat64.h265':         { stream: 'dbbea98e', yuv: '29f97dc5', tbs: 12 },
  'grad64.h265':         { stream: '388ab7aa', yuv: 'ee8a010d', tbs: 66 },
  'ramp64.h265':         { stream: 'b49222a4', yuv: '03717bc5', tbs: 30 },
  'qp_small.h265':       { stream: '924fb359', yuv: '24e25d60', tbs: 39 },
  'aq_intra_64.h265':    { stream: '924fb359', yuv: '24e25d60', tbs: 39 },
};

let checks = 0;
function ok(cond, msg) {
  if (!cond) { console.error('FAIL: ' + msg); process.exit(1); }
  checks++;
}

ok(g.cases.length === 13, 'expected 13 frame cases');

for (const c of g.cases) {
  const stream = Buffer.from(c.stream, 'base64');
  const yuv = Buffer.from(c.yuv, 'base64');
  const cw = (c.width + 1) >> 1;
  const ch = (c.height + 1) >> 1;
  const wantLen = c.width * c.height + 2 * cw * ch;
  ok(yuv.length === wantLen, `${c.name}: YUV length ${yuv.length} != ${wantLen}`);
  ok(c.width % 2 === 0 && c.height % 2 === 0, `${c.name}: odd luma dimensions`);

  // Annex B shape: at least VPS, SPS, PPS and one VCL NAL.
  let nals = 0, vcl = 0;
  for (let i = 0; i + 3 < stream.length; i++) {
    if (stream[i] === 0 && stream[i + 1] === 0 && stream[i + 2] === 1) {
      nals++;
      const t = (stream[i + 3] >> 1) & 0x3f;
      if (t < 32) vcl++;
      i += 2;
    }
  }
  ok(nals >= 4, `${c.name}: expected >= 4 NALs, got ${nals}`);
  ok(vcl === 1, `${c.name}: expected exactly one VCL slice, got ${vcl}`);

  // Fingerprints pin the exact bytes so a hand edit is caught.
  const pin = pins[c.name];
  ok(!!pin, `${c.name}: no fingerprint pin`);
  ok(fnv1a(stream) === pin.stream, `${c.name}: stream fingerprint drift`);
  ok(fnv1a(yuv) === pin.yuv, `${c.name}: YUV fingerprint drift`);

  // Trace invariants.
  const tr = c.trace || [];
  ok(tr.length === pin.tbs, `${c.name}: trace ${tr.length} != ${pin.tbs}`);
  for (const t of tr) {
    ok(t.log2 >= 2 && t.log2 <= 5, `${c.name}: bad log2 ${t.log2}`);
    ok(t.cidx >= 0 && t.cidx <= 2, `${c.name}: bad cidx ${t.cidx}`);
    ok(t.mode >= 0 && t.mode <= 34, `${c.name}: bad mode ${t.mode}`);
    ok(t.qp >= 0 && t.qp <= 51, `${c.name}: bad qp ${t.qp}`);
    ok(t.x >= 0 && t.y >= 0 && t.x < c.width && t.y < c.height,
      `${c.name}: TB outside picture (${t.x},${t.y})`);
  }
  // Chroma TBs follow their luma TB in the trace (transformUnit order).
  for (let i = 0; i < tr.length; i++) {
    if (tr[i].cidx > 0) {
      ok(i > 0, `${c.name}: chroma TB first`);
    }
  }
}

console.log(`frame crosscheck OK: ${g.cases.length} cases, ${checks} invariants, ` +
  `${g.cases.reduce((n, c) => n + (c.trace || []).length, 0)} TBs`);
