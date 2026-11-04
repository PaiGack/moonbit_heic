///|
test "context table follows the CTB area" {
  assert_eq(@cabac.context_table_size(4), 16L * 16L)
  assert_eq(@cabac.context_table_size(6), 64L * 64L)
}

///|
test "a shift the 64-bit carrier cannot hold is reported" {
  assert_true(
    try {
      ignore(@cabac.context_table_size(64))
      false
    } catch {
      @safe.Overflow => true
    },
  )
  assert_true(
    try {
      ignore(@cabac.context_table_size(-1))
      false
    } catch {
      @safe.Overflow => true
    },
  )
}
