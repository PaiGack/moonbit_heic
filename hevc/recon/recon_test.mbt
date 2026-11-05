// Byte-exact checks of the reconstruction DSP layers against golden.mbt,
// which tools/gen_recon_golden.mjs generates from an independent,
// from-the-spec transcription (itself checked against the real upstream Go).

///|
test "dequant matches the upstream 8.6.3 scaling" {
  for c in @recon.dequant_cases {
    let coef = c.coef.copy()
    @recon.dequant(coef, c.m, c.n, c.qp, 8, false)
    assert_eq(coef, c.want)
  }
}

///|
test "dequant keeps products in 64 bits (32-bit counterexample)" {
  // qp=51, m=255, coef=32767: the product 32767*255*(72<<8) is ~1.5e11,
  // which a 32-bit Int wraps. The result here is the clipped 32767, and the
  // test pins it so a narrowed carrier cannot silently disagree.
  let c = [32767]
  @recon.dequant(c, Some([255]), 4, 51, 8, false)
  assert_eq(c[0], 32767)
}

///|
test "2D inverse transform matches the upstream 8.6.4.1" {
  for c in @recon.transform_cases {
    let coef = c.coef.copy()
    @recon.inverse_transform(coef, c.n, c.dst, 8, false)
    assert_eq(coef, c.want)
  }
}

///|
test "intra prediction matches all 35 upstream modes" {
  for c in @recon.intra_cases {
    let r = @recon.RefSamples::new(c.n, c.s.copy())
    assert_eq(@recon.intra_predict(r, c.mode, c.c_idx, 8), c.want)
  }
}

///|
test "reference-sample substitution matches 8.4.4.2.2" {
  for c in @recon.sub_cases {
    let r = @recon.RefSamples::new((c.size - 1) / 4, c.s.copy())
    r.substitute(c.avail, 8)
    assert_eq(r.s, c.want)
  }
}

///|
test "a constant neighbourhood predicts that constant, every mode" {
  // The property the upstream TestIntraConstant holds: all prediction shapes
  // are weighted averages whose weights sum to one.
  for n in [4, 8, 16, 32] {
    for c_idx in [0, 1] {
      for mode = 0; mode < 35; mode = mode + 1 {
        let v = 137
        let samples = Array::make(4 * n + 1, v)
        let r = @recon.RefSamples::new(n, samples)
        let dst = @recon.intra_predict(r, mode, c_idx, 8)
        for s in dst {
          assert_eq(s, v)
        }
      }
    }
  }
}

///|
test "reference filtering matches 8.4.4.2.3" {
  for c in @recon.ref_cases {
    let r = @recon.RefSamples::new(c.n, c.s.copy())
    r.filter_ref(c.mode, c.c_idx, 8, 1, c.strong, c.disabled)
    assert_eq(r.s, c.want)
  }
}

///|
test "filterFlag derivation of 8.4.4.2.3" {
  assert_true(!@recon.filter_flag(@recon.intra_dc, 8, 0, 1))
  assert_true(!@recon.filter_flag(@recon.intra_planar, 4, 0, 1))
  assert_true(!@recon.filter_flag(@recon.intra_planar, 8, 1, 1))
  assert_true(@recon.filter_flag(@recon.intra_planar, 8, 0, 1))
  assert_true(!@recon.filter_flag(@recon.intra_ver, 8, 0, 1))
  assert_true(!@recon.filter_flag(@recon.intra_hor, 8, 0, 1))
  assert_true(@recon.filter_flag(@recon.intra_ver + 1, 32, 0, 1))
  assert_true(@recon.filter_flag(@recon.intra_planar, 8, 1, 3))
}

///|
test "chromaQP of Table 8-10 (ChromaArrayType 1)" {
  for q in 0..<@recon.chroma_qp_want.length() {
    assert_eq(@recon.chroma_qp(q, 1), @recon.chroma_qp_want[q])
  }
}

///|
test "chromaQP for a non-4:2:0 array type clamps to 51" {
  assert_eq(@recon.chroma_qp(60, 0), 51)
  assert_eq(@recon.chroma_qp(20, 3), 20)
}

///|
test "dequant refuses out-of-range qp/size without trapping" {
  let c = [100, -200, 300, -400]
  let before = c.copy()
  @recon.dequant(c, None, 4, -1, 8, false)
  assert_eq(c, before)
  @recon.dequant(c, None, 4, 999, 8, false)
  assert_eq(c, before)
  @recon.dequant(c, None, 2, 26, 8, false)
  assert_eq(c, before)
}

///|
test "an all-zero coefficient block transforms to all zeros" {
  // The one input whose inverse transform is exactly known by definition,
  // at every size and for both the DCT and the 4x4 DST.
  for n in [4, 8, 16, 32] {
    let c = Array::make(n * n, 0)
    @recon.inverse_transform(c, n, false, 8, false)
    for v in c {
      assert_eq(v, 0)
    }
  }
  let d = Array::make(16, 0)
  @recon.inverse_transform(d, 4, true, 8, false)
  for v in d {
    assert_eq(v, 0)
  }
}
