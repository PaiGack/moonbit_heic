///|
test "split_annex_b keeps the units of a real stream" {
  // The first access unit of ctu64_128x128.h265: VPS, SPS, PPS, then a slice.
  let stream = b"\x00\x00\x00\x01\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\x92\x80\x90" +
    b"\x00\x00\x01\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\xa0\x10\x20\x20\x59\x64\xa9\x24\xc2\xe0\x10\x00\x00\x3e\x80\x00\x07\x53\x00\x80" +
    b"\x00\x00\x01\x44\x01\xc1\x71\x81\xa4\x80" +
    b"\x00\x00\x01\x26\x01\xaf\x09\x40"

  let nals = @hevc.split_annex_b(stream)
  assert_eq(nals.length(), 4)
  assert_true(nals[0].nal_type() is Some(Vps))
  assert_true(nals[1].nal_type() is Some(Sps))
  assert_true(nals[2].nal_type() is Some(Pps))
  assert_true(nals[3].nal_type() is Some(IdrWRadl))
  assert_eq(nals[3].temporal_id, 0)
}

///|
test "split_annex_b drops the three-byte start code zeros" {
  // A three-byte start code directly follows a payload ending in zero bytes;
  // those zeros belong to the start code, not to the payload.
  let stream = b"\x00\x00\x01\x40\x01\x0c\x00\x00\x00\x01\x42\x01\x01"
  let nals = @hevc.split_annex_b(stream)
  assert_eq(nals.length(), 2)
  assert_eq(nals[0].rbsp.length(), 1)
  assert_eq(nals[1].rbsp.length(), 1)
}

///|
test "unescape removes emulation prevention bytes" {
  let data = b"\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00"
  let nal = @hevc.parse_nal(data).unwrap()
  // Three escapes, so three bytes fewer than the payload after the header.
  assert_eq(nal.rbsp.length(), data.length() - 2 - 3)
  assert_eq(nal.epb.length(), 3)
  assert_eq(nal.epb[0], 8)
}

///|
test "a payload handed over headerless means the same" {
  let with_header = b"\x42\x01\x01\x02\x20\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\xa0\x10\x20\x20\x4d\x96\xe9\x6f\x0b\x80\x40\x00\x00\xfa\x00\x00\x1d\x4c\x02"
  let headerless = with_header
    .exact_view(start=2, end=with_header.length())
    .to_owned()
  let a = sps_or_panic(with_header)
  let b = sps_or_panic(headerless)
  assert_eq(a.id, b.id)
  assert_eq(a.pic_width_in_luma_samples, b.pic_width_in_luma_samples)
  assert_eq(a.bit_depth_luma, b.bit_depth_luma)
}

///|
test "marshal round trips a NAL unit" {
  let data = b"\x42\x01\x01\x02\x20\x00\x00\x03\x00\x90"
  let nal = @hevc.parse_nal(data).unwrap()
  let again = @hevc.marshal_nal(nal)
  // The escaped form is what came in: the second header byte carries the
  // temporal id plus one, which is one for a still.
  assert_eq(again.to_array(), data.to_array())
}

///|
test "marshal_annex_b round trips through split_annex_b" {
  let vps = b"\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90"
  let sps = b"\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90"
  let nals = @hevc.split_annex_b(
    b"\x00\x00\x00\x01" + vps + b"\x00\x00\x00\x01" + sps,
  )
  assert_eq(nals.length(), 2)
  let back = @hevc.split_annex_b(@hevc.marshal_annex_b(nals))
  assert_eq(back.length(), 2)
  assert_eq(back[0].rbsp.to_array(), nals[0].rbsp.to_array())
  assert_eq(back[1].rbsp.to_array(), nals[1].rbsp.to_array())
}

///|
test "split_hvcc reads length prefixed units" {
  // One four-byte length then the unit, as an hvcC record frames it.
  let unit = b"\x40\x01\x0c\x01\xff\xff"
  let data = b"\x00\x00\x00\x06" + unit
  let nals = @hevc.split_hvcc(data, 4)
  assert_eq(nals.length(), 1)
  assert_true(nals[0].nal_type() is Some(Vps))
  assert_eq(nals[0].rbsp.length(), 4)
}

///|
test "split_hvcc stops at a length that runs past the data" {
  let data = b"\x00\x00\x00\xff\x40\x01"
  assert_eq(@hevc.split_hvcc(data, 4).length(), 0)
}

///|
test "a nal unit with a forbidden bit is refused" {
  // forbidden_zero_bit set.
  assert_true(@hevc.parse_nal(b"\xc0\x01") is None)
  // nuh_temporal_id_plus1 zero.
  assert_true(@hevc.parse_nal(b"\x40\x00") is None)
  // Too short for a header.
  assert_true(@hevc.parse_nal(b"\x40") is None)
}

///|
test "offsets map between the escaped and the rbsp payload" {
  let data = b"\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90"
  let nal = @hevc.parse_nal(data).unwrap()
  // Entry point offsets count bytes in the escaped payload after the header,
  // so an offset before the escape maps to itself and one past it loses a
  // byte.
  assert_eq(nal.nal_offset(6), 6)
  assert_eq(nal.rbsp_offset(7), 7)
  assert_eq(nal.rbsp_offset(9), 8)
}

///|
test "a truncated parameter set is refused rather than read past" {
  let sps = b"\x42\x01\x01\x02\x20\x00\x00\x03\x00\x90\x00\x00\x03\x00"
  let refused = try @hevc.parse_sps(sps) catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(refused)
}

///|
fn sps_or_panic(nal : Bytes) -> @hevc.SPS {
  try @hevc.parse_sps(nal) catch {
    _ => panic()
  } noraise {
    s => s
  }
}
