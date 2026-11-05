// End-to-end byte-exact checks of the frame-level 8.7.2 deblocking pass
// wired into decode_i_frame, against deblock_golden.mbt in hevc/loopfilter:
// the REAL upstream Go decoder output (DecodeNAL + Flush, -tags noasm) for
// single-slice I frames, WITH and WITHOUT the upstream deblock()/applySAO().
// This is the first test that proves the loop filter actually changes pixels
// in the decode path rather than being a byte-exact-checked but unwired
// kernel: encoder_lossy_32x32 has 109 samples that differ from the plain
// (filters-off) reconstruction, and decode_i_frame must reproduce the
// filtered YUV byte for byte.

///|
fn deblock_au_of(stream : Bytes) -> @hevc.AccessUnit raise Error {
  @hevc.parse_access_unit(stream, [], 4, true)
}

///|
fn deblock_planar_yuv(f : @decode.Yuv420p8) -> Bytes {
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
test "decode_i_frame reproduces upstream deblocked whole-frame YUV byte for byte" {
  let mut passed = 0
  for c in @loopfilter.deblock_cases {
    let au = deblock_au_of(c.stream)
    let frame = match @decode.decode_i_frame(au.sps, au.pps, au) {
      Ok(f) => f
      Err(_) => fail("\{c.name}: decode_i_frame failed")
    }
    let got = deblock_planar_yuv(frame)
    if got != c.full {
      let n = if got.length() < c.full.length() {
        got.length()
      } else {
        c.full.length()
      }
      let mut first = -1
      for i in 0..<n {
        if got[i] != c.full[i] {
          first = i
          break
        }
      }
      let ctx = if first >= 0 {
        "first diff at byte \{first}: got \{got[first]}, want \{c.full[first]}"
      } else {
        "length \{got.length()} vs \{c.full.length()}"
      }
      fail("\{c.name}: YUV mismatch, \{ctx}")
    }
    assert_eq(frame.width.to_int(), c.width)
    assert_eq(frame.height.to_int(), c.height)
    // full and plain must differ by exactly `changed` samples: a case with
    // changed > 0 is proof the deblock driver changed real pixels, and a
    // no-op case guards against the driver spuriously altering a picture.
    let mut diffs = 0
    for i in 0..<c.full.length() {
      if c.full[i] != c.plain[i] {
        diffs += 1
      }
    }
    assert_eq(diffs, c.changed)
    passed += 1
  }
  assert_eq(passed, @loopfilter.deblock_cases.length())
}

///|
test "the frame-level deblock driver is genuinely active, not a no-op" {
  // Guard the trust chain: at least one case must have filtering change real
  // pixels, and the upstream reference YUV cases must stay marked.
  let mut active = 0
  let mut with_ref = 0
  for c in @loopfilter.deblock_cases {
    if c.changed > 0 {
      active += 1
    }
    if c.has_ref {
      with_ref += 1
    }
  }
  assert_eq(active, 1)
  assert_eq(with_ref, 5)
  // The active case is the upstream lossy encoder frame: 32x32, single slice,
  // deblocking enabled, 109 samples changed by the loop filter.
  for c in @loopfilter.deblock_cases {
    if c.changed > 0 {
      assert_eq(c.name, "encoder_lossy_32x32.h265")
      assert_eq(c.changed, 109)
      assert_eq(c.deblock_disabled, false)
      assert_eq(c.width, 32)
      assert_eq(c.height, 32)
    }
  }
}
