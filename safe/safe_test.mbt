///|
/// Run `f` and report whether it raised `@safe.Overflow` rather than some
/// other error.
fn raises(f : () -> Unit raise @safe.Overflow) -> Bool {
  try {
    f()
    false
  } catch {
    @safe.Overflow => true
  }
}

///|
test "@safe.narrow keeps the full 32-bit range" {
  assert_eq(@safe.narrow(@safe.int_max), 2147483647)
  assert_eq(@safe.narrow(@safe.int_min), -2147483648)
  assert_eq(@safe.narrow(0L), 0)
}

///|
test "@safe.narrow reports overflow just past the range" {
  for value in [2147483648L, -2147483649L, 1L << 40, -(1L << 40)] {
    assert_true(
      raises(fn() raise @safe.Overflow { ignore(@safe.narrow(value)) }),
    )
  }
}

///|
test "100000 * 100000 no longer wraps" {
  // Upstream Go: int is 64-bit, this is exactly 1e10. The old 32-bit port
  // wrapped to 1410065408; Int64 arithmetic just answers.
  assert_eq(@safe.mul(100000L, 100000L), 10000000000L)
  // The wrap an unguarded 32-bit version produced, kept as a counterexample.
  assert_eq(100000 * 100000, 1410065408)
}

///|
test "multiplication past the old 32-bit ceiling is ordinary" {
  assert_eq(@safe.mul(46340L, 46340L), 2147395600L)
  assert_eq(@safe.mul(46341L, 46341L), 2147488281L)
  assert_eq(@safe.mul(-46340L, 46340L), -2147395600L)
  assert_eq(@safe.mul(0L, 2147483647L), 0L)
  assert_eq(@safe.mul(-1L, 9223372036854775807L), -9223372036854775807L)
}

///|
test "addition and subtraction carry through the old boundary" {
  assert_eq(@safe.add(2147483647L, 1L), 2147483648L)
  assert_eq(@safe.sub(-2147483648L, 1L), -2147483649L)
  // Wrapping left alone is how the naive version goes wrong.
  assert_eq(2147483647 + 1, -2147483648)
}

///|
test "@safe.mul_div keeps the intermediate in 64 bits" {
  assert_eq(@safe.mul_div(4096L, 4096L, 2L), 8388608L)
  assert_eq(@safe.mul_div(2048L, 3L, 2L), 3072L)
  // A numerator far past 32 bits that divides back into range.
  assert_eq(@safe.mul_div(4294967296L, 2L, 2L), 4294967296L)
  assert_true(
    raises(fn() raise @safe.Overflow { ignore(@safe.mul_div(1L, 1L, 0L)) }),
  )
}

///|
test "@safe.div_ceil rounds up like upstream (a+b-1)/b" {
  assert_eq(@safe.div_ceil(0L, 4L), 0L)
  assert_eq(@safe.div_ceil(1L, 4L), 1L)
  assert_eq(@safe.div_ceil(4L, 4L), 1L)
  assert_eq(@safe.div_ceil(5L, 4L), 2L)
  // The sum never wraps, so huge operands are fine.
  assert_eq(@safe.div_ceil(9223372036854775807L, 2L), 4611686018427387904L)
  assert_true(
    raises(fn() raise @safe.Overflow { ignore(@safe.div_ceil(1L, 0L)) }),
  )
  assert_true(
    raises(fn() raise @safe.Overflow { ignore(@safe.div_ceil(-1L, 4L)) }),
  )
}

///|
test "@safe.bit_mask covers the 31-bit case Go gets for free" {
  assert_eq(@safe.bit_mask(0), 0L)
  assert_eq(@safe.bit_mask(1), 1L)
  assert_eq(@safe.bit_mask(8), 255L)
  assert_eq(@safe.bit_mask(30), 1073741823L)
  // `1 << 31` is negative as an Int; the mask must not be.
  assert_eq(@safe.bit_mask(31), 2147483647L)
  assert_eq(@safe.bit_mask(32), 4294967295L)
  assert_true(raises(fn() raise @safe.Overflow { ignore(@safe.bit_mask(63)) }))
  assert_true(raises(fn() raise @safe.Overflow { ignore(@safe.bit_mask(-1)) }))
}

///|
test "@safe.shl and @safe.shr agree with the 64-bit reading" {
  assert_eq(@safe.shl(1L, 0), 1L)
  assert_eq(@safe.shl(1L, 30), 1073741824L)
  assert_eq(@safe.shl(1L, 31), 2147483648L)
  assert_eq(@safe.shl(1L, 63), -9223372036854775808L)
  assert_true(raises(fn() raise @safe.Overflow { ignore(@safe.shl(1L, 64)) }))
  assert_true(raises(fn() raise @safe.Overflow { ignore(@safe.shl(1L, -1)) }))
  assert_eq(@safe.shr(2147483647L, 30), 1L)
  assert_eq(@safe.shr(-1L, 24), 255L)
  assert_eq(@safe.shr(-2147483648L, 31), 1L)
  assert_true(raises(fn() raise @safe.Overflow { ignore(@safe.shr(1L, 64)) }))
}

///|
test "@safe.clamp saturates instead of reporting" {
  assert_eq(@safe.clamp(1L << 40), 2147483647)
  assert_eq(@safe.clamp(-(1L << 40)), -2147483648)
  assert_eq(@safe.clamp(42L), 42)
}
