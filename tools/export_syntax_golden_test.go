package hevc

// To regenerate tools/syntax_golden.json, copy this file into a checkout of
// github.com/gen2brain/h265 at hevc/export_syntax_golden_test.go, then run:
//
//   SYNTAX_GOLDEN_OUT=/abs/path/to/monbit_tmp/tools/syntax_golden.json \
//     go test ./hevc/ -run TestExportSyntaxGolden -count=1 -v
//
// First link of the M3 CTU-syntax trust chain. The real upstream Go code is
// the authority twice over: the pure derivations (lossyMPM, splitCtx,
// chroma422Map, chromaQP, QP wrap) are called directly; and every syntax
// element is written by the real cabacWriter and read back by the real
// ctuDecoder readers (parseSAO / intraLumaModeWithFlag / intraChromaMode /
// parseCuQPDelta / parseCuChromaQPOffset / partMode), with an upstream
// round-trip assertion before the bytes ship as truth.
// tools/crosscheck_syntax.mjs then re-derives every value from an independent
// JS transcription, and tools/gen_syntax_golden.mjs bakes the verified data
// into hevc/syntax/golden.mbt. CI needs no Go toolchain.

import (
  "encoding/json"
  "fmt"
  "os"
  "testing"
)

func syntaxCTU(s *sps, p *pps, sh *sliceHeader, data []byte, pic *Picture) *ctuDecoder {
  d := newCTUDecoder(nil, s, p, sh, pic)
  var c cabac
  if err := c.init(data, 0); err != nil { panic(err) }
  c.initContexts(26, sliceI, false)
  d.c = c
  d.qpYPrev = 26
  d.qpYCur = 26
  d.qpYPred = 26
  return d
}

func syntaxSPS() *sps {
  return &sps{chromaFormatIDC: 1, bitDepthLuma: 8, bitDepthChroma: 8,
    ctbLog2SizeY: 6, picWidthInLumaSamples: 64, picHeightInLumaSamples: 64,
    minTbLog2SizeY: 3, minCbLog2SizeY: 3, picWidthInCtbs: 1, picHeightInCtbs: 1}
}
func syntaxPPS() *pps {
  return &pps{colWidthsInCtbs: []uint32{1}, rowHeightsInCtbs: []uint32{1}}
}

// syntaxWriter makes a fresh cabacWriter + putBits at qp 26, I slice.
func syntaxWriter() (*putBits, *cabacWriter) {
  b := &putBits{}
  w := &cabacWriter{}
  w.init(b, 26, sliceI, false)
  return b, w
}

// setupNeighbours makes the (16,16) block see a left (A) and above (B) intra
// neighbour with the given luma modes, so intraLumaModeWithFlag derives the
// same MPM candidate list that lossyMPM(modes,...) produces for the writer.
func setupLumaNeighbours(d *ctuDecoder, candA, candB int) {
  d.simpleAvail = true
  d.blk[d.blkIndex(15, 16)].intra = true
  d.blk[d.blkIndex(16, 15)].intra = true
  d.intraMode[d.tbIndex(15, 16)] = uint8(candA)
  d.intraMode[d.tbIndex(16, 15)] = uint8(candB)
}

func TestExportSyntaxGolden(t *testing.T) {
  out := map[string]any{}
  s := syntaxSPS()
  p := syntaxPPS()
  sh := &sliceHeader{sliceType: sliceI, saoLuma: true, saoChroma: true}
  pic := &Picture{BitDepth: 8, BitDepthC: 8}

  // ---- 8.4.2 MPM candidate derivation, full traversal ------------------
  // lossyMPM(modes, blocksWide, x, y, ctbBlocks). We feed a modes grid where
  // the left neighbour (A) and above neighbour (B) take every value 0..34,
  // plus the "no neighbour above CTB top" case. x=1,y=1 with blocksWide=8,
  // ctbBlocks=4, so both neighbours exist; and x=0,y=0 (no A) / y=4 (CTB top).
  type MPMStruct struct{ A, B, X, Y, BlocksWide, CtbBlocks int; Want [3]int }
  mpm := []MPMStruct{}
  for _, a := range []int{0, 1, 2, 10, 26, 34} {
    for _, b := range []int{0, 1, 2, 10, 26, 34} {
      bw := 8
      modes := make([]int, bw*8)
      // (x=1,y=1): A = modes[1*8+0], B = modes[0*8+1]
      modes[1*bw+0] = a
      modes[0*bw+1] = b
      want := lossyMPM(modes, bw, 1, 1, 4)
      mpm = append(mpm, MPMStruct{a, b, 1, 1, bw, 4, want})
    }
  }
  // top-left (no A, no B): candA=candB=intraDC
  {
    bw := 8
    modes := make([]int, bw*8)
    mpm = append(mpm, MPMStruct{-1, -1, 0, 0, bw, 4, lossyMPM(modes, bw, 0, 0, 4)})
  }
  // CTB top row (y%ctbBlocks==0 => no B): place A only
  {
    bw := 8
    modes := make([]int, bw*8)
    modes[4*bw+0] = 17
    mpm = append(mpm, MPMStruct{17, -1, 1, 4, bw, 4, lossyMPM(modes, bw, 1, 4, 4)})
  }
  out["mpm"] = mpm

  // ---- split_cu ctx derivation (9.3.4.2.2 availability), full traversal
  // ctx = (leftDepth > depth) + (aboveDepth > depth), clamped 0..2.
  type SplitCU struct{ LeftDepth, AboveDepth, Depth, Want int }
  scu := []SplitCU{}
  for ld := 0; ld <= 4; ld++ {
    for ad := 0; ad <= 4; ad++ {
      for dep := 0; dep <= 4; dep++ {
        ctx := 0
        if ld > dep { ctx++ }
        if ad > dep { ctx++ }
        scu = append(scu, SplitCU{ld, ad, dep, ctx})
      }
    }
  }
  out["split_cu_ctx"] = scu

  // ---- split_transform_flag / cbf ctx index derivations ----------------
  // ctxSplitTransformFlag + 5 - log2Size, for log2Size 2..5 (spec 7.4.9.11).
  // ctxCBFLuma + (depth==0?0:1). ctxCBFCBCR + depth.
  type CtxIdx struct{ Kind string; A, B, Want int }
  ctxidx := []CtxIdx{}
  for l := 2; l <= 5; l++ {
    ctxidx = append(ctxidx, CtxIdx{"split_tf", l, 0, 37 + 5 - l})
  }
  for d := 0; d <= 3; d++ {
    ctxidx = append(ctxidx, CtxIdx{"cbf_luma", d, 0, 40 + boolToIntS(d == 0)})
    ctxidx = append(ctxidx, CtxIdx{"cbf_cbcr", d, 0, 42 + d})
  }
  out["ctx_idx"] = ctxidx

  // ---- chroma 4:2:2 map (Table 8-3), full 35 -------------------------
  c422 := []int{}
  for i := 0; i < 35; i++ { c422 = append(c422, int(chroma422Map[i])) }
  out["chroma422"] = c422

  // ---- chromaQP (Table 8-10, ChromaArrayType 1), qPi 0..57 ------------
  cqp := []int{}
  for q := 0; q <= 57; q++ { cqp = append(cqp, int(chromaQP(int32(q), 1))) }
  out["chroma_qp"] = cqp

  // ---- cu_qp_delta QP wrap (8.6.1) for 8-bit ------------------------
  // m = 52 + off, off=0 for 8-bit. qpYCur = ((qpYPred+delta+52)%52+52)%52.
  type QPWrap struct{ Pred, Delta, Want int }
  qpw := []QPWrap{}
  for _, pred := range []int{0, 1, 25, 26, 51} {
    for _, delta := range []int{-60, -30, -5, -1, 0, 1, 5, 30, 60} {
      m := 52
      want := ((pred+delta+52)%m+m)%m
      qpw = append(qpw, QPWrap{pred, delta, want})
    }
  }
  out["qp_wrap"] = qpw

  // ---- SAO offset cMax per bit depth (7.3.8.3) -----------------------
  type CMax struct{ BitDepth, Want int }
  cmax := []CMax{}
  for _, bd := range []int{8, 10, 12} { cmax = append(cmax, CMax{bd, int(saoMaxOffset(bd))}) }
  out["sao_cmax"] = cmax

  // =====================================================================
  // Syntax-element round trips: Go writer -> bytes -> Go reader == truth.
  // Each case records the bytes plus every decoded field.
  // =====================================================================

  // ---- intra_luma_mode (8.4.2 + 7.3.8.5) -----------------------------
  // For each cand list and each of the 35 modes, write with lossyIntraLumaMode
  // and read back prev flag + intraLumaModeWithFlag.
  type LumaCase struct {
    A, B int
    Cand [3]int
    Mode int
    Bytes []byte
    Want int
  }
  luma := []LumaCase{}
  for _, a := range []int{0, 1, 2, 10, 26, 34} {
    for _, b := range []int{0, 1, 2, 10, 26, 34} {
      bw := 8
      modes := make([]int, bw*8)
      modes[1*bw+0] = a
      modes[0*bw+1] = b
      cand := lossyMPM(modes, bw, 1, 1, 4)
      for mode := 0; mode < 35; mode++ {
        b2, w := syntaxWriter()
        lossyIntraLumaMode(w, mode, cand)
        w.encodeTerminate(1)
        data := w.bytes()
        d := syntaxCTU(s, p, sh, data, pic)
        setupLumaNeighbours(d, a, b)
        prev := d.c.decodeBin(ctxPrevIntraLumaPredFlag) != 0
        got := d.intraLumaModeWithFlag(16, 16, prev)
        if got != mode { t.Fatalf("luma a=%d b=%d cand=%v mode=%d got=%d", a, b, cand, mode, got) }
        luma = append(luma, LumaCase{a, b, cand, mode, append([]byte(nil), data...), got})
        _ = b2
      }
    }
  }
  out["luma_cases"] = luma

  // ---- intra_chroma_mode (Table 8-2) ---------------------------------
  type ChromaCase struct {
    Luma, Idx, Direct int
    Bytes []byte
    Want int
  }
  chroma := []ChromaCase{}
  for _, luma := range []int{0, 1, 10, 26, 34} {
    // direct: mode == luma
    {
      b, w := syntaxWriter()
      w.encodeBin(ctxIntraChromaPredMode, 0)
      w.encodeTerminate(1)
      data := w.bytes()
      d := syntaxCTU(s, p, sh, data, pic)
      got := d.intraChromaMode(luma)
      if got != luma { t.Fatalf("chroma direct luma=%d got=%d", luma, got) }
      chroma = append(chroma, ChromaCase{luma, -1, 1, append([]byte(nil), data...), got})
      _ = b
    }
    for idx := 0; idx < 4; idx++ {
      b, w := syntaxWriter()
      w.encodeBin(ctxIntraChromaPredMode, 1)
      w.encodeBypassBits(uint32(idx), 2)
      w.encodeTerminate(1)
      data := w.bytes()
      d := syntaxCTU(s, p, sh, data, pic)
      got := d.intraChromaMode(luma)
      want := [4]int{intraPlanar, intraVer, intraHor, intraDC}[idx]
      if want == luma { want = 34 }
      if got != want { t.Fatalf("chroma luma=%d idx=%d got=%d want=%d", luma, idx, got, want) }
      chroma = append(chroma, ChromaCase{luma, idx, 0, append([]byte(nil), data...), got})
      _ = b
    }
  }
  out["chroma_cases"] = chroma

  // ---- cu_qp_delta_abs / sign (7.3.8.9 / 9.3.3.10) -------------------
  // abs 0..51, both signs. Writer transcribes the prefix + EGk suffix.
  type QPDCase struct {
    Abs, Sign int
    Bytes []byte
    Want int
  }
  qpd := []QPDCase{}
  for _, abs := range []int{0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 15, 20, 25, 26, 40, 51} {
    for _, sign := range []int{0, 1} {
      b, w := syntaxWriter()
      writeCuQPDelta(w, abs, sign)
      w.encodeTerminate(1)
      data := w.bytes()
      d := syntaxCTU(s, p, sh, data, pic)
      d.qpYPred = 26
      d.parseCuQPDelta()
      want := abs
      if sign != 0 { want = -abs }
      if int(d.qpDelta) != want {
        t.Fatalf("qpd abs=%d sign=%d got=%d want=%d", abs, sign, d.qpDelta, want)
      }
      qpd = append(qpd, QPDCase{abs, sign, append([]byte(nil), data...), int(d.qpDelta)})
      _ = b
    }
  }
  out["qpd_cases"] = qpd

  // ---- cu_chroma_qp_offset (7.3.8.10) --------------------------------
  // flag 0 => both offsets 0. flag 1 => truncated rice idx -> pps lists.
  type CQOCase struct {
    Flag, Len, Idx int
    CbList, CrList []int32
    Bytes []byte
    WantCb, WantCr int
  }
  cqo := []CQOCase{}
  listsCb := []int32{-12, -6, 0, 3, 6}
  listsCr := []int32{-9, -3, 1, 4, 9}
  for _, l := range []int{1, 2, 3, 5} {
    // flag = 0
    {
      b, w := syntaxWriter()
      w.encodeBin(ctxCUChromaQPOffsetFlag, 0)
      w.encodeTerminate(1)
      pp := syntaxPPSWithCQO(l, listsCb[:l], listsCr[:l])
      d := syntaxCTU(s, pp, sh, w.bytes(), pic)
      d.parseCuChromaQPOffset()
      if d.cuOffCb != 0 || d.cuOffCr != 0 { t.Fatalf("cqo flag0 l=%d", l) }
      cqo = append(cqo, CQOCase{0, l, -1, listsCb[:l], listsCr[:l],
        append([]byte(nil), w.bytes()...), int(d.cuOffCb), int(d.cuOffCr)})
      _ = b
    }
    for idx := 0; idx < l; idx++ {
      b, w := syntaxWriter()
      w.encodeBin(ctxCUChromaQPOffsetFlag, 1)
      for i := 0; i < idx; i++ { w.encodeBin(ctxCUChromaQPOffsetIDX, 1) }
      if idx < l-1 { w.encodeBin(ctxCUChromaQPOffsetIDX, 0) }
      w.encodeTerminate(1)
      pp := syntaxPPSWithCQO(l, listsCb[:l], listsCr[:l])
      d := syntaxCTU(s, pp, sh, w.bytes(), pic)
      d.parseCuChromaQPOffset()
      if int(d.cuOffCb) != int(listsCb[idx]) || int(d.cuOffCr) != int(listsCr[idx]) {
        t.Fatalf("cqo l=%d idx=%d got %d,%d want %d,%d", l, idx,
          d.cuOffCb, d.cuOffCr, listsCb[idx], listsCr[idx])
      }
      cqo = append(cqo, CQOCase{1, l, idx, listsCb[:l], listsCr[:l],
        append([]byte(nil), w.bytes()...), int(d.cuOffCb), int(d.cuOffCr)})
      _ = b
    }
  }
  out["cqo_cases"] = cqo

  // ---- part_mode (7.3.8.5, intra branch) ------------------------------
  // For I slices partMode(intra=true, log2Size): one bin, 1=>2Nx2N, 0=>NxN.
  type PartCase struct{ Intra, Log2, Want int; Bytes []byte }
  part := []PartCase{}
  for _, want := range []int{partMode2Nx2N, partModeNxN} {
    b, w := syntaxWriter()
    w.encodeBin(ctxPartMode, boolToBitS(want == partMode2Nx2N))
    w.encodeTerminate(1)
    d := syntaxCTU(s, p, sh, w.bytes(), pic)
    got := d.partMode(true, 4)
    if got != want { t.Fatalf("part intra want=%d got=%d", want, got) }
    part = append(part, PartCase{1, 4, want, append([]byte(nil), w.bytes()...)})
    _ = b
  }
  out["part_cases"] = part

  // ---- split_cu_flag / split_tu_flag / cbf_luma / cbf_cbcr ------------
  // All are single decodeBin at a derived ctx. Record ctx + bin + bytes.
  type BinCase struct{ Kind string; Ctx, Want int; Bytes []byte }
  bins := []BinCase{}
  addBin := func(kind string, ctx, val int) {
    b, w := syntaxWriter()
    w.encodeBin(ctx, uint32(val))
    w.encodeTerminate(1)
    d := syntaxCTU(s, p, sh, w.bytes(), pic)
    got := int(d.c.decodeBin(ctx))
    if got != val { t.Fatalf("bin %s ctx=%d val=%d got=%d", kind, ctx, val, got) }
    bins = append(bins, BinCase{kind, ctx, val, append([]byte(nil), w.bytes()...)})
    _ = b
  }
  for _, ctx := range []int{2, 3, 4} { for _, v := range []int{0, 1} { addBin("split_cu", ctx, v) } }
  for _, ctx := range []int{37, 38, 39, 40} { for _, v := range []int{0, 1} { addBin("split_tf", ctx, v) } }
  for _, ctx := range []int{40, 41} { for _, v := range []int{0, 1} { addBin("cbf_luma", ctx, v) } }
  for _, ctx := range []int{42, 43, 44, 45} { for _, v := range []int{0, 1} { addBin("cbf_cbcr", ctx, v) } }
  out["bin_cases"] = bins

  // ---- SAO syntax (7.3.8.3) ------------------------------------------
  // Off / band / edge for luma and chroma, with merge flags where applicable.
  // Single CTB (0,0): no merge bins. We cover cIdx 0,1 (2 shares chroma type).
  type SAOCase struct {
    Label string
    Bytes []byte
    Types [3]int
    Offs [3][4]int32
    Bands [3]int
    Classes [3]int
  }
  saoc := []SAOCase{}
  addSAO := func(label string, write func(*cabacWriter)) {
    b, w := syntaxWriter()
    write(w)
    w.encodeTerminate(1)
    d := syntaxCTU(s, p, sh, w.bytes(), pic)
    d.parseSAO(0, 0)
    g := d.sao[0]
    saoc = append(saoc, SAOCase{label, append([]byte(nil), w.bytes()...),
      [3]int{g[0].typeIdx, g[1].typeIdx, g[2].typeIdx},
      [3][4]int32{g[0].offset, g[1].offset, g[2].offset},
      [3]int{g[0].band, g[1].band, g[2].band},
      [3]int{g[0].class, g[1].class, g[2].class}})
    _ = b
  }
  // all off
  addSAO("all_off", func(w *cabacWriter) {
    w.encodeBin(ctxSAOTypeIDX, 0)
    w.encodeBin(ctxSAOTypeIDX, 0)
  })
  // luma band
  addSAO("luma_band", func(w *cabacWriter) {
    w.encodeBin(ctxSAOTypeIDX, 1)
    w.encodeBypass(0) // band
    writeSaoOffsets(w, 8, [4]int{3, 0, 5, 7}, [4]int{1, 0, 0, 1}, 13, true)
    w.encodeBin(ctxSAOTypeIDX, 0) // chroma off
  })
  // luma edge
  addSAO("luma_edge", func(w *cabacWriter) {
    w.encodeBin(ctxSAOTypeIDX, 1)
    w.encodeBypass(1) // edge
    writeSaoOffsets(w, 8, [4]int{1, 2, 4, 6}, [4]int{0, 0, 0, 0}, 2, false)
    w.encodeBin(ctxSAOTypeIDX, 0)
  })
  // chroma band: cIdx=0 off, cIdx=1 band (cIdx=2 shares type via saoType[1])
  addSAO("chroma_band", func(w *cabacWriter) {
    w.encodeBin(ctxSAOTypeIDX, 0) // luma off
    w.encodeBin(ctxSAOTypeIDX, 1) // chroma type != off
    w.encodeBypass(0)             // band
    writeSaoOffsets(w, 8, [4]int{2, 1, 0, 7}, [4]int{1, 0, 0, 1}, 21, true)
    // cIdx=2 does NOT write type again, only offsets
    writeSaoOffsets(w, 8, [4]int{4, 3, 2, 1}, [4]int{0, 1, 0, 1}, 7, true)
  })
  out["sao_cases"] = saoc

  data, err := json.Marshal(out)
  if err != nil { t.Fatal(err) }
  path := os.Getenv("SYNTAX_GOLDEN_OUT")
  if path == "" { path = "/workspace/tools/syntax_golden.json" }
  if err := os.WriteFile(path, data, 0644); err != nil { t.Fatal(err) }
  fmt.Printf("wrote %d bytes to %s\n", len(data), path)
  t.Logf("mpm=%d split_cu=%d ctx=%d luma=%d chroma=%d qpd=%d cqo=%d part=%d bin=%d sao=%d",
    len(mpm), len(scu), len(ctxidx), len(luma), len(chroma), len(qpd), len(cqo), len(part), len(bins), len(saoc))
}

func syntaxPPSWithCQO(l int, cb, cr []int32) *pps {
  pp := &pps{colWidthsInCtbs: []uint32{1}, rowHeightsInCtbs: []uint32{1},
    chromaQPOffsetListLen: uint32(l)}
  for i := 0; i < l; i++ { pp.cbQPOffsetList[i] = cb[i]; pp.crQPOffsetList[i] = cr[i] }
  return pp
}

func boolToIntS(v bool) int { if v { return 1 }; return 0 }
func boolToBitS(v bool) uint32 { if v { return 1 }; return 0 }

// writeCuQPDelta transcribes the writer side of parseCuQPDelta: prefix bins,
// optional EGk suffix, then a sign bit.
func writeCuQPDelta(w *cabacWriter, abs, sign int) {
  prefix := abs
  if prefix > 4 { prefix = 5 }
  for k := 0; k < prefix; k++ {
    ctx := 1
    if k == 0 { ctx = 0 }
    w.encodeBin(ctxCUQPDelta+ctx, 1)
  }
  if prefix <= 4 {
    w.encodeBin(ctxCUQPDelta+1, 0)
  } else {
    v := abs - 5
    k := 0
    for (1<<k-1) <= v && k < 6 { k++ }
    k--
    for i := 0; i < k; i++ { w.encodeBypass(1) }
    if k < 6 { w.encodeBypass(0) }
    w.encodeBypassBits(uint32(v-(1<<k-1)), k)
  }
  w.encodeBypass(uint32(sign))
}

// writeSaoOffsets writes the four unary offset magnitudes, band sign bits and
// band position (band mode) or edge class (edge mode).
func writeSaoOffsets(w *cabacWriter, bitDepth int, offs, signs [4]int, tail int, band bool) {
  cMax := int(saoMaxOffset(bitDepth))
  for _, v := range offs {
    for i := 0; i < v; i++ { w.encodeBypass(1) }
    if v < cMax { w.encodeBypass(0) }
  }
  if band {
    for i, v := range offs { if v != 0 { w.encodeBypass(uint32(signs[i])) } }
    w.encodeBypassBits(uint32(tail), 5)
  } else {
    w.encodeBypassBits(uint32(tail), 2)
  }
}
