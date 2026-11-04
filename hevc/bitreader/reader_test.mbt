///|
test "reads bits MSB first across bytes" {
  let reader = @bitreader.BitReader::new(b"\xAA\x0F")
  assert_true(reader.read_bit())
  assert_false(reader.read_bit())
  assert_eq(reader.read_bits(6), (0b101010 : UInt32))
  assert_eq(reader.read_bits(8), (0x0F : UInt32))
  assert_eq(reader.remaining(), 0)
}

///|
test "stops at the end instead of reading past it" {
  let reader = @bitreader.BitReader::new(b"\xFF")
  assert_eq(reader.read_bits(8), (0xFF : UInt32))
  assert_true(
    try {
      ignore(reader.read_bit())
      false
    } catch {
      @bitreader.EndOfStream => true
    },
  )
}

///|
test "rejects impossible widths" {
  let reader = @bitreader.BitReader::new(b"\x00\x00\x00\x00\x00")
  assert_true(
    try {
      ignore(reader.read_bits(33))
      false
    } catch {
      @bitreader.Overflow => true
      _ => false
    },
  )
}
