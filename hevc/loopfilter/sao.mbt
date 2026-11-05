// 8.7.3 sample adaptive offset. sao_band_row / sao_edge_row are the pure
// kernels; sao_frame drives them over the whole picture with the copy-first,
// block-by-block geometry of the upstream single-thread implementation.

///|
/// 8.7.3 band offset over a run of samples.
pub fn sao_band_row(
  src : Array[Int32],
  band : Int32,
  offset : Array[Int32],
  shift : Int32,
  max_v : Int32,
) -> Array[Int32] {
  let out = src.copy()
  for i in 0..<src.length() {
    let v = src[i]
    let k = ((v >> shift) - band) & 31
    if k < 4 {
      out[i] = clip3(v + offset[k], 0, max_v)
    }
  }
  out
}

///|
/// 8.7.3 edge offset over a run, with the two neighbour rows passed in.
pub fn sao_edge_row(
  src : Array[Int32],
  na : Array[Int32],
  nb : Array[Int32],
  offset : Array[Int32],
  max_v : Int32,
) -> Array[Int32] {
  let out = src.copy()
  for i in 0..<src.length() {
    let v = src[i]
    let cat = sign_i32(v - na[i]) + sign_i32(v - nb[i])
    if cat == 0 {
      continue
    }
    let k = if cat > 0 { cat + 1 } else { cat + 2 }
    out[i] = clip3(v + offset[k], 0, max_v)
  }
  out
}

///|
/// Per-CTB SAO parameters of 7.3.8.3 (the syntax that parses them is part of
/// the CTU driver; here they are supplied by the caller).
pub(all) struct SaoParams {
  /// 0 off, 1 band, 2 edge.
  type_idx : Int32
  class : Int32
  band : Int32
  offset : Array[Int32]
}

///|
/// Why sao_frame refused a picture.
pub(all) enum SaoError {
  InvalidDimensions
  ShortPlane
}

///|
/// 8.7.3 over the whole picture. `params` has one entry per CTB (row-major),
/// shared by the three colour components as 7.3.8.3 gives Cb/Cr one type and
/// class between them. Returns Err on a malformed picture rather than trapping.
pub fn sao_frame(
  planes : Planes,
  st : FilterState,
  params : Array[SaoParams],
  sao_on : Bool,
) -> Result[Unit, SaoError] {
  if !sao_on {
    return Ok(())
  }
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
  let ctb_size = 1 << st.ctb_log2
  let ctbs_x = (w + ctb_size - 1) / ctb_size
  let ctbs_y = (h + ctb_size - 1) / ctb_size
  if params.length() == 0 {
    return Ok(())
  }
  // One src copy per component, taken before any writes so every offset reads
  // the picture exactly as deblocking left it.
  let src_y = planes.y.copy()
  let src_cb = planes.cb.copy()
  let src_cr = planes.cr.copy()
  for c_idx in 0..<3 {
    let sw = if c_idx > 0 { 2 } else { 1 }
    let sh = if c_idx > 0 { 2 } else { 1 }
    let pw = w / sw
    let ph = h / sh
    let stride = if c_idx > 0 { w / 2 } else { w }
    let plane = if c_idx == 0 {
      planes.y
    } else if c_idx == 1 {
      planes.cb
    } else {
      planes.cr
    }
    let src = if c_idx == 0 {
      src_y
    } else if c_idx == 1 {
      src_cb
    } else {
      src_cr
    }
    let ctb_w = ctb_size / sw
    let ctb_h = ctb_size / sh
    for ctb_y in 0..<ctbs_y {
      for ctb_x in 0..<ctbs_x {
        let ctb = ctb_y * ctbs_x + ctb_x
        if ctb >= params.length() {
          continue
        }
        let p = params[ctb]
        if p.type_idx == 0 {
          continue
        }
        let is_band = p.type_idx == 1
        let eo = eo_offsets[p.class]
        let a0 = eo.0
        let a1 = eo.1
        let b0 = eo.2
        let b1 = eo.3
        let x0 = ctb_x * ctb_w
        let y0 = ctb_y * ctb_h
        let xhi = if x0 + ctb_w < pw { x0 + ctb_w } else { pw }
        let yhi = if y0 + ctb_h < ph { y0 + ctb_h } else { ph }
        let mut y = y0
        while y < yhi {
          let mut xlo = x0
          let mut row_xhi = xhi
          if !is_band {
            if y + a1 < 0 || y + a1 >= ph || y + b1 < 0 || y + b1 >= ph {
              y += 1
              continue
            }
            let mx = if -a0 > -b0 { -a0 } else { -b0 }
            if mx > xlo {
              xlo = mx
            }
            let mxx = if a0 > b0 { a0 } else { b0 }
            let lim = pw - mxx
            if lim < row_xhi {
              row_xhi = lim
            }
          }
          let mut ilo = xlo
          let mut ihi = row_xhi
          if !is_band {
            if a1 != 0 && (y == y0 || y == yhi - 1) {
              ihi = ilo
            } else if a0 != 0 {
              let t = if xlo > x0 + 1 { xlo } else { x0 + 1 }
              ilo = if t < row_xhi { t } else { row_xhi }
              let u = if row_xhi < x0 + ctb_w - 1 {
                row_xhi
              } else {
                x0 + ctb_w - 1
              }
              ihi = if u > ilo { u } else { ilo }
            }
          }
          // edge samples: [xlo, ilo) and [ihi, row_xhi)
          let mut xx = xlo
          while xx < ilo {
            sao_sample(
              plane, src, st, stride, pw, ph, sw, sh, xx, y, p, a0, a1, b0, b1, is_band,
            )
            xx += 1
          }
          xx = ihi
          while xx < row_xhi {
            sao_sample(
              plane, src, st, stride, pw, ph, sw, sh, xx, y, p, a0, a1, b0, b1, is_band,
            )
            xx += 1
          }
          // interior runs
          let min_tb_log2 = 2
          xx = ilo
          while xx < ihi {
            let ti = tb_index(st, xx * sw, y * sh)
            if ti >= 0 && ti < st.no_filter.length() && st.no_filter[ti] {
              let next = ((((xx * sw) >> min_tb_log2) + 1) << min_tb_log2) / sw
              xx = if next < ihi { next } else { ihi }
              continue
            }
            let mut run = xx
            while run < ihi {
              let ti2 = tb_index(st, run * sw, y * sh)
              if ti2 >= 0 && ti2 < st.no_filter.length() && st.no_filter[ti2] {
                break
              }
              let next = ((((run * sw) >> min_tb_log2) + 1) << min_tb_log2) / sw
              run = if next < ihi { next } else { ihi }
            }
            if is_band {
              for q in xx..<run {
                let v = src[y * stride + q]
                let k = ((v >> 3) - p.band) & 31
                if k < 4 {
                  plane[y * stride + q] = clip3(v + p.offset[k], 0, 255)
                }
              }
            } else {
              for q in xx..<run {
                let v = src[y * stride + q]
                let va = src[(y + a1) * stride + q + a0]
                let vb = src[(y + b1) * stride + q + b0]
                let cat = sign_i32(v - va) + sign_i32(v - vb)
                if cat != 0 {
                  let k = if cat > 0 { cat + 1 } else { cat + 2 }
                  plane[y * stride + q] = clip3(v + p.offset[k], 0, 255)
                }
              }
            }
            xx = run
          }
          y += 1
        }
      }
    }
  }
  Ok(())
}

///|
/// 8.7.3 for one sample at a CTB edge, where a neighbour may be outside the
/// picture. Interior samples use the faster row kernels above.
fn sao_sample(
  plane : Array[Int32],
  src : Array[Int32],
  st : FilterState,
  stride : Int32,
  pw : Int32,
  ph : Int32,
  sw : Int32,
  sh : Int32,
  x : Int32,
  y : Int32,
  p : SaoParams,
  a0 : Int32,
  a1 : Int32,
  b0 : Int32,
  b1 : Int32,
  is_band : Bool,
) -> Unit {
  let ti = tb_index(st, x * sw, y * sh)
  if ti >= 0 && ti < st.no_filter.length() && st.no_filter[ti] {
    return
  }
  let v = src[y * stride + x]
  if is_band {
    let k = ((v >> 3) - p.band) & 31
    if k < 4 {
      plane[y * stride + x] = clip3(v + p.offset[k], 0, 255)
    }
    return
  }
  if x + a0 < 0 ||
    x + a0 >= pw ||
    y + a1 < 0 ||
    y + a1 >= ph ||
    x + b0 < 0 ||
    x + b0 >= pw ||
    y + b1 < 0 ||
    y + b1 >= ph {
    return
  }
  let va = src[(y + a1) * stride + x + a0]
  let vb = src[(y + b1) * stride + x + b0]
  let cat = sign_i32(v - va) + sign_i32(v - vb)
  if cat != 0 {
    let k = if cat > 0 { cat + 1 } else { cat + 2 }
    plane[y * stride + x] = clip3(v + p.offset[k], 0, 255)
  }
}
