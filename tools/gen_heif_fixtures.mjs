// Embeds the hex fixtures the HEIF tests read, so they do not need
// `moonbitlang/core/async/fs`: `moon check --deny-warn` does not resolve that
// package, and importing it failed the package before any test ran.
//
//   node tools/gen_heif_fixtures.mjs
//
// Output goes into the table between the two markers in heif/fixture_test.mbt.
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const BEGIN = "// BEGIN fixtures";
const END = "// END fixtures";

const sources = [];
const collect = (root, dir) => {
  for (const name of readdirSync(join(root, dir)).sort()) {
    const path = join(root, dir, name);
    if (statSync(path).isFile()) sources.push({ key: join(dir, name), path });
  }
};
// Fixtures are keyed by the path the tests ask for: binaries live under
// heif/testdata, the upstream Go dumps under tools/fixtures/heic.
collect("heif/testdata", "");
collect("heif/testdata", "malformed");
collect("tools/fixtures/heic", "");

const arm = (f) => {
  const bytes = readFileSync(f.path);
  const lits = [];
  for (let i = 0; i < bytes.length; i += 16) {
    lits.push(`    "${bytes.subarray(i, i + 16).toString("hex")}"`);
  }
  if (lits.length === 0) return `    "${f.key}" => ""`;
  return `    "${f.key}" =>\n${lits.join(" +\n")}`;
};

const table = [BEGIN, sources.map(arm).join("\n"), END].join("\n");

const path = "heif/fixture_test.mbt";
const source = readFileSync(path, "utf8");
const from = source.indexOf(BEGIN);
const to = source.indexOf(END);
if (from < 0 || to < 0) throw new Error(`markers not found in ${path}`);
writeFileSync(path, source.slice(0, from) + table + source.slice(to + END.length));
console.log(`wrote ${sources.length} fixtures into ${path}`);
