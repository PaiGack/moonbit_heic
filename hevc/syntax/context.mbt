// Pure derivations the CTU syntax loop reads before it decodes a bin: the
// MPM candidate list of 8.4.2, the context indices of 9.3.4.2, the chroma
// mode maps of Tables 8-2/8-3, the chroma QP of Table 8-10, the QP wrap of
// 8.6.1 and the SAO offset range of 7.3.8.3. All are self-contained Int32
// arithmetic, held value-for-value to the real upstream Go functions by the
// golden fixtures in golden.mbt.

///|
/// 8.4.2: the three most probable luma intra modes from neighbour modes A
/// (left) and B (above). A neighbour that is not intra or sits above the CTB
/// row contributes INTRA_DC; the caller passes that value directly.
pub fn mpm_cand(cand_a : Int32, cand_b : Int32) -> Array[Int32] {
  if cand_a == cand_b && cand_a < 2 {
    [intra_planar, intra_dc, intra_ver]
  } else if cand_a == cand_b {
    [cand_a, 2 + (cand_a + 29) % 32, 2 + (cand_a - 2 + 1) % 32]
  } else {
    let mut third = intra_ver
    if cand_a != intra_planar && cand_b != intra_planar {
      third = intra_planar
    } else if cand_a != intra_dc && cand_b != intra_dc {
      third = intra_dc
    }
    [cand_a, cand_b, third]
  }
}

///|
/// 9.3.4.2.2: ctxInc for split_cu_flag. Each available neighbour whose CB
/// depth exceeds the current depth adds one, so the result is in 0..2.
pub fn split_cu_ctx(
  left_depth : Int32,
  above_depth : Int32,
  depth : Int32,
) -> Int32 {
  let mut ctx = 0
  if left_depth > depth {
    ctx += 1
  }
  if above_depth > depth {
    ctx += 1
  }
  ctx
}

///|
/// 7.4.9.11: ctx for split_transform_flag is ctxSplitTransformFlag + 5 -
/// log2Size. log2Size is a transform size in 2..5, so no shift is involved and
/// the result stays in 37..40.
pub fn split_tf_ctx(log2_size : Int32) -> Int32 {
  ctx_split_transform_flag + 5 - log2_size
}

///|
/// 7.4.9.11: ctxInc for cbf_luma is (trafoDepth == 0), i.e. the root TU uses
/// ctxCBFLuma+1 and a nested TU uses ctxCBFLuma.
pub fn cbf_luma_ctx(depth : Int32) -> Int32 {
  ctx_cbf_luma + (if depth == 0 { 1 } else { 0 })
}

///|
/// 7.4.9.11: ctx for cbf_cb / cbf_cr is ctxCBFCBCR + trafoDepth.
pub fn cbf_cbcr_ctx(depth : Int32) -> Int32 {
  ctx_cbf_cbcr + depth
}

///|
/// Table 8-3: the 4:2:2 chroma intra mode remap (indexed by luma mode 0..34).
let chroma422_map : Array[Int32] = [
  0, 1, 2, 2, 2, 2, 3, 5, 7, 8, 10, 12, 13, 15, 17, 18, 19, 20, 21, 22, 23, 23, 24,
  24, 25, 25, 26, 27, 27, 28, 28, 29, 29, 30, 31,
]

///|
pub fn chroma422(mode : Int32) -> Result[Int32, SyntaxError] {
  guard mode >= 0 && mode < chroma422_map.length() else { Err(InvalidParam) }
  Ok(chroma422_map[mode])
}

///|
/// Table 8-10 for ChromaArrayType 1 (4:2:0), indexed by clipped qPi. A qPi
/// outside 0..57 cannot reach here from a validated 8-bit Main header, but a
/// corrupt stream must still not index past the table.
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
    // q_pi - 30 is in 0..13 here.
    chroma_qp_table[q_pi - 30]
  }
}

///|
/// 8.6.1: wrap qPY_PRED + cu_qp_delta into [-QpBdOffsetY, 51]. For this
/// 8-bit port QpBdOffsetY = 0, so m = 52; bit_depth is kept as a parameter so
/// the caller can state it, and a degenerate depth is guarded.
pub fn qp_wrap(pred : Int32, delta : Int32, bit_depth : Int32) -> Int32 {
  guard bit_depth >= 8 && bit_depth <= 16 else { return pred }
  let off = 6 * (bit_depth - 8)
  let m = 52 + off
  let sum = pred + delta + 52 + 2 * off
  // Modulo that keeps the sign of a negative dividend like Go's does.
  let r = sum % m
  let wrapped = if r < 0 { r + m } else { r }
  wrapped - off
}

///|
/// 7.3.8.3: cMax for sao_offset_abs, 1 << (min(bitDepth, 10) - 5) - 1. The
/// shift is on a clamped small exponent, so it can never go past 63.
pub fn sao_offset_cmax(bit_depth : Int32) -> Int32 {
  let e = (if bit_depth < 10 { bit_depth } else { 10 }) - 5
  if e <= 0 {
    0
  } else if e >= 31 {
    0x7FFFFFFF
  } else {
    (1 << e) - 1
  }
}
