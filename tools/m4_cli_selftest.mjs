// Exercises the M4 CLI end to end without an external image library:
// builds a decodable HEIC from one of M3's real I-frame bitstreams, runs
// `moon run cmd/heic2png` for PNG / 16-bit PNG / JPEG, and validates the
// container markers and declared geometry in the output.
//
//   node tools/m4_cli_selftest.mjs
import { execFileSync } from "node:child_process";
import { readFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "m4-cli-"));
const heic = join(dir, "frame.heic");
try {
  execFileSync("node", [
    "tools/build_m4_heic.mjs", "hevc/testdata/ctu64_128x128.h265", heic, "128", "128",
  ], { stdio: "pipe" });

  const png8 = join(dir, "out8.png");
  const png16 = join(dir, "out16.png");
  const jpg = join(dir, "out.jpg");
  const run = (args) => execFileSync("moon", ["run", "cmd/heic2png", "--", ...args], { stdio: "pipe" });
  run([heic, png8]);
  run(["--16bit", heic, png16]);
  run(["--jpeg", "--quality", "90", heic, jpg]);

  const assert = (ok, msg) => { if (!ok) throw new Error(msg); };
  const checkPng = (path, bitDepth) => {
    const d = readFileSync(path);
    assert(d.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])), "PNG signature");
    let off = 8, ihdr = null, idat = false, iend = false;
    while (off + 12 <= d.length) {
      const len = d.readUInt32BE(off);
      const typ = d.subarray(off + 4, off + 8).toString("ascii");
      if (typ === "IHDR") ihdr = d.subarray(off + 8, off + 8 + len);
      if (typ === "IDAT") idat = true;
      if (typ === "IEND") iend = true;
      off += 12 + len;
    }
    assert(ihdr && ihdr.length === 13, "IHDR present");
    assert(ihdr.readUInt32BE(0) === 128 && ihdr.readUInt32BE(4) === 128, "IHDR geometry");
    assert(ihdr[8] === bitDepth, `IHDR bit depth ${bitDepth}`);
    assert(ihdr[9] === 6, "IHDR RGBA colour type");
    assert(idat && iend, "IDAT + IEND present");
  };
  checkPng(png8, 8);
  checkPng(png16, 16);

  const j = readFileSync(jpg);
  assert(j[0] === 0xff && j[1] === 0xd8, "JPEG SOI");
  assert(j[j.length - 2] === 0xff && j[j.length - 1] === 0xd9, "JPEG EOI");
  let off = 2, sof0 = null, sos = false;
  while (off + 4 <= j.length) {
    if (j[off] !== 0xff) { off++; continue; }
    const code = j[off + 1];
    const len = j.readUInt16BE(off + 2);
    if (code === 0xda) { sos = true; break; }
    if (code === 0xc0) sof0 = j.subarray(off + 4, off + 2 + len);
    off += 2 + len;
  }
  assert(sof0 && sof0[0] === 8, "JPEG 8-bit SOF0");
  assert(sof0.readUInt16BE(1) === 128 && sof0.readUInt16BE(3) === 128, "JPEG geometry");
  assert(sof0[5] === 3, "JPEG three components");
  assert(sos, "JPEG SOS present");
  console.log("m4 cli self-test: PNG8 / PNG16 / JPEG all well-formed at 128x128");
} finally {
  rmSync(dir, { recursive: true, force: true });
}
