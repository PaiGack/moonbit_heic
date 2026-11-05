// Whole-picture byte-exact checks of the M3 CTU reconstruction chain against
// golden.mbt in hevc/ctu: the REAL upstream Go decoder output (DecodeNAL +
// Flush, -tags noasm) for small single-slice I frames, asserted against the
// upstream *_ref.yuv where one ships. This is the first test that runs
// decode_i_frame end to end and compares every produced YUV sample.

///|
fn au_of(stream : Bytes) -> @hevc.AccessUnit raise Error {
  @hevc.parse_access_unit(stream, [], 4, true)
}

///|
fn planar_yuv(f : @decode.Yuv420p8) -> Bytes {
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

///|
test "decode_i_frame reproduces upstream whole-frame YUV byte for byte" {
  let mut passed = 0
  for c in @ctu.frame_cases {
    let au = au_of(c.stream)
    let frame = match @decode.decode_i_frame(au.sps, au.pps, au) {
      Ok(f) => f
      Err(_) => fail("\{c.name}: decode_i_frame failed")
    }
    let got = planar_yuv(frame)
    if got != c.yuv {
      // Report the first differing byte with context, like the parity harness.
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
  assert_eq(passed, @ctu.frame_cases.length())
}

///|
test "the frame fixtures that ship an upstream reference YUV are marked" {
  // Every *_ref.yuv case is byte-exact truth from the upstream decoder; the
  // exporter asserted it. Guard the count so a fixture silently losing its
  // ref does not quietly weaken the trust chain.
  let mut with_ref = 0
  for c in @ctu.frame_cases {
    if c.has_ref {
      with_ref += 1
    }
  }
  assert_eq(with_ref, 8)
}
