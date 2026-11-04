// Self-test for the parity harness. Run with: node --test tools/parity/
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, 'dump.mjs');

function run(expected, actual) {
  const dir = mkdtempSync(join(tmpdir(), 'parity-'));
  const a = join(dir, 'expected.json');
  const b = join(dir, 'actual.json');
  writeFileSync(a, JSON.stringify(expected));
  writeFileSync(b, JSON.stringify(actual));
  const res = spawnSync(process.execPath, [script, a, b], { encoding: 'utf8' });
  return { code: res.status, out: res.stdout, err: res.stderr };
}

test('identical dumps pass', () => {
  const { code, out } = run({ sps: { width: 1920 } }, { sps: { width: 1920 } });
  assert.equal(code, 0);
  assert.match(out, /parity: ok/);
});

test('a field difference is reported with its path', () => {
  const { code, err } = run({ sps: { width: 1920 } }, { sps: { width: 1921 } });
  assert.equal(code, 1);
  assert.match(err, /\$\.sps\.width \(value\)/);
  assert.match(err, /expected: 1920/);
  assert.match(err, /actual:   1921/);
});

test('arrays report the index, not the whole array', () => {
  const { code, err } = run({ nals: [1, 2, 3] }, { nals: [1, 9, 3] });
  assert.equal(code, 1);
  assert.match(err, /\$\.nals\[1\]/);
});

test('a missing key says which side dropped it', () => {
  const { code, err } = run({ pps: { id: 0 } }, { pps: {} });
  assert.equal(code, 1);
  assert.match(err, /\$\.pps\.id \(missing\)/);
});

test('byte dumps highlight the first differing byte', () => {
  const { code, err } = run(
    { bytes: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] },
    { bytes: [0, 1, 2, 3, 4, 5, 0xff, 7, 8, 9] },
  );
  assert.equal(code, 1);
  assert.match(err, /bytes\[6\] \(byte\)/);
  assert.match(err, /\[06\]/);
  assert.match(err, /\[ff\]/);
});

test('hex strings are compared as bytes too', () => {
  const { code, err } = run({ hex: '00 01 02 03' }, { hex: '00010204' });
  assert.equal(code, 1);
  assert.match(err, /bytes\[3\]/);
});

test('length mismatch is a length, not a value diff', () => {
  const { code, err } = run({ bytes: [1, 2] }, { bytes: [1, 2, 3] });
  assert.equal(code, 1);
  assert.match(err, /length/);
});
