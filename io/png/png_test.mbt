///|
test "signature is eight bytes, NUL-free except the newlines" {
  assert_eq(@png.signature.length(), 8)
  assert_eq(@png.signature[0], (0x89 : Byte))
  assert_eq(@png.signature[1], (0x50 : Byte))
}

///|
test "signature detection" {
  assert_true(@png.has_signature(@png.signature))
  assert_true(@png.has_signature(b"\x89PNG\r\n\x1a\n\x00IHDR"))
  assert_false(@png.has_signature(b"\x89PNG"))
  assert_false(@png.has_signature(b"\x89Png\r\n\x1a\n"))
}
