///|
/// TestDiagScan of the upstream Go suite: the exact 4x4 diagonal order.
test "4x4 diagonal scan" {
  let want_x = [0, 0, 1, 0, 1, 2, 0, 1, 2, 3, 1, 2, 3, 2, 3, 3]
  let want_y = [0, 1, 0, 2, 1, 0, 3, 2, 1, 0, 3, 2, 1, 3, 2, 3]
  assert_eq(@dsp.scan_len(2, @dsp.scan_diag), 16)
  for i in 0..<16 {
    let p = @dsp.scan_pos(2, @dsp.scan_diag, i).unwrap()
    assert_eq(p.x, want_x[i])
    assert_eq(p.y, want_y[i])
  }
}

///|
/// TestScanOrdersArePermutations: every order visits each position of the
/// block exactly once, for every log2 size.
test "scan orders are permutations" {
  for k in 0..<=@dsp.max_scan_log2 {
    let size = 1 << k
    for order in 0..<@dsp.n_scan_orders {
      assert_eq(@dsp.scan_len(k, order), size * size)
      let seen : Array[Bool] = Array::make(size * size, false)
      for i in 0..<(size * size) {
        let p = @dsp.scan_pos(k, order, i).unwrap()
        assert_true(p.x >= 0 && p.x < size && p.y >= 0 && p.y < size)
        let idx = p.y * size + p.x
        assert_true(!seen[idx])
        seen[idx] = true
      }
      for s in seen {
        assert_true(s)
      }
    }
  }
}

///|
/// TestScanHorVerTranspose: the vertical order is the transpose of the
/// horizontal one, at every size.
test "horizontal and vertical scans transpose" {
  for k in 0..<=@dsp.max_scan_log2 {
    let n = @dsp.scan_len(k, @dsp.scan_hor)
    for i in 0..<n {
      let h = @dsp.scan_pos(k, @dsp.scan_hor, i).unwrap()
      let v = @dsp.scan_pos(k, @dsp.scan_ver, i).unwrap()
      assert_eq(h.x, v.y)
      assert_eq(h.y, v.x)
    }
  }
}

///|
/// TestDiagScanOrdering: the anti-diagonal index never decreases, and within
/// one diagonal x strictly increases.
test "diagonal scan ordering" {
  for k in 0..<=@dsp.max_scan_log2 {
    let n = @dsp.scan_len(k, @dsp.scan_diag)
    for i in 1..<n {
      let prev = @dsp.scan_pos(k, @dsp.scan_diag, i - 1).unwrap()
      let cur = @dsp.scan_pos(k, @dsp.scan_diag, i).unwrap()
      let pd = prev.x + prev.y
      let cd = cur.x + cur.y
      assert_true(cd >= pd)
      if cd == pd {
        assert_true(cur.x > prev.x)
      }
    }
  }
}

///|
/// A last-significant-coeff position past the block is a stream error, not an
/// out-of-bounds read (which would trap the process in MoonBit).
test "scan bounds are explicit" {
  assert_true(@dsp.scan_pos(2, @dsp.scan_diag, 16) is None)
  assert_true(@dsp.scan_pos(2, @dsp.scan_diag, -1) is None)
  assert_true(@dsp.scan_pos(6, @dsp.scan_diag, 0) is None)
  assert_true(@dsp.scan_pos(2, 3, 0) is None)
}

///|
/// TestTransMatrixReflection of the upstream suite: the first basis row is
/// flat 64, and every row is symmetric or anti-symmetric about its midpoint.
test "transform matrix reflection" {
  for n in 0..<32 {
    assert_eq(@dsp.trans_matrix(0, n).unwrap(), 64)
  }
  for k in 0..<32 {
    let sign = if k % 2 == 1 { -1 } else { 1 }
    for n in 0..<32 {
      assert_eq(
        @dsp.trans_matrix(k, 31 - n).unwrap(),
        sign * @dsp.trans_matrix(k, n).unwrap(),
      )
    }
  }
}

///|
/// TestTransMatrixOrthogonal: the basis is near-orthogonal by design. Diagonal
/// dot products sit near n*64*64, off-diagonal near zero, within 1/256.
test "transform matrix is near-orthogonal" {
  for n in [4, 8, 16, 32] {
    let stride = 32 / n
    let diag = n * 64 * 64
    for a in 0..<n {
      for b in 0..<n {
        let mut dot = 0
        for i in 0..<n {
          dot += @dsp.trans_matrix(a * stride, i).unwrap() *
            @dsp.trans_matrix(b * stride, i).unwrap()
        }
        if a == b {
          assert_true(dot >= diag - diag / 256 && dot <= diag + diag / 256)
        } else {
          assert_true(dot >= -(diag / 256) && dot <= diag / 256)
        }
      }
    }
  }
}

///|
/// The sign extension of the int8 bases: the negative entries of row 1 must
/// come back as negative Ints, not 0..255 bytes.
test "matrix entries are signed" {
  assert_eq(@dsp.trans_matrix(1, 0).unwrap(), 90)
  assert_eq(@dsp.trans_matrix(1, 16).unwrap(), -4)
  assert_eq(@dsp.trans_matrix(1, 31).unwrap(), -90)
  assert_eq(@dsp.dst_matrix(1, 3).unwrap(), -74)
  assert_eq(@dsp.dst_matrix(2, 1).unwrap(), -29)
}

///|
/// naive_1d and naive_1d_dst4 are the defining sums of 8.6.4.2 / 8.6.4.1.
/// The expected outputs live in golden.mbt, generated independently from the
/// committed transform matrices by tools/gen_m3_golden.mjs, so this checks the
/// matrix data, the sign extension and the summation together at every size.
test "naive 1d transform matches the upstream basis" {
  for case in @dsp.naive_cases {
    assert_eq(@dsp.naive_1d(case.input, case.n), case.want)
  }
  assert_eq(@dsp.naive_1d_dst4(@dsp.dst4_input), @dsp.dst4_want)
}
