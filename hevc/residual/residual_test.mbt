// Byte-exact checks of the residual-coefficient syntax layer against
// golden.mbt: the upstream Go encoder's real CABAC bitstreams and the full
// context-derivation traversals, cross-checked by an independent JS
// transcription in tools/crosscheck_residual.mjs.

///|
test "scanIndex matches the upstream 7.4.9.11 derivation" {
  for c in @residual.scan_index_cases {
    assert_eq(
      @residual.scan_index(c.log2_size, c.c_idx, c.mode, c.intra, c.chroma),
      c.want,
    )
  }
}

///|
test "lastSigCoeffCtx matches the upstream 9.3.4.2.3 derivation" {
  for c in @residual.last_ctx_cases {
    assert_eq(
      @residual.last_sig_coeff_ctx(c.log2_size, c.c_idx, c.bin_idx),
      c.want,
    )
  }
}

///|
test "sigCoeffCtx matches the upstream 9.3.4.2.5 derivation, full traversal" {
  let mut k = 0
  for log2 in [2, 3, 4, 5] {
    let n = 1 << log2
    for c_idx in [0, 1] {
      for scan in 0..<3 {
        for csbf in 0..<4 {
          for y in 0..<n {
            for x in 0..<n {
              assert_eq(
                @residual.sig_coeff_ctx(x, y, log2, c_idx, scan, csbf),
                @residual.sig_coeff_ctx_want[k],
              )
              k += 1
            }
          }
        }
      }
    }
  }
  assert_eq(k, @residual.sig_coeff_ctx_want.length())
}

///|
test "SigCtxSet::at matches the upstream derivation, full traversal" {
  let mut k = 0
  for log2 in [2, 3, 4, 5] {
    let n = 1 << log2
    for c_idx in [0, 1, 2] {
      for scan in 0..<3 {
        for csbf in 0..<4 {
          for y_s in 0..<(n / 4) {
            for x_s in 0..<(n / 4) {
              let set = @residual.SigCtxSet::new(
                x_s, y_s, log2, c_idx, scan, csbf, false,
              )
              for y in 0..<4 {
                for x in 0..<4 {
                  assert_eq(set.at(x, y), @residual.sig_ctx_set_want[k])
                  k += 1
                }
              }
            }
          }
        }
      }
    }
  }
  assert_eq(k, @residual.sig_ctx_set_want.length())
}

///|
test "decode_residual reproduces the upstream Go coefficients from real CABAC bitstreams" {
  for c in @residual.residual_cases {
    let dec = @cabac.Decoder::new(c.bytes, 0) catch {
      _ => fail("short CABAC init word")
    }
    dec.init_contexts(26, 2, false)
    let n = 1 << c.log2_size
    let coef = Array::make(n * n, 0)
    let b : @residual.ResidualBlock = {
      log2_size: c.log2_size,
      c_idx: c.c_idx,
      pred_mode_intra: c.pred_mode,
      intra: c.intra,
      transquant_bypass: false,
      max_transform_skip_size: 0,
    }
    let p : @residual.ResidualParams = {
      ..@residual.ResidualParams::main_420_8bit(),
      sign_data_hiding: c.sign_hiding,
    }
    let stat = [0, 0, 0, 0]
    let _ = match @residual.decode_residual(dec, coef, b, p, stat) {
      Ok(_) => ()
      Err(_) => fail("decode_residual failed")
    }
    assert_eq(coef, c.coef)
    assert_eq(dec.decode_terminate(), 1)
  }
}

///|
test "decode_residual rejects malformed blocks instead of trapping" {
  let bytes = Bytes::from_array([
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
  ])
  let dec = @cabac.Decoder::new(bytes, 0) catch {
    _ => fail("short CABAC init word")
  }
  dec.init_contexts(26, 2, false)
  let p = @residual.ResidualParams::main_420_8bit()
  let stat = [0, 0, 0, 0]
  // Wrong log2 size and a coef length that does not match the block.
  let bads : Array[@residual.ResidualBlock] = [
    {
      log2_size: 1,
      c_idx: 0,
      pred_mode_intra: 0,
      intra: true,
      transquant_bypass: false,
      max_transform_skip_size: 0,
    },
    {
      log2_size: 6,
      c_idx: 3,
      pred_mode_intra: 0,
      intra: true,
      transquant_bypass: false,
      max_transform_skip_size: 0,
    },
  ]
  for bad in bads {
    let r = @residual.decode_residual(dec, Array::make(16, 0), bad, p, stat)
    assert_true(r is Err(@residual.InvalidBlock))
  }
  // A coef array whose length disagrees with log2_size.
  let good : @residual.ResidualBlock = {
    log2_size: 2,
    c_idx: 0,
    pred_mode_intra: 0,
    intra: true,
    transquant_bypass: false,
    max_transform_skip_size: 0,
  }
  let r = @residual.decode_residual(dec, Array::make(15, 0), good, p, stat)
  assert_true(r is Err(@residual.InvalidBlock))
}
