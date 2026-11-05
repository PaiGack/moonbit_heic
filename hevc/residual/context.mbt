// Context derivations for residual_coding (7.3.8.11 / 9.3.4.2), transcribed
// from the spec. Each is a pure function of small integers; golden.mbt holds
// the full traversal checked value-for-value against the upstream Go.

///|
/// Scan order indices of 6.5 (kept here so the layer reads standalone).
pub let scan_diag : Int32 = 0

///|
pub let scan_hor : Int32 = 1

///|
pub let scan_ver : Int32 = 2

///|
/// Context base offsets of 9.3.2.2 (cabac_tables.go).
let ctx_last_sig_x : Int32 = 53

///|
let ctx_last_sig_y : Int32 = 71

///|
let ctx_sig_group : Int32 = 89

///|
let ctx_sig_flag : Int32 = 93

///|
let ctx_greater1 : Int32 = 137

///|
let ctx_greater2 : Int32 = 161

///|
/// `scanIndex` of 7.4.9.11: only small intra blocks depart from the diagonal
/// scan, and only for near-horizontal or near-vertical prediction modes.
pub fn scan_index(
  log2_size : Int32,
  c_idx : Int32,
  pred_mode_intra : Int32,
  intra : Bool,
  chroma_array_type : Int32,
) -> Int32 {
  if !intra {
    return scan_diag
  }
  if log2_size != 2 &&
    !(log2_size == 3 && (c_idx == 0 || chroma_array_type == 3)) {
    return scan_diag
  }
  if pred_mode_intra >= 6 && pred_mode_intra <= 14 {
    scan_ver
  } else if pred_mode_intra >= 22 && pred_mode_intra <= 30 {
    scan_hor
  } else {
    scan_diag
  }
}

///|
/// `lastSigCoeffCtx` of 9.3.4.2.3 (Table 9-43 context maps).
pub fn last_sig_coeff_ctx(
  log2_size : Int32,
  c_idx : Int32,
  bin_idx : Int32,
) -> Int32 {
  if c_idx == 0 {
    (bin_idx >> ((log2_size + 1) >> 2)) +
    3 * (log2_size - 2) +
    ((log2_size - 1) >> 2)
  } else {
    (bin_idx >> (log2_size - 2)) + 15
  }
}

///|
/// `sigCtxMap4x4` of Table 9-43, for 4x4 transform blocks.
let sig_ctx_map_4x4 : Array[Int32] = [
  0, 1, 4, 5, 2, 3, 4, 5, 6, 6, 8, 8, 7, 7, 8, 8,
]

///|
/// `sigCtxByCsbf[csbf][yP*4+xP]` of 9.3.4.2.5, built from the derivation so
/// the per-sub-block lookup below has one table read.
let sig_ctx_by_csbf : Array[Array[Int32]] = build_sig_ctx_by_csbf()

///|
fn build_sig_ctx_by_csbf() -> Array[Array[Int32]] {
  let out : Array[Array[Int32]] = []
  for csbf in 0..<4 {
    let row : Array[Int32] = Array::make(16, 0)
    for y_p in 0..<4 {
      for x_p in 0..<4 {
        let mut sig = 0
        if csbf == 0 {
          if x_p + y_p == 0 {
            sig = 2
          } else if x_p + y_p < 3 {
            sig = 1
          }
        } else if csbf == 1 {
          if y_p == 0 {
            sig = 2
          } else if y_p == 1 {
            sig = 1
          }
        } else if csbf == 2 {
          if x_p == 0 {
            sig = 2
          } else if x_p == 1 {
            sig = 1
          }
        } else {
          sig = 2
        }
        row[y_p * 4 + x_p] = sig
      }
    }
    out.push(row)
  }
  out
}

///|
/// `sigCoeffCtx` of 9.3.4.2.5, the full derivation from absolute coordinates.
/// Held to `SigCtxSet::at` in golden.mbt over every combination.
pub fn sig_coeff_ctx(
  x_c : Int32,
  y_c : Int32,
  log2_size : Int32,
  c_idx : Int32,
  scan_idx : Int32,
  prev_csbf : Int32,
) -> Int32 {
  let mut sig = 0
  if log2_size == 2 {
    sig = sig_ctx_map_4x4[y_c * 4 + x_c]
  } else if x_c + y_c != 0 {
    sig = sig_ctx_by_csbf[prev_csbf][(y_c & 3) * 4 + (x_c & 3)]
    if c_idx == 0 {
      if (x_c >> 2) + (y_c >> 2) > 0 {
        sig += 3
      }
      if log2_size == 3 {
        sig += if scan_idx == scan_diag { 9 } else { 15 }
      } else {
        sig += 21
      }
    } else {
      sig += if log2_size == 3 { 9 } else { 12 }
    }
  }
  if c_idx == 0 {
    sig
  } else {
    27 + sig
  }
}

///|
/// `sigCtxSet` of 9.3.4.2.5 with everything fixed for a sub-block resolved,
/// so a coefficient costs one table lookup and an add. `flat` is the one
/// context a transform-skip block uses throughout.
pub(all) struct SigCtxSet {
  base : Int32
  dc : Int32
  small : Int32
  prev_csbf : Int32
  is4x4 : Bool
  sb_dc : Bool
  flat : Bool
}

///|
pub fn SigCtxSet::new(
  x_s : Int32,
  y_s : Int32,
  log2_size : Int32,
  c_idx : Int32,
  scan_idx : Int32,
  prev_csbf : Int32,
  flat : Bool,
) -> SigCtxSet {
  let is4x4 = log2_size == 2
  let sb_dc = (x_s | y_s) == 0
  if flat {
    return {
      base: if c_idx != 0 {
        43
      } else {
        42
      },
      dc: 0,
      small: 0,
      prev_csbf,
      is4x4,
      sb_dc,
      flat,
    }
  }
  if c_idx != 0 {
    return {
      base: 27 + (if log2_size == 3 { 9 } else { 12 }),
      dc: 27,
      small: 27,
      prev_csbf,
      is4x4,
      sb_dc,
      flat,
    }
  }
  let mut base = if x_s + y_s > 0 { 3 } else { 0 }
  base += if log2_size == 3 {
    if scan_idx == scan_diag {
      9
    } else {
      15
    }
  } else {
    21
  }
  { base, dc: 0, small: 0, prev_csbf, is4x4, sb_dc, flat, }
}

///|
pub fn SigCtxSet::at(self : SigCtxSet, x : Int32, y : Int32) -> Int32 {
  if self.flat {
    return self.base
  }
  if self.is4x4 {
    return self.small + sig_ctx_map_4x4[y * 4 + x]
  }
  if self.sb_dc && (x | y) == 0 {
    return self.dc
  }
  self.base + sig_ctx_by_csbf[self.prev_csbf][(y & 3) * 4 + (x & 3)]
}
