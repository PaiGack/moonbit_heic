// E2E fixture builder: wrap a real M3 I-frame bitstream (tools/frame_golden.json
// carries the upstream Go decoder's planar YUV next to each stream) into a
// minimal but valid HEIC. The M5 CLI then decodes it end to end, and the
// harness compares the emitted PNG against an INDEPENDENT reference
// YUV->RGB conversion of that YUV (see reference.mjs), not the MoonBit colour
// code under test.
//
//   node tools/e2e/build_case.mjs <case-name> <out.heic> [out.ref.yuv]
//
// `colr` is BT.709 / BT.709 / BT.709 limited range, so the reference and the
// CLI agree on the matrix by construction, and the PSNR measures the decoder
// + PNG encoder rather than a colour-management disagreement.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const [name, heicOut, yuvOut] = process.argv.slice(2);
if (!name || !heicOut) throw new Error("usage: node build_case.mjs <case> <out.heic> [out.yuv]");

const golden = JSON.parse(readFileSync(join(root, "tools/frame_golden.json"), "utf8"));
const c = golden.cases.find((x) => x.name === name);
if (!c) throw new Error(`unknown case ${name}; available: ${golden.cases.map((x) => x.name).join(", ")}`);
const src = Buffer.from(c.stream, "base64");
const width = c.width;
const height = c.height;

// Split on both 3- and 4-byte AnnexB start codes, like M3's split_annex_b.
const nals = [];
let start = -1;
for (let i = 0; i < src.length; i++) {
  let sc = 0;
  if (i + 4 <= src.length && src[i] === 0 && src[i + 1] === 0 && src[i + 2] === 0 && src[i + 3] === 1) sc = 4;
  else if (i + 3 <= src.length && src[i] === 0 && src[i + 1] === 0 && src[i + 2] === 1) sc = 3;
  if (sc) {
    if (start >= 0) {
      let end = i;
      while (end > start && src[end - 1] === 0) end--;
      if (end > start) nals.push(src.subarray(start, end));
    }
    start = i + sc;
    i += sc - 1;
  }
}
if (start >= 0) nals.push(src.subarray(start));
const nalType = (n) => (n[0] >> 1) & 0x3f;
const paramNals = nals.filter((n) => [32, 33, 34].includes(nalType(n)));
const sliceNals = nals.filter((n) => [19, 20, 21].includes(nalType(n)));
if (paramNals.length < 3 || sliceNals.length !== 1) {
  throw new Error(`expected VPS/SPS/PPS + one IDR slice, got ${JSON.stringify(nals.map(nalType))}`);
}

const box = (type, payload) => {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(8 + payload.length, 0);
  head.write(type, 4, "ascii");
  return Buffer.concat([head, payload]);
};
const full = (type, version, flags, payload) => {
  const head = Buffer.alloc(4);
  head[0] = version;
  head[1] = (flags >> 16) & 0xff;
  head[2] = (flags >> 8) & 0xff;
  head[3] = flags & 0xff;
  return box(type, Buffer.concat([head, payload]));
};

// hvcC (ISO/IEC 14496-15 E.2.3): 23 fixed bytes, then one NAL array per type.
const arrays = [];
for (const t of [32, 33, 34]) {
  const group = paramNals.filter((n) => nalType(n) === t);
  if (!group.length) continue;
  const parts = [Buffer.from([0x80 | t])];
  const cnt = Buffer.alloc(2); cnt.writeUInt16BE(group.length);
  parts.push(cnt);
  for (const n of group) {
    const len = Buffer.alloc(2); len.writeUInt16BE(n.length);
    parts.push(len, n);
  }
  arrays.push(Buffer.concat(parts));
}
const hvcCHdr = Buffer.from([
  0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x3c, 0xf0, 0x00, 0xfc,
  0xfd, 0xf8, 0xf8, 0x00, 0x00, 0x0f, 0x03,
]);
const hvcC = box("hvcC", Buffer.concat([hvcCHdr, ...arrays]));

const ispe = full("ispe", 0, 0, (() => {
  const p = Buffer.alloc(8); p.writeUInt32BE(width, 0); p.writeUInt32BE(height, 4); return p;
})());
// nclx: primaries=1 (BT.709), transfer=1 (BT.709), matrix=1 (BT.709), limited.
const colr = box("colr", Buffer.from([
  0x6e, 0x63, 0x6c, 0x78,
  0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00,
]));
const ipco = box("ipco", Buffer.concat([hvcC, ispe, colr]));
const ipma = full("ipma", 0, 0, Buffer.concat([
  Buffer.from([0, 0, 0, 1]), Buffer.from([0, 1, 3, 0x01, 0x02, 0x03]),
]));
const iprp = box("iprp", Buffer.concat([ipco, ipma]));
const infe = full("infe", 2, 0, Buffer.concat([
  Buffer.from([0, 1]), Buffer.from([0, 0]), Buffer.from("hvc1", "ascii"), Buffer.from([0]),
]));
const iinf = full("iinf", 0, 0, Buffer.concat([Buffer.from([0, 1]), infe]));
const hdlr = full("hdlr", 0, 0, Buffer.concat([
  Buffer.alloc(4), Buffer.from("pict", "ascii"), Buffer.alloc(12), Buffer.from([0]),
]));
const pitm = full("pitm", 0, 0, Buffer.from([0, 1]));

const slice = sliceNals[0];
const mdatPayload = Buffer.concat([
  (() => { const l = Buffer.alloc(4); l.writeUInt32BE(slice.length); return l; })(),
  slice,
]);
const iloc = full("iloc", 0, 0, Buffer.concat([
  Buffer.from([0x44, 0, 0, 1]), Buffer.from([0, 1]), Buffer.from([0, 0]),
  Buffer.from([0, 1]), Buffer.from([0, 0, 0, 0]), Buffer.from([0, 0, 0, 0]),
]));
const meta = full("meta", 0, 0, Buffer.concat([hdlr, pitm, iloc, iinf, iprp]));
const ftyp = box("ftyp", Buffer.concat([
  Buffer.from("heic", "ascii"), Buffer.from([0, 0, 0, 0]),
  Buffer.from("heic", "ascii"), Buffer.from("mif1", "ascii"), Buffer.from("hevc", "ascii"),
]));
const mdatHead = Buffer.alloc(8);
mdatHead.writeUInt32BE(8 + mdatPayload.length, 0);
mdatHead.write("mdat", 4, "ascii");
const file = Buffer.concat([ftyp, meta, mdatHead, mdatPayload]);
const marker = Buffer.from([0x44, 0, 0, 1, 0, 1, 0, 0, 0, 1]);
const pos = file.indexOf(marker);
if (pos < 0) throw new Error("iloc marker not found");
file.writeUInt32BE(file.length - mdatPayload.length, pos + marker.length);
file.writeUInt32BE(mdatPayload.length, pos + marker.length + 4);
writeFileSync(heicOut, file);

if (yuvOut) {
  const yuv = Buffer.from(c.yuv, "base64");
  const expected = width * height + 2 * Math.ceil(width / 2) * Math.ceil(height / 2);
  if (yuv.length !== expected) throw new Error(`${name}: yuv ${yuv.length} != ${expected}`);
  writeFileSync(yuvOut, yuv);
}
console.log(`${name}: ${width}x${height}, ${file.length}-byte HEIC`);
