// PNG encoder for M4. The chunk layer is ours so that 16-bit containers and
// ICC profiles are under our control; the DEFLATE stream comes from MoonBit
// core's `compress/zlib`, which also supplies the zlib framing PNG requires.

///|
/// The eight bytes every PNG stream starts with.
pub let signature : Bytes = b"\x89PNG\r\n\x1a\n"

///|
/// Whether `data` starts with the PNG signature.
pub fn has_signature(data : Bytes) -> Bool {
  guard data.length() >= 8 else { return false }
  for i in 0..<8 {
    guard data[i] == signature[i] else { return false }
  }
  true
}

///|
/// Why a picture cannot be written as PNG.
pub suberror PngError {
  /// A zero or unindexable dimension, or a buffer that is too short.
  InvalidImage
}

///|
/// Options for the encoder. `bit_depth` is 8 or 16; `icc` is the raw profile
/// payload from a `colr`/`prof` box, carried verbatim into `iCCP`.
pub(all) struct EncodeOptions {
  bit_depth : Int32
  /// DEFLATE level 0..=9, passed to core zlib.
  compression_level : Int32
  icc : Bytes?
}

///|
pub fn EncodeOptions::default() -> EncodeOptions {
  { bit_depth: 8, compression_level: 6, icc: None, }
}

///|
/// CRC-32 (IEEE 802.3) over a byte sequence. PNG uses the standard reflected
/// polynomial; MoonBit core's CRC32 is internal, so the table-free loop lives
/// here (a small, auditable 8-bit shift per byte).
pub fn crc32(data : Bytes) -> UInt32 {
  let mut crc : UInt32 = 0xFFFFFFFFU
  for byte in data {
    let mut c = crc ^ byte.to_uint()
    for _ in 0..<8 {
      c = if (c & 1U) != 0U { (c >> 1) ^ 0xEDB88320U } else { c >> 1 }
    }
    crc = c
  }
  crc ^ 0xFFFFFFFFU
}

///|
fn u32be(value : UInt32) -> Bytes {
  let out = FixedArray::make(4, b'\x00')
  out[0] = (value >> 24).land(0xFFU).to_byte()
  out[1] = (value >> 16).land(0xFFU).to_byte()
  out[2] = (value >> 8).land(0xFFU).to_byte()
  out[3] = value.land(0xFFU).to_byte()
  Bytes::from_array(out)
}

///|
fn chunk(typ : Bytes, data : Bytes) -> Bytes {
  let crc_input : Array[Byte] = []
  for b in typ {
    crc_input.push(b)
  }
  for b in data {
    crc_input.push(b)
  }
  let parts : Array[Byte] = []
  for b in u32be(data.length().reinterpret_as_uint()) {
    parts.push(b)
  }
  for b in typ {
    parts.push(b)
  }
  for b in data {
    parts.push(b)
  }
  for b in u32be(crc32(Bytes::from_array(crc_input))) {
    parts.push(b)
  }
  Bytes::from_array(parts)
}

///|
/// PNG filter type 1 (Sub): each byte is stored as the difference from the
/// byte `bpp` positions to its left. Filtering is what makes DEFLATE useful
/// on a gradient; type 0 (None) would also be valid, just larger.
fn filter_sub(data : BytesView, width : Int64, bpp : Int64) -> Bytes {
  // PNG scanlines are: one filter byte, then `width * bpp` sample bytes.
  // Filter type 1 (Sub) stores each byte as its difference from the byte
  // `bpp` positions to the left (zero when there is no left neighbour).
  let stride = @safe.mul(width, bpp)
  let rows = data.length().to_int64() / stride
  let out = FixedArray::make((rows * (stride + 1L)).to_int(), b'\x00')
  for y in 0..<rows.to_int() {
    let src = y.to_int64() * stride
    let dst = y.to_int64() * (stride + 1L)
    out[dst.to_int()] = b'\x01'
    for i in 0..<stride.to_int() {
      let cur = data[(src + i.to_int64()).to_int()]
      let left = if i.to_int64() < bpp {
        b'\x00'
      } else {
        data[(src + i.to_int64() - bpp).to_int()]
      }
      out[(dst + 1L + i.to_int64()).to_int()] = cur - left
    }
  }
  Bytes::from_array(out)
}

///|
/// Build the scanline stream for an RGBA picture at the requested bit depth.
/// PNG 16-bit samples are big-endian; `Rgba8::to_rgba16` produces that order.
fn scanlines(
  image : @color.Rgba8,
  options : EncodeOptions,
) -> Bytes raise PngError {
  let bpp : Int64 = if options.bit_depth == 16 { 8L } else { 4L }
  let raw = if options.bit_depth == 16 {
    image.to_rgba16() catch {
      _ => raise InvalidImage
    }
  } else {
    image.data
  }
  let expected = @safe.mul(@safe.mul(image.width, image.height), bpp)
  if raw.length().to_int64() < expected {
    raise InvalidImage
  }
  filter_sub(raw[:expected.to_int()], image.width, bpp)
}

///|
/// Encode an RGBA picture to PNG.
///
/// Layout: signature, IHDR, optional iCCP, IDAT, IEND. Colour type 6 (RGBA)
/// with bit depth 8 or 16. `iCCP` stores the profile name plus a zero byte
/// and the zlib-compressed profile, exactly as PNG 1.2 §11.3.3.3 specifies.
pub fn encode(
  image : @color.Rgba8,
  options~ : EncodeOptions = EncodeOptions::default(),
) -> Bytes raise PngError {
  if image.width <= 0L ||
    image.height <= 0L ||
    image.width > 1L << 20 ||
    image.height > 1L << 20 ||
    (options.bit_depth != 8 && options.bit_depth != 16) {
    raise InvalidImage
  }
  let level = options.compression_level.clamp(min=0, max=9)
  let out : Array[Byte] = []
  for b in signature {
    out.push(b)
  }
  let ihdr = FixedArray::make(13, b'\x00')
  let w : UInt32 = image.width.to_int().reinterpret_as_uint()
  let h : UInt32 = image.height.to_int().reinterpret_as_uint()
  let iw = u32be(w)
  let ih = u32be(h)
  for i in 0..<4 {
    ihdr[i] = iw[i]
    ihdr[4 + i] = ih[i]
  }
  ihdr[8] = options.bit_depth.to_byte()
  ihdr[9] = b'\x06' // colour type 6: RGBA
  ihdr[10] = b'\x00' // compression: DEFLATE
  ihdr[11] = b'\x00' // filter: adaptive (we emit Sub)
  ihdr[12] = b'\x00' // interlace: none
  for b in chunk(b"IHDR", Bytes::from_array(ihdr)) {
    out.push(b)
  }
  match options.icc {
    None => ()
    Some(profile) => {
      // Profile name: an empty name is legal, so the payload is a single NUL,
      // a zero compression method byte, then the compressed profile.
      let iccp : Array[Byte] = [b'\x00', b'\x00']
      let compressed = @zlib.compress(profile, strategy=@flate.Standard(level~))
      for b in compressed {
        iccp.push(b)
      }
      for b in chunk(b"iCCP", Bytes::from_array(iccp)) {
        out.push(b)
      }
    }
  }
  let raw = scanlines(image, options)
  let idat = @zlib.compress(raw, strategy=@flate.Standard(level~))
  for b in chunk(b"IDAT", idat) {
    out.push(b)
  }
  for b in chunk(b"IEND", b"") {
    out.push(b)
  }
  Bytes::from_array(out)
}
