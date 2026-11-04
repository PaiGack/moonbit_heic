///|
/// A bitstream that is not HEVC at all has to come back as an error, not as a
/// trap: every entry point below is reachable from a file a person can be sent.

///|
test "a truncated parameter set is refused at every prefix" {
  let full = @hevc.split_annex_b(tu8)[1].rbsp
  let mut n = 0
  while n < full.length() {
    let part = full.exact_view(start=0, end=n).to_owned()
    let refused = try {
      ignore(@hevc.parse_sps(part))
      false
    } catch {
      _ => true
    }
    assert_true(refused)
    n = n + 1
  }
  // The whole thing parses, so the loop above proved something about the
  // truncations rather than about the bytes.
  ignore(@hevc.parse_sps(full))
}

///|
test "a truncated VPS and PPS are refused too" {
  let vps = @hevc.split_annex_b(tu8)[0].rbsp
  let pps = @hevc.split_annex_b(tu8)[2].rbsp
  for n in 0..<vps.length() {
    let refused = try {
      ignore(@hevc.parse_vps(vps.exact_view(start=0, end=n).to_owned()))
      false
    } catch {
      _ => true
    }
    assert_true(refused)
  }
  for n in 0..<pps.length() {
    let refused = try {
      ignore(@hevc.parse_pps(pps.exact_view(start=0, end=n).to_owned()))
      false
    } catch {
      _ => true
    }
    assert_true(refused)
  }
}

///|
/// Every byte-flipped variant of a real parameter set either parses or is
/// refused. Neither outcome may be a trap, and neither may be a hang: the
/// Exp-Golomb reader stops at 32 leading zeros, which is what keeps the
/// second one true.
test "a corrupted parameter set never traps" {
  let full = @hevc.split_annex_b(ctu64)[1].rbsp
  for i in 0..<full.length() {
    for bit in 0..<8 {
      let bytes = full.to_array()
      // Flip one bit of the payload; the header bytes stay as the stream
      // wrote them, because a stream that gets them wrong is refused earlier.
      let flip = 1 << bit
      bytes[i] = (bytes[i].to_int() ^ flip).to_byte()
      let tail : Array[Byte] = []
      let mut k = 2
      while k < bytes.length() {
        tail.push(bytes[k])
        k = k + 1
      }
      let variant = Bytes::from_array(tail)
      ignore(@hevc.parse_sps(variant)) catch {
        _ => ()
      }
    }
  }
}

///|
test "the slice header of a corrupted slice never traps" {
  let nals = @hevc.split_annex_b(ctu64)
  let sps = @hevc.parse_sps(nals[1].rbsp)
  let pps = @hevc.parse_pps(nals[2].rbsp)
  let slice = nals[3].rbsp
  let mut i = 2
  while i < slice.length() {
    let bytes = slice.to_array()
    bytes[i] = (bytes[i].to_int() ^ 0x5a).to_byte()
    ignore(
      @hevc.parse_slice_header(
        Bytes::from_array(bytes),
        @hevc.NALType::IdrNLp,
        sps,
        pps,
      ),
    ) catch {
      _ => ()
    }
    i = i + 1
  }
}

///|
/// A conformance window that would leave no picture. The window offsets are
/// Exp-Golomb, so a stream can state any one of them, and the arithmetic that
/// turns them into a width is the only thing standing between that and a
/// zero-height plane.
test "a conformance window that empties the picture is refused" {
  let cases : Array[(Int32, Int32, Int32, Int32, Bool)] = [
    (0, 0, 0, 0, true),
    (15, 0, 15, 0, true),
    (8, 8, 0, 0, false),
    (0, 0, 8, 8, false),
    (17, 0, 0, 0, false),
    (0, 0, 17, 0, false),
  ]
  for (left, right, top, bottom, valid) in cases {
    let sps = crop_sps(left, right, top, bottom)
    let got = try {
      let s = @hevc.parse_sps(sps)
      Some((s.cropped_width(), s.cropped_height()))
    } catch {
      _ => None
    }
    match got {
      None => assert_false(valid)
      Some((w, h)) => {
        assert_true(valid)
        assert_eq(w, 32 - 2 * (left + right))
        assert_eq(h, 32 - 2 * (top + bottom))
      }
    }
  }
}

///|
/// The picture buffer the ordering information declares: 7.4.3.2.1 bounds
/// reordering by the buffer, and A.4.2 bounds the buffer at 16.
test "picture buffering outside what a level allows is refused" {
  let cases : Array[(Bool, Int32, Int32)] = [
    (true, 0, 0),
    (true, 15, 15),
    (true, 3, 2),
    (false, 16, 0),
    (false, 1, 2),
  ]
  for (valid, buffering, reorder) in cases {
    let sps = ordering_sps(buffering, reorder)
    let got = try {
      ignore(@hevc.parse_sps(sps))
      true
    } catch {
      _ => false
    }
    assert_eq(got, valid)
  }
}

///|
/// A 32x32 SPS with the conformance window of 7.4.3.2.1 set by argument,
/// everything else held at what an encoder writes.
fn crop_sps(left : Int32, right : Int32, top : Int32, bottom : Int32) -> Bytes {
  build_sps(true, left, right, top, bottom, 0, 0)
}

///|
fn ordering_sps(buffering : Int32, reorder : Int32) -> Bytes {
  build_sps(false, 0, 0, 0, 0, buffering, reorder)
}

///|
/// The one builder both tests above use: a 32x32 Main SPS, with either a
/// conformance window or a picture buffer the caller sets.
fn build_sps(
  crop_present : Bool,
  left : Int32,
  right : Int32,
  top : Int32,
  bottom : Int32,
  buffering : Int32,
  reorder : Int32,
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
  u(1, 5) // profile_idc, Main
  u(0, 32) // compat flags
  u(1, 1)
  u(0, 1)
  u(1, 1)
  u(1, 1)
  u(0, 44)
  u(60, 8) // level
  ue(0) // sps id
  ue(1) // 4:2:0
  ue(32)
  ue(32)
  if crop_present {
    u(1, 1)
    ue(left)
    ue(right)
    ue(top)
    ue(bottom)
  } else {
    u(0, 1)
  }
  ue(0) // bit_depth_luma_minus8
  ue(0) // bit_depth_chroma_minus8
  ue(4) // log2_max_poc_lsb_minus4
  if crop_present {
    // The default case: one sub-layer, one picture in the buffer.
    u(1, 1)
    ue(1)
    ue(0)
    ue(0)
  } else {
    u(1, 1)
    ue(buffering)
    ue(reorder)
    ue(0)
  }
  ue(1) // log2_min_cb_size_minus3 -> 16x16
  ue(2) // log2_diff_max_min_cb_size -> 64x64
  ue(0) // log2_min_tb_size_minus2
  ue(2) // log2_diff_max_min_tb_size
  ue(0)
  ue(0)
  u(0, 1) // scaling list
  u(0, 1) // amp
  u(0, 1) // sao
  u(0, 1) // pcm
  ue(0) // num_short_term_ref_pic_sets
  u(0, 1) // long_term_ref_pics_present
  u(1, 1) // temporal_mvp
  u(1, 1) // strong_intra_smoothing
  u(0, 1) // vui
  u(0, 1) // extension
  bits.push(true)
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
