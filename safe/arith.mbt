///|
/// `a + b` with overflow reported.
pub fn add(a : Int32, b : Int32) -> Int32 raise Overflow {
  narrow(a.to_int64() + b.to_int64())
}

///|
/// `a - b` with overflow reported.
pub fn sub(a : Int32, b : Int32) -> Int32 raise Overflow {
  narrow(a.to_int64() - b.to_int64())
}

///|
/// `a * b` with overflow reported.
///
/// The canonical trap: `100000 * 100000` is `1e10`, which fits in Go's `int`
/// and wraps in MoonBit's.
pub fn mul(a : Int32, b : Int32) -> Int32 raise Overflow {
  narrow(a.to_int64() * b.to_int64())
}

///|
/// `(a * b) / c` computed entirely in 64 bits — the shape most size formulas
/// in the decoder take (e.g. `width * height * 3 / 2`).
pub fn mul_div(a : Int32, b : Int32, c : Int32) -> Int32 raise Overflow {
  if c == 0 {
    raise Overflow
  }
  narrow(a.to_int64() * b.to_int64() / c.to_int64())
}

///|
/// Ceiling division, matching upstream's `(a + b - 1) / b`.
pub fn div_ceil(a : Int32, b : Int32) -> Int32 raise Overflow {
  if b <= 0 || a < 0 {
    raise Overflow
  }
  let (q, r) = (a / b, a % b)
  if r == 0 {
    q
  } else {
    add(q, 1)
  }
}
