///|
/// Upstream's `hevc/getbits_test.go`, field for field: the same bytes, the same
/// expectations. The exp-Golomb reader is where a wrong shift stops being a
/// wrong number and starts being a wrong picture, so it is pinned rather than
/// covered.
test "bits are read most significant first" {
  // 0b1010_0011 0b1100_0000
  let data = b"\xa3\xc0"
  assert_eq(@hevc.bits_at(data, 0, 4), (0b1010 : UInt32))
  assert_eq(@hevc.bits_at(data, 4, 4), (0b0011 : UInt32))
  assert_eq(@hevc.bits_at(data, 8, 2), (0b11 : UInt32))
}

///|
test "ue reads the Exp-Golomb code of 9.2" {
  // 0b1010_0110 0b0100_0000 encodes 0, 1, 2, 3 in turn: 1, 010, 011, 00100.
  let data = b"\xa6\x40"
  assert_eq(@hevc.ue_seq(data, 4), [0U, 1U, 2U, 3U])
}

///|
test "se reads the signed code of 9.2" {
  let data = b"\xa6\x42\x80"
  assert_eq(@hevc.se_seq(data, 5), [0, 1, -1, 2, -2])
}

///|
test "a read past the end reports rather than wraps" {
  let data = b"\xff"
  assert_eq(@hevc.bits_at(data, 0, 8), (0xff : UInt32))
  // The second byte is not there; the reader says so instead of handing back
  // whatever the shift left behind.
  assert_true(@hevc.read_past_end(data))
}

///|
test "fourteen leading zeros is an error, not a loop" {
  // 0x00_00 is fourteen zero bits then ones: the longest code 9.2 allows is
  // what follows them, and the reader has to survive a run of zeros that long
  // without spinning.
  let zeros = b"\x00\x00\x00\x00\x00\x00\x00\x00"
  assert_true(@hevc.ue_overflows(zeros))
  // A run of zeros with no terminator at all ends at the buffer edge, and the
  // reader reports it the same way.
  assert_true(@hevc.ue_overflows(b"\x00\x00"))
}

///|
test "skip walks across the 32-bit window" {
  // Four bytes, skip two: the remaining 16 bits are what a single 64-bit
  // refill never had to see in two halves.
  assert_eq(@hevc.bits_at(b"\xde\xad\xbe\xef", 16, 16), (0xbeef : UInt32))
}

///|
test "byte alignment moves to the next boundary and stays put on one" {
  // Three bits in, then aligned, is eight.
  assert_eq(@hevc.pos_after(b"\xff\x0f", 3), 3)
  assert_eq(@hevc.pos_after(b"\xff\x0f", 8), 8)
  assert_eq(@hevc.pos_after(b"\xff\x0f", 16), 16)
}

///|
test "more_rbsp_data stops at the stop bit and at the padding behind it" {
  // 0b1010_0000: data behind the stop bit at bit 2.
  assert_true(@hevc.more_rbsp_data(b"\xa0", 0))
  assert_false(@hevc.more_rbsp_data(b"\xa0", 2))
  // A lone stop bit followed by zero bytes is the end of the structure.
  assert_false(@hevc.more_rbsp_data(b"\x80\x00\x00", 0))
  // Bytes before the last non-zero byte are data.
  assert_true(@hevc.more_rbsp_data(b"\x12\x80", 0))
  assert_false(@hevc.more_rbsp_data(b"\x12\x80", 8))
}
