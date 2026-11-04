///|
test "SOI / EOI markers match the spec" {
  assert_eq(@jpeg.soi, [0xFF, 0xD8])
  assert_eq(@jpeg.eoi, [0xFF, 0xD9])
}

///|
test "SOI detection" {
  assert_true(@jpeg.has_soi(b"\xFF\xD8\xFF\xE0"))
  assert_false(@jpeg.has_soi(b"\xFF"))
  assert_false(@jpeg.has_soi(b"\x89PNG"))
}
