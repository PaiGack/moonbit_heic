#!/usr/bin/env node
// Parity harness for the MoonBit port of gen2brain/h265.
//
// The upstream project ships Go helpers that dump parsed structures as JSON
// (one dump per milestone: NAL list, VPS/SPS/PPS fields, slice headers, plane
// checksums). This script does the comparing, so every milestone gets the same
// report shape instead of `assert_eq` on a stringified blob.
//
// Usage:
//   node tools/parity/dump.mjs expected.json actual.json
//   node tools/parity/dump.mjs --first-diff expected.json actual.json
//
// Exit codes: 0 equal, 1 different, 2 unreadable input.

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const args = process.argv.slice(2);
const firstDiffOnly = args.includes('--first-diff');
const files = args.filter((a) => !a.startsWith('--'));

if (files.length !== 2) {
  console.error('usage: dump.mjs [--first-diff] <expected.json> <actual.json>');
  process.exit(2);
}

function load(path) {
  try {
    return JSON.parse(readFileSync(resolve(path), 'utf8'));
  } catch (err) {
    console.error(`parity: cannot read ${path}: ${err.message}`);
    process.exit(2);
  }
}

const expected = load(files[0]);
const actual = load(files[1]);

// Walk both values in parallel and describe the first place they disagree.
// Paths are `a.b[3].c` so a failing diff can be pasted straight into a
// `moon test` filter or a grep.
function diff(a, b, path, out) {
  if (out.length > 0 && firstDiffOnly) return;
  if (a === b) return;

  if (typeof a !== typeof b) {
    out.push({ path, expected: a, actual: b, reason: 'type' });
    return;
  }
  if (a === null || b === null || typeof a !== 'object') {
    out.push({
      path,
      expected: a,
      actual: b,
      reason: typeof a === 'number' && typeof b === 'number' ? 'value' : 'value',
    });
    return;
  }
  if (Array.isArray(a) !== Array.isArray(b)) {
    out.push({ path, expected: a, actual: b, reason: 'shape' });
    return;
  }
  if (Array.isArray(a)) {
    if (a.length !== b.length) {
      out.push({
        path: `${path}.length`,
        expected: a.length,
        actual: b.length,
        reason: 'length',
      });
    }
    const n = Math.min(a.length, b.length);
    for (let i = 0; i < n; i++) {
      diff(a[i], b[i], `${path}[${i}]`, out);
      if (out.length > 0 && firstDiffOnly) return;
    }
    return;
  }
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const key of [...keys].sort()) {
    if (!(key in a)) {
      out.push({ path: `${path}.${key}`, expected: '<missing>', actual: b[key], reason: 'missing' });
    } else if (!(key in b)) {
      out.push({ path: `${path}.${key}`, expected: a[key], actual: '<missing>', reason: 'missing' });
    } else {
      diff(a[key], b[key], `${path}.${key}`, out);
    }
    if (out.length > 0 && firstDiffOnly) return;
  }
}

// A hex window around a pixel/byte divergence turns "differs at 4096" into
// something you can actually look at.
function hexWindow(buffer, offset, radius = 8) {
  const start = Math.max(0, offset - radius);
  const end = Math.min(buffer.length, offset + radius);
  const cells = [];
  for (let i = start; i < end; i++) {
    const hex = buffer[i].toString(16).padStart(2, '0');
    cells.push(i === offset ? `[${hex}]` : hex);
  }
  return cells.join(' ');
}

// Byte dumps are `{ bytes: [..] }` or a bare array; report the first differing
// index plus its neighbourhood, which is what the pixel comparison needs.
function compareBytes(a, b) {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) {
      return {
        path: `bytes[${i}]`,
        expected: a[i],
        actual: b[i],
        reason: 'byte',
        context: {
          expected: hexWindow(a, i),
          actual: hexWindow(b, i),
        },
      };
    }
  }
  if (a.length !== b.length) {
    return {
      path: 'bytes.length',
      expected: a.length,
      actual: b.length,
      reason: 'length',
    };
  }
  return null;
}

function asBytes(value) {
  if (Array.isArray(value)) return value.every((v) => typeof v === 'number') ? value : null;
  if (value && Array.isArray(value.bytes)) return value.bytes;
  if (value && typeof value.hex === 'string') {
    const clean = value.hex.replace(/\s+/g, '');
    const out = [];
    for (let i = 0; i + 1 < clean.length; i += 2) out.push(parseInt(clean.slice(i, i + 2), 16));
    return out;
  }
  return null;
}

const expectedBytes = asBytes(expected);
const actualBytes = asBytes(actual);
const findings = [];
if (expectedBytes && actualBytes) {
  const finding = compareBytes(expectedBytes, actualBytes);
  if (finding) findings.push(finding);
} else {
  diff(expected, actual, '$', findings);
}

if (findings.length === 0) {
  console.log(`parity: ok (${files[0]} == ${files[1]})`);
  process.exit(0);
}

console.error(`parity: ${findings.length} difference(s) between ${files[0]} and ${files[1]}`);
for (const f of findings) {
  console.error(`  at ${f.path} (${f.reason})`);
  console.error(`    expected: ${JSON.stringify(f.expected)}`);
  console.error(`    actual:   ${JSON.stringify(f.actual)}`);
  if (f.context) {
    console.error(`    expected ctx: ${f.context.expected}`);
    console.error(`    actual   ctx: ${f.context.actual}`);
  }
}
process.exit(1);
