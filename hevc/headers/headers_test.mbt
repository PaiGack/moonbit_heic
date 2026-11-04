///|
test "cropped width subtracts both conformance windows" {
  // 1920 with 8 columns off the left and 8 off the right.
  assert_eq(@headers.cropped_width(1920L, 8L, 8L), 1904L)
  assert_eq(@headers.cropped_width(64L, 0L, 0L), 64L)
}

///|
test "cropped width refuses a degenerate picture" {
  assert_true(
    try {
      ignore(@headers.cropped_width(16L, 8L, 8L))
      false
    } catch {
      @safe.Overflow => true
    },
  )
}
