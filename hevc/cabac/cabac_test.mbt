///|
test "context table follows the CTB area" {
  assert_eq(@cabac.context_table_size(4), 16 * 16)
  assert_eq(@cabac.context_table_size(6), 64 * 64)
}

///|
test "an impossible CTB log2 is reported, not wrapped" {
  assert_true(
    try {
      ignore(@cabac.context_table_size(31))
      false
    } catch {
      @safe.Overflow => true
    },
  )
}
