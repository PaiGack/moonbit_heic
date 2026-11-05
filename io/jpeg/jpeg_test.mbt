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

///|
fn solid(
  w : Int64,
  h : Int64,
  r : Int32,
  g : Int32,
  b : Int32,
) -> @color.Rgba8 raise @image.TransformError {
  let data : Array[Byte] = []
  for _ in 0..<@safe.mul(@safe.mul(w, h), 4L).to_int() {
    data.push(r.to_byte())
    data.push(g.to_byte())
    data.push(b.to_byte())
    data.push(b'\xFF')
  }
  @image.rgba8(w, h, Bytes::from_array(data))
}

///|
fn find_marker(data : Bytes, code : Int32) -> Bytes? {
  let mut off = 2
  while off + 4 <= data.length() {
    if data[off] != b'\xFF' {
      off += 1
      continue
    }
    let c = data[off + 1].to_int()
    if c == 0xD9 {
      return None
    }
    let len = data[off + 2].to_int() * 256 + data[off + 3].to_int()
    if c == code {
      return Some(data[off + 4:off + 2 + len].to_owned())
    }
    off += 2 + len
  }
  None
}

///|
test "standard tables are complete" {
  assert_eq(@jpeg.zigzag.length(), 64)
  assert_eq(@jpeg.quant_luma.length(), 64)
  assert_eq(@jpeg.quant_chroma.length(), 64)
  assert_eq(@jpeg.ac_luma_values.length(), 162)
  assert_eq(@jpeg.ac_chroma_values.length(), 162)
  let mut sum = 0
  for n in @jpeg.dc_luma_bits {
    sum += n
  }
  assert_eq(sum, 12)
}

///|
test "encode produces SOI, JFIF, DQT, SOF0, DHT, SOS and EOI" {
  let img = solid(8L, 8L, 200, 100, 50)
  let data = @jpeg.encode(img)
  assert_true(@jpeg.has_soi(data))
  assert_eq(data[data.length() - 2], b'\xFF')
  assert_eq(data[data.length() - 1], b'\xD9')
  assert_true(find_marker(data, 0xE0) is Some(_)) // APP0 JFIF
  assert_true(find_marker(data, 0xDB) is Some(_)) // DQT
  let sof0 = find_marker(data, 0xC0).unwrap()
  assert_eq(sof0[0], b'\x08') // precision
  assert_eq(sof0[5], b'\x03') // 3 components
  assert_true(find_marker(data, 0xC4) is Some(_)) // DHT
  assert_true(find_marker(data, 0xDA) is Some(_)) // SOS
}

///|
test "quality changes quantisation and output size" {
  let img : @color.Rgba8 = {
    let data : Array[Byte] = []
    for i in 0..<(16 * 16) {
      data.push((i % 256).to_byte())
      data.push((i * 3 % 256).to_byte())
      data.push((i * 7 % 256).to_byte())
      data.push(b'\xFF')
    }
    @image.rgba8(16L, 16L, Bytes::from_array(data))
  }
  let lo = @jpeg.encode(img, options={ quality: 10, icc: None, })
  let hi = @jpeg.encode(img, options={ quality: 95, icc: None, })
  assert_true(hi.length() > lo.length())
  let dqt_lo = find_marker(lo, 0xDB).unwrap()
  let dqt_hi = find_marker(hi, 0xDB).unwrap()
  assert_true(dqt_lo != dqt_hi)
}

///|
test "ICC profile travels in APP2, verbatim" {
  let profile = b"a-fake-icc-profile"
  let img = solid(1L, 1L, 1, 2, 3)
  let data = @jpeg.encode(img, options={ quality: 85, icc: Some(profile), })
  let app2 = find_marker(data, 0xE2).unwrap()
  assert_eq(app2[0:12], b"ICC_PROFILE\x00")
  assert_eq(app2[12], b'\x01') // sequence number
  assert_eq(app2[13], b'\x01') // sequence count
  assert_eq(app2[14:], profile)
}

///|
test "0xFF bytes in entropy data are stuffed" {
  let img = solid(16L, 16L, 255, 255, 255)
  let data = @jpeg.encode(img, options={ quality: 100, icc: None, })
  // Find the end of the SOS header: after it, every literal 0xFF must be
  // followed by 0x00, except the final EOI marker.
  let mut off = 2
  let mut scan_start = 0
  while off + 4 <= data.length() {
    if data[off] == b'\xFF' && data[off + 1].to_int() == 0xDA {
      let len = data[off + 2].to_int() * 256 + data[off + 3].to_int()
      scan_start = off + 2 + len
      break
    }
    if data[off] == b'\xFF' {
      let len = data[off + 2].to_int() * 256 + data[off + 3].to_int()
      off += 2 + len
    } else {
      off += 1
    }
  }
  assert_true(scan_start > 0)
  let mut found_eoi = false
  for i in scan_start..<(data.length() - 1) {
    if data[i] == b'\xFF' {
      let next = data[i + 1].to_int()
      if next == 0xD9 {
        found_eoi = true
        break
      }
      assert_eq(next, 0x00)
    }
  }
  assert_true(found_eoi)
}

///|
test "pure white/black blocks stay deterministic" {
  let a = @jpeg.encode(solid(8L, 8L, 255, 255, 255))
  let b = @jpeg.encode(solid(8L, 8L, 255, 255, 255))
  assert_eq(a, b)
  let black = @jpeg.encode(solid(8L, 8L, 0, 0, 0))
  assert_true(black.length() > 0)
  assert_true(a.length() > 0)
}
