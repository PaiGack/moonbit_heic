///|
/// Derives the clean aperture rectangle of a `clap` box inside a picture of
/// `w` by `h`, in whole pixels.
///
/// The box states everything in fractions throughout, and upstream's version
/// divides by four of those denominators. Each one is checked to be positive
/// first, so a malformed box comes back as `None` instead of a division trap —
/// which is the whole reason `safe/` exists in this project.
///
/// The arithmetic runs in `Int64`: `w * horizD` is a dimension times a
/// denominator, and both are 64-bit quantities once a writer is allowed to
/// hand us its own.
pub fn crop_rect(clap : Array[Int64], w : Int64, h : Int64) -> CleanAperture? {
  guard clap.length() >= 8 else { return None }
  // The fields are written as signed 32-bit fractions, so a numerator that
  // walked past 2^31 is a negative offset rather than a huge one.
  let width_num = sign_extend_32(clap[0])
  let width_den = sign_extend_32(clap[1])
  let height_num = sign_extend_32(clap[2])
  let height_den = sign_extend_32(clap[3])
  let horiz_num = sign_extend_32(clap[4])
  let horiz_den = sign_extend_32(clap[5])
  let vert_num = sign_extend_32(clap[6])
  let vert_den = sign_extend_32(clap[7])

  if width_den <= 0L || height_den <= 0L || horiz_den <= 0L || vert_den <= 0L {
    return None
  }
  if width_num < 0L || height_num < 0L {
    return None
  }
  if width_num % width_den != 0L || height_num % height_den != 0L {
    return None
  }
  let clap_w = width_num / width_den
  let clap_h = height_num / height_den

  let num_x = w * horiz_den + 2L * horiz_num - clap_w * horiz_den
  let den_x = 2L * horiz_den
  let num_y = h * vert_den + 2L * vert_num - clap_h * vert_den
  let den_y = 2L * vert_den
  if num_x % den_x != 0L || num_y % den_y != 0L {
    return None
  }
  let x = num_x / den_x
  let y = num_y / den_y

  if x < 0L || y < 0L || clap_w <= 0L || clap_h <= 0L {
    return None
  }
  if x + clap_w > w || y + clap_h > h {
    return None
  }

  Some({ width: clap_w, height: clap_h, horiz_off: x, vert_off: y, })
}

///|
/// Reinterprets the low 32 bits of a value as a signed number.
///
/// `clap` stores its eight fractions as `uint32` on the wire but means them
/// signed; upstream spells that `int64(int32(v))`, and the round trip is what
/// turns `0xFFFFFFFF` into `-1`.
pub fn sign_extend_32(value : Int64) -> Int64 {
  let low = value & 0xFFFFFFFFL
  if low >= 0x80000000L {
    low - 0x100000000L
  } else {
    low
  }
}
