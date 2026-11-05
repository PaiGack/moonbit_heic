// Builds a minimal, decodable HEIC around one of M3's real AnnexB I-frame
// streams, so the M4 CLI can be exercised end to end (container -> M3 ->
// colour -> PNG/JPEG -> external decoder).
//
//   node tools/build_m4_heic.mjs <annexb.h265> <out.heic> [width] [height]
//
// Item data is 4-byte-length-prefixed NAL units; parameter sets live in hvcC.
import { readFileSync, writeFileSync } from "node:fs";

const [input, output, wArg, hArg] = process.argv.slice(2);
if (!input || !output) throw new Error("usage: node build_m4_heic.mjs <in.h265> <out.heic> [w] [h]");
const width = Number(wArg ?? 64);
const height = Number(hArg ?? 64);

const src = readFileSync(input);
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
      while (end > start && src[end - 1] === 0) end--; // trailing zero bytes
      if (end > start) nals.push(src.subarray(start, end));
    }
    start = i + sc;
    i += sc - 1;
  }
}
if (start >= 0) nals.push(src.subarray(start));

const nalType = (n) => (n[0] >> 1) & 0x3f;
const paramNals = nals.filter((n) => [32, 33, 34].includes(nalType(n)));
const sliceNals = nals.filter((n) => nalType(n) === 19 || nalType(n) === 20 || nalType(n) === 21);
if (paramNals.length < 3 || sliceNals.length !== 1) {
  throw new Error(`expected VPS/SPS/PPS + exactly one IDR slice, got ${JSON.stringify(nals.map((n) => nalType(n)))}`);
}

function box(type, payload) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(8 + payload.length, 0);
  head.write(type, 4, "ascii");
  return Buffer.concat([head, payload]);
}
function full(type, version, flags, payload) {
  const head = Buffer.alloc(4);
  head[0] = version; head[1] = (flags >> 16) & 0xff;
  head[2] = (flags >> 8) & 0xff; head[3] = flags & 0xff;
  return box(type, Buffer.concat([head, payload]));
}

// hvcC: ISO/IEC 14496-15 E.2.3. NAL arrays are [array_completeness|type,
// numNalus, (length, nal)...]; lengthSizeMinusOne = 3 (4-byte prefixes).
const arrays = [];
for (const t of [32, 33, 34]) {
  const group = paramNals.filter((n) => nalType(n) === t);
  if (!group.length) continue;
  const parts = [Buffer.from([0x80 | t, 0, group.length])];
  for (const n of group) {
    const len = Buffer.alloc(2); len.writeUInt16BE(n.length);
    parts.push(len, n);
  }
  const hdr = Buffer.alloc(2); hdr.writeUInt16BE(group.length);
  parts[0] = Buffer.from([0x80 | t]);
  arrays.push(Buffer.concat([parts[0], hdr, ...parts.slice(1)]));
}
// 23 bytes of fixed hvcC fields (ISO/IEC 14496-15 E.2.3), then NAL arrays.
// Mirrors the layout the M1 parser reads: version, profile, compat u32,
// 6 reserved bytes, level, u16, u8, chroma, 2 depths, u16, length_size,
// num_arrays.
const hvcCHdr = Buffer.from([
  0x01, 0x03, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x3c, 0xf0, 0x00, 0xfc,
  0xfd, 0xf8, 0xf8, 0x00, 0x00, 0x0f, 0x03,
]);
const hvcC = box("hvcC", Buffer.concat([hvcCHdr, ...arrays]));

const ispe = full("ispe", 0, 0, (() => {
  const p = Buffer.alloc(8); p.writeUInt32BE(width, 0); p.writeUInt32BE(height, 4); return p;
})());
// colr 'nclx': primaries=1 (BT.709), transfer=1, matrix=1 (BT.709), full range.
// colr 'nclx': colour_type, then primaries/transfer/matrix as u16 and the
// full-range flag in the top bit of a byte (MIAF / ISO 23008-12).
const colr = box("colr", Buffer.from([
  0x6e, 0x63, 0x6c, 0x78,
  0x00, 0x01, 0x00, 0x0d, 0x00, 0x06, 0x80,
]));

const ipco = box("ipco", Buffer.concat([hvcC, ispe, colr]));
const ipma = full("ipma", 0, 0, Buffer.concat([
  Buffer.from([0, 0, 0, 1]),
  Buffer.from([0, 1, 3, 0x01, 0x02, 0x03]),
]));
const iprp = box("iprp", Buffer.concat([ipco, ipma]));

const infe = full("infe", 2, 0, Buffer.concat([
  Buffer.from([0, 1]), Buffer.from([0, 0]),
  Buffer.from("hvc1", "ascii"), Buffer.from([0]),
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

// iloc v0: full-box hdr, sizes=0x44 (offset/length = 4), base_size=0,
// item_count u16, then id u16, construction_method u16, base_offset u32(0),
// extent_count u16, extent offset u32, extent length u32.
const iloc = full("iloc", 0, 0, Buffer.concat([
  Buffer.from([0x44, 0, 0, 1]),
  Buffer.from([0, 1]), Buffer.from([0, 0]),
  Buffer.from([0, 1]),
  Buffer.from([0, 0, 0, 0]), Buffer.from([0, 0, 0, 0]),
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
// Patch the iloc extent offset/length: find the fixed marker near iloc.
const marker = Buffer.from([0x44, 0, 0, 1, 0, 1, 0, 0, 0, 1]);
const pos = file.indexOf(marker);
if (pos < 0) throw new Error("iloc marker not found");
file.writeUInt32BE(file.length - mdatPayload.length, pos + marker.length);
file.writeUInt32BE(mdatPayload.length, pos + marker.length + 4);

writeFileSync(output, file);
console.log(`wrote ${output}: ${file.length} bytes, one ${slice.length}-byte IDR slice, payload at ${file.length - mdatPayload.length}`);
