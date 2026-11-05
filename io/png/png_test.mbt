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

///|
fn solid(
  w : Int64,
  h : Int64,
  r : Int32,
  g : Int32,
  b : Int32,
  a : Int32,
) -> @color.Rgba8 raise @image.TransformError {
  let data : Array[Byte] = []
  for _ in 0..<@safe.mul(@safe.mul(w, h), 4L).to_int() {
    data.push(r.to_byte())
    data.push(g.to_byte())
    data.push(b.to_byte())
    data.push(a.to_byte())
  }
  @image.rgba8(w, h, Bytes::from_array(data))
}

///|
fn find_chunk(data : Bytes, typ : Bytes) -> Bytes? {
  let mut off = 8
  while off + 12 <= data.length() {
    let mut len : Int64 = 0L
    for i in 0..<4 {
      len = len * 256L + data[off + i].to_int().to_int64()
    }
    if data[off + 4] == typ[0] &&
      data[off + 5] == typ[1] &&
      data[off + 6] == typ[2] &&
      data[off + 7] == typ[3] {
      return Some(data[off + 8:off + 8 + len.to_int()].to_owned())
    }
    off = off + 12 + len.to_int()
  }
  None
}

///|
test "CRC-32 matches the PNG spec's check value" {
  // CRC of "IEND" is the reference value 0xAE426082.
  assert_eq(@png.crc32(b"IEND"), (0xAE426082U : UInt32))
}

///|
test "encode produces a well-formed 8-bit RGBA PNG" {
  let img = solid(3L, 2L, 200, 100, 50, 255)
  let data = @png.encode(img)
  assert_true(@png.has_signature(data))
  let ihdr = find_chunk(data, b"IHDR").unwrap()
  assert_eq(ihdr.length(), 13)
  assert_eq(ihdr[8], b'\x08') // 8-bit
  assert_eq(ihdr[9], b'\x06') // RGBA
  assert_eq(ihdr[12], b'\x00') // no interlace
  assert_true(find_chunk(data, b"IDAT") is Some(_))
  assert_true(find_chunk(data, b"IEND") is Some(_))
}

///|
test "16-bit container doubles the sample width" {
  let img = solid(2L, 2L, 10, 20, 30, 255)
  let data = @png.encode(img, options={
    bit_depth: 16,
    compression_level: 6,
    icc: None,
  })
  let ihdr = find_chunk(data, b"IHDR").unwrap()
  assert_eq(ihdr[8], b'\x10')
  // Filtered scanlines: 2 rows, each 1 filter byte + 2 pixels * 8 bytes.
  let idat = find_chunk(data, b"IDAT").unwrap()
  let raw = @zlib.decompress(idat)
  assert_eq(raw.length(), 34)
  assert_eq(raw[0], b'\x01')
  assert_eq(raw[17], b'\x01')
}

///|
test "compression level is honoured" {
  let img = solid(64L, 64L, 123, 45, 67, 255)
  let l0 = @png.encode(img, options={
    bit_depth: 8,
    compression_level: 0,
    icc: None,
  })
  let l9 = @png.encode(img, options={
    bit_depth: 8,
    compression_level: 9,
    icc: None,
  })
  assert_true(l0.length() > l9.length())
}

///|
test "ICC profile lands in iCCP, verbatim after decompression" {
  let profile = b"fake-icc-profile-bytes"
  let img = solid(1L, 1L, 1, 2, 3, 4)
  let data = @png.encode(img, options={
    bit_depth: 8,
    compression_level: 6,
    icc: Some(profile),
  })
  let iccp = find_chunk(data, b"iCCP").unwrap()
  assert_eq(iccp[0], b'\x00') // empty profile name
  assert_eq(iccp[1], b'\x00') // compression method
  assert_eq(@zlib.decompress(iccp[2:]), profile)
}
