///|
/// Narrow a 64-bit value to a 32-bit `Int`, reporting `Overflow` instead of
/// wrapping.
///
/// Only for values that really are 32-bit quantities at the API boundary —
/// chroma format ids, bit depths, NAL header fields. Sizes stay `Int64`.
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
/// values read off the bitstream prefer `narrow`, where a clamp hides a bad
/// stream.
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
/// `1 << bits`, as a mask, computed in 64 bits so `bits = 31` is just a mask.
pub fn bit_mask(bits : Int32) -> Int64 raise Overflow {
  guard bits >= 0 && bits <= 62 else { raise Overflow }
  (1L << bits) - 1L
}

///|
/// Shift left, reporting a shift amount the 64-bit carrier cannot hold.
pub fn shl(value : Int64, bits : Int32) -> Int64 raise Overflow {
  guard bits >= 0 && bits <= 63 else { raise Overflow }
  value << bits
}

///|
/// Logical right shift of a value whose low 32 bits are an unsigned quantity.
///
/// MoonBit's `>>` on `Int` is arithmetic, so `x >> 24` on a negative value
/// keeps the sign bits. Anything ported from Go's `uint32(x) >> n` must come
/// through here.
pub fn shr(value : Int64, bits : Int32) -> Int64 raise Overflow {
  guard bits >= 0 && bits <= 63 else { raise Overflow }
  (value & 0xFFFFFFFFL) >> bits
}
