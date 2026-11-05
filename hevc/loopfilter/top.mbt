// The loop-filter layer of M3: 8.7.2 deblocking and 8.7.3 sample adaptive
// offset, the last byte-exact-verifiable computation layer below the CTU
// syntax driver. Every function is a self-contained arithmetic kernel; the
// whole-picture drivers deblock_frame / sao_frame reproduce the single-thread,
// single-slice, single-tile geometry the upstream Go uses for these passes.
//
// Samples and offsets are Int32 (the width of an 8-bit sample and of the
// spec's beta/tc/offset integers). Picture dimensions and strides are Int64
// where they are used to size a plane, then narrowed once at the allocation
// boundary in hevc/decode. A malformed dimension must never reach an
// unchecked array index: every read is guarded by an explicit bound.

///|
/// `Clip3` of 5.6 on 32-bit carriers.
fn clip3(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn abs_i32(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
fn sign_i32(v : Int32) -> Int32 {
  if v < 0 {
    -1
  } else if v > 0 {
    1
  } else {
    0
  }
}

///|
/// Table 8-10 for ChromaArrayType 1 (already checked in hevc/recon).
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

///|
/// Table 8-12: beta and tc indexed by the (clipped) QP.
let beta_table : Array[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6, 7, 8, 9, 10, 11, 12, 13, 14,
  15, 16, 17, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50,
  52, 54, 56, 58, 60, 62, 64,
]

///|
let tc_table : Array[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, 8, 9, 10, 11, 13, 14, 16, 18, 20,
  22, 24,
]

///|
/// The beta / tc pair of 8.7.2.5.3. `bit_depth` is 8 for this port, so the
/// (1 << (bitDepth-8)) scale is 1; kept as a parameter so a shift past 63 is
/// impossible to express here (bit_depth is clamped by the caller).
pub(all) struct BetaTc {
  beta : Int32
  tc : Int32
}

///|
pub fn beta_tc(
  qp : Int32,
  bs : Int32,
  beta_off_div2 : Int32,
  tc_off_div2 : Int32,
  bit_depth : Int32,
) -> BetaTc {
  let qb = clip3(qp + beta_off_div2 * 2, 0, 51)
  let qt = clip3(qp + 2 * (bs - 1) + tc_off_div2 * 2, 0, 53)
  // 8-bit: scale = 1 << (bit_depth - 8) = 1. Guard the shift anyway.
  let scale = if bit_depth <= 8 || bit_depth >= 32 {
    1
  } else {
    1 << (bit_depth - 8)
  }
  { beta: beta_table[qb] * scale, tc: tc_table[qt] * scale, }
}

///|
/// Table 8-16: the two neighbour offsets of each SAO edge class.
pub let eo_offsets : Array[(Int32, Int32, Int32, Int32)] = [
  (-1, 0, 1, 0),
  (0, -1, 0, 1),
  (-1, -1, 1, 1),
  (1, -1, -1, 1),
]
