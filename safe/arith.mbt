///|
/// `a + b`.
///
/// The operands are `Int64`, so 64-bit semantics is what the caller already
/// asked for: no range check, no narrowing, no wrap at 2^31.
pub fn add(a : Int64, b : Int64) -> Int64 {
  a + b
}

///|
/// `a - b`.
pub fn sub(a : Int64, b : Int64) -> Int64 {
  a - b
}

///|
/// `a * b`.
///
/// The canonical trap this replaces: `100000 * 100000` is `1e10`, which wraps
/// in MoonBit's 32-bit `Int` and is simply `1e10` here.
pub fn mul(a : Int64, b : Int64) -> Int64 {
  a * b
}

///|
/// `(a * b) / c` — the shape most size formulas take
/// (e.g. `width * height * 3 / 2`). The intermediate stays in 64 bits, and a
/// zero divisor is reported instead of trapping.
pub fn mul_div(a : Int64, b : Int64, c : Int64) -> Int64 raise Overflow {
  guard c != 0L else { raise Overflow }
  a * b / c
}

///|
/// Ceiling division, matching upstream's `(a + b - 1) / b` without the
/// intermediate sum.
pub fn div_ceil(a : Int64, b : Int64) -> Int64 raise Overflow {
  guard b > 0L && a >= 0L else { raise Overflow }
  let (q, r) = (a / b, a % b)
  if r == 0L {
    q
  } else {
    q + 1L
  }
}
