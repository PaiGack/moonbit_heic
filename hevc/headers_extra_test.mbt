///|
/// The encoder headers upstream's `TestWriteParameterSets` builds, ported bit
/// for bit: VPS, SPS and PPS as `hevc/headersenc.go` writes them, with no
/// fixture stream behind them. `parse_sps` refuses nothing here, so the test
/// is also the one that proves a hand-built Main stream gets through the
/// profile gate.
test "hand-built encoder parameter sets round trip" {
  // 320x240, Main profile, level 6.0, PCM and sign data hiding on.
  let vps = b"\x0c\x01\xff\xff\x01\x60\x00\x00\x00\xb0\x00\x00\x00\x00\x00\x3c\xac\x09"
  let sps = b"\x01\x01\x60\x00\x00\x00\xb0\x00\x00\x00\x00\x00\x3c\xa0\x0a\x08\x0f\x16\x5a\xd6\xf1\x77\x5c\x10"
  let pps = b"\xc1\x71\xc0\x99\x20"

  let v = @hevc.parse_vps(vps)
  assert_eq(v.id, 0)
  assert_eq(v.ptl.profile_idc, 1)
  assert_eq(v.ptl.level_idc, 60)
  assert_false(v.ptl.tier_flag)

  let s = @hevc.parse_sps(sps)
  assert_eq(s.vps_id, 0)
  assert_eq(s.pic_width_in_luma_samples, 320)
  assert_eq(s.pic_height_in_luma_samples, 240)
  assert_eq(s.chroma_format_idc, 1)
  assert_eq(s.bit_depth_luma, 8)
  assert_eq(s.bit_depth_chroma, 8)
  assert_true(s.pcm_enabled)
  assert_eq(s.log2_min_pcm_cb_size, 4)
  assert_eq(s.log2_max_pcm_cb_size, 4)
  assert_true(s.pcm_loop_filter_disabled)

  let p = @hevc.parse_pps(pps)
  assert_eq(p.id, 0)
  assert_eq(p.sps_id, 0)
  assert_true(p.sign_data_hiding_enabled)
  assert_true(p.deblocking_control_present)
  assert_false(p.deblocking_disabled)
  assert_false(p.tiles_enabled)
  assert_false(p.entropy_coding_sync)
  assert_false(p.loop_filter_across_slices)
  assert_false(p.scaling_list_present)
  assert_false(p.lists_modification_present)
}

///|
/// ISO/IEC 14496-15 has a container repeat the twelve bytes from
/// `general_profile_space` through `general_level_idc`, so they have to be the
/// ones the sequence parameter set itself carries.
test "profile_tier_level_bytes is the twelve the record repeats" {
  let sps = b"\x01\x01\x60\x00\x00\x00\xb0\x00\x00\x00\x00\x00\x3c\xa0\x0a"
  let ptl = match @hevc.profile_tier_level_bytes(sps) {
    Some(b) => b
    None => panic()
  }
  assert_eq(ptl.length(), 12)
  // profile_space 0, tier 0, profile_idc 1 in the first byte.
  assert_eq(ptl[0], b"\x01"[0])
  assert_eq(ptl[11], b"\x3c"[0])
  // One byte short of the field: there is nothing to repeat.
  assert_true(
    @hevc.profile_tier_level_bytes(sps.exact_view(start=0, end=12).to_owned())
    is None,
  )
}

///|
/// A hand-built VUI: `video_signal_type` is where a sequence declares the range
/// and the matrix its samples are in, and a container with no description of
/// its own falls back to it.
test "vui video_signal_type lands on the colour description" {
  // 64x64 Main, then a VUI whose video_signal_type is present with
  // full_range 1 and colour_description 1, saying BT.709 primaries, sRGB
  // transfer and BT.709 matrix — the description basic.heic's `colr` repeats.
  let sps = b"\x01\x01\x60\x00\x00\x00\xb0\x00\x00\x00\x00\x00\x3c\xa0\x20\x81\x05\x96\xb4\xef\x0b\x9b\x80\x86\x83\x00\x40"
  let s = @hevc.parse_sps(sps)
  assert_true(s.full_range)
  assert_eq(s.colour_primaries, 1)
  assert_eq(s.transfer_characteristics, 13)
  assert_eq(s.matrix_coefficients, 6)
}

///|
/// The same SPS with `video_signal_type` absent: the description stays at the
/// "unspecified" E.3.1 infers, which is 2 in all three fields.
test "an absent video_signal_type leaves the description unspecified" {
  let sps = b"\x01\x01\x60\x00\x00\x00\xb0\x00\x00\x00\x00\x00\x3c\xa0\x20\x81\x05\x96\xb4\xef\x0b\x80\x08"
  let s = @hevc.parse_sps(sps)
  assert_false(s.full_range)
  assert_eq(s.colour_primaries, 2)
  assert_eq(s.transfer_characteristics, 2)
  assert_eq(s.matrix_coefficients, 2)
}
