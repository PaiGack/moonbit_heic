///|
test "context table follows the CTB area" {
  assert_eq(@cabac.context_table_size(4), 16L * 16L)
  assert_eq(@cabac.context_table_size(6), 64L * 64L)
}

///|
test "a shift the 64-bit carrier cannot hold is reported" {
  assert_true(
    try {
      ignore(@cabac.context_table_size(64))
      false
    } catch {
      @safe.Overflow => true
    },
  )
  assert_true(
    try {
      ignore(@cabac.context_table_size(-1))
      false
    } catch {
      @safe.Overflow => true
    },
  )
}

///|
/// TestCABACInitBounds of the upstream Go suite: a short buffer, a negative
/// offset and an offset past the end are all refused; a valid init leaves
/// rng = 0x1fe.
test "cabac init bounds" {
  let two = Bytes::from_array([b'\x01', b'\x02'])
  assert_true(
    try {
      ignore(@cabac.Decoder::new(Bytes::from_array([b'\x01']), 0))
      false
    } catch {
      @cabac.InvalidInit => true
    },
  )
  assert_true(
    try {
      ignore(@cabac.Decoder::new(two, 1))
      false
    } catch {
      @cabac.InvalidInit => true
    },
  )
  assert_true(
    try {
      ignore(@cabac.Decoder::new(two, -1))
      false
    } catch {
      @cabac.InvalidInit => true
    },
  )
  assert_true(
    try {
      let d = @cabac.Decoder::new(two, 0)
      d.rng == 0x1FEU
    } catch {
      @cabac.InvalidInit => false
    },
  )
}

///|
/// Every golden bitstream is the output of an independent arithmetic encoder
/// and has been decoded bin-for-bin by a JS port of the upstream Go decoder.
/// The MoonBit decoder must reproduce all of them, including the final
/// terminating bin. One wrong renormalisation shift corrupts the rest of a
/// slice, so this is the load-bearing test of the whole CABAC layer.
test "golden bitstreams decode bin-for-bin" {
  let mut checked = 0
  for case in @cabac.golden_cases {
    let d = @cabac.Decoder::new(case.bytes, 0)
    d.init_contexts(case.qp, case.slice_type_code, false)
    let ops = case.ops
    let mut i = 0
    while i < ops.length() {
      let kind = ops[i]
      let a = ops[i + 1]
      let want = ops[i + 3]
      let got = match kind {
        0 => d.decode_bin(a)
        1 => d.decode_bypass()
        2 => d.decode_bypass_bits(a).reinterpret_as_int()
        3 => d.decode_terminate()
        _ => -1
      }
      assert_eq(got, want)
      checked += 1
      i += 4
    }
    assert_eq(d.decode_terminate(), 1)
  }
  assert_eq(checked, 8400)
}

///|
/// decode_bypass_bits rejects a count past the 32 bits a UInt32 can hold,
/// rather than returning a wrapped value.
test "bypass bit count is bounded" {
  let d = @cabac.Decoder::new(Bytes::from_array([b'\x01', b'\x02']), 0)
  assert_true(
    try {
      ignore(d.decode_bypass_bits(33))
      false
    } catch {
      @cabac.BadBypassCount => true
    },
  )
}

///|
/// A context index outside the 179 allocated is reported, not read out of
/// bounds (which would be an unreachable trap in MoonBit).
test "context index is bounded" {
  let d = @cabac.Decoder::new(Bytes::from_array([b'\x01', b'\x02']), 0)
  assert_true(
    try {
      ignore(d.decode_bin(179))
      false
    } catch {
      @cabac.BadContext => true
    },
  )
}
