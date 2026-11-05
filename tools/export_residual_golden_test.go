// To regenerate tools/residual_golden.json, copy this file into a checkout of
// github.com/gen2brain/h265 at hevc/export_residual_golden_test.go, then run:
//
//   RESIDUAL_GOLDEN_OUT=/abs/path/to/monbit_tmp/tools/residual_golden.json \
//     go test ./hevc/ -run TestExportResidualGolden -count=1 -v
//
// It is the first link of the M3 residual trust chain: the real upstream Go
// encoder (encodeResidual / cabacWriter) produces 118 CABAC bitstreams plus
// every context-derivation value. tools/crosscheck_residual.mjs then holds
// that JSON against an independent, from-the-spec JS transcription
// (122488 values, zero differences), and tools/gen_residual_golden.mjs bakes
// the verified data into hevc/residual/golden.mbt. CI needs no Go toolchain.

package hevc

// TestExportResidualGolden produces the authoritative truth for the M3
// residual-coefficient syntax layer (7.3.8.11). It is NOT a test of the
// MoonBit port; it runs the real upstream Go encoder (encodeResidual) and
// pure context derivations, then writes a JSON blob that
// tools/crosscheck_residual.mjs and tools/gen_residual_golden.mjs consume.
//
//   go test -run TestExportResidualGolden -count=1
//
// The output path is passed via the RESIDUAL_GOLDEN_OUT env var.

import (
  "encoding/json"
  "math/rand/v2"
  "os"
  "testing"
)

func TestExportResidualGolden(t *testing.T) {
  out := map[string]any{}

  // ---- 9.3.4.2.5 / 7.4.9.11 pure derivations, full traversal ----------
  type SI struct{ Log2, CIdx, Mode int; Intra bool; Chroma uint32; Want int }
  sis := []SI{}
  for _, log2 := range []int{2, 3, 4, 5} {
    for _, cIdx := range []int{0, 1, 2} {
      for mode := 0; mode <= 34; mode++ {
        for _, intra := range []bool{false, true} {
          for _, chroma := range []uint32{1, 3} {
            sis = append(sis, SI{log2, cIdx, mode, intra, chroma,
              scanIndex(log2, cIdx, mode, intra, chroma)})
          }
        }
      }
    }
  }
  out["scan_index"] = sis

  type LSC struct{ Log2, CIdx, Bin, Want int }
  lscs := []LSC{}
  for log2 := 2; log2 <= 5; log2++ {
    cMax := log2<<1 - 1
    for _, cIdx := range []int{0, 1} {
      for bin := 0; bin < cMax; bin++ {
        lscs = append(lscs, LSC{log2, cIdx, bin, lastSigCoeffCtx(log2, cIdx, bin)})
      }
    }
  }
  out["last_sig_coeff_ctx"] = lscs

  // sigCoeffCtx: fixed traversal order documented in the generator.
  // for log2=2..5, cIdx in {0,1}, scan=0..2, csbf=0..3, y=0..n-1, x=0..n-1.
  scc := []int{}
  var sbSet []int
  for log2 := 2; log2 <= 5; log2++ {
    n := 1 << log2
    for _, cIdx := range []int{0, 1} {
      for scan := 0; scan < 3; scan++ {
        for csbf := 0; csbf < 4; csbf++ {
          for y := 0; y < n; y++ {
            for x := 0; x < n; x++ {
              scc = append(scc, sigCoeffCtx(x, y, log2, cIdx, scan, csbf))
            }
          }
        }
      }
    }
  }
  // sigCtxSet.at over every combination, held to the derivation.
  for _, log2 := range []int{2, 3, 4, 5} {
    n := 1 << log2
    for _, cIdx := range []int{0, 1, 2} {
      for scan := 0; scan < 3; scan++ {
        for csbf := 0; csbf < 4; csbf++ {
          for yS := 0; yS < n/4; yS++ {
            for xS := 0; xS < n/4; xS++ {
              set := newSigCtxSet(xS, yS, log2, cIdx, scan, csbf, false)
              for y := 0; y < 4; y++ {
                for x := 0; x < 4; x++ {
                  sbSet = append(sbSet, set.at(x, y))
                }
              }
            }
          }
        }
      }
    }
  }
  out["sig_coeff_ctx"] = scc
  out["sig_ctx_set"] = sbSet

  // ---- residual_coding round-trip cases: Go encoder -> CABAC bytes ------
  type Case struct {
    Log2, CIdx, PredMode int
    Intra, SignHiding    bool
    Coef                 []int32
    Bytes                []byte
  }
  cases := []Case{}

  addCase := func(b residualBlock, p pps, coef []int32) {
    s := sps{chromaFormatIDC: 1}
    var bits putBits
    var w cabacWriter
    w.init(&bits, 26, sliceI, false)
    if err := encodeResidual(&w, &s, &p, coef, b); err != nil {
      t.Fatalf("encode log2=%d cIdx=%d mode=%d hiding=%v: %v",
        b.log2Size, b.cIdx, b.predModeIntra, p.signDataHidingEnabled, err)
    }
    w.encodeTerminate(1)
    // Verify the upstream decoder reproduces the coefficients from these
    // exact bytes before we ship them as truth.
    var d cabac
    if err := d.init(w.bytes(), 0); err != nil {
      t.Fatal(err)
    }
    d.initContexts(26, sliceI, false)
    var stat [4]uint8
    got := make([]int32, len(coef))
    if _, err := decodeResidual(&d, &s, &p, &sliceHeader{sliceType: sliceI}, got, b, &stat); err != nil {
      t.Fatalf("decode verify: %v", err)
    }
    for i := range coef {
      if got[i] != coef[i] {
        t.Fatalf("upstream round-trip mismatch at %d", i)
      }
    }
    if d.decodeTerminate() != 1 {
      t.Fatal("missing termination")
    }
    cases = append(cases, Case{b.log2Size, b.cIdx, b.predModeIntra, b.intra,
      p.signDataHidingEnabled, coef, append([]byte(nil), w.bytes()...)})
  }

  r := rand.New(rand.NewPCG(0xC0FFEE, 0xBEEF))
  sparse := func(n int, dense bool) []int32 {
    coef := make([]int32, n*n)
    for i := range coef {
      p := 5
      if dense { p = 2 }
      if r.IntN(p) == 0 {
        level := int32(1 + r.IntN(12))
        if r.IntN(7) == 0 { level = int32(100 + r.IntN(30000)) }
        if r.IntN(2) != 0 { level = -level }
        coef[i] = level
      }
    }
    coef[r.IntN(len(coef))] = int32(1 + r.IntN(3))
    return coef
  }

  // Broad matrix: sizes, components, intra modes that trigger scan changes.
  for _, log2 := range []int{2, 3, 4, 5} {
    n := 1 << log2
    for _, cIdx := range []int{0, 1, 2} {
      for _, mode := range []int{0, 1, 6, 10, 14, 22, 26, 30, 34} {
        b := residualBlock{log2Size: log2, cIdx: cIdx, predModeIntra: mode, intra: true}
        addCase(b, pps{}, sparse(n, false))
      }
    }
  }
  // A few dense and non-intra cases.
  for _, log2 := range []int{3, 4} {
    n := 1 << log2
    addCase(residualBlock{log2Size: log2}, pps{}, sparse(n, true))
    addCase(residualBlock{log2Size: log2, cIdx: 1}, pps{}, sparse(n, false))
  }
  // Empty-DC-sub-block boundary: nonzero only far from the DC sub-block.
  for _, b := range []residualBlock{{log2Size: 3}, {log2Size: 4}, {log2Size: 5}} {
    n := 1 << b.log2Size
    coef := make([]int32, n*n)
    coef[(n/2+1)*n+n/2+1] = 3
    coef[(n/2+2)*n+n/2+2] = -2
    addCase(b, pps{}, coef)
  }
  // Sign data hiding: coefficients pre-adjusted to the inferred parity.
  for _, b := range []residualBlock{
    {log2Size: 2}, {log2Size: 3, cIdx: 1, predModeIntra: 22, intra: true},
    {log2Size: 4, predModeIntra: 6, intra: true},
  } {
    n := 1 << b.log2Size
    coef := make([]int32, n*n)
    for i := range coef {
      if i%3 == 0 {
        coef[i] = int32(i%5 + 1)
        if i&1 != 0 { coef[i] = -coef[i] }
      }
    }
    hideSigns(coef, n, b.predModeIntra, b.cIdx)
    addCase(b, pps{signDataHidingEnabled: true}, coef)
  }

  out["cases"] = cases

  data, err := json.Marshal(out)
  if err != nil { t.Fatal(err) }
  path := os.Getenv("RESIDUAL_GOLDEN_OUT")
  if path == "" { path = "/workspace/tools/residual_golden.json" }
  if err := os.WriteFile(path, data, 0644); err != nil { t.Fatal(err) }
  t.Logf("wrote %d bytes to %s: %d scan_index, %d lastctx, %d sigctx, %d sigset, %d cases",
    len(data), path, len(sis), len(lscs), len(scc), len(sbSet), len(cases))
}
