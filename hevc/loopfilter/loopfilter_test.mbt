// Byte-exact parity tests for 8.7.2 deblocking and 8.7.3 SAO. Every value is
// golden from the real upstream Go deblock()/applySAO() (see
// tools/export_loopfilter_golden_test.go), verified independently by
// tools/crosscheck_loopfilter.mjs.

///|
fn bytes_to_array(b : Bytes) -> Array[Int32] {
  let a : Array[Int32] = Array::make(b.length(), 0)
  for i in 0..<b.length() {
    a[i] = b[i].to_int()
  }
  a
}

///|
fn frame_planes(c : @loopfilter.FrameCase) -> @loopfilter.Planes {
  {
    y: bytes_to_array(c.y),
    cb: bytes_to_array(c.cb),
    cr: bytes_to_array(c.cr),
  }
}

///|
test "beta_tc matches upstream Table 8-12 over full qp/bs/offset range" {
  for c in @loopfilter.beta_tc_cases {
    let got = @loopfilter.beta_tc(c.qp, c.bs, c.beta_off, c.tc_off, 8)
    assert_eq(got.beta, c.beta)
    assert_eq(got.tc, c.tc)
  }
  assert_eq(@loopfilter.beta_tc_cases.length(), 1188)
}

///|
test "deblock luma plan + apply match upstream 8.7.2.5.3/8.7.2.5.7" {
  for c in @loopfilter.luma_cases {
    let pl = @loopfilter.deblock_luma_plan(c.input, c.beta, c.tc)
    assert_eq(pl.mode, c.plan_mode)
    assert_eq(pl.n_dp, c.n_dp)
    assert_eq(pl.n_dq, c.n_dq)
    let got = @loopfilter.deblock_luma_apply(
      c.input,
      pl,
      c.bit_depth,
      c.no_p,
      c.no_q,
    )
    assert_eq(got, c.want)
  }
  assert_eq(@loopfilter.luma_cases.length(), 25)
}

///|
test "chroma line filter matches upstream 8.7.2.5.5" {
  for c in @loopfilter.chroma_cases {
    let got = @loopfilter.chroma_line(c.input, c.tc, c.max_v, c.no_p, c.no_q)
    assert_eq(got, c.want)
  }
  assert_eq(@loopfilter.chroma_cases.length(), 30)
}

///|
test "SAO band row matches upstream 8.7.3" {
  for c in @loopfilter.sao_band_cases {
    let got = @loopfilter.sao_band_row(
      c.src,
      c.band,
      c.offset,
      c.shift,
      c.max_v,
    )
    assert_eq(got, c.want)
  }
  assert_eq(@loopfilter.sao_band_cases.length(), 30)
}

///|
test "SAO edge row matches upstream 8.7.3" {
  for c in @loopfilter.sao_edge_cases {
    let got = @loopfilter.sao_edge_row(c.src, c.na, c.nb, c.offset, c.max_v)
    assert_eq(got, c.want)
  }
  assert_eq(@loopfilter.sao_edge_cases.length(), 30)
}

///|
/// Drive a whole picture through deblock_frame then sao_frame and compare all
/// three planes byte-for-byte with the upstream truth.
test "whole-picture deblock + SAO match upstream byte-for-byte" {
  for c in @loopfilter.frame_cases {
    let st = @loopfilter.filter_state(
      c.width,
      c.height,
      c.ctb_log2,
      c.qp_field,
      c.no_filter,
    )
    let planes = frame_planes(c)
    let r = @loopfilter.deblock_frame(
      planes,
      st,
      c.qp_y,
      c.beta_off,
      c.tc_off,
      c.deblock_off,
    )
    assert_true(r is Ok(_))
    assert_eq(planes.y, bytes_to_array(c.deb_y))
    assert_eq(planes.cb, bytes_to_array(c.deb_cb))
    assert_eq(planes.cr, bytes_to_array(c.deb_cr))
    let ctb_size = 1 << c.ctb_log2
    let ctbs_x = (c.width + ctb_size - 1) / ctb_size
    let ctbs_y = (c.height + ctb_size - 1) / ctb_size
    let params : Array[@loopfilter.SaoParams] = []
    for _ in 0..<(ctbs_x * ctbs_y) {
      params.push({
        type_idx: c.sao_type,
        class: c.sao_class,
        band: c.sao_band,
        offset: c.sao_offset,
      })
    }
    let r2 = @loopfilter.sao_frame(planes, st, params, c.sao_on)
    assert_true(r2 is Ok(_))
    assert_eq(planes.y, bytes_to_array(c.sao_y))
    assert_eq(planes.cb, bytes_to_array(c.sao_cb))
    assert_eq(planes.cr, bytes_to_array(c.sao_cr))
  }
  assert_eq(@loopfilter.frame_cases.length(), 7)
}

///|
test "malformed pictures return an error instead of trapping" {
  let st = @loopfilter.filter_state(64, 64, 6, [], [])
  let short : @loopfilter.Planes = { y: Array::make(10, 0), cb: [], cr: [], }
  assert_true(
    @loopfilter.deblock_frame(short, st, 26, 0, 0, false)
    is Err(@loopfilter.ShortPlane),
  )
  assert_true(
    @loopfilter.sao_frame(short, st, [], true) is Err(@loopfilter.ShortPlane),
  )
  let bad = @loopfilter.filter_state(65, 64, 6, [], [])
  let ok_planes : @loopfilter.Planes = {
    y: Array::make(64 * 64, 0),
    cb: Array::make(32 * 32, 0),
    cr: Array::make(32 * 32, 0),
  }
  assert_true(
    @loopfilter.deblock_frame(ok_planes, bad, 26, 0, 0, false)
    is Err(InvalidDimensions),
  )
}

///|
test "filter_state_from_blocks accepts a real 4x4-raster state and refuses a short one" {
  // 32x32 -> 8x8 = 64 blocks. A real I-frame state has every block intra,
  // a legal QP, and no noFilter flag (no PCM / transquant bypass).
  let n = 8 * 8
  let intra = Array::make(n, true)
  let cbf = Array::make(n, false)
  let tu_v = Array::make(n, false)
  let tu_h = Array::make(n, false)
  let pu_v = Array::make(n, false)
  let pu_h = Array::make(n, false)
  let qp_y = Array::make(n, 26)
  let no_filter = Array::make(n, false)
  // One real TU edge at (8, 8): its 4x4 block carries tuV/tuH.
  tu_v[2 * 8 + 2] = true
  tu_h[2 * 8 + 2] = true
  let st = match
    @loopfilter.filter_state_from_blocks(
      32, 32, 4, intra, cbf, tu_v, tu_h, pu_v, pu_h, qp_y, no_filter,
    ) {
    Ok(v) => v
    Err(_) => fail("real block state was refused")
  }
  // An intra boundary has strength 2 (8.7.2.4), regardless of cbf.
  assert_eq(@loopfilter.boundary_strength(st, 7, 8, 8, 8, true), 2)
  // A short state is a caller bug, refused as Err rather than an unchecked
  // array index / trap.
  let short = Array::make(3, false)
  assert_true(
    @loopfilter.filter_state_from_blocks(
      32, 32, 4, short, cbf, tu_v, tu_h, pu_v, pu_h, qp_y, no_filter,
    )
    is Err(@loopfilter.ShortPlane),
  )
  // Odd dimensions are invalid for 4:2:0 and must not reach an allocation.
  assert_true(
    @loopfilter.filter_state_from_blocks(
      33, 32, 4, intra, cbf, tu_v, tu_h, pu_v, pu_h, qp_y, no_filter,
    )
    is Err(@loopfilter.InvalidDimensions),
  )
}
