// 2D inverse transform, 8.6.4.1. The column pass scales each 1D result by
// (v+64)>>7 and clips to the transform range, then the row pass leaves the
// residuals un-clipped. The 1D sums are the already byte-exact checked
// @dsp.naive_1d / @dsp.naive_1d_dst4; the only new arithmetic here is the
// two-pass layout and the clipping, which the upstream suite checks against
// its own independently written naiveTransform2D.

///|
/// `inverseTransform` of 8.6.4.1, scaled in place. `n` is 4/8/16/32; `dst`
/// selects the 4x4 DST (only legal for n=4); `bit_depth` is 8 for this port.
/// `extended` selects the wider transform range (off for Main 8-bit).
pub fn inverse_transform(
  coef : Array[Int32],
  n : Int32,
  dst : Bool,
  bit_depth : Int32,
  extended : Bool,
) -> Unit {
  let range = transform_range(bit_depth, extended)
  let lo : Int32 = -(1 << range)
  let hi : Int32 = (1 << range) - 1
  let mid : Array[Int32] = Array::make(n * n, 0)

  // Column pass: for each x, transform the column and scale by 1/128.
  for x in 0..<n {
    let col : Array[Int32] = Array::make(n, 0)
    for y in 0..<n {
      col[y] = coef[y * n + x]
    }
    let out = if dst { @dsp.naive_1d_dst4(col) } else { @dsp.naive_1d(col, n) }
    for y in 0..<n {
      mid[y * n + x] = clip3((out[y] + 64) >> 7, lo, hi)
    }
  }

  // Row pass: transform each row, no clipping (the residual is the result).
  for y in 0..<n {
    let row : Array[Int32] = Array::make(n, 0)
    for x in 0..<n {
      row[x] = mid[y * n + x]
    }
    let out = if dst { @dsp.naive_1d_dst4(row) } else { @dsp.naive_1d(row, n) }
    for x in 0..<n {
      coef[y * n + x] = out[x]
    }
  }
}
