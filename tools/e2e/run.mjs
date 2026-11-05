#!/usr/bin/env node
// M5 end-to-end acceptance harness.
//
//   node tools/e2e/run.mjs [--smoke] [--out <report.json>]
//
// Builds decodable HEICs from the REAL upstream Go I-frame fixtures
// (tools/frame_golden.json, which also carries the decoder's planar YUV),
// runs the MoonBit CLI on them, and checks:
//   1. exit codes 0 / 1 / 2 / 3 on a matrix of good and refused inputs,
//   2. PSNR of the emitted PNG against an INDEPENDENT JS YUV->RGB reference
//      (reference.mjs), not the MoonBit colour code under test,
//   3. decode wall-time per backend (native / wasm / wasm-gc / js) and the
//      emitted artifact sizes -> a JSON report + a timing curve.
//
// --smoke keeps CI cheap: one 16x16 case, PNG only, one backend, no 4032x3024.
// No Go, no network, no external image library (Pillow not required).
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync, rmSync, existsSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "url";
import { yuv420pToRgba, decodePng, psnr } from "./reference.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const smoke = process.argv.includes("--smoke");
const outIdx = process.argv.indexOf("--out");
const reportPath = outIdx >= 0 ? process.argv[outIdx + 1] : join(root, "tools/e2e/report.json");
const golden = JSON.parse(readFileSync(join(root, "tools/frame_golden.json"), "utf8"));

const CASES = smoke
  ? ["angular_grad.h265"]
  : ["angular_grad.h265", "grad64.h265", "ramp64.h265", "qp_small.h265", "signhide.h265"];
// The native backend needs a system C compiler, which slim CI images do not
// ship. wasm / wasm-gc / js do not. Keep native in the report whenever a
// compiler is available, but never fail the smoke just because one is missing.
const hasCCompiler = () => {
  if (process.env.MOON_CC) return true;
  const r = spawnSync("sh", ["-c", "command -v cc || command -v gcc || command -v clang"], { encoding: "utf8" });
  return r.status === 0 && (r.stdout ?? "").trim().length > 0;
};
const nativeOK = hasCCompiler();
const allBackends = ["native", "wasm", "wasm-gc", "js"];
const BACKENDS = smoke
  ? [nativeOK ? "native" : "wasm"]
  : allBackends.filter((t) => t !== "native" || nativeOK);
const assert = (ok, msg) => { if (!ok) throw new Error(msg); };
const dir = mkdtempSync(join(tmpdir(), "m5-e2e-"));

const run = (cmd, args, opts = {}) => {
  const r = spawnSync(cmd, args, { encoding: "utf8", cwd: root, ...opts });
  return { code: r.status, out: r.stdout ?? "", err: r.stderr ?? "" };
};
const moon = (args, target) => run("moon", target ? ["run", "--target", target, ...args] : ["run", ...args]);

try {
  const report = {
    generated: new Date().toISOString(),
    smoke,
    source: "tools/frame_golden.json (REAL upstream Go decoder DecodeNAL+Flush, -tags noasm)",
    note: "One picture decoded per iteration; ns_per_call is wall time of the full convert() (container->M3->M4->PNG).",
    psnr: [],
    timing: [],
    artifacts: [],
    exit_codes: [],
  };

  // ---- 1. PSNR: CLI output vs an independent JS reference -----------------
  const pngs = [];
  for (const name of CASES) {
    const c = golden.cases.find((x) => x.name === name);
    assert(c, `missing golden case ${name}`);
    const heic = join(dir, name + ".heic");
    const yuv = join(dir, name + ".yuv");
    const png = join(dir, name + ".png");
    execFileSync("node", ["tools/e2e/build_case.mjs", name, heic, yuv], { cwd: root, stdio: "pipe" });
    const r = moon(["cmd/heic2png", "--", heic, png]);
    assert(r.code === 0, `${name}: CLI exited ${r.code}: ${r.err.split("\n").filter((l) => !l.startsWith("Warning")).slice(0, 2).join(" | ")}`);
    const ref = yuv420pToRgba(readFileSync(yuv), c.width, c.height, { limited: true });
    const dec = decodePng(readFileSync(png));
    assert(dec.width === c.width && dec.height === c.height, `${name}: geometry ${dec.width}x${dec.height}`);
    const p = psnr(dec.rgba, ref);
    // A deterministic full-reconstruction decoder must be sample-exact with
    // an independent BT.709 reference; allow >=45dB (Issue acceptance bar)
    // but print the real number, which is Infinity when exactly equal.
    assert(p >= 45, `${name}: PSNR ${p} < 45dB`);
    report.psnr.push({ case: name, width: c.width, height: c.height, psnr_db: p === Infinity ? "inf" : Number(p.toFixed(2)) });
    pngs.push({ name, png });
  }

  // ---- 2. wall time + artifact size per backend -------------------------
  const iters = smoke ? 1 : 3;
  for (const target of BACKENDS) {
    const built = run("moon", ["build", "--target", target, "cmd/bench"], { cwd: root });
    assert(built.code === 0, `build ${target} failed: ${built.err.slice(-400)}`);
    const bench = moon(["cmd/bench", "--", String(iters)], target);
    assert(bench.code === 0, `bench ${target} failed: ${bench.err.slice(-400)}`);
    const m = bench.out.match(/iters=(\d+) ns_per_call=(\d+) bytes=(\d+)/);
    assert(m, `bench ${target} produced no measurement: ${bench.out}`);
    const artifact = { target, ns_per_call: Number(m[2]), bytes: Number(m[3]), iters: Number(m[1]) };
    const exts = { native: "exe", wasm: "wasm", "wasm-gc": "wasm", js: "js" };
    const file = join(root, "_build", target, "debug/build/cmd/bench", `bench.${exts[target]}`);
    artifact.artifact_bytes = existsSync(file) ? statSync(file).size : null;
    report.timing.push(artifact);
    report.artifacts.push({ target, artifact_bytes: artifact.artifact_bytes, output_bytes: artifact.bytes });
  }

  // ---- 3. exit codes on the refusal matrix ------------------------------
  // Build a 10-bit-claiming container from the same small stream, then feed
  // the harness's own good case for 0. The rest come from heif/testdata and
  // deliberately corrupted bytes.
  const good = join(dir, CASES[0] + ".heic");
  const fake10 = join(dir, "fake10.heic");
  {
    const bytes = Buffer.from(readFileSync(good));
    const i = bytes.indexOf(Buffer.from("hvcC"));
    bytes[i + 4 + 17] = 0xfa; // (0xfa & 7)+8 = 10-bit luma
    bytes[i + 4 + 18] = 0xfa;
    bytes[i + 4 + 1] = (bytes[i + 4 + 1] & 0xe0) | 2; // profile_idc = Main 10
    writeFileSync(fake10, bytes);
  }
  const missing = join(dir, "nope.heic");
  const truncated = join(dir, "truncated.heic");
  {
    // Keep the container intact but cut the IDR slice short: M3 reaches the
    // access unit and refuses it as a decode failure (exit 3), which is the
    // bucket the "decode failed" contract names.
    const bytes = Buffer.from(readFileSync(good));
    const mi = bytes.indexOf(Buffer.from("mdat"));
    const payload = mi + 4;
    const keep = 4 + 20;
    const cut = Buffer.from(bytes.subarray(0, payload + keep));
    cut.writeUInt32BE(8 + cut.length - payload, mi - 4);
    const marker = Buffer.from([0x44, 0, 0, 1, 0, 1, 0, 0, 0, 1]);
    const pos = cut.indexOf(marker);
    cut.writeUInt32BE(cut.length - payload, pos + marker.length + 4);
    writeFileSync(truncated, cut);
  }
  const matrix = [
    { label: "good -> 0", args: [good, join(dir, "ok.png")], want: 0 },
    { label: "unreadable -> 1", args: [missing, join(dir, "no.png")], want: 1 },
    { label: "10-bit profile -> 2", args: [fake10, join(dir, "ten.png")], want: 2 },
    { label: "grid -> 2", args: [join(root, "heif/testdata/grid.heic"), join(dir, "grid.png")], want: 2 },
    { label: "4:2:2 -> 2", args: [join(root, "heif/testdata/chroma422.heic"), join(dir, "c422.png")], want: 2 },
    { label: "truncated -> 3", args: [truncated, join(dir, "trunc.png")], want: 3 },
    { label: "bad flag -> 1", args: ["--bogus"], want: 1 },
  ];
  for (const t of matrix) {
    const r = moon(["cmd/heic2png", "--", ...t.args]);
    assert(r.code === t.want, `${t.label}: got ${r.code}, want ${t.want}: ${r.err.split("\n").filter((l) => !l.startsWith("Warning")).slice(0, 1).join("")}`);
    report.exit_codes.push({ label: t.label, exit: r.code });
  }

  // ---- 4. write the report + a tiny timing curve ------------------------
  writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n");
  const curve = report.timing
    .map((t) => `  ${t.target.padEnd(9)} ${(t.ns_per_call / 1e6).toFixed(1).padStart(8)} ms/call   artifact ${t.artifact_bytes ?? "?"} B`)
    .join("\n");
  console.log(`M5 e2e ${smoke ? "(smoke) " : ""}report -> ${reportPath}`);
  console.log("PSNR vs independent BT.709 reference:");
  for (const p of report.psnr) console.log(`  ${p.case.padEnd(22)} ${p.width}x${p.height}  ${p.psnr_db} dB`);
  console.log("decode wall time (full convert, 64x64 I frame):");
  console.log(curve);
  console.log("exit codes:", report.exit_codes.map((e) => `${e.label}=${e.exit}`).join(", "));
} finally {
  rmSync(dir, { recursive: true, force: true });
}
