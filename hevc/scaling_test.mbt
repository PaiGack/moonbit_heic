// 7.4.5 scaling-factor derivation checked against the REAL upstream Go
// sps.scalingList + scalingList.factors() truth (tools/scaling_truth.json,
// re-derived independently by tools/crosscheck_scaling.mjs).

///|
fn sl_from_case(c : @hevc.ScalingCase) -> @hevc.ScalingList {
  { sl: c.sl, dc: c.dc, }
}

///|
test "ScalingList::factors matches upstream 7.4.5 value for value" {
  for c in @hevc.scaling_cases {
    let got = sl_from_case(c).factors()
    assert_eq(got.length(), c.factors.length())
    for s in 0..<got.length() {
      assert_eq(got[s].length(), c.factors[s].length())
      for m in 0..<got[s].length() {
        let f = got[s][m]
        assert_eq(f.size_id, s)
        assert_eq(f.matrix_id, m)
        assert_eq(f.n, 4 << s)
        assert_eq(f.factor, c.factors[s][m])
      }
    }
  }
}

///|
test "scaling_factor selects the right matrix per (log2, cIdx)" {
  let sl = sl_from_case(@hevc.scaling_cases[0]).factors()
  // intra: matrix_id = cIdx; 32x32 chroma collapses to matrix 0.
  let a = @hevc.scaling_factor(sl, 3, 0, false, true, true)
  assert_true(a is Some(_))
  assert_eq(a.unwrap(), sl[1][0].factor)
  let b = @hevc.scaling_factor(sl, 5, 2, false, true, true)
  assert_true(b is Some(_))
  assert_eq(b.unwrap(), sl[3][0].factor)
  // transform skip > 4x4 / scaling off => flat (None).
  assert_true(@hevc.scaling_factor(sl, 4, 0, true, true, true) is None)
  assert_true(@hevc.scaling_factor(sl, 3, 0, false, true, false) is None)
}
