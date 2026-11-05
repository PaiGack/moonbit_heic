#!/usr/bin/env node
// Regenerates hevc/decode/frame2_golden.mbt: whole-I-frame byte-exact
// fixtures for the REMAINING M3 tools (SAO, scaling lists, PCM, transform
// skip, transquant bypass, cu_chroma_qp_offset) plus 720p/1080p scale checks.
//
// The fixture data comes from tools/frame2_golden.json, produced by the REAL
// upstream Go decoder (tools/export_frame2_golden_test.go, run in a
// gen2brain/h265 checkout with -tags noasm): the FIRST picture of each stream
// is decoded by DecodeNAL + Flush into its final planar YUV and asserted
// byte-for-byte against the upstream *_ref.yuv where one ships. Two extra
// cases are produced by the upstream ENCODER itself with SAO enabled
// (single slice, single tile, no WPP) and then decoded by the same real
// decoder; their SAO genuinely changes pixels (1226 / 5976 samples), which a
// counterfactual "applySAO disabled" decode confirms.
//
// tools/crosscheck_frame2.mjs verifies every case's stream/YUV SHA-256
// fingerprint independently (no Go/network). Small frames carry the full
// YUV for MoonBit to reproduce sample for sample; the 720p/1080p frames
// carry a fingerprint plus evenly spaced sample probes so golden.mbt stays
// a reasonable size while still proving the decode agrees.
//
//   node tools/gen_frame2_golden.mjs            # rewrite the fixture
//   node tools/gen_frame2_golden.mjs --check    # verify it is current

import fs from 'fs';
import path from 'path';
import crypto from 'crypto';
import { fileURLToPath } from 'url';
import { execFileSync } from 'child_process';
import os from 'os';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const raw = JSON.parse(fs.readFileSync(path.join(root, 'tools/frame2_golden.json'), 'utf8'));
const check = process.argv.includes('--check');

const b64 = s => Array.from(Buffer.from(s, 'base64'));
const boolLit = v => v ? 'true' : 'false';
function bytesLit(arr, indent) {
  if (arr.length === 0) return indent;
  const out = [];
  for (let i = 0; i < arr.length; i += 9)
    out.push(indent + arr.slice(i, i + 9).map(b => `b'\\x${b.toString(16).padStart(2, '0')}'`).join(', ') + ',');
  return out.join('\n');
}
function bytesArr(arr, indent) {
  if (arr.length === 0) return 'b""';
  const lines = [];
  for (let i = 0; i < arr.length; i += 9) {
    lines.push(indent + arr.slice(i, i + 9).map(b => `b'\\x${b.toString(16).padStart(2, '0')}'`).join(', ') + ',');
  }
  return 'Bytes::from_array([\n' + lines.join('\n') + '\n  ])';
}

// MoonBit caps a single text segment (the lines between two `///|` markers)
// at ~16384 lines; with `--deny-warn` an over-long segment is a hard error.
// A big bitstream used to be one ~19000-line segment inside its case struct.
// Split large byte arrays into several top-level `let` helpers, each in its
// own `///|` block, and join the pieces back with `+` (Array[Byte]).
const CHUNK_LINES = 3000; // 9 bytes per line -> 27000 bytes per helper block
function byteLines(arr, indent) {
  const lines = [];
  for (let i = 0; i < arr.length; i += 9) {
    lines.push(indent + arr.slice(i, i + 9).map(b => `b'\\x${b.toString(16).padStart(2, '0')}'`).join(', ') + ',');
  }
  return lines;
}
// Pushes helper `let` blocks to L (when needed) and returns the expression
// to use for a Bytes field.
function emitBytes(arr, indent, vn, field) {
  const lines = byteLines(arr, indent);
  if (lines.length <= CHUNK_LINES) {
    return bytesArr(arr, indent);
  }
  const chunkSize = CHUNK_LINES * 9;
  const parts = [];
  let pi = 0;
  for (let off = 0; off < arr.length; off += chunkSize, pi++) {
    const name = `${vn}_${field}_p${pi}`;
    L.push('///|');
    L.push(`let ${name} : Array[Byte] = [`);
    for (const line of byteLines(arr.slice(off, off + chunkSize), '  ')) L.push(line);
    L.push(']');
    L.push('');
    parts.push(name);
  }
  return `Bytes::from_array(${parts.join(' + ')})`;
}
const sha = b => crypto.createHash('sha256').update(Buffer.from(b)).digest('hex');

// Large frames keep a fingerprint + 64 evenly spaced probe samples.
const BIG = new Set(['realworld_720p.h265', '1080p.h265', 'large_4032x3024.h265']);
const PROBES = 64;
// A MoonBit-computable whole-plane checksum (FNV-1a over Int64) plus a
// nonzero count. These catch any pixel error without needing SHA-256 in the
// MoonBit test; the JS crosscheck re-derives them independently.
function planeCheck(arr) {
  let hash = 0xcbf29ce484222325n;
  const mask = 0xffffffffffffffffn;
  let nonzero = 0;
  for (const b of arr) {
    hash = ((hash ^ BigInt(b)) * 0x100000001b3n) & mask;
    if (b !== 0) nonzero++;
  }
  return { hash: hash.toString(), nonzero };
}
function probes(arr) {
  const out = [];
  for (let k = 0; k < PROBES; k++) {
    const i = Math.floor(k * (arr.length - 1) / (PROBES - 1));
    out.push([i, arr[i]]);
  }
  return out;
}

const L = [];
L.push('// Golden fixtures for the REMAINING M3 tools: SAO syntax/application,');
L.push('// scaling lists, PCM, transform skip, transquant bypass, cu_chroma_qp_offset,');
L.push('// plus 720p/1080p scale checks. Generated by tools/gen_frame2_golden.mjs');
L.push('// from tools/frame2_golden.json (the REAL upstream Go decoder, -tags noasm,');
L.push('// first picture; two SAO-active frames from the real upstream encoder).');
L.push('// Small frames carry the full planar YUV for MoonBit to reproduce sample');
L.push('// for sample; large frames carry a SHA-256 fingerprint + probe samples.');
L.push('');
L.push('///|');
L.push('/// One whole I frame: stream bytes, expected planar YUV (or a fingerprint');
L.push('/// + probes for large frames), dimensions and the upstream reference flag.');
L.push('pub(all) struct Frame2Case {');
L.push('  name : String');
L.push('  stream : Bytes');
L.push('  yuv : Bytes');
L.push('  width : Int32');
L.push('  height : Int32');
L.push('  has_ref : Bool');
L.push('  big : Bool');
L.push('  yuv_sha : String');
L.push('  probes : Array[(Int32, Int32)]');
L.push('  checksum : String');
L.push('  nonzero : Int32');
L.push('  stream_sha : String');
L.push('}');
L.push('');

const caseNames = [];
for (let ci = 0; ci < raw.cases.length; ci++) {
  const c = raw.cases[ci];
  const stream = b64(c.stream);
  const yuv = c.yuv ? b64(c.yuv) : [];
  const big = !!c.big;
  const yuvSha = big ? c.yuv_fp : sha(yuv);
  const streamSha = sha(stream);
  const pr = big ? c.probes.map(([i, v]) => [i, v]) : [];
  const pc = big ? { hash: String(c.checksum), nonzero: c.nonzero } : { hash: '0', nonzero: 0 };
  const vn = `frame2_case_${ci}`;
  caseNames.push(vn);
  // Compute byte-field expressions first: emitBytes may push helper `let`
  // blocks (in their own `///|` segments) that must precede the case struct.
  const streamExpr = emitBytes(stream, '    ', vn, 'stream');
  const yuvExpr = big ? 'b""' : emitBytes(yuv, '    ', vn, 'yuv');
  L.push('///|');
  L.push(`pub let ${vn} : Frame2Case = {`);
  L.push(`  name: ${JSON.stringify(c.name)},`);
  L.push(`  stream: ${streamExpr},`);
  L.push(`  yuv: ${yuvExpr},`);
  L.push(`  width: ${c.width},`);
  L.push(`  height: ${c.height},`);
  L.push(`  has_ref: ${boolLit(c.has_ref)},`);
  L.push(`  big: ${boolLit(big)},`);
  L.push(`  yuv_sha: ${JSON.stringify(yuvSha)},`);
  L.push(`  stream_sha: ${JSON.stringify(streamSha)},`);
  L.push('  probes: [');
  for (const [i, v] of pr) L.push(`    (${i}, ${v}),`);
  L.push('  ],');
  L.push(`  checksum: ${JSON.stringify(pc.hash)},`);
  L.push(`  nonzero: ${pc.nonzero},`);
  L.push('}');
  L.push('');
}
L.push('///|');
L.push(`/// ${raw.cases.length} single-slice, single-tile, no-WPP pure I frames.`);
L.push('pub let frame2_cases : Array[Frame2Case] = [');
for (const vn of caseNames) L.push(`  ${vn},`);
L.push(']');
L.push('');

const out = L.join('\n');

// moon fmt rewraps long array literals (column width). The committed golden
// is the formatted form, so --check must compare against a formatted copy of
// the generated text rather than the raw text. Format a temp file through the
// real formatter; generate mode formats the target in place.
function formatted(text) {
  // Format inside the package: moon fmt only applies its ///| block
  // splitting and column-width rewrapping when the file is in a package.
  const tmp = path.join(root, 'hevc/decode', `_m3golden_fmt_${process.pid}.mbt`);
  fs.writeFileSync(tmp, text);
  try {
    execFileSync('moon', ['fmt', tmp], { stdio: 'ignore' });
  } catch (e) {
    fs.unlinkSync(tmp);
    throw new Error(
      'moon fmt is required to verify golden fixtures; ' +
      'ensure moon is on PATH (export PATH="$HOME/.moon/bin:$PATH"). ' +
      `Underlying error: ${e.message}`
    );
  }
  const r = fs.readFileSync(tmp, 'utf8');
  fs.unlinkSync(tmp);
  return r;
}

const target = path.join(root, 'hevc/decode/frame2_golden.mbt');
if (check) {
  const cur = fs.readFileSync(target, 'utf8');
  if (formatted(out) !== cur) {
    console.error(`${target} is stale; run node ${path.basename(process.argv[1])}`);
    process.exit(1);
  }
  console.log(`frame2 golden OK (${raw.cases.length} cases)`);
} else {
  fs.writeFileSync(target, out);
  try {
    execFileSync('moon', ['fmt', target], { stdio: 'ignore' });
  } catch (e) {
    throw new Error(
      'moon fmt is required to write formatted golden fixtures; ' +
      'ensure moon is on PATH (export PATH="$HOME/.moon/bin:$PATH"). ' +
      `Underlying error: ${e.message}`
    );
  }
  console.log(`wrote ${target} (${raw.cases.length} cases)`);
}
