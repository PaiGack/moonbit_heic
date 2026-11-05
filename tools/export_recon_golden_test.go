package hevc

import (
  "encoding/json"
  "fmt"
  "math/rand/v2"
  "os"
  "testing"
)

func TestExportGolden(t *testing.T) {
  out := map[string]any{}

  type DQCase struct {
    BitDepth, N, QP int
    Coef []int32
    M []int32
    Want []int32
  }
  dq := []DQCase{}
  dr := rand.New(rand.NewPCG(7, 8))
  for _, n := range []int{4, 8, 16, 32} {
    for _, qp := range []int{0, 1, 5, 6, 12, 25, 30, 43, 51} {
      coef := make([]int32, n*n)
      m := make([]uint8, n*n)
      for i := range coef {
        coef[i] = int32(dr.IntN(1<<17) - 1<<16)
        m[i] = uint8(1 + dr.IntN(255))
      }
      want := append([]int32(nil), coef...)
      dequant(want, m, n, qp, 8, false)
      mi := make([]int32, n*n)
      for i := range mi { mi[i] = int32(m[i]) }
      dq = append(dq, DQCase{8, n, qp, coef, mi, want})
      want2 := append([]int32(nil), coef...)
      dequant(want2, nil, n, qp, 8, false)
      dq = append(dq, DQCase{8, n, qp, coef, nil, want2})
    }
  }
  out["dequant"] = dq

  type ITCase struct {
    BitDepth, N int
    Dst bool
    Coef []int32
    Want []int32
  }
  it := []ITCase{}
  ir := rand.New(rand.NewPCG(5, 6))
  var s transformScratch
  for _, n := range []int{4, 8, 16, 32} {
    for _, dst := range []bool{false, true} {
      if dst && n != 4 { continue }
      for rep := 0; rep < 3; rep++ {
        coef := make([]int32, n*n)
        for i := range coef { coef[i] = int32(ir.IntN(1<<16) - 1<<15) }
        want := append([]int32(nil), coef...)
        inverseTransform(want, n, dst, 8, false, &s)
        it = append(it, ITCase{8, n, dst, coef, want})
      }
    }
  }
  out["inverse_transform"] = it

  type IPCase struct {
    N, CIdx, Mode int
    Ref []int32
    Want []int32
  }
  ip := []IPCase{}
  pr := rand.New(rand.NewPCG(6, 6))
  for _, n := range []int{4, 8, 16, 32} {
    for _, cIdx := range []int{0, 1} {
      for mode := 0; mode <= 34; mode++ {
        for rep := 0; rep < 2; rep++ {
          r := newRef(n, func(int) int32 { return int32(pr.IntN(256)) })
          ref := append([]int32(nil), r.s[:4*n+1]...)
          dst := make([]uint8, n*n)
          intraPredict(dst, 0, n, r, mode, cIdx, 8)
          w := make([]int32, n*n)
          for i := range w { w[i] = int32(dst[i]) }
          ip = append(ip, IPCase{n, cIdx, mode, ref, w})
        }
      }
    }
  }
  out["intra_predict"] = ip

  // refSamples.substitute + filterRef outputs, checked directly
  type RefCase struct {
    N, Mode, CIdx int
    Strong, Disabled bool
    Avail []bool
    Ref []int32
    Want []int32
  }
  rc := []RefCase{}
  rr := rand.New(rand.NewPCG(9, 9))
  for _, n := range []int{4, 8, 16, 32} {
    for _, mode := range []int{0, 1, 10, 18, 26, 34} {
      for _, strong := range []bool{false, true} {
        r := newRef(n, func(int) int32 { return int32(rr.IntN(256)) })
        avail := make([]bool, 4*n+1)
        for i := range avail { avail[i] = rr.IntN(2) == 0 }
        r.substitute(avail, 8)
        sp := &sps{chromaFormatIDC: 1, strongIntraSmoothing: strong}
        orig := append([]int32(nil), r.s[:4*n+1]...)
        filterRef(r, mode, 0, 8, sp)
        want := append([]int32(nil), r.s[:4*n+1]...)
        rc = append(rc, RefCase{n, mode, 0, strong, false, avail, orig, want})
      }
    }
  }
  out["ref_filter"] = rc

  cq := []int32{}
  for q := 0; q <= 63; q++ { cq = append(cq, chromaQP(int32(q), 1)) }
  out["chroma_qp"] = cq

  b, _ := json.Marshal(out)
  if err := os.WriteFile("/tmp/recon_golden.json", b, 0644); err != nil { t.Fatal(err) }
  fmt.Printf("wrote golden: %d dequant, %d it, %d ip, %d ref cases\n", len(dq), len(it), len(ip), len(rc))
}
