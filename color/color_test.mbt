///|
test "BT.709 and BT.601 luma weights differ" {
  let bt709 = @color.ColorMatrix::from_matrix_coefficients(1)
  let bt601 = @color.ColorMatrix::from_matrix_coefficients(5)
  assert_eq(bt709.kr, 2126)
  assert_eq(bt601.kr, 2990)
  assert_eq(bt709.shift, @color.matrix_shift)
}

///|
test "unknown matrix coefficients are reported" {
  assert_true(
    try {
      ignore(@color.ColorMatrix::from_matrix_coefficients(0))
      false
    } catch {
      @color.NotYetImplemented => true
    },
  )
}
