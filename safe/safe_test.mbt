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
test "@safe.narrow accepts the full Int range" {
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
test "100000 * 100000 must not wrap" {
  // Upstream Go: int is 64-bit, this is exactly 1e10.
  assert_true(
    raises(fn() raise @safe.Overflow { ignore(@safe.mul(100000, 100000)) }),
  )
  // The wrap an unguarded port would produce.
  assert_eq(100000 * 100000, 1410065408)
}

///|
test "multiplication near the boundary" {
  assert_eq(@safe.mul(46340, 46340), 2147395600)
  assert_true(
    raises(fn() raise @safe.Overflow { ignore(@safe.mul(46341, 46341)) }),
  )
  assert_eq(@safe.mul(-46340, 46340), -2147395600)
  assert_eq(@safe.mul(0, 2147483647), 0)
  assert_eq(@safe.mul(-1, 2147483647), -2147483647)
  assert_true(
    raises(fn() raise @safe.Overflow { ignore(@safe.mul(-2147483648, -1)) }),
  )
}

///|
test "addition and subtraction at the boundary" {
  assert_eq(@safe.add(2147483646, 1), 2147483647)
  assert_true(
    raises(fn() raise @safe.Overflow { ignore(@safe.add(2147483647, 1)) }),
  )
  assert_eq(@safe.sub(-2147483647, 1), -2147483648)
  assert_true(
    raises(fn() raise @safe.Overflow { ignore(@safe.sub(-2147483648, 1)) }),
  )
  // Wrapping left alone is how the naive version goes wrong.
  assert_eq(2147483647 + 1, -2147483648)
}

///|
test "@safe.mul_div keeps the intermediate in 64 bits" {
  // 4096 * 4096 = 16777216 already overflows inside a byte count * 3.
  assert_eq(@safe.mul_div(4096, 4096, 2), 8388608)
  assert_eq(@safe.mul_div(2048, 3, 2), 3072)
  assert_true(
    raises(fn() raise @safe.Overflow { ignore(@safe.mul_div(1, 1, 0)) }),
  )
  assert_true(
    raises(fn() raise @safe.Overflow { ignore(@safe.mul_div(2147483647, 2, 1)) }),
  )
  // The numerator may overflow even when the quotient does not.
  assert_eq(@safe.mul_div(2147483647, 2, 2), 2147483647)
}

///|
test "@safe.div_ceil rounds up like upstream (a+b-1)/b" {
  assert_eq(@safe.div_ceil(0, 4), 0)
  assert_eq(@safe.div_ceil(1, 4), 1)
  assert_eq(@safe.div_ceil(4, 4), 1)
  assert_eq(@safe.div_ceil(5, 4), 2)
  assert_true(
    raises(fn() raise @safe.Overflow { ignore(@safe.div_ceil(1, 0)) }),
  )
  assert_true(
    raises(fn() raise @safe.Overflow { ignore(@safe.div_ceil(-1, 4)) }),
  )
}

///|
test "@safe.bit_mask handles the 31-bit case Go gets for free" {
  assert_eq(@safe.bit_mask(0), 0)
  assert_eq(@safe.bit_mask(1), 1)
  assert_eq(@safe.bit_mask(8), 255)
  assert_eq(@safe.bit_mask(30), 1073741823)
  // `1 << 31` is negative as an Int; the mask must not be.
  assert_eq(@safe.bit_mask(31), 2147483647)
  assert_true(raises(fn() raise @safe.Overflow { ignore(@safe.bit_mask(32)) }))
  assert_true(raises(fn() raise @safe.Overflow { ignore(@safe.bit_mask(-1)) }))
}

///|
test "@safe.shl and @safe.shr agree with the 64-bit reading" {
  assert_eq(@safe.shl(1L, 0), 1)
  assert_eq(@safe.shl(1L, 30), 1073741824)
  assert_true(raises(fn() raise @safe.Overflow { ignore(@safe.shl(1L, 31)) }))
  assert_true(raises(fn() raise @safe.Overflow { ignore(@safe.shl(1L, -1)) }))
  // exp-golomb style: (1 << 6) - 1 + suffix
  assert_eq(@safe.shr(2147483647, 30), 1)
  assert_eq(@safe.shr(-1, 24), 255)
  assert_eq(@safe.shr(-2147483648, 31), 1)
  assert_true(raises(fn() raise @safe.Overflow { ignore(@safe.shr(1, 32)) }))
}

///|
test "@safe.clamp saturates instead of reporting" {
  assert_eq(@safe.clamp(1L << 40), 2147483647)
  assert_eq(@safe.clamp(-(1L << 40)), -2147483648)
  assert_eq(@safe.clamp(42L), 42)
}
