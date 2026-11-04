///|
test "cropped width subtracts both conformance windows" {
  // 1920 with 8 columns off the left and 8 off the right.
  assert_eq(@headers.cropped_width(1920, 8, 8), 1904)
  assert_eq(@headers.cropped_width(64, 0, 0), 64)
}

///|
test "cropped width refuses a degenerate picture" {
  assert_true(
    try {
      ignore(@headers.cropped_width(16, 8, 8))
      false
    } catch {
      @safe.Overflow => true
    },
  )
}
