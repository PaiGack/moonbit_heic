#!/usr/bin/env node
// Independent verification of tools/frame2_golden.json and the generated
// hevc/decode/frame2_golden.mbt, with no Go/network.
//
// For small frames (full planar YUV shipped): re-derive the stream/YUV
// SHA-256 fingerprint, verify the planar length from width/height, and pin
// the generated MoonBit golden's names, dimensions, fingerprints.
//
// For large frames (720p / 1080p / 4032x3024, YUV NOT shipped): the Go
// exporter recorded an FNV-1a checksum, a nonzero count and 64 evenly spaced
// probe samples instead. This script verifies those values are internally
// consistent (checksum is a decimal UInt64, nonzero <= plane length, probe
// indices are in range and ascending) and that the MoonBit golden carries the
// identical checksum / nonzero / probes. MoonBit decode_i_frame recomputes
// the checksum from its own decoded picture, so a single wrong pixel fails.
//
// Link 1 of the truth chain is the real upstream Go decoder
// (tools/export_frame2_golden_test.go). A hand edit fails CI.

import fs from 'fs';
import path from 'path';
import crypto from 'crypto';
import { fileURLToPath } from 'url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const g = JSON.parse(fs.readFileSync(path.join(root, 'tools/frame2_golden.json'), 'utf8'));
const mbt = fs.readFileSync(path.join(root, 'hevc/decode/frame2_golden.mbt'), 'utf8');

const sha = b => crypto.createHash('sha256').update(Buffer.from(b)).digest('hex');
const b64 = s => Array.from(Buffer.from(s, 'base64'));
let checks = 0;
const eq = (a, b, msg) => { if (a !== b) { console.error(`MISMATCH ${msg}: ${a} != ${b}`); process.exit(1); } checks++; };
const ok = (c, msg) => { if (!c) { console.error(`FAIL ${msg}`); process.exit(1); } checks++; };

eq(g.source.includes('gen2brain/h265 real decoder'), true, 'source is the real Go decoder');

const PROBES = 64;
let refCount = 0, bigCount = 0, saoActive = 0;
for (const c of g.cases) {
  const stream = b64(c.stream);
  // The Go exporter records the first 16 hex chars of the SHA-256 as a
  // compact fingerprint; re-derive the full digest and pin the prefix.
  eq(sha(stream).slice(0, 16), c.stream_fp, `${c.name} stream fingerprint`);
  ok(stream[0] === 0 && stream[1] === 0 && stream[2] === 0 && stream[3] === 1, `${c.name} annex B framing`);
  ok(mbt.includes(`name: ${JSON.stringify(c.name)}`), `${c.name} present in golden.mbt`);
  ok(mbt.includes(`stream_sha: ${JSON.stringify(sha(stream))}`), `${c.name} stream_sha in golden.mbt`);

  if (c.has_ref) refCount++;
  if (c.name.startsWith('sao_active')) saoActive++;

  if (c.big) {
    bigCount++;
    const planeLen = c.width * c.height + 2 * Math.ceil(c.width / 2) * Math.ceil(c.height / 2);
    ok(/^\d+$/.test(String(c.checksum)), `${c.name} checksum is a decimal UInt64`);
    ok(BigInt(c.checksum) <= 0xffffffffffffffffn, `${c.name} checksum fits UInt64`);
    ok(c.nonzero >= 0 && c.nonzero <= planeLen, `${c.name} nonzero in range`);
    eq(c.yuv_fp.length, 16, `${c.name} yuv_fp is the 16-hex prefix`);
    eq(c.probes.length, PROBES, `${c.name} probe count`);
    let prev = -1;
    for (const [i, v] of c.probes) {
      ok(i > prev && i < planeLen, `${c.name} probe index ${i} ascending/in range`);
      ok(v >= 0 && v <= 255, `${c.name} probe value ${v} is a byte`);
      prev = i;
      ok(mbt.includes(`(${i}, ${v})`), `${c.name} probe (${i}, ${v}) in golden.mbt`);
    }
    ok(mbt.includes(`checksum: ${JSON.stringify(String(c.checksum))}`), `${c.name} checksum in golden.mbt`);
    ok(mbt.includes(`nonzero: ${c.nonzero}`), `${c.name} nonzero in golden.mbt`);
  } else {
    const yuv = b64(c.yuv);
    eq(sha(yuv).slice(0, 16), c.yuv_fp, `${c.name} yuv fingerprint`);
    const wantLen = c.width * c.height + 2 * Math.ceil(c.width / 2) * Math.ceil(c.height / 2);
    eq(yuv.length, wantLen, `${c.name} planar YUV length`);
    ok(mbt.includes(`yuv_sha: ${JSON.stringify(sha(yuv))}`), `${c.name} yuv_sha in golden.mbt`);
  }
}
eq(refCount, 3, 'three frames carry an upstream *_ref.yuv');
eq(bigCount, 3, 'three large scale frames (720p, 1080p, 4032x3024)');
ok(saoActive >= 2, 'at least two SAO-active encoder frames');
const goldenCaseCount = (mbt.match(/name: "/g) || []).length;
eq(goldenCaseCount, g.cases.length, 'golden.mbt case count');

console.log(`frame2 crosscheck OK (${g.cases.length} cases, ${refCount} ref.yuv, ${saoActive} SAO-active, ${bigCount} large, ${checks} checks)`);
