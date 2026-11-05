# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

- The module is `PaiGack/heic`. Packages, one per milestone:
  `safe/` (64-bit arithmetic helpers), `heif/` (ISOBMFF container),
  `hevc/` (NAL + parameter sets), `hevc/bitreader/`, `hevc/headers/`,
  `hevc/cabac/`, `hevc/decode/`, `color/`, `io/png/`, `io/jpeg/`,
  `cmd/heic2png/`. `tools/parity/` holds the Node parity harness, and
  `tools/fixtures/` its inputs.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

- **Sizes and shifts are `Int64`, always.** MoonBit's `Int` is 32 bits; the
  upstream Go this is ported from has a 64-bit `int`. Any quantity that can
  outgrow 2^31 — picture dimensions, plane and buffer sizes, CTB counts,
  `1 << bits` masks, `(a + b - 1) / b` — is declared `Int64` and computed
  through `safe/`, which is 64-bit arithmetic with the degenerate cases (zero
  divisor, negative count, a shift past 63) reported as `Overflow`.
  `Int32` is for values that are structurally small: chroma format ids, bit
  depths, log2 sizes, NAL header fields, loop counters. Do not narrow a size
  back to `Int32` "temporarily"; if a field is 32-bit today because of an old
  guard, widen it.

- `safe/narrow` is the one-way door from `Int64` to `Int` for the genuinely
  32-bit fields; `safe/clamp` is the rare saturating variant. Neither belongs
  anywhere near an allocation size.

- Add a test next to every new size computation, and keep the counterexample
  showing what the 32-bit version would have done.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

- `node --test tools/parity/` runs the parity harness self-test. The harness
  compares a dump against the upstream Go output; see `tools/parity/README.md`
  for the dump format.

## CI

`.cnb.yml` runs `moon check --deny-warn`, `moon test`, `moon info` (fails if
`.mbti` files drift), `moon fmt --check`, and the parity harness self-test on
every push and pull request.
