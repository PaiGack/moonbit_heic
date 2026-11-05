// Byte-exact checks of the spatial-state layer against golden.mbt: the real
// upstream Go buildMinTbAddr / available / predictQP / gatherRef, cross-checked
// by an independent JS transcription in tools/crosscheck_reconstruct.mjs.

///|
test "Geometry::new reproduces the upstream 6.5.2 MinTbAddrZs table" {
  for c in @geometry.mta_cases {
    let w = c.ctbs_w.to_int64() << c.ctb_log2
    let h = c.ctbs_h.to_int64() << c.ctb_log2
    let g = @geometry.Geometry::new(w, h, c.ctb_log2, c.min_tb_log2)
    assert_eq(g.min_tb_addr, c.addr)
  }
}

///|
test "Geometry::available reproduces the upstream 6.4.1 z-scan availability" {
  // The available sweep used a 64x64 luma picture, ctb_log2=6, min_tb_log2=2.
  let g = @geometry.Geometry::new(64L, 64L, 6, 2)
  for c in @geometry.avail_cases {
    assert_eq(g.available(c.x_curr, c.y_curr, c.x_n, c.y_n), c.want)
  }
}

///|
test "predict_qp reproduces the upstream 8.6.1 qPY_PRED" {
  for c in @geometry.qp_cases {
    // Exporter predicts at (8,8) with ctb_log2=6; both neighbours are
    // available and inside the same CTB.
    assert_eq(
      @geometry.predict_qp(c.qp_prev, c.qp_a, c.qp_b, 6, 8, 8, true, true),
      c.want,
    )
  }
}

///|
test "gather_ref reproduces the upstream 8.4.4.2.2 reference samples" {
  for c in @geometry.ref_cases {
    let g = @geometry.Geometry::new(64L, 64L, 6, 2)
    let plane = if c.c_idx == 0 { c.plane } else { c.cplane }
    let stride = if c.c_idx == 0 { 64 } else { 32 }
    let r = @geometry.gather_ref(g, plane, stride, c.x, c.y, c.n, c.c_idx, 2, 2)
    assert_eq(r.s, c.samples)
    assert_eq(r.avail, c.avail)
  }
}

///|
test "predict_qp respects the CTB boundary (32-bit mask, no wrap)" {
  // At x=32 the left neighbour (31) is in the previous CTB: ignored.
  let a = @geometry.predict_qp(20, 40, 30, 5, 32, 8, true, true)
  assert_eq(a, (20 + 30 + 1) >> 1)
  // At x=8 both neighbours are in the same CTB: both count.
  let b = @geometry.predict_qp(20, 40, 30, 5, 8, 8, true, true)
  assert_eq(b, (40 + 30 + 1) >> 1)
}
