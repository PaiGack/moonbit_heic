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

///|
test "each_box walks a flat list and keeps payload offsets" {
  let data = b"\x00\x00\x00\x0cftypisom" + b"\x00\x00\x00\x08free"
  let walk = @heif.each_box(data, 0L)
  assert_true(walk.is_clean())
  assert_eq(walk.boxes.length(), 2)
  assert_eq(walk.boxes[0].typ, "ftyp")
  assert_eq(walk.boxes[0].payload.length(), 4)
  assert_eq(walk.boxes[0].offset, 8L)
  assert_eq(walk.boxes[1].typ, "free")
}

///|
test "each_box reads a 64-bit size" {
  // size == 1 means a largesize follows the type.
  let data = b"\x00\x00\x00\x01ftyp" +
    b"\x00\x00\x00\x00\x00\x00\x00\x14" +
    b"isomisom"
  let walk = @heif.each_box(data, 0L)
  assert_true(walk.is_clean())
  assert_eq(walk.boxes.length(), 1)
  assert_eq(walk.boxes[0].typ, "ftyp")
  // 20 - 16 header bytes.
  assert_eq(walk.boxes[0].payload.length(), 4)
}

///|
test "each_box reads size 0 as the rest of the container" {
  let data = b"\x00\x00\x00\x00mdat" + b"\xde\xad\xbe\xef"
  let walk = @heif.each_box(data, 0L)
  assert_true(walk.is_clean())
  assert_eq(walk.boxes.length(), 1)
  assert_eq(walk.boxes[0].payload.length(), 4)
}

///|
test "each_box reports a truncation instead of trapping" {
  // Declares 64 bytes, carries 4.
  let data = b"\x00\x00\x00\x40mdat" + b"\xde\xad\xbe\xef"
  let walk = @heif.each_box(data, 0L)
  assert_false(walk.is_clean())
  assert_eq(walk.boxes.length(), 0)
}

///|
test "each_box rejects a size smaller than its own header" {
  let data = b"\x00\x00\x00\x04mdat" +
    b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  let walk = @heif.each_box(data, 0L)
  assert_false(walk.is_clean())
}

///|
test "each_box skips a uuid box without naming it" {
  let data = b"\x00\x00\x00\x18uuid" +
    b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  let walk = @heif.each_box(data, 0L)
  assert_true(walk.is_clean())
  assert_eq(walk.boxes.length(), 0)
}
