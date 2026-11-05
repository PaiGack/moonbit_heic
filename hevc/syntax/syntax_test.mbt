// Byte-exact checks of the CTU-level CABAC syntax layer against golden.mbt:
// the real upstream Go pure derivations and cabacWriter -> ctuDecoder
// round-tripped bitstreams. tools/crosscheck_syntax.mjs holds the same JSON
// value-for-value against an independent JS transcription.

///|
fn new_decoder(bytes : Bytes) -> @cabac.Decoder raise {
  let dec = @cabac.Decoder::new(bytes, 0) catch {
    _ => fail("short CABAC init word")
  }
  dec.init_contexts(26, 2, false)
  dec
}

///|
test "mpm_cand matches the upstream 8.4.2 derivation" {
  for c in @syntax.mpm_cases {
    // -1 marks an absent neighbour, which contributes INTRA_DC.
    let a = if c.a < 0 { @syntax.intra_dc } else { c.a }
    let b = if c.b < 0 { @syntax.intra_dc } else { c.b }
    let got = @syntax.mpm_cand(a, b)
    assert_eq(got.length(), 3)
    for i in 0..<3 {
      assert_eq(got[i], c.want[i])
    }
  }
}

///|
test "split_cu_ctx matches the upstream 9.3.4.2.2 derivation, full traversal" {
  for c in @syntax.split_cu_ctx_cases {
    assert_eq(
      @syntax.split_cu_ctx(c.left_depth, c.above_depth, c.depth),
      c.want,
    )
  }
}

///|
test "derived syntax context indices match upstream" {
  for c in @syntax.ctx_idx_cases {
    let got = if c.kind == 0 {
      @syntax.split_tf_ctx(c.arg)
    } else if c.kind == 1 {
      @syntax.cbf_luma_ctx(c.arg)
    } else {
      @syntax.cbf_cbcr_ctx(c.arg)
    }
    assert_eq(got, c.want)
  }
}

///|
test "chroma422 matches Table 8-3 (upstream chroma422Map)" {
  for mode in 0..<@syntax.chroma422_want.length() {
    let got = @syntax.chroma422(mode).unwrap()
    assert_eq(got, @syntax.chroma422_want[mode])
  }
  // Out-of-range mode is an explicit error, not an unchecked index.
  assert_true(@syntax.chroma422(35) is Err(_))
  assert_true(@syntax.chroma422(-1) is Err(_))
}

///|
test "chroma_qp matches Table 8-10 (upstream chromaQP), qPi 0..57" {
  for q in 0..<@syntax.chroma_qp_want.length() {
    assert_eq(@syntax.chroma_qp(q, 1), @syntax.chroma_qp_want[q])
  }
}

///|
test "qp_wrap matches the upstream 8.6.1 QP wrap" {
  for c in @syntax.qp_wrap_cases {
    assert_eq(@syntax.qp_wrap(c.pred, c.delta, 8), c.want)
  }
}

///|
test "sao_offset_cmax matches 7.3.8.3" {
  for c in @syntax.sao_cmax_cases {
    assert_eq(@syntax.sao_offset_cmax(c.bit_depth), c.want)
  }
}

///|
test "decode_intra_luma_mode reproduces upstream from real CABAC bitstreams" {
  for c in @syntax.luma_cases {
    let dec = new_decoder(c.bytes)
    let got = @syntax.decode_intra_luma_mode(dec, c.cand).unwrap()
    assert_eq(got, c.want)
  }
}

///|
test "decode_intra_chroma_mode reproduces upstream (Table 8-2) from real bitstreams" {
  for c in @syntax.chroma_cases {
    let dec = new_decoder(c.bytes)
    let got = @syntax.decode_intra_chroma_mode(dec, c.luma, 1).unwrap()
    assert_eq(got, c.want)
  }
}

///|
test "decode_cu_qp_delta reproduces upstream (7.3.8.9) from real bitstreams" {
  for c in @syntax.qpd_cases {
    let dec = new_decoder(c.bytes)
    let got = @syntax.decode_cu_qp_delta(dec).unwrap()
    assert_eq(got, c.want)
  }
}

///|
test "decode_cu_chroma_qp_offset reproduces upstream (7.3.8.10) from real bitstreams" {
  for c in @syntax.cqo_cases {
    let dec = new_decoder(c.bytes)
    let (got_cb, got_cr) = @syntax.decode_cu_chroma_qp_offset(
      dec,
      c.len,
      c.cb_list,
      c.cr_list,
    ).unwrap()
    assert_eq(got_cb, c.want_cb)
    assert_eq(got_cr, c.want_cr)
  }
  // A zero-length list is refused, not indexed out of bounds.
  let dec = new_decoder(@syntax.cqo_cases[0].bytes)
  assert_true(@syntax.decode_cu_chroma_qp_offset(dec, 0, [], []) is Err(_))
}

///|
test "decode_part_mode_intra reproduces upstream (7.3.8.5) from real bitstreams" {
  for c in @syntax.part_cases {
    let dec = new_decoder(c.bytes)
    let got = @syntax.decode_part_mode_intra(dec).unwrap()
    assert_eq(got, c.want)
  }
}

///|
test "decode_flag reproduces single-bin elements at derived contexts" {
  for c in @syntax.bin_cases {
    let dec = new_decoder(c.bytes)
    let got = @syntax.decode_flag(dec, c.ctx).unwrap()
    assert_eq(got, c.want)
  }
  // An out-of-range context is an explicit error, not a trap.
  let dec = new_decoder(@syntax.bin_cases[0].bytes)
  assert_true(@syntax.decode_flag(dec, 179) is Err(_))
}

///|
test "decode_sao reproduces upstream 7.3.8.3 from real bitstreams" {
  for c in @syntax.sao_cases {
    let dec = new_decoder(c.bytes)
    let got = @syntax.decode_sao(dec, 8, 0, 0, true, true).unwrap()
    assert_eq(got.length(), 3)
    for k in 0..<3 {
      assert_eq(got[k].type_idx, c.types[k])
      assert_eq(got[k].band, c.bands[k])
      assert_eq(got[k].class_, c.classes[k])
      for i in 0..<4 {
        assert_eq(got[k].offset[i], c.offs[k][i])
      }
    }
  }
}
