// 7.4.5 ScalingFactor derivation: the eight-by-eight scaling-list matrices
// the header parser produces are replicated across larger transform sizes,
// and the 16x16 / 32x32 DC coefficients override position zero. The CTU
// reconstruction picks one matrix per (log2Size, cIdx) and passes it to
// @recon.dequant as the per-coefficient factor `m`; a flat list is `None`.

///|
/// One scaling matrix, as a flat row-major n*n array of Int32 factors.
pub(all) struct ScalingFactors {
  size_id : Int32
  matrix_id : Int32
  n : Int32
  factor : Array[Int32]
}

///|
/// 7.4.5: `sl[size_id][matrix_id]` replicated to (4 << size_id)^2, with
/// `dc[size_id-2][matrix_id]` at position zero for the two largest sizes.
/// Returns one ScalingFactors per (size_id 0..3, matrix_id 0..5), i.e. 24
/// matrices, in the same [size_id][matrix_id] order as the upstream Go.
pub fn ScalingList::factors(self : ScalingList) -> Array[Array[ScalingFactors]] {
  let out : Array[Array[ScalingFactors]] = []
  for size_id in 0..<max_scaling_list_sizes {
    let n = 4 << size_id
    let rep = if n >= 8 { n / 8 } else { 1 }
    let mats : Array[ScalingFactors] = []
    for matrix_id in 0..<max_scaling_list_mats {
      let f : Array[Int32] = Array::make(n * n, 0)
      if size_id == 0 {
        for i in 0..<16 {
          f[i] = self.sl[0][matrix_id][i]
        }
      } else {
        for y in 0..<n {
          for x in 0..<n {
            f[y * n + x] = self.sl[size_id][matrix_id][y / rep * 8 + x / rep]
          }
        }
        if size_id > 1 {
          f[0] = self.dc[size_id - 2][matrix_id]
        }
      }
      mats.push({ size_id, matrix_id, n, factor: f, })
    }
    out.push(mats)
  }
  out
}

///|
/// 8.6.3's `scalingFactor` selection of 7.4.5: the matrix for one transform
/// block. `cur_intra` is true for every M3 I slice. A skipped transform of
/// size > 4x4 uses no scaling list (returns None). `scaling_on` reflects
/// `scaling_list_enabled_flag`; when off, the flat-16 default is used (None).
pub fn scaling_factor(
  factors : Array[Array[ScalingFactors]],
  log2_size : Int32,
  c_idx : Int32,
  skip : Bool,
  cur_intra : Bool,
  scaling_on : Bool,
) -> Array[Int32]? {
  if !scaling_on || (skip && log2_size > 2) {
    return None
  }
  let size_id = log2_size - 2
  if size_id < 0 || size_id >= factors.length() {
    return None
  }
  let mut matrix_id = c_idx
  if !cur_intra {
    matrix_id += 3
  }
  if size_id == 3 && c_idx > 0 {
    matrix_id = if cur_intra { 0 } else { 3 }
  }
  if matrix_id < 0 || matrix_id >= factors[size_id].length() {
    return None
  }
  Some(factors[size_id][matrix_id].factor)
}
