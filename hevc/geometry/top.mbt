// Spatial state for the CTU loop: the z-scan MinTbAddrZs table of 6.5.2, the
// neighbour-availability process of 6.4.1, qPY_PRED of 8.6.1 and reference-
// sample gathering of 8.4.4.2.2. This is the last independently verifiable
// layer below the quadtree driver: every value here is a pure derivation the
// loop reads before it decodes a bin.
//
// M3 is single-thread, single-slice, single-tile. With one tile the raster-to-
// tile-scan map rsToTs is the identity, and with a slice starting at CTB 0
// simpleAvail is true, so available() reduces to the z-scan address compare.
// Both simplifications are held value-for-value to the real upstream Go
// functions by the golden fixtures in golden.mbt.
//
// Picture dimensions arrive as Int64 (a width is a size) and are narrowed once
// here to the Int32 carrier the plane is indexed with. The z-scan addresses
// are Int32, matching the upstream []int32: for a 4032x3024 picture the
// largest is ~774144, far inside the 32-bit range. A malformed dimension is
// refused rather than reaching an unchecked array index.

///|
fn narrow_dim(v : Int64) -> Int32 {
  @safe.narrow(v) catch {
    _ => 0
  }
}

///|
/// The per-picture spatial state. `min_tb_addr` is the whole 6.5.2 table,
/// indexed by tb_index(x, y). `pic_w`/`pic_h` are the luma dimensions the
/// availability process bounds-checks against.
pub(all) struct Geometry {
  ctbs_w : Int32
  ctbs_h : Int32
  ctb_log2 : Int32
  min_tb_log2 : Int32
  min_tb_w : Int32
  min_tb_h : Int32
  pic_w : Int32
  pic_h : Int32
  min_tb_addr : Array[Int32]
}

///|
/// Build the MinTbAddrZs table of 6.5.2 for a single-tile picture (rsToTs is
/// the identity). `shift` = ctb_log2 - min_tb_log2; the low `shift` bits of the
/// min-TB coordinates are interleaved into ctb << (2*shift), exactly the
/// z-scan order 6.4.1 compares.
pub fn Geometry::new(
  pic_w : Int64,
  pic_h : Int64,
  ctb_log2 : Int32,
  min_tb_log2 : Int32,
) -> Geometry {
  let w = narrow_dim(pic_w)
  let h = narrow_dim(pic_h)
  let ctb = 1 << ctb_log2
  let ctbs_w = (w + ctb - 1) / ctb
  let ctbs_h = (h + ctb - 1) / ctb
  let shift = ctb_log2 - min_tb_log2
  let min_tb_w = ctbs_w << shift
  let min_tb_h = ctbs_h << shift
  let addr : Array[Int32] = Array::make(min_tb_w * min_tb_h, 0)
  for y in 0..<min_tb_h {
    for x in 0..<min_tb_w {
      let tb_x = x >> shift
      let tb_y = y >> shift
      let mut v = (tb_y * ctbs_w + tb_x) << (shift * 2)
      for i in 0..<shift {
        let m = 1 << i
        if (m & x) != 0 {
          v += m * m
        }
        if (m & y) != 0 {
          v += 2 * m * m
        }
      }
      addr[y * min_tb_w + x] = v
    }
  }
  {
    ctbs_w,
    ctbs_h,
    ctb_log2,
    min_tb_log2,
    min_tb_w,
    min_tb_h,
    pic_w: w,
    pic_h: h,
    min_tb_addr: addr,
  }
}

///|
/// Index into the per-min-TB arrays (min_tb_addr, and later intraMode / qpY).
pub fn Geometry::tb_index(self : Geometry, x : Int32, y : Int32) -> Int32 {
  (y >> self.min_tb_log2) * self.min_tb_w + (x >> self.min_tb_log2)
}

///|
/// 6.4.1 z-scan availability. A neighbour is available when it lies inside
/// the picture and precedes (x_curr, y_curr) in z-scan order. With a single
/// tile and a slice starting at CTB 0 (simpleAvail), tile and slice checks
/// are trivially satisfied.
pub fn Geometry::available(
  self : Geometry,
  x_curr : Int32,
  y_curr : Int32,
  x_n : Int32,
  y_n : Int32,
) -> Bool {
  if x_n < 0 || y_n < 0 || x_n >= self.pic_w || y_n >= self.pic_h {
    return false
  }
  let cur = self.tb_index(x_curr, y_curr)
  let nb = self.tb_index(x_n, y_n)
  self.min_tb_addr[nb] < self.min_tb_addr[cur]
}

///|
/// 8.6.1 qPY_PRED. Left/above QP replace qp_prev only when the neighbour is
/// available and inside the current CTB (ctbMask comparison). The caller
/// passes the already-derived availability and neighbour QP, exactly as the
/// loop does.
pub fn predict_qp(
  qp_prev : Int32,
  qp_a : Int32,
  qp_b : Int32,
  ctb_log2 : Int32,
  x : Int32,
  y : Int32,
  left_ok : Bool,
  top_ok : Bool,
) -> Int32 {
  // ~((1 << ctb_log2) - 1) == -(1 << ctb_log2).
  let mut a = qp_prev
  let mut b = qp_prev
  let mask = -(1 << ctb_log2)
  if left_ok && ((x - 1) & mask) == (x & mask) {
    a = qp_a
  }
  if top_ok && ((y - 1) & mask) == (y & mask) {
    b = qp_b
  }
  (a + b + 1) >> 1
}

///|
/// Reference samples for one intra block, after substitution. `s` holds the
/// 4*n+1 samples in the refSamples scan order (left column bottom-to-top,
/// corner, top row left-to-right); `avail` is the per-sample availability
/// BEFORE substitution.
pub(all) struct RefResult {
  s : Array[Int32]
  avail : Array[Bool]
}

///|
/// 8.4.4.2.2 gatherRef + substitute. `plane` carries the working component's
/// samples (0..255), `x`/`y`/`n` are component coordinates and size. For a
/// chroma block the coordinates are scaled back to luma (`* sub_w`/`* sub_h`)
/// before the z-scan availability lookup, exactly as upstream does.
///
/// Availability is uniform across a min-TB, so it is derived once per min-TB
/// (lastTb caching). The plane is read only where a sample is available; a
/// missing neighbour inherits its predecessor (or mid-grey 128 for 8-bit when
/// none is available).
pub fn gather_ref(
  geom : Geometry,
  plane : Array[Int32],
  stride : Int32,
  x : Int32,
  y : Int32,
  n : Int32,
  c_idx : Int32,
  sub_w : Int32,
  sub_h : Int32,
) -> RefResult {
  let sw = if c_idx > 0 { sub_w } else { 1 }
  let sh = if c_idx > 0 { sub_h } else { 1 }
  let w = geom.pic_w / sw
  let h = geom.pic_h / sh
  let size = 4 * n + 1
  let s : Array[Int32] = Array::make(size, 0)
  let avail : Array[Bool] = Array::make(size, false)
  let mut last_tb = -1
  let mut last_ok = false
  for i in 0..<size {
    let mut nx = 0
    let mut ny = 0
    if i < 2 * n {
      nx = x - 1
      ny = y + 2 * n - 1 - i
    } else if i == 2 * n {
      nx = x - 1
      ny = y - 1
    } else {
      nx = x + i - 2 * n - 1
      ny = y - 1
    }
    let mut ok = nx >= 0 && ny >= 0 && nx < w && ny < h
    if ok {
      let tb = geom.tb_index(nx * sw, ny * sh)
      if tb != last_tb {
        last_tb = tb
        last_ok = geom.available(x * sw, y * sh, nx * sw, ny * sh)
      }
      ok = last_ok
    }
    avail[i] = ok
    if ok {
      let idx = ny * stride + nx
      if idx < plane.length() {
        s[i] = plane[idx]
      }
    }
  }
  // 8.4.4.2.2 substitute.
  let mut first = -1
  for i in 0..<size {
    if avail[i] {
      first = i
      break
    }
  }
  if first < 0 {
    for i in 0..<size {
      s[i] = 128
    }
  } else {
    s[0] = s[first]
    for i = 1; i < size; i = i + 1 {
      if !avail[i] {
        s[i] = s[i - 1]
      }
    }
  }
  { s, avail, }
}
