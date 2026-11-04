///|
test "full box header splits version and flags" {
  let header = @heif.read_full_box_header(0x00000000U)
  assert_eq(header.version, 0)
  assert_eq(header.flags, 0)
  let header = @heif.read_full_box_header(0x01000001U)
  assert_eq(header.version, 1)
  assert_eq(header.flags, 1)
  let header = @heif.read_full_box_header(0xFF123456U)
  assert_eq(header.version, 255)
  assert_eq(header.flags, 0x123456)
}

///|
test "box type stays a four-character string" {
  let box : @heif.BoxType = "meta"
  assert_eq(box, "meta")
}
