///|
test "crop_rect is the identity when the aperture is the whole picture" {
  // 640/1 x 480/1, centred on a 640x480 picture.
  let clap = [640L, 1L, 480L, 1L, 0L, 1L, 0L, 1L]
  let c = @heif.crop_rect(clap, 640L, 480L).unwrap()
  assert_eq(c.width, 640L)
  assert_eq(c.height, 480L)
  assert_eq(c.horiz_off, 0L)
  assert_eq(c.vert_off, 0L)
}

///|
test "crop_rect reads the fractions as signed" {
  // A centred half-size aperture: 320x240 at (+160, +120).
  let clap = [320L, 1L, 240L, 1L, 0L, 1L, 0L, 1L]
  let c = @heif.crop_rect(clap, 640L, 480L).unwrap()
  assert_eq(c.width, 320L)
  assert_eq(c.height, 240L)
  assert_eq(c.horiz_off, 160L)
  assert_eq(c.vert_off, 120L)
}

///|
test "crop_rect rejects a zero denominator instead of dividing by it" {
  for
    clap in [
      [320L, 0L, 240L, 1L, 0L, 1L, 0L, 1L],
      [320L, 1L, 240L, 0L, 0L, 1L, 0L, 1L],
      [320L, 1L, 240L, 1L, 0L, 0L, 0L, 1L],
      [320L, 1L, 240L, 1L, 0L, 1L, 0L, 0L],
    ] {
    assert_true(@heif.crop_rect(clap, 640L, 480L) is None)
  }
}

///|
test "crop_rect rejects a negative denominator" {
  let clap = [320L, -1L, 240L, 1L, 0L, 1L, 0L, 1L]
  assert_true(@heif.crop_rect(clap, 640L, 480L) is None)
}

///|
test "crop_rect rejects an aperture larger than the picture" {
  let clap = [1280L, 1L, 960L, 1L, 0L, 1L, 0L, 1L]
  assert_true(@heif.crop_rect(clap, 640L, 480L) is None)
}

///|
test "crop_rect rejects a fractional pixel" {
  // 1000/3 is not a whole number of samples.
  let clap = [1000L, 3L, 480L, 1L, 0L, 1L, 0L, 1L]
  assert_true(@heif.crop_rect(clap, 640L, 480L) is None)
}

///|
test "crop_rect reports a short array as absent, not as zeroes" {
  assert_true(@heif.crop_rect([], 640L, 480L) is None)
  assert_true(@heif.crop_rect([320L, 1L, 240L], 640L, 480L) is None)
}

///|
test "sign_extend_32 turns the wire's uint32 back into a signed fraction" {
  assert_eq(@heif.sign_extend_32(0L), 0L)
  assert_eq(@heif.sign_extend_32(1L), 1L)
  assert_eq(@heif.sign_extend_32(0xFFFFFFFEL), -2L)
  assert_eq(@heif.sign_extend_32(0xFFFFFFFFL), -1L)
  // Only the low 32 bits are the field.
  assert_eq(@heif.sign_extend_32(0x1_00000001L), 1L)
}

///|
test "a negative numerator is refused rather than read as a huge size" {
  // A writer that meant -1 as a width numerator gets the same answer as one
  // that meant UINT32_MAX: the aperture is unusable.
  let clap = [0xFFFFFFFFL, 1L, 240L, 1L, 0L, 1L, 0L, 1L]
  assert_true(@heif.crop_rect(clap, 640L, 480L) is None)
}
