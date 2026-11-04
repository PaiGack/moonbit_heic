///|
/// The one profile this port decodes goes through, and the one beside it does
/// not. The upstream test set is Main plus Main 10, so the same SPS with the
/// three fields that put it out of scope changed is exactly what the gate has
/// to catch.
test "main profile is the only one that gets through" {
  let tu8_sps = @hevc.split_annex_b(tu8)[1].rbsp
  let s = @hevc.parse_sps(tu8_sps)
  assert_eq(s.ptl.profile_idc, 3)
  assert_eq(s.chroma_format_idc, 1)
  assert_eq(s.bit_depth_luma, 8)
  // Main Still Picture is the same toolset under another id, so it is in.
  @hevc.check_main_profile(s)
}

///|
fn refused(s : @hevc.SPS) -> (Int32, Int32, Int32)? {
  try {
    @hevc.check_main_profile(s)
    None
  } catch {
    @hevc.UnsupportedProfile(profile_idc~, chroma_format_idc~, bit_depth_luma~) =>
      Some((profile_idc, chroma_format_idc, bit_depth_luma))
    _ => None
  }
}

///|
test "a picture outside Main is named, not dropped" {
  let base = @hevc.parse_sps(@hevc.split_annex_b(tu8)[1].rbsp)
  // Main 10.
  assert_eq(
    refused({ ..base, ptl: { ..base.ptl, profile_idc: 2, }, }),
    Some((2, 1, 8)),
  )
  // Range extensions.
  assert_eq(
    refused({ ..base, ptl: { ..base.ptl, profile_idc: 4, }, }),
    Some((4, 1, 8)),
  )
  // Main profile at 4:2:2.
  assert_eq(refused({ ..base, chroma_format_idc: 2, }), Some((3, 2, 8)))
  // Main profile at ten bits.
  assert_eq(refused({ ..base, bit_depth_luma: 10, }), Some((3, 1, 10)))
  assert_eq(refused({ ..base, bit_depth_chroma: 12, }), Some((3, 1, 8)))
  // A separate colour plane is 4:0:0 by another name.
  assert_eq(refused({ ..base, separate_colour_plane: true, }), Some((3, 1, 8)))
}

///|
test "parse_sps refuses a Main 10 stream on its own" {
  // 10bit_128x128.h265's SPS, which the upstream test set uses to cover Main
  // 10. Upstream decodes it; this port does not, and says why.
  let sps = b"\x01\x02\x20\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\xa0\x10\x20\x20\x4d\x96\xe9\x6f\x0b\x80\x40\x00\x00\xfa\x00\x00\x1d\x4c\x02"
  let got = try {
    ignore(@hevc.parse_sps(sps))
    None
  } catch {
    @hevc.UnsupportedProfile(profile_idc~, chroma_format_idc~, bit_depth_luma~) =>
      Some((profile_idc, chroma_format_idc, bit_depth_luma))
    _ => None
  }
  assert_eq(got, Some((2, 1, 10)))
}

///|
test "a 4:2:2 stream is refused by its chroma format" {
  // chroma_format_idc 2, still profile 1: a stream no Main decoder may take.
  let sps = hand_sps(chroma_format=2, bit_depth=8, profile_idc=1)
  let got = try {
    ignore(@hevc.parse_sps(sps))
    None
  } catch {
    @hevc.UnsupportedProfile(profile_idc~, chroma_format_idc~, bit_depth_luma~) =>
      Some((profile_idc, chroma_format_idc, bit_depth_luma))
    _ => None
  }
  assert_eq(got, Some((1, 2, 8)))
}

///|
/// A 64x64 SPS with the three fields the profile gate reads set by argument.
/// Everything else is the minimum a Main stream needs.
fn hand_sps(
  chroma_format~ : Int32,
  bit_depth~ : Int32,
  profile_idc~ : Int32,
) -> Bytes {
  let bits : Array[Bool] = []
  let u = fn(v : Int32, n : Int32) {
    for i in 0..<n {
      bits.push(((v >> (n - 1 - i)) & 1) == 1)
    }
  }
  let ue = fn(v : Int32) {
    let mut n = 0
    while (v + 1) >> (n + 1) != 0 {
      n = n + 1
    }
    u(0, n)
    u(v + 1, n + 1)
  }
  u(0, 4) // sps_video_parameter_set_id
  u(0, 3) // sps_max_sub_layers_minus1
  u(1, 1) // temporal_id_nesting
  u(0, 2) // profile_space
  u(0, 1) // tier
  u(profile_idc, 5)
  u(0, 32) // compat flags
  u(1, 1) // progressive source
  u(0, 1) // interlaced source
  u(1, 1) // non-packed
  u(1, 1) // frame only
  u(0, 44) // reserved, and the constraint flags of a profile that has none
  u(60, 8) // level
  ue(0) // sps id
  ue(chroma_format)
  ue(64)
  ue(64)
  u(0, 1) // no conformance window
  ue(bit_depth - 8)
  ue(bit_depth - 8)
  ue(4) // log2_max_poc_lsb_minus4
  u(1, 1) // ordering present
  ue(1)
  ue(0)
  ue(0)
  ue(1) // log2_min_cb_size_minus3
  ue(2) // log2_diff_max_min_cb_size
  ue(0) // log2_min_tb_size_minus2
  ue(2) // log2_diff_max_min_tb_size
  ue(0)
  ue(0)
  u(0, 1) // scaling list
  u(0, 1) // amp
  u(0, 1) // sao
  u(0, 1) // pcm
  ue(0) // short term rps
  u(0, 1) // long term ref pics
  u(1, 1) // temporal mvp
  u(1, 1) // strong intra smoothing
  u(0, 1) // vui
  u(0, 1) // extension
  bits.push(true) // rbsp_stop_one_bit
  while bits.length() % 8 != 0 {
    bits.push(false)
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < bits.length() {
    let mut byte = 0
    for j in 0..<8 {
      byte = (byte << 1) | (if bits[i + j] { 1 } else { 0 })
    }
    out.push(byte.to_byte())
    i = i + 8
  }
  Bytes::from_array(out)
}
