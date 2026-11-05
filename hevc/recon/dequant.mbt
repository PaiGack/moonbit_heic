// Dequantisation, 8.6.3. Every product is carried in Int64: a coefficient is
// fifteen bits, the scaling matrix entry eight, and levelScale<<qp/6 up to
// seven more -- the sum is thirty bits, and the rounding addend plus a large
// qp pushes it past 2^31. A 32-bit port wraps exactly where a real residual
// has energy, which is why the upstream Go keeps this in int64.

///|
/// `levelScale` of Table 8-9, indexed by `qp % 6`.
let level_scale : Array[Int64] = [40L, 45L, 51L, 57L, 64L, 72L]

///|
/// `transformRange` of 8.6.3. M3 is 8-bit without extended precision, so the
/// range is the constant 15; the argument is kept so the call site reads the
/// way the spec does and a future 10-bit port has one place to widen.
fn transform_range(bit_depth : Int32, extended : Bool) -> Int32 {
  if !extended {
    15
  } else {
    let v = bit_depth + 6
    if v > 15 {
      v
    } else {
      15
    }
  }
}

///|
/// `dequant` of 8.6.3, scaled in place. `m` is the per-coefficient scaling
/// factor from the scaling list; `None` means the flat-16 default. `qp` is
/// `Qp'Y`/`Qp'C`, `bit_depth` is 8 for this port, `n` the transform size.
///
/// The `Int64` carrier is the point: `coef * m * (levelScale << qp/6) + rnd`
/// is a 64-bit product, and clipping is applied to that same 64-bit value
/// before narrowing, exactly as upstream does. `shift - qp/6` is never
/// folded into a 32-bit fast path here; the arithmetic is the definition.
pub fn dequant(
  coef : Array[Int32],
  m : Array[Int32]?,
  n : Int32,
  qp : Int32,
  bit_depth : Int32,
  extended : Bool,
) -> Unit {
  // Structurally bounded by the validated headers (qp in 0..51, n in
  // {4,8,16,32}), but public: a stray caller must not drive a shift past 63
  // or a negative shift into a trap. Leave the coefficients untouched.
  if qp < 0 || qp > 63 || n < 4 || n > 32 {
    return
  }
  let range = transform_range(bit_depth, extended)
  let shift = bit_depth + log2_int(n) + 10 - range
  let lo : Int64 = -(1L << range)
  let hi : Int64 = (1L << range) - 1L
  let scale = level_scale[qp % 6] << (qp / 6)
  let rnd : Int64 = 1L << (shift - 1)
  let flat = match m {
    None => true
    Some(_) => false
  }
  for i in 0..<coef.length() {
    let c = coef[i]
    if c == 0 {
      continue
    }
    let mm : Int64 = if flat { 16L } else { m.unwrap()[i].to_int64() }
    let v : Int64 = (@safe.mul(c.to_int64(), mm) * scale + rnd) >> shift
    coef[i] = if v < lo {
      lo.to_int()
    } else if v > hi {
      hi.to_int()
    } else {
      v.to_int()
    }
  }
}
