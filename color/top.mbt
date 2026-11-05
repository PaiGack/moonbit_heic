// M4 colour conversion. The arithmetic is integer-exact (fixed-point), like
// the rest of the decoder: every sample is an 8-bit plane value on the way in
// and an 8-bit RGBA sample on the way out.

///|
/// Why a colour description cannot be turned into pixels.
pub suberror ColorError {
  /// `matrix_coefficients` value this port has no matrix for.
  UnsupportedMatrix(Int32)
  /// `transfer_characteristics` value this port has no transfer function for.
  UnsupportedTransfer(Int32)
  /// A picture geometry that cannot be indexed (zero or too large).
  InvalidGeometry
}

///|
/// A colour transform, in the fixed-point form the decoder uses.
///
/// `kr` / `kb` are the luma weights scaled by `1 << shift`; `kg` is
/// `1 - kr - kb`, so the matrix is fully determined by the two of them.
pub(all) struct ColorMatrix {
  /// Weight of Y in R, etc. Scaled by `shift`.
  kr : Int32
  kb : Int32
  shift : Int32
}

///|
/// Fixed-point shift used by the VUI-derived transforms. `kr` / `kb` are
/// stored as `round(K * (1 << shift))`, so a shift of 16 means the weights
/// are 16.16 fixed-point, not the decimal-scaled literals a reader might
/// guess from `0.2126`.
pub let matrix_shift : Int32 = 16

///|
/// Derive the luma weights for a `MatrixCoefficients` value.
///
/// The three matrices HEIC stills actually use (H.273 Table 4). Values 0/2/3
/// and the identity matrices are not RGB output: 0 is GBR, 2 is unspecified,
/// 3 is YCgCo — report them rather than silently picking BT.709.
pub fn ColorMatrix::from_matrix_coefficients(
  matrix_coefficients : Int32,
) -> ColorMatrix raise ColorError {
  match matrix_coefficients {
    1 => { kr: 13933, kb: 4732, shift: matrix_shift, } // BT.709
    5 | 6 => { kr: 19595, kb: 7471, shift: matrix_shift, } // BT.601
    9 => { kr: 17219, kb: 3886, shift: matrix_shift, } // BT.2020 NCL
    _ => raise UnsupportedMatrix(matrix_coefficients)
  }
}

///|
/// Which `colr` / VUI fields the conversion actually honours.
pub(all) struct ColorDescription {
  /// `matrix_coefficients`.
  matrix : Int32
  /// `transfer_characteristics`.
  transfer : Int32
  /// `video_full_range_flag`.
  full_range : Bool
}

///|
/// The default an item with no `nclx` gets: BT.709, limited range.
pub fn ColorDescription::default() -> ColorDescription {
  { matrix: 1, transfer: 1, full_range: false, }
}

///|
/// Transfer characteristics that pass through unchanged, on the grounds that
/// the display transfer is already the sRGB-ish one PNG/JPEG expect.
pub fn transfer_is_identity(transfer : Int32) -> Bool {
  // 1 = BT.709, 2 = unspecified, 6 = SMPTE 170M, 13 = sRGB,
  // 14/15 = BT.2020 10/12-bit (same OETF as 1, just a different depth).
  transfer == 1 ||
  transfer == 2 ||
  transfer == 6 ||
  transfer == 13 ||
  transfer == 14 ||
  transfer == 15
}

///|
/// PQ (SMPTE ST 2084) maps a code value to a display-linear light level. The
/// "minimal mapping" this port promises is a fixed 1000-nit peak: invert the
/// PQ EOTF, then clip to 0..1 so the output stays display-referred SDR.
pub fn pq_to_linear(code : Int32) -> Double {
  let n = code.to_double() / 1023.0
  let m1 = 2610.0 / 16384.0
  let m2 = 2523.0 / 4096.0 * 128.0
  let c1 = 3424.0 / 4096.0
  let c2 = 2413.0 / 4096.0 * 32.0
  let c3 = 2392.0 / 4096.0 * 32.0
  let p = @math.pow(n, 1.0 / m2)
  let num = (p - c1).max(0.0)
  let den = c2 - c3 * p
  let linear = @math.pow(num / den, 1.0 / m1)
  (linear * 10.0).min(1.0).max(0.0)
}

///|
/// HLG (ARIB STD-B67) inverse OETF, then the BT.2100 reference EOTF with a
/// 1000-nit system gamma of 1.2. Same "clip to SDR" contract as PQ.
pub fn hlg_to_linear(code : Int32) -> Double {
  let e = code.to_double() / 1023.0
  let a = 0.17883277
  let b = 0.28466892
  let c = 0.55991073
  let scene = if e <= 0.5 {
    e * e / 3.0
  } else {
    (@math.exp((e - c) / a) + b) / 12.0
  }
  let linear = @math.pow(scene, 1.2)
  linear.min(1.0).max(0.0)
}

///|
/// Apply the transfer characteristic to an 8-bit luma/chroma sample.
///
/// PQ / HLG get the minimal SDR tone map above; everything else is either a
/// pass-through or reported as unsupported, never guessed.
pub fn apply_transfer(
  desc : ColorDescription,
  sample : Int32,
) -> Int32 raise ColorError {
  if transfer_is_identity(desc.transfer) {
    return sample
  }
  match desc.transfer {
    16 => (pq_to_linear(sample) * 255.0).to_int()
    18 => (hlg_to_linear(sample) * 255.0).to_int()
    _ => raise UnsupportedTransfer(desc.transfer)
  }
}

///|
/// Clamp an integer-exact sample to 0..255.
fn clamp8(v : Int64) -> Int32 {
  if v < 0L {
    0
  } else if v > 255L {
    255
  } else {
    v.to_int()
  }
}

///|
/// Integer-exact YUV→RGB for one triple, with 4:2:0 nearest-neighbour
/// upsampling done by the caller (it hands us the U/V for this pixel).
///
/// Limited range follows H.273: Y in 16..235, C in 16..240 with 128 neutral;
/// full range uses 0..255 for all three. The matrix coefficients are derived
/// from `kr`/`kb` so BT.709 (kr=0.2126) and BT.2020 (kr=0.2627) share one
/// code path.
pub fn yuv_to_rgb(
  desc : ColorDescription,
  matrix : ColorMatrix,
  y : Int32,
  u : Int32,
  v : Int32,
) -> (Int32, Int32, Int32) {
  let (yy, uu, vv) = if desc.full_range {
    (y.to_int64(), u.to_int64() - 128L, v.to_int64() - 128L)
  } else {
    (
      ((y.to_int64() - 16L) * 255L + 109L) / 219L,
      ((u.to_int64() - 128L) * 255L + 112L) / 224L,
      ((v.to_int64() - 128L) * 255L + 112L) / 224L,
    )
  }
  let s = matrix.shift
  let one = 1L << s
  let kr = matrix.kr.to_int64()
  let kb = matrix.kb.to_int64()
  let kg = one - kr - kb
  // R = Y + 2(1-kr)V, B = Y + 2(1-kb)U,
  // G = Y - 2(kr(1-kr)V + kb(1-kb)U)/kg.
  let r = yy + (2L * (one - kr) * vv + (one >> 1)) / one
  let b = yy + (2L * (one - kb) * uu + (one >> 1)) / one
  let g = yy -
    (2L * (kr * (one - kr) * vv + kb * (one - kb) * uu) + (kg >> 1)) /
    (one * kg)
  (clamp8(r), clamp8(g), clamp8(b))
}

///|
/// An 8-bit RGBA picture, row-major, four bytes per pixel.
///
/// Dimensions are `Int64` because a picture width is a size; the backing
/// array is sized through `safe` at the allocation boundary and narrowed once.
pub(all) struct Rgba8 {
  width : Int64
  height : Int64
  /// Exactly `width * height * 4` bytes.
  data : Bytes
}

///|
pub fn Rgba8::pixel(
  self : Rgba8,
  x : Int64,
  y : Int64,
) -> (Int32, Int32, Int32, Int32) raise ColorError {
  if x < 0L || y < 0L || x >= self.width || y >= self.height {
    raise InvalidGeometry
  }
  let off = (y * self.width + x) * 4L
  (
    self.data[off.to_int()].to_int(),
    self.data[(off + 1L).to_int()].to_int(),
    self.data[(off + 2L).to_int()].to_int(),
    self.data[(off + 3L).to_int()].to_int(),
  )
}

///|
/// Convert a planar 8-bit 4:2:0 picture to RGBA with nearest-neighbour
/// chroma upsampling. `y`, `u`, `v` are the three planes; the chroma planes
/// have `ceil(width/2) * ceil(height/2)` samples each.
///
/// Transfer characteristics are applied to luma before the matrix, which is
/// where PQ/HLG tone mapping belongs (display-referred SDR output).
pub fn yuv420p_to_rgba8(
  desc : ColorDescription,
  y_plane : Bytes,
  u_plane : Bytes,
  v_plane : Bytes,
  width : Int64,
  height : Int64,
) -> Rgba8 raise ColorError {
  let matrix = ColorMatrix::from_matrix_coefficients(desc.matrix)
  if width <= 0L || height <= 0L || width > 1L << 20 || height > 1L << 20 {
    raise InvalidGeometry
  }
  let cw = (width + 1L) / 2L
  let ch = (height + 1L) / 2L
  let luma_size = @safe.mul(width, height)
  let chroma_size = @safe.mul(cw, ch)
  if y_plane.length().to_int64() < luma_size ||
    u_plane.length().to_int64() < chroma_size ||
    v_plane.length().to_int64() < chroma_size {
    raise InvalidGeometry
  }
  let out_size = @safe.mul(luma_size, 4L)
  let n = @safe.narrow(out_size) catch {
    @safe.Overflow => raise InvalidGeometry
  }
  let out = FixedArray::make(n, b'\x00')
  for y in 0..<height.to_int() {
    let cy = y / 2
    let row = y.to_int64() * width
    let crow = cy.to_int64() * cw
    for x in 0..<width.to_int() {
      let cx = x / 2
      let yi = row + x.to_int64()
      let ci = crow + cx.to_int64()
      let yv = apply_transfer(desc, y_plane[yi.to_int()].to_int())
      let (r, g, b) = yuv_to_rgb(
        desc,
        matrix,
        yv,
        u_plane[ci.to_int()].to_int(),
        v_plane[ci.to_int()].to_int(),
      )
      let o = yi.to_int() * 4
      out[o] = r.to_byte()
      out[o + 1] = g.to_byte()
      out[o + 2] = b.to_byte()
      out[o + 3] = b'\xFF'
    }
  }
  { width, height, data: Bytes::from_array(out), }
}

///|
/// Compose an alpha plane (8-bit, full-size) into an RGBA picture.
///
/// `auxC` alpha is a monochrome HEVC item; its luma plane is the alpha
/// channel, with the same geometry as the colour picture. A shorter plane is
/// an error rather than a silent partial composite.
pub fn apply_alpha(image : Rgba8, alpha : Bytes) -> Rgba8 raise ColorError {
  let size = @safe.mul(image.width, image.height)
  if alpha.length().to_int64() < size {
    raise InvalidGeometry
  }
  let out = FixedArray::make(image.data.length(), b'\x00')
  for i in 0..<size.to_int() {
    let o = i * 4
    out[o] = image.data[o]
    out[o + 1] = image.data[o + 1]
    out[o + 2] = image.data[o + 2]
    out[o + 3] = alpha[i]
  }
  { width: image.width, height: image.height, data: Bytes::from_array(out), }
}

///|
/// Build a colour description from the fields an `nclx` box carries.
pub fn ColorDescription::new(
  matrix : Int32,
  transfer : Int32,
  full_range : Bool,
) -> ColorDescription {
  { matrix, transfer, full_range, }
}

///|
/// Widen an 8-bit RGBA picture to a 16-bit-per-channel one by replicating the
/// byte into both halves of the 16-bit sample (PNG's rule for 8→16bit).
///
/// `pixi` declaring 10bit is what makes the 16-bit container necessary; the
/// decoder is 8-bit only, so this is an honest widening, not invented detail.
pub fn Rgba8::to_rgba16(self : Rgba8) -> Bytes raise ColorError {
  let n = @safe.narrow(@safe.mul(self.data.length().to_int64(), 2L)) catch {
    @safe.Overflow => raise InvalidGeometry
  }
  let out = FixedArray::make(n, b'\x00')
  for i in 0..<self.data.length() {
    out[i * 2] = self.data[i]
    out[i * 2 + 1] = self.data[i]
  }
  Bytes::from_array(out)
}
