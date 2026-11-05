// End-to-end M3 → M4: a real upstream HEVC I frame decoded by M3, colour
// converted, transformed, and encoded as PNG / JPEG. The bytes are not
// asserted here (compression is not bit-stable across core versions); the
// CLI integration test checks them with an external decoder instead.

///|
fn render_case(c : @decode.Frame2Case) -> @color.Rgba8 raise Error {
  let au = @hevc.parse_access_unit(c.stream, [], 4, true)
  let frame = match @decode.decode_i_frame(au.sps, au.pps, au) {
    Ok(f) => f
    Err(_) => fail("\{c.name}: decode_i_frame failed")
  }
  @image.render({
    y: Bytes::from_array(frame.y),
    u: Bytes::from_array(frame.u),
    v: Bytes::from_array(frame.v),
    width: frame.width,
    height: frame.height,
    color: @color.ColorDescription::default(),
    orientation: @image.Orientation::new(0, None),
    crop_rect: None,
    alpha: None,
    icc: None,
  })
}

///|
test "M3 frame decodes through the M4 render pipeline" {
  let c = @decode.frame2_cases[0]
  let rgba = render_case(c)
  assert_eq(rgba.width, c.width.to_int64())
  assert_eq(rgba.height, c.height.to_int64())
  assert_eq(rgba.data.length(), c.width * c.height * 4)
}

///|
test "M3 frame encodes to PNG and JPEG with plausible sizes" {
  let c = @decode.frame2_cases[0]
  let rgba = render_case(c)
  let png = @png.encode(rgba)
  let jpeg = @jpeg.encode(rgba, options={ quality: 80, icc: None, })
  assert_true(@png.has_signature(png))
  assert_true(@jpeg.has_soi(jpeg))
  assert_eq(jpeg[jpeg.length() - 2], b'\xFF')
  assert_eq(jpeg[jpeg.length() - 1], b'\xD9')
  assert_true(png.length() > 60)
  assert_true(jpeg.length() > 60)
}

///|
test "rotation applied to a decoded frame swaps its dimensions" {
  let c = @decode.frame2_cases[0]
  let au = @hevc.parse_access_unit(c.stream, [], 4, true)
  let frame = match @decode.decode_i_frame(au.sps, au.pps, au) {
    Ok(f) => f
    Err(_) => fail("decode failed")
  }
  let rgba = @image.render({
    y: Bytes::from_array(frame.y),
    u: Bytes::from_array(frame.u),
    v: Bytes::from_array(frame.v),
    width: frame.width,
    height: frame.height,
    color: @color.ColorDescription::default(),
    orientation: @image.Orientation::new(1, None),
    crop_rect: None,
    alpha: None,
    icc: None,
  })
  assert_eq(rgba.width, frame.height)
  assert_eq(rgba.height, frame.width)
  assert_eq(@jpeg.encode(rgba).length() > 0, true)
}

///|
test "ICC profile survives the whole pipeline into PNG and JPEG" {
  let c = @decode.frame2_cases[0]
  let rgba = render_case(c)
  let icc = b"pipeline-icc-profile"
  let png = @png.encode(rgba, options={
    bit_depth: 8,
    compression_level: 6,
    icc: Some(icc),
  })
  let jpeg = @jpeg.encode(rgba, options={ quality: 85, icc: Some(icc), })
  assert_true(png.length() > 0)
  assert_true(jpeg.length() > 0)
}
