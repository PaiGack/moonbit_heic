///|
test "BT.709 and BT.601 luma weights differ" {
  let bt709 = @color.ColorMatrix::from_matrix_coefficients(1)
  let bt601 = @color.ColorMatrix::from_matrix_coefficients(5)
  assert_eq(bt709.kr, 13933)
  assert_eq(bt601.kr, 19595)
  assert_eq(bt709.shift, @color.matrix_shift)
}

///|
test "unknown matrix coefficients are reported" {
  assert_true(
    try {
      ignore(@color.ColorMatrix::from_matrix_coefficients(0))
      false
    } catch {
      @color.UnsupportedMatrix(_) => true
      _ => false
    },
  )
}

///|
test "limited-range neutral grey stays grey" {
  // Y=126, U=V=128 in BT.709 limited range is a mid grey. Check the
  // hand-computed value: the matrix is exact, so all three channels agree.
  let m = @color.ColorMatrix::from_matrix_coefficients(1)
  let (r, g, b) = @color.yuv_to_rgb(
    @color.ColorDescription::new(1, 1, false),
    m,
    126,
    128,
    128,
  )
  assert_eq(r, g)
  assert_eq(g, b)
  assert_eq(r, 128)
}

///|
test "full-range black and white hit the rails" {
  let m = @color.ColorMatrix::from_matrix_coefficients(1)
  let d = @color.ColorDescription::new(1, 1, true)
  assert_eq(@color.yuv_to_rgb(d, m, 0, 128, 128), (0, 0, 0))
  assert_eq(@color.yuv_to_rgb(d, m, 255, 128, 128), (255, 255, 255))
}

///|
test "BT.709 primary red" {
  let m = @color.ColorMatrix::from_matrix_coefficients(1)
  let (r, g, b) = @color.yuv_to_rgb(
    @color.ColorDescription::new(1, 1, false),
    m,
    81,
    90,
    240,
  )
  assert_true(r > g + 100)
  assert_true(r > b + 100)
}

///|
test "BT.2020 and BT.709 disagree on the same sample" {
  let d709 = @color.ColorDescription::new(1, 1, false)
  let d2020 = @color.ColorDescription::new(9, 1, false)
  let m709 = @color.ColorMatrix::from_matrix_coefficients(1)
  let m2020 = @color.ColorMatrix::from_matrix_coefficients(9)
  let a = @color.yuv_to_rgb(d709, m709, 100, 80, 170)
  let b = @color.yuv_to_rgb(d2020, m2020, 100, 80, 170)
  assert_true(a != b)
}

///|
test "PQ / HLG map into SDR without going out of range" {
  for c in [0, 64, 128, 192, 255] {
    let pq = @color.apply_transfer(
      @color.ColorDescription::new(1, 16, false),
      c,
    )
    let hlg = @color.apply_transfer(
      @color.ColorDescription::new(1, 18, false),
      c,
    )
    assert_true(pq >= 0 && pq <= 255)
    assert_true(hlg >= 0 && hlg <= 255)
  }
}

///|
test "unsupported transfer is reported" {
  assert_true(
    try {
      ignore(
        @color.apply_transfer(@color.ColorDescription::new(1, 99, false), 128),
      )
      false
    } catch {
      @color.UnsupportedTransfer(_) => true
      _ => false
    },
  )
}

///|
test "4:2:0 upsampling is nearest-neighbour and deterministic" {
  // 2x2 picture: one chroma sample for the whole thing, four luma samples.
  let y = b"\x10\x20\x30\x40"
  let u = b"\x80"
  let v = b"\x80"
  let img = @color.yuv420p_to_rgba8(
    @color.ColorDescription::new(1, 1, false),
    y,
    u,
    v,
    2L,
    2L,
  )
  assert_eq(img.width, 2L)
  assert_eq(img.height, 2L)
  assert_eq(img.data.length(), 16)
  // Every pixel is opaque, and left/right differ only through luma.
  for i in 0..<4 {
    assert_eq(img.data[i * 4 + 3], b'\xFF')
  }
  let (r0, _, _, _) = img.pixel(0L, 0L)
  let (r1, _, _, _) = img.pixel(1L, 0L)
  assert_true(r1 > r0)
}

///|
test "alpha composition replaces the alpha byte only" {
  let img = @color.yuv420p_to_rgba8(
    @color.ColorDescription::new(1, 1, false),
    b"\x80",
    b"\x80",
    b"\x80",
    1L,
    1L,
  )
  let with_alpha = @color.apply_alpha(img, b"\x40")
  assert_eq(with_alpha.pixel(0L, 0L), (130, 130, 130, 64))
}

///|
test "RGBA allocation size is 64-bit and refuses the 32-bit wrap" {
  // 50000 x 50000 x 4 = 1e10 bytes: a 32-bit Int wraps to 1410065408,
  // which would silently allocate a picture far too small. Int64 keeps the
  // true size and `safe.narrow` refuses it at the allocation boundary.
  let w = 50000L
  let h = 50000L
  let size = @safe.mul(@safe.mul(w, h), 4L)
  assert_eq(size, 10000000000L)
  assert_eq(w.to_int() * h.to_int() * 4, 1410065408) // 32-bit counterexample
  assert_true(
    try {
      ignore(@safe.narrow(size))
      false
    } catch {
      @safe.Overflow => true
    },
  )
}

///|
test "a short colour plane is refused, not read past its end" {
  assert_true(
    try {
      ignore(
        @color.yuv420p_to_rgba8(
          @color.ColorDescription::new(1, 1, false),
          b"\x80",
          b"",
          b"",
          2L,
          2L,
        ),
      )
      false
    } catch {
      @color.InvalidGeometry => true
      _ => false
    },
  )
}
