// MIAF 7.3.6.7 transformations: irot, imir and the clean aperture. These run
// on the RGBA picture after colour conversion, in the order the specification
// mandates: crop first, then rotate, then mirror.

///|
/// Why a transformation cannot be applied.
pub suberror TransformError {
  /// A crop rectangle that leaves the picture.
  InvalidCrop
  /// A picture whose size cannot be indexed.
  InvalidGeometry
}

///|
/// The orientation an `irot` / `imir` pair describes.
pub(all) struct Orientation {
  /// Quarter turns anticlockwise, 0..=3.
  angle : Int32
  /// `Some(axis)` for `imir`: 0 = vertical axis, 1 = horizontal axis.
  mirror : Int32?
}

///|
/// A clean aperture in whole pixels, applied before rotation.
pub(all) struct Crop {
  width : Int64
  height : Int64
  x : Int64
  y : Int64
}

///|
/// Crop an RGBA picture. The rectangle is checked against the stored picture,
/// so a malformed `clap` is reported rather than reading outside the buffer.
pub fn crop(
  image : @color.Rgba8,
  rect : Crop,
) -> @color.Rgba8 raise TransformError {
  if rect.x < 0L ||
    rect.y < 0L ||
    rect.width <= 0L ||
    rect.height <= 0L ||
    rect.x + rect.width > image.width ||
    rect.y + rect.height > image.height {
    raise InvalidCrop
  }
  let out_size = @safe.mul(@safe.mul(rect.width, rect.height), 4L)
  let n = @safe.narrow(out_size) catch {
    @safe.Overflow => raise InvalidGeometry
  }
  let out = FixedArray::make(n, b'\x00')
  for y in 0..<rect.height.to_int() {
    let src = ((rect.y + y.to_int64()) * image.width + rect.x) * 4L
    let dst = y.to_int64() * rect.width * 4L
    for i in 0..<(rect.width * 4L).to_int() {
      out[dst.to_int() + i] = image.data[src.to_int() + i]
    }
  }
  { width: rect.width, height: rect.height, data: Bytes::from_array(out), }
}

///|
/// Apply `irot` (0/1/2/3 quarter turns anticlockwise) then `imir` (0 =
/// vertical-axis mirror, 1 = horizontal-axis mirror). The order is MIAF
/// 7.3.6.7: rotation first, mirror second.
pub fn orient(
  image : @color.Rgba8,
  orientation : Orientation,
) -> @color.Rgba8 raise TransformError {
  let turned = match orientation.angle % 4 {
    0 => image
    1 => rotate90(image)
    2 => rotate180(image)
    3 => rotate270(image)
    _ => raise InvalidGeometry
  }
  match orientation.mirror {
    None => turned
    Some(axis) =>
      match axis {
        0 => mirror_vertical(turned)
        1 => mirror_horizontal(turned)
        _ => raise InvalidGeometry
      }
  }
}

///|
fn rotate90(image : @color.Rgba8) -> @color.Rgba8 {
  // Anticlockwise 90: output is (h, w). out(x, y) = in(y, h-1-x).
  let out = FixedArray::make(image.data.length(), b'\x00')
  for oy in 0..<image.width.to_int() {
    for ox in 0..<image.height.to_int() {
      let sx = oy.to_int64()
      let sy = image.height - 1L - ox.to_int64()
      let s = (sy * image.width + sx) * 4L
      let d = (oy.to_int64() * image.height + ox.to_int64()) * 4L
      for c in 0..<4 {
        out[d.to_int() + c] = image.data[s.to_int() + c]
      }
    }
  }
  { width: image.height, height: image.width, data: Bytes::from_array(out), }
}

///|

///|
fn rotate180(image : @color.Rgba8) -> @color.Rgba8 {
  let out = FixedArray::make(image.data.length(), b'\x00')
  for y in 0..<image.height.to_int() {
    for x in 0..<image.width.to_int() {
      let s = (y.to_int64() * image.width + x.to_int64()) * 4L
      let d = (
          (image.height - 1L - y.to_int64()) * image.width +
          image.width -
          1L -
          x.to_int64()
        ) *
        4L
      for c in 0..<4 {
        out[d.to_int() + c] = image.data[s.to_int() + c]
      }
    }
  }
  { width: image.width, height: image.height, data: Bytes::from_array(out), }
}

///|
fn rotate270(image : @color.Rgba8) -> @color.Rgba8 {
  // Clockwise 90: output is (h, w). out(x, y) = in(w-1-y, x).
  let out = FixedArray::make(image.data.length(), b'\x00')
  for oy in 0..<image.width.to_int() {
    for ox in 0..<image.height.to_int() {
      let sx = image.width - 1L - oy.to_int64()
      let sy = ox.to_int64()
      let s = (sy * image.width + sx) * 4L
      let d = (oy.to_int64() * image.height + ox.to_int64()) * 4L
      for c in 0..<4 {
        out[d.to_int() + c] = image.data[s.to_int() + c]
      }
    }
  }
  { width: image.height, height: image.width, data: Bytes::from_array(out), }
}

///|

///|
fn mirror_vertical(image : @color.Rgba8) -> @color.Rgba8 {
  // Mirror about the vertical axis: flip x (left <-> right).
  let out = FixedArray::make(image.data.length(), b'\x00')
  for y in 0..<image.height.to_int() {
    for x in 0..<image.width.to_int() {
      let s = (y.to_int64() * image.width + x.to_int64()) * 4L
      let d = (y.to_int64() * image.width + image.width - 1L - x.to_int64()) *
        4L
      for c in 0..<4 {
        out[d.to_int() + c] = image.data[s.to_int() + c]
      }
    }
  }
  { width: image.width, height: image.height, data: Bytes::from_array(out), }
}

///|
fn mirror_horizontal(image : @color.Rgba8) -> @color.Rgba8 {
  // Mirror about the horizontal axis: flip y (top <-> bottom).
  let out = FixedArray::make(image.data.length(), b'\x00')
  for y in 0..<image.height.to_int() {
    for x in 0..<image.width.to_int() {
      let s = (y.to_int64() * image.width + x.to_int64()) * 4L
      let d = ((image.height - 1L - y.to_int64()) * image.width + x.to_int64()) *
        4L
      for c in 0..<4 {
        out[d.to_int() + c] = image.data[s.to_int() + c]
      }
    }
  }
  { width: image.width, height: image.height, data: Bytes::from_array(out), }
}

///|
/// Build the pipeline's own `Rgba8` from raw RGBA bytes, for tests and for
/// callers that already have a decoded RGBA buffer.
pub fn rgba8(
  width : Int64,
  height : Int64,
  data : Bytes,
) -> @color.Rgba8 raise TransformError {
  let expected = @safe.mul(@safe.mul(width, height), 4L)
  if width <= 0L || height <= 0L || data.length().to_int64() < expected {
    raise InvalidGeometry
  }
  { width, height, data, }
}

///|
/// The description of one decoded item: everything the render pipeline needs
/// that is not already in the pixel buffer.
pub(all) struct RenderInput {
  /// The decoded 4:2:0 luma/chroma planes and their geometry.
  y : Bytes
  u : Bytes
  v : Bytes
  width : Int64
  height : Int64
  /// Colour description from `colr` (or the bitstream's VUI).
  color : @color.ColorDescription
  /// `irot` / `imir`.
  orientation : Orientation
  /// `clap` clean aperture, already in stored-picture coordinates.
  crop_rect : Crop?
  /// `auxC` alpha plane, when the item has one.
  alpha : Bytes?
  /// `colr`/`prof` ICC payload, passed through to PNG `iCCP` / JPEG `APP2`.
  icc : Bytes?
}

///|
/// Render a decoded item to an RGBA picture, applying the transformations in
/// MIAF 7.3.6.7 order: clean aperture, colour conversion, alpha, then the
/// rotation/mirror pair.
pub fn render(input : RenderInput) -> @color.Rgba8 raise Error {
  let mut img = @color.yuv420p_to_rgba8(
    input.color,
    input.y,
    input.u,
    input.v,
    input.width,
    input.height,
  )
  match input.crop_rect {
    None => ()
    Some(rect) => img = crop(img, rect)
  }
  match input.alpha {
    None => ()
    Some(a) => img = @color.apply_alpha(img, a)
  }
  orient(img, input.orientation)
}

///|
/// Build a `ColorDescription` from the `colr` box fields. Without `nclx` the
/// bitstream's VUI is authoritative; the caller passes those when it has
/// them, and this function defaults to BT.709 limited range otherwise.
pub fn color_from_colr(
  matrix : Int32,
  transfer : Int32,
  full_range : Bool,
  has_nclx : Bool,
) -> @color.ColorDescription {
  if has_nclx {
    @color.ColorDescription::new(matrix, transfer, full_range)
  } else {
    @color.ColorDescription::default()
  }
}

///|
pub fn Crop::new(width : Int64, height : Int64, x : Int64, y : Int64) -> Crop {
  { width, height, x, y, }
}

///|
pub fn Orientation::new(angle : Int32, mirror : Int32?) -> Orientation {
  { angle, mirror, }
}
