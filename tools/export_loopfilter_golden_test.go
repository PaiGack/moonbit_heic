// To regenerate tools/loopfilter_golden.json, copy this file into a checkout of
// github.com/gen2brain/h265 at hevc/export_loopfilter_golden_test.go, then run:
//
//   go test -tags noasm ./hevc/ -run TestExportLoopFilterGolden -count=1 -v
//
// with LOOPFILTER_GOLDEN_OUT pointing at the JSON file to write. It is the
// first link of the M3 loop-filter trust chain: the REAL upstream Go
// implementation (deblock.go deblock() 8.7.2 and sao.go applySAO() 8.7.3) is
// driven on controlled single-CTB pictures, and every output plane plus the
// pure derivation tables (betaTc, boundaryStrength, luma plan/apply, chroma,
// SAO band/edge) is emitted verbatim. tools/crosscheck_loopfilter.mjs holds
// the JSON against an independent from-the-spec JS transcription, and
// tools/gen_loopfilter_golden.mjs bakes the verified data into
// hevc/loopfilter/golden.mbt. CI needs no Go toolchain.
//
// -tags noasm is essential: it forces the pure-Go deblockLumaApply path so the
// emitted truth is the readable spec implementation, not an assembly kernel.

package hevc

import (
  "encoding/json"
  "math/rand/v2"
  "os"
  "testing"
)

// mkSPS builds the smallest Main 8-bit 4:2:0 sps the loop filters read.
func mkSPS(w, h int, ctbLog2 uint8) *sps {
  ctb := 1 << ctbLog2
  return &sps{
    chromaFormatIDC: 1, separateColourPlane: false,
    subWidthC: 2, subHeightC: 2,
    picWidthInLumaSamples: uint32(w), picHeightInLumaSamples: uint32(h),
    bitDepthLuma: 8, bitDepthChroma: 8,
    ctbLog2SizeY: ctbLog2, ctbSizeY: uint32(ctb),
    minTbLog2SizeY: 2, maxTbLog2SizeY: 5,
    picWidthInCtbs: uint32((w + ctb - 1) / ctb),
    picHeightInCtbs: uint32((h + ctb - 1) / ctb),
  }
}

func mkPPS(betaOff, tcOff int32) *pps {
  return &pps{
    cbQPOffset: 0, crQPOffset: 0,
    loopFilterAcrossTiles: true, loopFilterAcrossSlices: true,
    betaOffsetDiv2: betaOff, tcOffsetDiv2: tcOff,
    colWidthsInCtbs: []uint32{1}, rowHeightsInCtbs: []uint32{1},
  }
}

func mkSH(qpY int32, betaOff, tcOff int32, saoOn bool, deblockOff bool) *sliceHeader {
  return &sliceHeader{
    qpY: qpY, cbQPOffset: 0, crQPOffset: 0,
    saoLuma: saoOn, saoChroma: saoOn,
    deblockingDisabled: deblockOff,
    betaOffsetDiv2: betaOff, tcOffsetDiv2: tcOff,
    loopFilterAcross: true,
  }
}


func clip3i(v, lo, hi int32) int32 {
  if v < lo { return lo }
  if v > hi { return hi }
  return v
}

// mkPicture allocates a fresh 8-bit 4:2:0 picture with the given samples.
func mkPicture(s *sps, y, cb, cr []uint8) *Picture {
  return &Picture{
    Width: int(s.picWidthInLumaSamples), Height: int(s.picHeightInLumaSamples),
    BitDepth: 8, BitDepthC: 8, ChromaFormat: 1,
    StrideY: int(s.picWidthInLumaSamples),
    StrideC: int(s.picWidthInLumaSamples) / s.subWidthC,
    WidthC: int(s.picWidthInLumaSamples) / s.subWidthC,
    HeightC: int(s.picHeightInLumaSamples) / s.subHeightC,
    Y: y, Cb: cb, Cr: cr,
  }
}

// mkDecoder builds a ctuDecoder with single-slice / single-tile geometry.
// qpMap and noFilter are supplied per min-TB.
func mkDecoder(s *sps, p *pps, sh *sliceHeader, pic *Picture,
  qpMap []int8, noFilter []bool) *ctuDecoder {
  d := newCTUDecoder(nil, s, p, sh, pic)
  d.threads = 1
  for i := range d.qpY {
    if i < len(qpMap) { d.qpY[i] = qpMap[i] }
  }
  for i := range d.noFilter {
    if i < len(noFilter) { d.noFilter[i] = noFilter[i] }
  }
  ctbs := int(s.picWidthInCtbs) * int(s.picHeightInCtbs)
  for i := 0; i < ctbs; i++ {
    d.ctbSlice[i] = 0
    d.ctbSliceAddr[i] = 0
    d.sliceLF[i] = true
  }
  d.slices = []*sliceHeader{sh}
  // Model one 8x8 transform/prediction unit per cell: markTU/markPU set the
  // tuV/puV (left) and tuH/puH (top) flags only on a unit's first 4x4 block
  // column/row, so every 8-sample grid line becomes a real 8.7.2 edge. All
  // units are intra (BS=2) and carry cbf, matching an I-frame CTU.
  for ty := 0; ty < int(s.picHeightInLumaSamples); ty += 8 {
    for tx := 0; tx < int(s.picWidthInLumaSamples); tx += 8 {
      d.markTU(tx, ty, 8, 8, true)
      d.markPU(tx, ty, 8, 8, true)
    }
  }
  return d
}

func TestExportLoopFilterGolden(t *testing.T) {
  r := rand.New(rand.NewPCG(0x1f2e3d4c, 0x5a6b7c8d))
  out := map[string]any{}

  // ---- pure derivation table: betaTc over full qp/bs/offset range ----
  type BTC struct{ QP, BS, BetaOff, TcOff, Beta, Tc int32 }
  btcs := []BTC{}
  sh0 := mkSH(26, 0, 0, false, false)
  for qp := -5; qp <= 60; qp += 1 {
    for _, bs := range []int{1, 2} {
      for _, bo := range []int32{-6, 0, 6} {
        for _, to := range []int32{-6, 0, 6} {
          sh := mkSH(int32(qp), bo, to, false, false)
          beta, tc := betaTc(int32(qp), bs, sh, 8)
          btcs = append(btcs, BTC{int32(qp), int32(bs), bo, to, beta, tc})
        }
      }
    }
  }
  _ = sh0
  out["beta_tc"] = btcs

  // ---- pure derivation: luma plan + apply over random 8x8 strips ----
  // We expose deblockLumaPlan / deblockLumaApply results as (input 8x8,
  // qp-derived beta/tc, noP/noQ) -> (output 8x4 filtered).
  type LumaCase struct {
    Beta, Tc, BitDepth int32
    NoP, NoQ bool
    In []int32 // 4 lines x 8 samples (indices -4..3)
    PlanMode int32
    NDp, NDq int32
    Out []int32 // 4 lines x 8 samples
  }
  lumaCases := []LumaCase{}
  for c := 0; c < 40; c++ {
    qp := int32(r.IntN(56))
    bs := 1 + r.IntN(2)
    sh := mkSH(qp, 0, 0, false, false)
    beta, tc := betaTc(qp, bs, sh, 8)
    if beta == 0 || tc == 0 { continue }
    noP := r.IntN(4) == 0
    noQ := r.IntN(4) == 0
    // build a 4x8 int32 strip with values 0..255
    strip := make([]int32, 4*8)
    for i := range strip { strip[i] = int32(r.IntN(256)) }
    // deblockLumaPlan reads at(l,-3..0..3) mapping to strip columns 1..7
    // base layout: plane[l*8 + (i+4)] where i in -4..3
    plane := make([]uint8, 4*8)
    for l := 0; l < 4; l++ {
      for i := 0; i < 8; i++ { plane[l*8+i] = uint8(strip[l*8+i]) }
    }
    line, step := 8, 1
    // base for i=-4..3 with plane[l*8+j]: base+l*line + (i)*step, i+4=j
    // base = 4 makes at(l,i)=plane[l*8 + (i+4)], i in -4..3 -> col 0..7
    // deblockLumaPlan at(l,i) = plane[base+l*line+i*step]; i=-3 => col1
    // offset i by +4: represent plane index p = i+4, so i = p-4
    // We'll pass a plane of 4x8 and base such that at(l,i)=plane[l*8+i+4].
    base := 4
    at := func(l, i int) int32 {
      // emulate: plane[base + l*line + i*step], here i physically = i+4
      return int32(plane[l*8+i+4])
    }
    _ = at
    pl := deblockLumaPlan(plane, base, line, step, beta, tc)
    // apply to a copy
    dst := make([]uint8, 4*8)
    copy(dst, plane)
    deblockLumaApply(dst, base, line, step, pl, 8, noP, noQ)
    outStrip := make([]int32, 4*8)
    for l := 0; l < 4; l++ {
      for i := 0; i < 8; i++ { outStrip[l*8+i] = int32(dst[l*8+i]) }
    }
    lumaCases = append(lumaCases, LumaCase{
      beta, tc, 8, noP, noQ, strip, int32(pl.mode), int32(pl.nDp), int32(pl.nDq), outStrip,
    })
  }
  out["luma"] = lumaCases

  // ---- pure derivation: chromaLine over random 4-sample strips ----
  type ChromaCase struct {
    Tc, MaxV int32
    NoP, NoQ bool
    In []int32 // p1,p0,q0,q1
    Out []int32
  }
  chromaCases := []ChromaCase{}
  for c := 0; c < 30; c++ {
    tc := int32(1 + r.IntN(12))
    noP := r.IntN(4) == 0
    noQ := r.IntN(4) == 0
    vals := []int32{int32(r.IntN(256)), int32(r.IntN(256)),
      int32(r.IntN(256)), int32(r.IntN(256))}
    // physical plane: off-2, off-1, off, off+1 -> vals[0..3]
    plane := []uint8{uint8(vals[0]), uint8(vals[1]), uint8(vals[2]), uint8(vals[3])}
    // chromaLine(plane, off, step, ...) with off=2, step=1:
    // p0=plane[1], p1=plane[0], q0=plane[2], q1=plane[3]
    chromaLine(plane, 2, 1, tc, 255, noP, noQ)
    outVals := []int32{int32(plane[0]), int32(plane[1]), int32(plane[2]), int32(plane[3])}
    chromaCases = append(chromaCases, ChromaCase{tc, 255, noP, noQ, vals, outVals})
  }
  out["chroma"] = chromaCases

  // ---- pure derivation: SAO band/edge row + sample ----
  type SaoBandCase struct {
    Band, Shift, MaxV int32
    Offset [4]int32
    Src []int32
    Dst []int32
  }
  bandCases := []SaoBandCase{}
  for c := 0; c < 30; c++ {
    band := int32(r.IntN(32))
    var off [4]int32
    for i := range off { off[i] = int32(r.IntN(15) - 7) }
    n := 1 + r.IntN(16)
    src := make([]int32, n)
    for i := range src { src[i] = int32(r.IntN(256)) }
    srcU := make([]uint8, n)
    for i := range src { srcU[i] = uint8(src[i]) }
    dstU := make([]uint8, n)
    copy(dstU, srcU)
    saoBandRow(dstU, srcU, n, int(band), &off, 3, 255)
    dst := make([]int32, n)
    for i := range dst { dst[i] = int32(dstU[i]) }
    bandCases = append(bandCases, SaoBandCase{band, 3, 255, off, src, dst})
  }
  out["sao_band"] = bandCases

  type SaoEdgeCase struct {
    MaxV int32
    Offset [4]int32
    Src, Na, Nb []int32
    Dst []int32
  }
  edgeCases := []SaoEdgeCase{}
  for c := 0; c < 30; c++ {
    var off [4]int32
    for i := range off { off[i] = int32(r.IntN(15) - 7) }
    n := 1 + r.IntN(16)
    src := make([]int32, n); na := make([]int32, n); nb := make([]int32, n)
    for i := range src { src[i] = int32(r.IntN(256)); na[i] = int32(r.IntN(256)); nb[i] = int32(r.IntN(256)) }
    srcU := make([]uint8, n); naU := make([]uint8, n); nbU := make([]uint8, n)
    for i := range src { srcU[i] = uint8(src[i]); naU[i] = uint8(na[i]); nbU[i] = uint8(nb[i]) }
    dstU := make([]uint8, n); copy(dstU, srcU)
    saoEdgeRow(dstU, srcU, naU, nbU, n, &off, 255)
    dst := make([]int32, n)
    for i := range dst { dst[i] = int32(dstU[i]) }
    edgeCases = append(edgeCases, SaoEdgeCase{255, off, src, na, nb, dst})
  }
  out["sao_edge"] = edgeCases

  // ---- end-to-end whole-picture deblock + SAO ----
  // 2 scenarios: 64x64 (1 CTB) and 128x128 (2x2 CTBs), various qp / sao.
  type FrameCase struct {
    Label string
    W, H, CtbLog2 int
    QpY, BetaOff, TcOff int32
    DeblockOff, SaoOn bool
    SaoType int // 0 off, 1 band, 2 edge
    SaoClass int
    SaoBand int
    SaoOffset [4]int32
    QpField []int8
    NoFilter []bool
    Y, Cb, Cr []uint8 // input
    DebY, DebCb, DebCr []uint8 // after deblock
    SaoY, SaoCb, SaoCr []uint8 // after SAO
  }
  frames := []FrameCase{}

  addFrame := func(label string, w, h int, ctbLog2 uint8, qpY int32,
    betaOff, tcOff int32, deblockOff, saoOn bool, saoType, saoClass, saoBand int,
    saoOff [4]int32) {
    s := mkSPS(w, h, ctbLog2)
    p := mkPPS(betaOff, tcOff)
    sh := mkSH(qpY, betaOff, tcOff, saoOn, deblockOff)
    ny := w * h
    nc := (w / 2) * (h / 2)
    yIn := make([]uint8, ny); cbIn := make([]uint8, nc); crIn := make([]uint8, nc)
    // "smooth" frames use near-flat 8x8 blocks with a small step across each
    // grid edge, so deblocking's dp+dq < beta test actually fires on luma;
    // "noise" frames (sao edge / 2ctb) keep full random samples so SAO's
    // edge categories are exercised over a wide value spread.
    smooth := !saoOn || saoType == 1
    if smooth {
      for yy := 0; yy < h; yy++ {
        for xx := 0; xx < w; xx++ {
          base := 100 + ((xx/8)*7 + (yy/8)*11)%40
          yIn[yy*w+xx] = uint8(clip3i(int32(base)+int32(r.IntN(5)-2), 0, 255))
        }
      }
      for yy := 0; yy < h/2; yy++ {
        for xx := 0; xx < w/2; xx++ {
          base := 110 + ((xx/4)*5 + (yy/4)*9)%30
          cbIn[yy*(w/2)+xx] = uint8(clip3i(int32(base)+int32(r.IntN(5)-2), 0, 255))
          crIn[yy*(w/2)+xx] = uint8(clip3i(int32(base)+int32(r.IntN(5)-2), 0, 255))
        }
      }
    } else {
      for i := range yIn { yIn[i] = uint8(r.IntN(256)) }
      for i := range cbIn { cbIn[i] = uint8(r.IntN(256)) }
      for i := range crIn { crIn[i] = uint8(r.IntN(256)) }
    }
    // per-min-TB qp and noFilter
    minTbW := (w + 3) / 4
    minTbH := (h + 3) / 4
    ntb := minTbW * minTbH
    qpField := make([]int8, ntb)
    noFilter := make([]bool, ntb)
    for i := range qpField {
      qpField[i] = int8(26 + (r.IntN(13) - 6))
      noFilter[i] = r.IntN(8) == 0
    }
    // snapshot input
    ySnap := append([]uint8(nil), yIn...)
    cbSnap := append([]uint8(nil), cbIn...)
    crSnap := append([]uint8(nil), crIn...)

    pic := mkPicture(s, yIn, cbIn, crIn)
    d := mkDecoder(s, p, sh, pic, qpField, noFilter)

    // ---- deblock ----
    d.deblock()
    yDeb := append([]uint8(nil), yIn...)
    cbDeb := append([]uint8(nil), cbIn...)
    crDeb := append([]uint8(nil), crIn...)

    // ---- SAO params ----
    if saoOn {
      ctbs := int(s.picWidthInCtbs) * int(s.picHeightInCtbs)
      for i := 0; i < ctbs; i++ {
        for cIdx := 0; cIdx < 3; cIdx++ {
          pr := &d.sao[i][cIdx]
          pr.typeIdx = saoType
          pr.class = saoClass
          pr.band = saoBand
          pr.offset = saoOff
        }
      }
    }
    // ---- SAO ----
    d.applySAO()
    ySao := append([]uint8(nil), yIn...)
    cbSao := append([]uint8(nil), cbIn...)
    crSao := append([]uint8(nil), crIn...)

    frames = append(frames, FrameCase{
      label, w, h, int(ctbLog2), qpY, betaOff, tcOff, deblockOff, saoOn,
      saoType, saoClass, saoBand, saoOff, qpField, noFilter,
      ySnap, cbSnap, crSnap,
      yDeb, cbDeb, crDeb,
      ySao, cbSao, crSao,
    })
  }

  addFrame("deblock_only", 64, 64, 6, 26, 0, 0, false, false, 0, 0, 0, [4]int32{})
  addFrame("deblock_beta_tc", 64, 64, 6, 40, -3, 4, false, false, 0, 0, 0, [4]int32{})
  addFrame("deblock_off", 64, 64, 6, 30, 0, 0, true, false, 0, 0, 0, [4]int32{})
  addFrame("sao_band_luma", 64, 64, 6, 26, 0, 0, false, true, 1, 0, 14,
    [4]int32{3, -2, 4, -1})
  addFrame("sao_edge_luma", 64, 64, 6, 26, 0, 0, false, true, 2, 1, 0,
    [4]int32{2, 3, -2, -3})
  addFrame("sao_band_chroma", 64, 64, 6, 26, 0, 0, false, true, 1, 2, 12,
    [4]int32{-4, 2, -3, 5})
  addFrame("both_2ctb", 128, 128, 6, 33, 2, -2, false, true, 2, 0, 0,
    [4]int32{1, -1, 2, -2})

  out["frames"] = frames

  b, err := json.Marshal(out)
  if err != nil { t.Fatal(err) }
  path := os.Getenv("LOOPFILTER_GOLDEN_OUT")
  if path == "" { path = "loopfilter_golden.json" }
  if err := os.WriteFile(path, b, 0644); err != nil { t.Fatal(err) }
  t.Logf("wrote %s (%d bytes): %d betaTc, %d luma, %d chroma, %d sao_band, %d sao_edge, %d frames",
    path, len(b), len(btcs), len(lumaCases), len(chromaCases), len(bandCases), len(edgeCases), len(frames))
}
