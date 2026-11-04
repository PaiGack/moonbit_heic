///|
/// Narrow a 64-bit intermediate back to `Int`, reporting `Overflow` instead of
/// wrapping.
pub fn narrow(value : Int64) -> Int32 raise Overflow {
  if value > int_max || value < int_min {
    raise Overflow
  }
  value.to_int()
}

///|
/// Saturating variant of `narrow`: clamps to the representable range.
///
/// Use this only where the upstream code is known to tolerate clamping; for
/// parsing bitstream fields prefer `narrow`, where a clamp hides a bad stream.
pub fn clamp(value : Int64) -> Int32 {
  if value > int_max {
    int_max.to_int()
  } else if value < int_min {
    int_min.to_int()
  } else {
    value.to_int()
  }
}

///|
/// Bit widths above this cannot be represented as a shift amount for `Int`.
let max_shift : Int32 = 31

///|
/// `1 << bits`, computed in 64 bits so `bits = 31` does not go negative.
///
/// Upstream Go is full of `1 << bits` used as a mask; with MoonBit's 32-bit
/// `Int` the same expression yields a negative mask as soon as `bits` is 31.
pub fn bit_mask(bits : Int32) -> Int32 raise Overflow {
  if bits < 0 {
    raise Overflow
  }
  narrow((1L << bits) - 1L)
}

///|
/// Shift an `Int64` left, reporting `Overflow` when the result leaves the
/// range of `Int` or the shift amount is not usable.
pub fn shl(value : Int64, bits : Int32) -> Int32 raise Overflow {
  if bits < 0 || bits > max_shift {
    raise Overflow
  }
  narrow(value << bits)
}

///|
/// Logical right shift of a 32-bit value.
///
/// MoonBit's `>>` on `Int` is arithmetic, so `x >> 24` on a negative value
/// keeps the sign bits. Anything ported from Go's `uint32(x) >> n` must come
/// through here.
pub fn shr(value : Int32, bits : Int32) -> Int32 raise Overflow {
  if bits < 0 || bits > max_shift {
    raise Overflow
  }
  let wide = value.to_int64() & 0xFFFFFFFFL
  (wide >> bits).to_int()
}
