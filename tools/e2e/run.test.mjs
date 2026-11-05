// Self-test for the e2e harness' INDEPENDENT reference. The PSNR number is
// only meaningful if the reference conversion and the tiny PNG decoder are
// themselves correct; these tests pin them with hand-computed fixtures.
import { test } from "node:test";
import assert from "node:assert/strict";
import { inflateSync, deflateSync } from "node:zlib";
import { yuv420pToRgba, decodePng, psnr } from "./reference.mjs";

const PNG_SIG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const chunk = (type, data) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crcTable = [];
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; crcTable[n] = c >>> 0; }
  let crc = 0xffffffff;
  for (const b of body) crc = crcTable[(crc ^ b) & 255] ^ (crc >>> 8);
  const crcBuf = Buffer.alloc(4); crcBuf.writeUInt32BE((crc ^ 0xffffffff) >>> 0, 0);
  return Buffer.concat([len, body, crcBuf]);
};
const makePng = (w, h, rows) => {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6;
  const raw = Buffer.concat(rows.map((r) => Buffer.concat([Buffer.from([r[0]]), Buffer.from(r.slice(1))])));
  return Buffer.concat([PNG_SIG, chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
};

test("yuv420pToRgba: neutral grey is (128,128,128,255) in limited range", () => {
  // 2x2 Y=126 (limited-> ~128), U=V=128 neutral.
  const yuv = Buffer.from([126, 126, 126, 126, 128, 128]);
  const rgba = yuv420pToRgba(yuv, 2, 2, { limited: true });
  for (let i = 0; i < 4; i++) {
    assert.deepEqual([...rgba.subarray(i * 4, i * 4 + 4)], [128, 128, 128, 255]);
  }
});

test("yuv420pToRgba: nearest-neighbour chroma upsampling", () => {
  // 2x2, one chroma sample U=0/V=255 (strong blue/red) for all 4 luma.
  const yuv = Buffer.from([126, 126, 126, 126, 0, 255]);
  const rgba = yuv420pToRgba(yuv, 2, 2, { limited: true });
  const first = [...rgba.subarray(0, 4)];
  for (let i = 1; i < 4; i++) assert.deepEqual([...rgba.subarray(i * 4, i * 4 + 4)], first);
  assert.equal(first[3], 255);
});

test("decodePng: Sub filter round-trip", () => {
  const w = 2, h = 2;
  // Sub-filtered row 1: each byte is the delta from the byte 4 positions
  // to its left in the SAME row (not from the previous scanline).
  const rows = [
    [0, 10, 20, 30, 255, 40, 50, 60, 255],
    [1, 5, 5, 5, 5, 5, 5, 5, 5],
  ];
  const png = makePng(w, h, rows);
  const dec = decodePng(png);
  assert.equal(dec.width, 2);
  assert.equal(dec.height, 2);
  // row 0: (10,20,30,255),(40,50,60,255)
  assert.deepEqual([...dec.rgba.subarray(0, 8)], [10, 20, 30, 255, 40, 50, 60, 255]);
  // row 1: (5,5,5,5),(10,10,10,10) -- left neighbour is already unfiltered.
  assert.deepEqual([...dec.rgba.subarray(8, 16)], [5, 5, 5, 5, 10, 10, 10, 10]);
});

test("psnr: identical -> inf, one-step error is large but finite", () => {
  const a = Buffer.from([10, 20, 30, 40]);
  assert.equal(psnr(a, Buffer.from(a)), Infinity);
  const b = Buffer.from([11, 20, 30, 40]);
  const p = psnr(a, b);
  assert.ok(Number.isFinite(p) && p > 40, `psnr ${p}`);
});
