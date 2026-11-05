// End-to-end byte-exact checks of the REMAINING M3 tools wired into
// decode_i_frame, against frame2_golden.mbt: the REAL upstream Go decoder's
// first-picture output (DecodeNAL + Flush, -tags noasm), asserted against the
// upstream *_ref.yuv where one ships, plus two SAO-active frames produced by
// the real upstream encoder. WPP/tiles streams are out of M3 scope.

///|
fn f2_au(stream : Bytes) -> @hevc.AccessUnit raise Error {
  @hevc.parse_access_unit(stream, [], 4, true)
}

///|
fn f2_planar(f : @decode.Yuv420p8) -> Bytes {
  let out : Array[Byte] = []
  for b in f.y {
    out.push(b)
  }
  for b in f.u {
    out.push(b)
  }
  for b in f.v {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
fn f2_fnv(bytes : Bytes) -> (String, Int32) {
  let mut hash : UInt64 = 0xcbf29ce484222325UL
  let mut nonzero = 0
  for b in bytes {
    hash = (hash ^ b.to_uint64()) * 0x100000001b3UL
    if b != b'\x00' {
      nonzero += 1
    }
  }
  (hash.to_string(), nonzero)
}

///|
test "M2 parses every remaining-tool fixture" {
  let mut n = 0
  for c in @decode.frame2_cases {
    let au = f2_au(c.stream)
    assert_eq(au.sps.pic_width_in_luma_samples, c.width)
    assert_eq(au.sps.pic_height_in_luma_samples, c.height)
    assert_true(au.slices.length() >= 1)
    n += 1
  }
  assert_eq(n, @decode.frame2_cases.length())
}

///|
test "decode_i_frame reproduces remaining-tool upstream YUV byte for byte" {
  let mut passed = 0
  for c in @decode.frame2_cases {
    let au = f2_au(c.stream)
    let frame = match @decode.decode_i_frame(au.sps, au.pps, au) {
      Ok(f) => f
      Err(_) => fail("\{c.name}: decode_i_frame failed")
    }
    let got = f2_planar(frame)
    if c.big {
      // Large frames: FNV-1a checksum + nonzero count + probe samples.
      let (hash, nonzero) = f2_fnv(got)
      assert_eq(hash, c.checksum)
      assert_eq(nonzero, c.nonzero)
      for (i, want) in c.probes {
        assert_eq(got[i].to_int(), want)
      }
    } else if got != c.yuv {
      let n = if got.length() < c.yuv.length() {
        got.length()
      } else {
        c.yuv.length()
      }
      let mut first = -1
      for i in 0..<n {
        if got[i] != c.yuv[i] {
          first = i
          break
        }
      }
      let ctx = if first >= 0 {
        "first diff at byte \{first}: got \{got[first]}, want \{c.yuv[first]}"
      } else {
        "length \{got.length()} vs \{c.yuv.length()}"
      }
      fail("\{c.name}: YUV mismatch, \{ctx}")
    }
    assert_eq(frame.width.to_int(), c.width)
    assert_eq(frame.height.to_int(), c.height)
    passed += 1
  }
  assert_eq(passed, @decode.frame2_cases.length())
}

///|
test "malformed tool bitstreams return DecodeError, never trap" {
  // Corrupt the CABAC slice data of a SAO frame, a scaling-list frame and a
  // PCM frame. A malformed bin, a bad context, a truncated PCM block or a
  // desynchronised arithmetic decoder must come back as DecodeError rather
  // than reaching an unchecked array index (MoonBit's `a[5]` traps).
  for name in ["sao.h265", "scaling_list.h265", "pcm_32x32.h265"] {
    for c in @decode.frame2_cases {
      if c.name != name {
        continue
      }
      let n = c.stream.length()
      // Flip a byte in the last third (the coded slice data), and truncate.
      let flipped : Array[Byte] = []
      let cut = n * 2 / 3
      for i in 0..<n {
        let b = c.stream[i]
        flipped.push(if i == cut { b ^ b'\xff' } else { b })
      }
      let bad = Bytes::from_array(flipped)
      // A byte flip need not be detectable (a decoder may produce a different
      // but still valid picture), but it must never trap: reaching this line
      // at all is the assertion. A hard truncation of the slice data, on the
      // other hand, must come back as DecodeError.
      for stream in [bad] {
        let r = try {
          let au = f2_au(stream)
          @decode.decode_i_frame(au.sps, au.pps, au)
        } catch {
          _ => Err(@decode.InvalidStream)
        }
        ignore(r)
      }
      let short = if n > 8 {
        c.stream.exact_view(start=0, end=n / 2).to_owned()
      } else {
        bad
      }
      let r = try {
        let au = f2_au(short)
        @decode.decode_i_frame(au.sps, au.pps, au)
      } catch {
        _ => Err(@decode.InvalidStream)
      }
      assert_true(
        match r {
          Err(_) => true
          Ok(_) => false
        },
      )
    }
  }
}

///|
test "multi-slice and WPP/tiles streams are refused, not half-decoded" {
  // The Issue locks M3 to a single thread with no WPP/tiles. A second slice
  // is its own CABAC substream, so decode_i_frame refuses it with
  // NotImplemented rather than returning a half picture.
  for c in @decode.frame2_cases {
    if c.name == "sao.h265" {
      let au = f2_au(c.stream)
      let two = { ..au, slices: [au.slices[0], au.slices[0]], }
      assert_true(
        match @decode.decode_i_frame(au.sps, au.pps, two) {
          Err(NotImplemented) => true
          _ => false
        },
      )
      let wpp = { ..au.pps, entropy_coding_sync: true, }
      assert_true(
        match @decode.decode_i_frame(au.sps, wpp, au) {
          Err(NotImplemented) => true
          _ => false
        },
      )
      let tiles = { ..au.pps, tiles_enabled: true, }
      assert_true(
        match @decode.decode_i_frame(au.sps, tiles, au) {
          Err(NotImplemented) => true
          _ => false
        },
      )
    }
  }
}
