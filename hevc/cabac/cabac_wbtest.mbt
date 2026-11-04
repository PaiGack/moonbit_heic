// Whitebox tests: the derived tables and the small arithmetic helpers of the
// CABAC layer, held against the exact same assertions the upstream Go suite
// makes in hevc/cabac_test.go.

///|
/// TestNormShift: norm_shift(r) is the shift that brings r into 256..511,
/// without overshooting. Upstream walks every r in 1..511.
test "norm_shift" {
  for r in 1..<512 {
    let n = norm_shift(r.reinterpret_as_uint())
    let v = r.reinterpret_as_uint() << n
    assert_true(v >= 256U && v <= 511U)
    if n > 0 {
      assert_true(r.reinterpret_as_uint() << (n - 1) < 256U)
    }
  }
}

///|
/// TestTransitionTables: trans_state and lps_range are the two derived tables
/// decode_bin indexes, built from Tables 9-46 / 9-47 at package init.
test "transition tables" {
  // MPS path.
  for st in 0..<64 {
    let want_mps = if st >= 62 { st } else { st + 1 }
    for v in 0..<2 {
      let s = 2 * st + v
      assert_eq(trans_state[128 + s].to_int(), 2 * want_mps + v)
      // LPS path: valMps flips only when the state is zero.
      let mps = if st == 0 { 1 - v } else { v }
      let want_lps = 2 * trans_idx_lps[st].to_int() + mps
      assert_eq(trans_state[127 - s].to_int(), want_lps)
    }
  }
  // lps_range[g][2*st+v] == rangeTabLPS[st][g].
  for g in 0..<4 {
    for st in 0..<64 {
      for v in 0..<2 {
        assert_eq(
          lps_range[g * 128 + 2 * st + v].to_int(),
          range_tab_lps[st * 4 + g].to_int(),
        )
      }
    }
  }
}

///|
/// TestInitState: the Go reference is written from the pre-clipped state and
/// its two halves rather than the s ^= s>>31 shortcut, so this is a genuine
/// cross-check of the arithmetic, not a restatement of the implementation.
/// Walks every init value and qp in -10..60.
test "init_state" {
  for v in 0..<256 {
    for qp in -10..<=60 {
      let m = (v >> 4) * 5 - 45
      let n = (v & 0x0F) * 8 - 16
      let q = if qp < 0 { 0 } else if qp > 51 { 51 } else { qp }
      let mut pre = ((m * q) >> 4) + n
      if pre < 1 {
        pre = 1
      } else if pre > 126 {
        pre = 126
      }
      let val_mps = if pre > 63 { 1 } else { 0 }
      let p_state = if pre > 63 { pre - 64 } else { 63 - pre }
      let want = 2 * p_state + val_mps
      assert_eq(init_state(v, qp), want)
    }
  }
}

///|
/// TestInitType: the Table 9-4 row chosen by slice type and cabac_init.
test "init_type" {
  let cases = [
    (2, false, 0),
    (2, true, 0),
    (1, false, 1),
    (1, true, 2),
    (0, false, 2),
    (0, true, 1),
  ]
  for (st, flag, want) in cases {
    assert_eq(init_type(st, flag), want)
  }
}

///|
/// TestContextStateRange: every initialised state for every slice type and
/// qp stays inside 0..125, the range trans_state indexes.
test "context state range" {
  let d = Decoder::new(Bytes::from_array([b'\x01', b'\x02']), 0)
  for st in [2, 1, 0] {
    for qp in 0..<=51 {
      d.init_contexts(qp, st, false)
      for s in d.states() {
        assert_true(s <= 125 && s >= 0)
      }
    }
  }
}
