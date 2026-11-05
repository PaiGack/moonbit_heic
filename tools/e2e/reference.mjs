// Independent YUV->RGB reference for the e2e PSNR report.
//
// This is deliberately NOT the MoonBit colour code under test: it is a
// straight floating-point H.273 BT.709 limited-range conversion written from
// the spec, with nearest-neighbour 4:2:0 upsampling, plus a small pure-JS
// PNG decoder (zlib inflate via node:zlib) so no external image library is
// needed. Comparing the CLI's PNG against this reference catches decoder,
// colour and PNG-encoder regressions in one number.
import { inflateSync } from "node:zlib";

const clamp = (v) => Math.max(0, Math.min(255, Math.round(v)));

///|
export function yuv420pToRgba(yuv, width, height, { limited = true } = {}) {
  const cw = Math.ceil(width / 2), ch = Math.ceil(height / 2);
  const lumaSize = width * height;
  const chromaSize = cw * ch;
  if (yuv.length < lumaSize + 2 * chromaSize) throw new Error("short YUV");
  const out = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    const cy = y >> 1;
    for (let x = 0; x < width; x++) {
      const cx = x >> 1;
      let Y = yuv[y * width + x];
      const U = yuv[lumaSize + cy * cw + cx];
      const V = yuv[lumaSize + chromaSize + cy * cw + cx];
      if (limited) Y = ((Y - 16) * 255) / 219;
      const Cb = limited ? ((U - 128) * 255) / 224 : U - 128;
      const Cr = limited ? ((V - 128) * 255) / 224 : V - 128;
      // BT.709: Kr=0.2126, Kb=0.0722.
      const R = Y + 2 * (1 - 0.2126) * Cr;
      const B = Y + 2 * (1 - 0.0722) * Cb;
      const G = Y - (2 * (0.2126 * (1 - 0.2126) * Cr + 0.0722 * (1 - 0.0722) * Cb)) / (1 - 0.2126 - 0.0722);
      const o = (y * width + x) * 4;
      out[o] = clamp(R);
      out[o + 1] = clamp(G);
      out[o + 2] = clamp(B);
      out[o + 3] = 255;
    }
  }
  return out;
}

///|
export function decodePng(png) {
  if (png.length < 8 || !png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) throw new Error("PNG signature");
  let off = 8, ihdr = null, idat = [];
  while (off + 12 <= png.length) {
    const len = png.readUInt32BE(off);
    const typ = png.subarray(off + 4, off + 8).toString("ascii");
    const data = png.subarray(off + 8, off + 8 + len);
    if (typ === "IHDR") ihdr = data;
    if (typ === "IDAT") idat.push(data);
    if (typ === "IEND") break;
    off += 12 + len;
  }
  if (!ihdr) throw new Error("no IHDR");
  const width = ihdr.readUInt32BE(0), height = ihdr.readUInt32BE(4);
  const depth = ihdr[8], colour = ihdr[9];
  if (depth !== 8 || colour !== 6) throw new Error(`unsupported PNG depth/colour ${depth}/${colour}`);
  const raw = inflateSync(Buffer.concat(idat));
  const bpp = 4, stride = width * bpp;
  const out = Buffer.alloc(height * stride);
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = Buffer.from(raw.subarray(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride));
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? line[i - bpp] : 0;
      const b = prev[i];
      const c = i >= bpp ? prev[i - bpp] : 0;
      let v = line[i];
      if (filter === 1) v += a;
      else if (filter === 2) v += b;
      else if (filter === 3) v += Math.floor((a + b) / 2);
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      } else if (filter !== 0) throw new Error(`unknown PNG filter ${filter}`);
      line[i] = v & 255;
    }
    line.copy(out, y * stride);
    prev = line;
  }
  return { width, height, rgba: out };
}

///|
export function psnr(actual, expected) {
  if (actual.length !== expected.length) throw new Error(`length ${actual.length} != ${expected.length}`);
  let se = 0;
  for (let i = 0; i < actual.length; i++) {
    const d = actual[i] - expected[i];
    se += d * d;
  }
  const mse = se / actual.length;
  if (mse === 0) return Infinity;
  return 10 * Math.log10((255 * 255) / mse);
}
