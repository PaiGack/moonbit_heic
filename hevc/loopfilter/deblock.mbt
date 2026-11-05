// 8.7.2 deblocking. The luma strong/normal decision and apply, and the chroma
// line filter, are the pure kernels; deblock_frame drives them over every
// 8-sample edge of the picture (vertical pass, then horizontal).

///|
/// What 8.7.2.5.3 decided for one group of four lines.
pub(all) struct LumaPlan {
  tc : Int32
  /// 0 none, 1 strong, 2 normal.
  mode : Int32
  n_dp : Int32
  n_dq : Int32
}

///|
/// 8.7.2.5.3 over a 4x8 strip. `s` is laid out as four lines of eight samples
/// indexed -4..3 (physical column = i + 4), matching the p/q neighbourhood
/// the spec reads.
pub fn deblock_luma_plan(
  s : Array[Int32],
  beta : Int32,
  tc : Int32,
) -> LumaPlan {
  let at : (Int32, Int32) -> Int32 = fn(l, i) { s[l * 8 + i + 4] }
  let dp0 = abs_i32(at(0, -3) - 2 * at(0, -2) + at(0, -1))
  let dq0 = abs_i32(at(0, 2) - 2 * at(0, 1) + at(0, 0))
  let dp3 = abs_i32(at(3, -3) - 2 * at(3, -2) + at(3, -1))
  let dq3 = abs_i32(at(3, 2) - 2 * at(3, 1) + at(3, 0))
  let dp = dp0 + dp3
  let dq = dq0 + dq3
  if dp + dq >= beta {
    return { tc: 0, mode: 0, n_dp: 0, n_dq: 0, }
  }
  let strong : (Int32, Int32) -> Bool = fn(l, d2) {
    2 * d2 < beta >> 2 &&
    abs_i32(at(l, -4) - at(l, -1)) + abs_i32(at(l, 0) - at(l, 3)) < beta >> 3 &&
    abs_i32(at(l, -1) - at(l, 0)) < (5 * tc + 1) >> 1
  }
  if strong(0, dp0 + dq0) && strong(3, dp3 + dq3) {
    return { tc, mode: 1, n_dp: 0, n_dq: 0, }
  }
  let n_dp = if dp < (beta + (beta >> 1)) >> 3 { 1 } else { 0 }
  let n_dq = if dq < (beta + (beta >> 1)) >> 3 { 1 } else { 0 }
  { tc, mode: 2, n_dp, n_dq, }
}

///|
/// 8.7.2.5.7 apply over the same 4x8 strip. Returns a new strip; `no_p` /
/// `no_q` leave a side untouched when its coding unit bypassed the transform.
pub fn deblock_luma_apply(
  s : Array[Int32],
  pl : LumaPlan,
  bit_depth : Int32,
  no_p : Bool,
  no_q : Bool,
) -> Array[Int32] {
  let tc = pl.tc
  let max_v = (1 << bit_depth) - 1
  let out = s.copy()
  let at : (Int32, Int32) -> Int32 = fn(l, i) { s[l * 8 + i + 4] }
  let set : (Int32, Int32, Int32) -> Unit = fn(l, i, v) {
    if (i < 0 && no_p) || (i >= 0 && no_q) {
      return
    }
    out[l * 8 + i + 4] = clip3(v, 0, max_v)
  }
  if pl.mode == 1 {
    let c = 2 * tc
    for l in 0..<4 {
      let p0 = at(l, -1)
      let p1 = at(l, -2)
      let p2 = at(l, -3)
      let p3 = at(l, -4)
      let q0 = at(l, 0)
      let q1 = at(l, 1)
      let q2 = at(l, 2)
      let q3 = at(l, 3)
      set(
        l,
        -1,
        clip3((p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3, p0 - c, p0 + c),
      )
      set(l, -2, clip3((p2 + p1 + p0 + q0 + 2) >> 2, p1 - c, p1 + c))
      set(
        l,
        -3,
        clip3((2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3, p2 - c, p2 + c),
      )
      set(
        l,
        0,
        clip3((p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3, q0 - c, q0 + c),
      )
      set(l, 1, clip3((p0 + q0 + q1 + q2 + 2) >> 2, q1 - c, q1 + c))
      set(
        l,
        2,
        clip3((p0 + q0 + q1 + 3 * q2 + 2 * q3 + 4) >> 3, q2 - c, q2 + c),
      )
    }
    return out
  }
  for l in 0..<4 {
    let p0 = at(l, -1)
    let p1 = at(l, -2)
    let p2 = at(l, -3)
    let q0 = at(l, 0)
    let q1 = at(l, 1)
    let q2 = at(l, 2)
    let delta0 = (9 * (q0 - p0) - 3 * (q1 - p1) + 8) >> 4
    if abs_i32(delta0) >= tc * 10 {
      continue
    }
    let delta = clip3(delta0, -tc, tc)
    set(l, -1, p0 + delta)
    set(l, 0, q0 - delta)
    if pl.n_dp != 0 {
      set(
        l,
        -2,
        p1 +
        clip3((((p2 + p0 + 1) >> 1) - p1 + delta) >> 1, -(tc >> 1), tc >> 1),
      )
    }
    if pl.n_dq != 0 {
      set(
        l,
        1,
        q1 +
        clip3((((q2 + q0 + 1) >> 1) - q1 - delta) >> 1, -(tc >> 1), tc >> 1),
      )
    }
  }
  out
}

///|
/// 8.7.2.5.5 chroma line. `inp` is [p1, p0, q0, q1]; returns the filtered
/// quadruple with the two outer samples clipped to [0, max_v].
pub fn chroma_line(
  inp : Array[Int32],
  tc : Int32,
  max_v : Int32,
  no_p : Bool,
  no_q : Bool,
) -> Array[Int32] {
  let p0 = inp[1]
  let p1 = inp[0]
  let q0 = inp[2]
  let q1 = inp[3]
  let delta = clip3((((q0 - p0) << 2) + p1 - q1 + 4) >> 3, -tc, tc)
  let out = inp.copy()
  if !no_p {
    out[1] = clip3(p0 + delta, 0, max_v)
  }
  if !no_q {
    out[2] = clip3(q0 - delta, 0, max_v)
  }
  out
}

///|
/// Per-4x4-block flags the boundary strength derivation reads back. I-frame
/// CTUs are all intra with a coded block flag, so bs is 2 on every TU/PU edge.
pub(all) struct BlockInfo {
  intra : Bool
  cbf : Bool
  mut tu_v : Bool
  mut tu_h : Bool
  mut pu_v : Bool
  mut pu_h : Bool
}

///|
/// The controlled state an M3 I-frame loop filter needs: one 8x8 intra TU/PU
/// per cell, a per-min-TB QP and noFilter field, and the plane dimensions.
pub(all) struct FilterState {
  width : Int32
  height : Int32
  ctb_log2 : Int32
  min_tb_w : Int32
  blk : Array[BlockInfo]
  qp_y : Array[Int32]
  no_filter : Array[Bool]
}

///|
fn blk_index(st : FilterState, x : Int32, y : Int32) -> Int32 {
  (y >> 2) * ((st.width + 3) / 4) + (x >> 2)
}

///|
fn tb_index(st : FilterState, x : Int32, y : Int32) -> Int32 {
  (y >> 2) * st.min_tb_w + (x >> 2)
}

///|
/// 8.7.2.4 boundary strength. In the controlled I-frame state p and q are
/// always intra, so any TU/PU edge yields 2.
pub fn boundary_strength(
  st : FilterState,
  x_p : Int32,
  y_p : Int32,
  x_q : Int32,
  y_q : Int32,
  vertical : Bool,
) -> Int32 {
  let q = st.blk[blk_index(st, x_q, y_q)]
  let tu = if vertical { q.tu_v } else { q.tu_h }
  let pu = if vertical { q.pu_v } else { q.pu_h }
  if !tu && !pu {
    return 0
  }
  let p = st.blk[blk_index(st, x_p, y_p)]
  if p.intra || q.intra {
    return 2
  }
  if tu && (p.cbf || q.cbf) {
    return 1
  }
  1
}

///|
/// Build the controlled state from an I-frame's QP / noFilter fields. The
/// TU/PU flags are set so every 8-sample grid line is a real 8.7.2 edge.
pub fn filter_state(
  width : Int32,
  height : Int32,
  ctb_log2 : Int32,
  qp_y : Array[Int32],
  no_filter : Array[Bool],
) -> FilterState {
  let mv_w = (width + 3) / 4
  let mv_h = (height + 3) / 4
  let blk : Array[BlockInfo] = Array::make(mv_w * mv_h, {
    intra: true,
    cbf: true,
    tu_v: false,
    tu_h: false,
    pu_v: false,
    pu_h: false,
  })
  let mut ty = 0
  while ty < height {
    let mut tx = 0
    while tx < width {
      for j in 0..<2 {
        for i in 0..<2 {
          let bi = ((ty + j * 4) >> 2) * mv_w + ((tx + i * 4) >> 2)
          if bi < blk.length() {
            let b = blk[bi]
            b.tu_v = b.tu_v || i == 0
            b.pu_v = b.pu_v || i == 0
            b.tu_h = b.tu_h || j == 0
            b.pu_h = b.pu_h || j == 0
          }
        }
      }
      tx += 8
    }
    ty += 8
  }
  { width, height, ctb_log2, min_tb_w: mv_w, blk, qp_y, no_filter, }
}

///|
/// Why deblock_frame refused a picture.
pub(all) enum FilterError {
  InvalidDimensions
  ShortPlane
}

///|
/// The three planes of an 8-bit 4:2:0 picture, as mutable Int32 arrays.
pub(all) struct Planes {
  y : Array[Int32]
  cb : Array[Int32]
  cr : Array[Int32]
}

///|
/// 8.7.2 over the whole picture: every vertical edge, then every horizontal
/// one, both on the eight-sample grid. Single-thread, single-slice, single-tile
/// (the M3 scope). Returns Err on a malformed picture rather than trapping.
pub fn deblock_frame(
  planes : Planes,
  st : FilterState,
  qp_y : Int32,
  beta_off : Int32,
  tc_off : Int32,
  deblock_off : Bool,
) -> Result[Unit, FilterError] {
  let w = st.width
  let h = st.height
  if w <= 0 || h <= 0 || w % 2 != 0 || h % 2 != 0 {
    return Err(InvalidDimensions)
  }
  let luma_len : Int64 = w.to_int64() * h.to_int64()
  let chroma_len : Int64 = w.to_int64() / 2L * (h.to_int64() / 2L)
  if planes.y.length().to_int64() < luma_len ||
    planes.cb.length().to_int64() < chroma_len ||
    planes.cr.length().to_int64() < chroma_len {
    return Err(ShortPlane)
  }
  if deblock_off {
    return Ok(())
  }
  let stride_y = w
  let stride_c = w / 2
  for vertical in [true, false] {
    let mut y = 0
    while y < h {
      let mut x = 0
      while x < w {
        if !((vertical && x == 0) || (!vertical && y == 0)) {
          deblock_edge(
            planes, st, qp_y, beta_off, tc_off, x, y, vertical, stride_y, stride_c,
          )
        }
        x += 8
      }
      y += 8
    }
  }
  Ok(())
}

///|
/// One 8x8 edge segment (luma + both chroma), reproducing deblockEdge +
/// deblockChromaEdge for the single-slice/tile case.
fn deblock_edge(
  planes : Planes,
  st : FilterState,
  _qp_y : Int32,
  beta_off : Int32,
  tc_off : Int32,
  x : Int32,
  y : Int32,
  vertical : Bool,
  stride_y : Int32,
  stride_c : Int32,
) -> Unit {
  let w = st.width
  let h = st.height
  let plan : Array[LumaPlan?] = [None, None]
  let no_p : Array[Bool] = [false, false]
  let no_q : Array[Bool] = [false, false]
  let on_c : Array[Bool] = [false, false]
  let qp_c : Array[Int32] = [0, 0]
  for k in [0, 4] {
    let g = k / 4
    let px = if vertical { x - 1 } else { x + k }
    let py = if vertical { y + k } else { y - 1 }
    let qx = if vertical { x } else { x + k }
    let qy = if vertical { y + k } else { y }
    if qy >= h || qx >= w {
      continue
    }
    let bs = boundary_strength(st, px, py, qx, qy, vertical)
    if bs == 0 {
      continue
    }
    let pt = tb_index(st, px, py)
    let qt = tb_index(st, qx, qy)
    if pt < 0 || pt >= st.qp_y.length() || qt < 0 || qt >= st.qp_y.length() {
      continue
    }
    let qp = (st.qp_y[pt] + st.qp_y[qt] + 1) >> 1
    no_p[g] = st.no_filter[pt]
    no_q[g] = st.no_filter[qt]
    let bt = beta_tc(qp, bs, beta_off, tc_off, 8)
    if bt.beta != 0 && bt.tc != 0 {
      let strip = gather_luma(planes.y, w, h, x, y, k, vertical, stride_y)
      plan[g] = Some(deblock_luma_plan(strip, bt.beta, bt.tc))
    }
    if bs == 2 {
      if (vertical && x % 16 != 0) || (!vertical && y % 16 != 0) {
        continue
      }
      on_c[g] = true
      qp_c[g] = qp
    }
  }
  // chroma
  for g in 0..<2 {
    if !on_c[g] {
      continue
    }
    let qp_cb = chroma_qp(clip3(qp_c[g], 0, 57), 1)
    let bt = beta_tc(qp_cb, 2, beta_off, tc_off, 8)
    let tc = bt.tc
    if tc == 0 {
      continue
    }
    let cx = if vertical { x } else { x + 4 * g }
    let cy = if vertical { y + 4 * g } else { y }
    let base = cy / 2 * stride_c + cx / 2
    let step = if vertical { 1 } else { stride_c }
    let line = if vertical { stride_c } else { 1 }
    for l in 0..<2 {
      let off = base + l * line
      if off - 2 * step < 0 || off + step >= planes.cb.length() {
        continue
      }
      let in_cb : Array[Int32] = [
        planes.cb[off - 2 * step],
        planes.cb[off - step],
        planes.cb[off],
        planes.cb[off + step],
      ]
      let in_cr : Array[Int32] = [
        planes.cr[off - 2 * step],
        planes.cr[off - step],
        planes.cr[off],
        planes.cr[off + step],
      ]
      let o_cb = chroma_line(in_cb, tc, 255, no_p[g], no_q[g])
      let o_cr = chroma_line(in_cr, tc, 255, no_p[g], no_q[g])
      if !no_p[g] {
        planes.cb[off - step] = o_cb[1]
        planes.cr[off - step] = o_cr[1]
      }
      if !no_q[g] {
        planes.cb[off] = o_cb[2]
        planes.cr[off] = o_cr[2]
      }
    }
  }
  // luma apply, two 4-line groups
  for g in 0..<2 {
    match plan[g] {
      None => continue
      Some(pl) => {
        if pl.mode == 0 {
          continue
        }
        let strip = gather_luma(planes.y, w, h, x, y, 4 * g, vertical, stride_y)
        let out = deblock_luma_apply(strip, pl, 8, no_p[g], no_q[g])
        scatter_luma(planes.y, out, w, h, x, y, 4 * g, vertical, stride_y)
      }
    }
  }
}

///|
/// Gather a 4x8 strip (indices -4..3) from the luma plane around an edge.
/// Out-of-picture samples read as 0, matching the controlled exporter which
/// never filters an edge whose q side is outside the picture.
fn gather_luma(
  plane : Array[Int32],
  w : Int32,
  h : Int32,
  x : Int32,
  y : Int32,
  k : Int32,
  vertical : Bool,
  stride_y : Int32,
) -> Array[Int32] {
  let strip : Array[Int32] = Array::make(32, 0)
  for l in 0..<4 {
    for i in -4..<4 {
      let sx = if vertical { x + i } else { x + k + l }
      let sy = if vertical { y + k + l } else { y + i }
      if sx >= 0 && sx < w && sy >= 0 && sy < h {
        strip[l * 8 + i + 4] = plane[sy * stride_y + sx]
      }
    }
  }
  strip
}

///|
fn scatter_luma(
  plane : Array[Int32],
  out : Array[Int32],
  w : Int32,
  h : Int32,
  x : Int32,
  y : Int32,
  k : Int32,
  vertical : Bool,
  stride_y : Int32,
) -> Unit {
  for l in 0..<4 {
    for i in -4..<4 {
      let sx = if vertical { x + i } else { x + k + l }
      let sy = if vertical { y + k + l } else { y + i }
      if sx >= 0 && sx < w && sy >= 0 && sy < h {
        plane[sy * stride_y + sx] = out[l * 8 + i + 4]
      }
    }
  }
}
