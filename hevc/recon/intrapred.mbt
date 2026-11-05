// Intra prediction, 8.4.4.2: reference-sample substitution and smoothing,
// then the three prediction shapes (Planar, DC, angular). Everything here is
// a pure function of a flat reference array `s` laid out as upstream's
// refSamples: left column bottom-to-top, corner, top row left-to-right.

///|
/// Mode numbers of 8.4.4.2.1.
pub let intra_planar : Int32 = 0

///|
pub let intra_dc : Int32 = 1

///|
pub let intra_hor : Int32 = 10

///|
pub let intra_ver : Int32 = 26

///|
/// `intraPredAngle` of Table 8-4, indexed by `mode - 2`.
let intra_pred_angle : Array[Int32] = [
  32, 26, 21, 17, 13, 9, 5, 2, 0, -2, -5, -9, -13, -17, -21, -26, -32, -26, -21,
  -17, -13, -9, -5, -2, 0, 2, 5, 9, 13, 17, 21, 26, 32,
]

///|
/// `intraInvAngle` of Table 8-5, indexed by `mode - 11`.
let intra_inv_angle : Array[Int32] = [
  -4096, -1638, -910, -630, -482, -390, -315, -256, -315, -390, -482, -630, -910,
  -1638, -4096,
]

///|
/// The flat reference samples of 8.4.4.2.2. `s` holds `4*n+1` samples in the
/// scan order; `n` is the block size. Methods mirror the upstream accessors so
/// a substitution or smoothing bug is visible at one index.
pub(all) struct RefSamples {
  mut s : Array[Int32]
  n : Int32
}

///|
pub fn RefSamples::new(n : Int32, s : Array[Int32]) -> RefSamples {
  { s, n, }
}

///|
pub fn RefSamples::corner(self : RefSamples) -> Int32 {
  self.s[2 * self.n]
}

///|
pub fn RefSamples::top(self : RefSamples, x : Int32) -> Int32 {
  self.s[2 * self.n + 1 + x]
}

///|
pub fn RefSamples::left(self : RefSamples, y : Int32) -> Int32 {
  self.s[2 * self.n - 1 - y]
}

///|
fn RefSamples::set_top(self : RefSamples, x : Int32, v : Int32) -> Unit {
  self.s[2 * self.n + 1 + x] = v
}

///|
fn RefSamples::set_left(self : RefSamples, y : Int32, v : Int32) -> Unit {
  self.s[2 * self.n - 1 - y] = v
}

///|
/// `substitute` of 8.4.4.2.2, scaled in place. `avail` runs in the same order
/// as `s`. When no neighbour is available every sample becomes the mid-grey
/// `1 << (bit_depth-1)`; otherwise the first available value is copied to the
/// front and each gap inherits its predecessor.
pub fn RefSamples::substitute(
  self : RefSamples,
  avail : Array[Bool],
  bit_depth : Int32,
) -> Unit {
  let size = 4 * self.n + 1
  let mut first = -1
  for i = 0; i < size; i = i + 1 {
    if avail[i] {
      first = i
      break
    }
  }
  if first < 0 {
    let v = 1 << (bit_depth - 1)
    for i = 0; i < size; i = i + 1 {
      self.s[i] = v
    }
    return
  }
  self.s[0] = self.s[first]
  for i = 1; i < size; i = i + 1 {
    if !avail[i] {
      self.s[i] = self.s[i - 1]
    }
  }
}

///|
/// `filterFlag` of 8.4.4.2.3. `chroma_array_type` is 1 for the 4:2:0 this
/// port decodes; chroma planes are not smoothed unless it is 3 (4:4:4).
pub fn filter_flag(
  mode : Int32,
  n : Int32,
  c_idx : Int32,
  chroma_array_type : Int32,
) -> Bool {
  if c_idx != 0 && chroma_array_type != 3 {
    return false
  }
  if mode == intra_dc || n == 4 {
    return false
  }
  let thres = match n {
    8 => 7
    16 => 1
    32 => 0
    _ => return false
  }
  let d = if abs(mode - intra_ver) < abs(mode - intra_hor) {
    abs(mode - intra_ver)
  } else {
    abs(mode - intra_hor)
  }
  d > thres
}

///|
/// `filterRef` of 8.4.4.2.3, scaled in place. Strong intra smoothing replaces
/// the top/left rows with a linear ramp when the 32x32 luma neighbourhood is
/// flat; otherwise a three-tap [1 2 1]/4 filter runs over the interior.
pub fn RefSamples::filter_ref(
  self : RefSamples,
  mode : Int32,
  c_idx : Int32,
  bit_depth : Int32,
  chroma_array_type : Int32,
  strong_intra_smoothing : Bool,
  intra_smoothing_disabled : Bool,
) -> Unit {
  if intra_smoothing_disabled ||
    !filter_flag(mode, self.n, c_idx, chroma_array_type) {
    return
  }
  let n = self.n
  if strong_intra_smoothing && c_idx == 0 && n == 32 {
    let lim = 1 << (bit_depth - 5)
    let flat_top = abs(
        self.corner() + self.top(2 * n - 1) - 2 * self.top(n - 1),
      ) <
      lim
    let flat_left = abs(
        self.corner() + self.left(2 * n - 1) - 2 * self.left(n - 1),
      ) <
      lim
    if flat_top && flat_left {
      let c = self.corner()
      let tr = self.top(2 * n - 1)
      let bl = self.left(2 * n - 1)
      for i = 0; i < 2 * n - 1; i = i + 1 {
        self.set_left(i, ((63 - i) * c + (i + 1) * bl + 32) >> 6)
        self.set_top(i, ((63 - i) * c + (i + 1) * tr + 32) >> 6)
      }
      return
    }
  }
  let f : Array[Int32] = Array::make(4 * n + 1, 0)
  f[0] = self.s[0]
  f[4 * n] = self.s[4 * n]
  for i = 1; i < 4 * n; i = i + 1 {
    f[i] = (self.s[i - 1] + 2 * self.s[i] + self.s[i + 1] + 2) >> 2
  }
  for i = 0; i < 4 * n + 1; i = i + 1 {
    self.s[i] = f[i]
  }
}

///|
/// `predPlanar` of 8.4.4.2.5.
fn RefSamples::pred_planar(self : RefSamples) -> Array[Int32] {
  let n = self.n
  let shift = log2_int(n) + 1
  let tr = self.top(n)
  let bl = self.left(n)
  let dst = Array::make(n * n, 0)
  for y = 0; y < n; y = y + 1 {
    let l = self.left(y)
    for x = 0; x < n; x = x + 1 {
      dst[y * n + x] = (
          (n - 1 - x) * l +
          (x + 1) * tr +
          (n - 1 - y) * self.top(x) +
          (y + 1) * bl +
          n
        ) >>
        shift
    }
  }
  dst
}

///|
/// `predDC` of 8.4.4.2.4.
fn RefSamples::pred_dc(self : RefSamples, c_idx : Int32) -> Array[Int32] {
  let n = self.n
  let mut sum = 0
  for i = 0; i < n; i = i + 1 {
    sum += self.top(i) + self.left(i)
  }
  let dc = (sum + n) >> (log2_int(n) + 1)
  let dst = Array::make(n * n, dc)
  if c_idx != 0 || n >= 32 {
    return dst
  }
  dst[0] = (self.left(0) + 2 * dc + self.top(0) + 2) >> 2
  for x = 1; x < n; x = x + 1 {
    dst[x] = (self.top(x) + 3 * dc + 2) >> 2
  }
  for y = 1; y < n; y = y + 1 {
    dst[y * n] = (self.left(y) + 3 * dc + 2) >> 2
  }
  dst
}

///|
/// `predAngular` of 8.4.4.2.6 plus `finishAngular`'s boundary smoothing for
/// pure vertical/horizontal modes on luma blocks below 32.
fn RefSamples::pred_angular(
  self : RefSamples,
  mode : Int32,
  c_idx : Int32,
  bit_depth : Int32,
) -> Array[Int32] {
  let n = self.n
  let angle = intra_pred_angle[mode - 2]
  let vertical = mode >= 18
  let base = 2 * n
  let pred_ref : Array[Int32] = Array::make(3 * 32 * 2, 0)
  let m = if angle >= 0 { 2 * n } else { n }
  if vertical {
    for x = 0; x <= m; x = x + 1 {
      pred_ref[base + x] = self.s[base + x]
    }
  } else {
    pred_ref[base] = self.s[base]
    for x = 1; x <= m; x = x + 1 {
      pred_ref[base + x] = self.s[base - x]
    }
  }
  if angle < 0 {
    let lim = (n * angle) >> 5
    if lim < -1 {
      let inv = intra_inv_angle[mode - 11]
      let mut x = -1
      while x >= lim {
        let i = (x * inv + 128) >> 8
        pred_ref[base + x] = if i == 0 {
          self.s[base]
        } else if vertical {
          self.s[base - i]
        } else {
          self.s[base + i]
        }
        x = x - 1
      }
    }
  }
  let dst = Array::make(n * n, 0)
  for b = 0; b < n; b = b + 1 {
    let idx = ((b + 1) * angle) >> 5
    let fact = ((b + 1) * angle) & 31
    for a = 0; a < n; a = a + 1 {
      let v = if fact != 0 {
        (
          (32 - fact) * pred_ref[base + idx + 1 + a] +
          fact * pred_ref[base + idx + 2 + a] +
          16
        ) >>
        5
      } else {
        pred_ref[base + idx + 1 + a]
      }
      if vertical {
        dst[b * n + a] = v
      } else {
        dst[a * n + b] = v
      }
    }
  }
  if c_idx != 0 || n >= 32 {
    return dst
  }
  let max_v = (1 << bit_depth) - 1
  if mode == intra_ver {
    for y = 0; y < n; y = y + 1 {
      dst[y * n] = clip3(
        self.top(0) + ((self.left(y) - self.corner()) >> 1),
        0,
        max_v,
      )
    }
  }
  if mode == intra_hor {
    for x = 0; x < n; x = x + 1 {
      dst[x] = clip3(
        self.left(0) + ((self.top(x) - self.corner()) >> 1),
        0,
        max_v,
      )
    }
  }
  dst
}

///|
/// `intraPredict` of 8.4.4.2.4-8.4.4.2.6, dispatching on the mode. Returns a
/// fresh `n*n` array of predicted sample values (0..2^bit_depth-1 on a valid
/// stream); the caller clips into its pixel plane.
pub fn intra_predict(
  r : RefSamples,
  mode : Int32,
  c_idx : Int32,
  bit_depth : Int32,
) -> Array[Int32] {
  if mode == intra_planar {
    r.pred_planar()
  } else if mode == intra_dc {
    r.pred_dc(c_idx)
  } else {
    r.pred_angular(mode, c_idx, bit_depth)
  }
}

///|
/// `chromaQP` of Table 8-10 for ChromaArrayType 1 (4:2:0). `q_pi` is clipped
/// to 0..57 by the caller before the table lookup; values outside the table's
/// domain are returned by the two linear branches.
let chroma_qp_table : Array[Int32] = [
  29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37,
]

///|
pub fn chroma_qp(q_pi : Int32, chroma_array_type : Int32) -> Int32 {
  if chroma_array_type != 1 {
    if q_pi > 51 {
      51
    } else {
      q_pi
    }
  } else if q_pi < 30 {
    q_pi
  } else if q_pi > 43 {
    q_pi - 6
  } else {
    chroma_qp_table[q_pi - 30]
  }
}
