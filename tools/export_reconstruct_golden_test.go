// To regenerate tools/reconstruct_golden.json, copy this file into a checkout
// of github.com/gen2brain/h265 at hevc/export_reconstruct_golden_test.go, then
// run:
//
//   RECONSTRUCT_GOLDEN_OUT=/abs/path/to/monbit_tmp/tools/reconstruct_golden.json \
//     go test -tags noasm ./hevc/ -run TestExportReconstructGolden -count=1 -v
//
// It is the FIRST link of the M3 "geometry + single-block reconstruction"
// trust chain. It drives the REAL upstream Go implementation:
//
//   - buildMinTbAddr (6.5.2)   -> whole minTbAddr[] table
//   - available      (6.4.1)    -> z-scan neighbour availability, full sweep
//   - predictQP      (8.6.1)    -> qPY_PRED
//   - gatherRef      (8.4.4.2.2)-> ref.s[] (after substitute) + avail[]
//   - reconstructPlane (8.6.x)  -> real pixels, from real cabacWriter/
//     encodeResidual CABAC bitstreams through dequant -> inverseTransform ->
//     intraPredict -> addResidual
//
// tools/crosscheck_reconstruct.mjs holds the JSON against an independent
// from-the-spec JS transcription; tools/gen_reconstruct_golden.mjs bakes the
// verified data into hevc/{geometry,reconstruct}/golden.mbt. CI needs no Go.
//
// -tags noasm forces the readable pure-Go dsp path, so the emitted truth is
// the spec implementation, not an assembly kernel.

package hevc

import (
  "encoding/json"
  "math/rand/v2"
  "os"
  "testing"
)

type rgSpec struct{ log2, mode, cIdx, qp int }

func rgSPS(w, h int, ctbLog2 uint8, minTbLog2 int) *sps {
  ctb := 1 << ctbLog2
  return &sps{
    chromaFormatIDC: 1, subWidthC: 2, subHeightC: 2,
    picWidthInLumaSamples: uint32(w), picHeightInLumaSamples: uint32(h),
    bitDepthLuma: 8, bitDepthChroma: 8,
    ctbLog2SizeY: ctbLog2, ctbSizeY: uint32(ctb),
    minTbLog2SizeY: uint8(minTbLog2), maxTbLog2SizeY: 5,
    minCbLog2SizeY: 3,
    picWidthInCtbs: uint32((w + ctb - 1) / ctb),
    picHeightInCtbs: uint32((h + ctb - 1) / ctb),
  }
}
func rgPPS(wc, hc int) *pps {
  return &pps{
    loopFilterAcrossTiles: true, loopFilterAcrossSlices: true,
    colWidthsInCtbs: []uint32{uint32(wc)}, rowHeightsInCtbs: []uint32{uint32(hc)},
  }
}
func rgSH(qpY int32) *sliceHeader {
  return &sliceHeader{ qpY: qpY, sliceType: sliceI, loopFilterAcross: true }
}
func rgPic(w, h int, y []uint8) *Picture {
  return &Picture{
    Width: w, Height: h, BitDepth: 8, BitDepthC: 8, ChromaFormat: 1,
    StrideY: w, StrideC: w / 2, WidthC: w / 2, HeightC: h / 2,
    Y: y, Cb: make([]uint8, w/2*h/2), Cr: make([]uint8, w/2*h/2),
  }
}
func rgDecoder(s *sps, p *pps, sh *sliceHeader, pic *Picture) *ctuDecoder {
  d := newCTUDecoder(nil, s, p, sh, pic)
  d.threads = 1
  d.simpleAvail = true
  d.sliceAddrRs = 0
  return d
}

func TestExportReconstructGolden(t *testing.T) {
  out := map[string]any{}

  // ---- 6.5.2 minTbAddr: full table for several geometries ----
  type MTACase struct {
    CtbsW, CtbsH, CtbLog2, MinTbLog2 int
    Addr []int32
  }
  mtas := []MTACase{}
  for _, ctbLog2 := range []int{4, 5, 6} {
    for _, minTbLog2 := range []int{2, 3} {
      for _, cw := range []int{1, 2, 3} {
        for _, ch := range []int{1, 2} {
          ctb := 1 << ctbLog2
          s := rgSPS(ctb*cw, ctb*ch, uint8(ctbLog2), minTbLog2)
          p := rgPPS(cw, ch)
          pic := rgPic(ctb*cw, ctb*ch, make([]uint8, ctb*cw*ctb*ch))
          d := rgDecoder(s, p, rgSH(26), pic)
          addr := append([]int32(nil), d.minTbAddr...)
          mtas = append(mtas, MTACase{cw, ch, ctbLog2, minTbLog2, addr})
        }
      }
    }
  }
  out["min_tb_addr"] = mtas

  // ---- 6.4.1 available: full sweep for a 2x2-CTB, 64x64 picture ----
  // ctbLog2=6 (one CTB), minTbLog2=2. Enumerate every (xCurr,yCurr) and the
  // 8 surrounding + self + far neighbours at min-TB granularity (step 4).
  type AvailCase struct {
    XCurr, YCurr, XN, YN int
    Want bool
  }
  avails := []AvailCase{}
  {
    w, h := 64, 64
    s := rgSPS(w, h, 6, 2)
    p := rgPPS(1, 1)
    pic := rgPic(w, h, make([]uint8, w*h))
    d := rgDecoder(s, p, rgSH(26), pic)
    for yc := 0; yc < h; yc += 4 {
      for xc := 0; xc < w; xc += 4 {
        for _, dy := range []int{-8, -4, 0, 4, 8} {
          for _, dx := range []int{-8, -4, 0, 4, 8} {
            xn, yn := xc+dx, yc+dy
            avails = append(avails, AvailCase{xc, yc, xn, yn,
              d.available(xc, yc, xn, yn)})
          }
        }
      }
    }
  }
  out["available"] = avails

  // ---- 8.6.1 predictQP: qPY_PRED over several QP neighbourhoods ----
  // qpYPrev is the fallback; qpY[...] of available left/above min TBs feed in.
  type QPCase struct {
    QpPrev, QpA, QpB int32
    LeftAvail, TopAvail bool
    Want int32
  }
  qps := []QPCase{}
  {
    w, h := 64, 64
    for _, qpPrev := range []int32{0, 12, 26, 40, 51} {
      for _, qpA := range []int32{5, 26, 48} {
        for _, qpB := range []int32{9, 33, 50} {
          s := rgSPS(w, h, 6, 2)
          p := rgPPS(1, 1)
          pic := rgPic(w, h, make([]uint8, w*h))
          d := rgDecoder(s, p, rgSH(qpPrev), pic)
          d.qpYPrev = qpPrev
          // Predict at (8,8): left min TB at (4,8), above min TB at (8,4).
          // available() uses z-scan (MinTbAddr) which is already built; to
          // make left/above genuinely available we set their qpY and keep the
          // z-order property by construction (both precede (8,8) in z-scan).
          d.qpY[d.tbIndex(4, 8)] = int8(qpA)
          d.qpY[d.tbIndex(8, 4)] = int8(qpB)
          want := d.predictQP(8, 8)
          qps = append(qps, QPCase{qpPrev, qpA, qpB, true, true, want})
        }
      }
    }
  }
  out["predict_qp"] = qps

  // ---- 8.4.4.2.2 gatherRef: ref.s[] after substitute + avail[] ----
  type RefCase struct {
    X, Y, N, CIdx int
    Plane []uint8
    CPlane []uint8
    Ref []int32
    Avail []bool
  }
  refs := []RefCase{}
  {
    w, h := 64, 64
    r := rand.New(rand.NewPCG(0x9E3779B9, 0x243F6A88))
    y := make([]uint8, w*h)
    cb := make([]uint8, w/2*h/2)
    for i := range y { y[i] = uint8(r.IntN(256)) }
    for i := range cb { cb[i] = uint8(r.IntN(256)) }
    type gspec struct{ x,y,n,cIdx int }
    specs := []gspec{
      {8,8,4,0},{8,8,8,0},{16,16,16,0},{8,8,32,0},
      {0,8,8,0},{8,0,8,0},{0,0,4,0},           // picture edges / corner
      {4,4,4,1},{8,8,8,1},                      // chroma (sub 2x2)
    }
    for _, sp := range specs {
      s := rgSPS(w, h, 6, 2)
      p := rgPPS(1, 1)
      pic := rgPic(w, h, y)
      pic.Cb = cb; pic.Cr = cb
      d := rgDecoder(s, p, rgSH(26), pic)
      var plane []uint8
      var stride int
      if sp.cIdx == 0 { plane, stride = y, w } else { plane, stride = cb, w/2 }
      gatherRef(d, plane, stride, sp.x, sp.y, sp.n, sp.cIdx)
      ref := append([]int32(nil), d.ref.s[:4*sp.n+1]...)
      av := append([]bool(nil), d.avail[:4*sp.n+1]...)
      yCopy := append([]uint8(nil), y...)
      cbCopy := append([]uint8(nil), cb...)
      refs = append(refs, RefCase{sp.x, sp.y, sp.n, sp.cIdx, yCopy, cbCopy, ref, av})
    }
  }
  out["gather_ref"] = refs

  // ---- 8.6.x reconstructPlane: real CABAC bitstream -> real pixels ----
  // For each case we encode a residual block with the upstream encoder, run
  // reconstructPlane on a fresh picture, and emit the whole working plane
  // (Y or Cb) plus the prediction-only plane (cbf=false) for layer checks.
  type ReconCase struct {
    Log2, Mode, CIdx, QP int
    X, Y, Stride int
    Coef []int32
    Bytes []byte
    PlaneIn []uint8
    PredPlane []uint8
    PlaneOut []uint8
  }
  recons := []ReconCase{}
  {
    w, h := 64, 64
    r := rand.New(rand.NewPCG(0x1234567, 0x89ABCDEF))
    specs := []rgSpec{
      {2,0,0,26},{2,1,0,26},{2,10,0,30},{2,26,0,20},{2,18,0,26},
      {3,0,0,26},{3,1,0,40},{3,10,0,26},{3,26,0,26},{3,34,0,15},
      {4,0,0,26},{4,6,0,26},{4,22,0,51},{4,26,0,26},
      {2,0,1,26},{3,1,1,30},{3,26,1,26},
    }
    for _, sp := range specs {
      n := 1 << sp.log2
      coef := make([]int32, n*n)
      for i := range coef {
        if r.IntN(6) == 0 {
          lvl := int32(1 + r.IntN(12))
          if r.IntN(9) == 0 { lvl = int32(100 + r.IntN(20000)) }
          if r.IntN(2) != 0 { lvl = -lvl }
          coef[i] = lvl
        }
      }
      coef[r.IntN(len(coef))] = int32(1 + r.IntN(3))

      s := rgSPS(w, h, 6, 2)
      p := rgPPS(1, 1)
      var bits putBits
      var cw cabacWriter
      cw.init(&bits, int32(sp.qp), sliceI, false)
      b := residualBlock{log2Size: sp.log2, cIdx: sp.cIdx,
        predModeIntra: sp.mode, intra: true}
      if err := encodeResidual(&cw, s, p, coef, b); err != nil { t.Fatal(err) }
      cw.encodeTerminate(1)
      stream := append([]byte(nil), cw.bytes()...)

      // Working plane: luma is w*h, chroma is (w/2)*(h/2). Stride matches.
      var stride, plen int
      if sp.cIdx == 0 { stride, plen = w, w*h } else { stride, plen = w/2, (w/2)*(h/2) }
      base := make([]uint8, plen)
      for i := range base { base[i] = uint8((i*37 + 11) & 255) }
      x, y0 := 8, 8 // interior block, both left/above neighbours exist

      // prediction-only (cbf=false): no CABAC consumed
      predPlane := rgRecon(w, h, sp, x, y0, base, stream, false)
      // full reconstruction (cbf=true) from the real bitstream
      outPlane := rgRecon(w, h, sp, x, y0, base, stream, true)

      recons = append(recons, ReconCase{sp.log2, sp.mode, sp.cIdx, sp.qp,
        x, y0, stride, coef, stream, base, predPlane, outPlane})
    }
  }
  out["recon"] = recons

  data, err := json.Marshal(out)
  if err != nil { t.Fatal(err) }
  path := os.Getenv("RECONSTRUCT_GOLDEN_OUT")
  if path == "" { path = "/workspace/tools/reconstruct_golden.json" }
  if err := os.WriteFile(path, data, 0644); err != nil { t.Fatal(err) }
  t.Logf("wrote %d bytes to %s: %d mta, %d avail, %d qp, %d ref, %d recon",
    len(data), path, len(mtas), len(avails), len(qps), len(refs), len(recons))
}

// rgRecon runs reconstructPlane on a fresh copy of base and returns the plane.
func rgRecon(w, h int, sp rgSpec, x, y0 int, base, stream []uint8, cbf bool) []uint8 {
  plane := append([]uint8(nil), base...)
  s := rgSPS(w, h, 6, 2)
  p := rgPPS(1, 1)
  sh := rgSH(int32(sp.qp))
  var stride int
  if sp.cIdx == 0 { stride = w } else { stride = w / 2 }
  pic := rgPic(w, h, plane)
  if sp.cIdx == 1 { pic.Cb = plane; pic.Cr = plane }
  d := rgDecoder(s, p, sh, pic)
  d.curIntra = true
  d.qpYCur = int32(sp.qp)
  d.qpYPrev = int32(sp.qp)
  if cbf {
    if err := d.c.init(stream, 0); err != nil { panic(err) }
    d.c.initContexts(int32(sp.qp), sliceI, false)
  }
  _ = reconstructPlane(d, plane, stride, x, y0, sp.log2, sp.cIdx, sp.mode, cbf)
  return plane
}
