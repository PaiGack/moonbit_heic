// Baseline JPEG encoder for M4. RGBA in, JFIF/ICC-marked baseline JPEG out.
// No subsampling (4:4:4): one 8x8 block per component per MCU, which keeps
// the entropy coder honest and the output readable by any decoder. Tables
// come from ITU T.81 Annex K; quality scales the quantisation tables the
// same way libjpeg does.

///|
/// The two bytes that open a JPEG frame.
pub let soi : Array[Int32] = [0xFF, 0xD8]

///|
/// The two bytes that close it.
pub let eoi : Array[Int32] = [0xFF, 0xD9]

///|
/// Whether `data` starts with SOI and is at least a marker pair long.
pub fn has_soi(data : Bytes) -> Bool {
  guard data.length() >= 2 else { return false }
  data[0].to_int() == soi[0] && data[1].to_int() == soi[1]
}

///|
/// Why a picture cannot be written as JPEG.
pub suberror JpegError {
  /// A zero or unindexable dimension, or a buffer that is too short.
  InvalidImage
}

///|
/// Encoder options: quality 1..=100 (clamped) and the optional raw ICC
/// profile from a `colr`/`prof` box, carried into APP2 segments.
pub(all) struct EncodeOptions {
  quality : Int32
  icc : Bytes?
}

///|
pub fn EncodeOptions::default() -> EncodeOptions {
  { quality: 85, icc: None, }
}

///|
/// A JPEG marker segment: two bytes `FF xx` plus a big-endian length that
/// counts itself but not the marker.
fn marker(code : Int32, payload : Bytes) -> Bytes {
  let len = payload.length() + 2
  let out : Array[Byte] = [
    b'\xFF',
    code.to_byte(),
    (len / 256).to_byte(),
    (len % 256).to_byte(),
  ]
  for b in payload {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// Bit sink. Entropy-coded data is a bit stream; a `0xFF` byte must be
/// followed by a stuffed `0x00` so it cannot be mistaken for a marker.
priv struct BitWriter {
  out : Array[Byte]
  mut acc : Int32
  mut nbits : Int32
}

///|
fn BitWriter::new() -> BitWriter {
  { out: [], acc: 0, nbits: 0, }
}

///|
fn BitWriter::write_bits(
  self : BitWriter,
  value : Int32,
  length : Int32,
) -> Unit {
  if length <= 0 {
    return
  }
  let v = value
  let mut n = length
  while n > 0 {
    // Emit the top bit of this length-wide value.
    let bit = (v >> (n - 1)) & 1
    self.acc = (self.acc << 1) | bit
    self.nbits += 1
    if self.nbits == 8 {
      let byte = self.acc.to_byte()
      self.out.push(byte)
      if byte == b'\xFF' {
        self.out.push(b'\x00')
      }
      self.acc = 0
      self.nbits = 0
    }
    n -= 1
  }
}

///|
fn BitWriter::flush(self : BitWriter) -> Unit {
  while self.nbits > 0 {
    self.write_bits(1, 1)
  }
}

///|
fn BitWriter::to_bytes(self : BitWriter) -> Bytes {
  Bytes::from_array(self.out)
}

///|
/// A canonical Huffman table built from the spec's "bits" (code lengths) and
/// "values" (symbols), giving the code and length for each symbol.
priv struct HuffTable {
  codes : Array[Int32]
  lengths : Array[Int32]
}

///|
fn HuffTable::build(bits : Array[Int32], values : Array[Int32]) -> HuffTable {
  let codes = Array::make(256, 0)
  let lengths = Array::make(256, 0)
  let mut code = 0
  let mut k = 0
  for len in 1..<16 {
    for _ in 0..<bits[len - 1] {
      codes[values[k]] = code
      lengths[values[k]] = len
      code += 1
      k += 1
    }
    code = code << 1
  }
  { codes, lengths, }
}

///|
fn HuffTable::emit(self : HuffTable, w : BitWriter, symbol : Int32) -> Unit {
  w.write_bits(self.codes[symbol], self.lengths[symbol])
}

///|
/// Precomputed cosine factors for the 8x8 forward DCT.
fn dct_cosines() -> Array[Double] {
  let c = Array::make(64, 0.0)
  for u in 0..<8 {
    for x in 0..<8 {
      c[u * 8 + x] = @math.cos(
        (2 * x + 1).to_double() * u.to_double() * @math.PI / 16.0,
      )
    }
  }
  c
}

///|
/// Quality-scaled quantisation table, in zig-zag order like the base tables.
fn scale_quant(base : Array[Int32], quality : Int32) -> Array[Int32] {
  let q = quality.clamp(min=1, max=100)
  let scale = if q < 50 { 5000 / q } else { 200 - 2 * q }
  let out : Array[Int32] = []
  for v in base {
    let scaled = (v * scale + 50) / 100
    out.push(scaled.clamp(min=1, max=255))
  }
  out
}

///|
/// The amplitude category of a coefficient (JPEG Table F.1): the number of
/// bits needed to hold its magnitude.
fn category(value : Int32) -> Int32 {
  let mut v = if value < 0 { -value } else { value }
  let mut n = 0
  while v > 0 {
    n += 1
    v = v >> 1
  }
  n
}

///|
/// Encode one signed amplitude after its category: positive is the value
/// itself, negative is the one's complement of the magnitude.
fn amplitude_bits(value : Int32, size : Int32) -> Int32 {
  if value < 0 {
    value + (1 << size) - 1
  } else {
    value
  }
}

///|
/// Forward 8x8 DCT of a block of level-shifted samples (-128..127), returned
/// in natural (row-major) order.
fn fdct(block : Array[Double]) -> Array[Double] {
  let c = dct_cosines()
  let out = Array::make(64, 0.0)
  for v in 0..<8 {
    for u in 0..<8 {
      let mut sum = 0.0
      for y in 0..<8 {
        for x in 0..<8 {
          sum += block[y * 8 + x] * c[u * 8 + x] * c[v * 8 + y]
        }
      }
      let cu = if u == 0 { 0.7071067811865476 } else { 1.0 }
      let cv = if v == 0 { 0.7071067811865476 } else { 1.0 }
      out[v * 8 + u] = 0.25 * cu * cv * sum
    }
  }
  out
}

///|
/// RGB → YCbCr (ITU T.871, full-range JPEG conversion), written into three
/// sample arrays of `width * height` values, level-shifted to -128..127.
fn rgb_to_ycbcr(
  image : @color.Rgba8,
) -> (Array[Double], Array[Double], Array[Double]) {
  let n = (image.width * image.height).to_int()
  let yy = Array::make(n, 0.0)
  let cb = Array::make(n, 0.0)
  let cr = Array::make(n, 0.0)
  for i in 0..<n {
    let r = image.data[i * 4].to_int().to_double()
    let g = image.data[i * 4 + 1].to_int().to_double()
    let b = image.data[i * 4 + 2].to_int().to_double()
    yy[i] = 0.299 * r + 0.587 * g + 0.114 * b - 128.0
    cb[i] = -0.168736 * r - 0.331264 * g + 0.5 * b
    cr[i] = 0.5 * r - 0.418688 * g - 0.081312 * b
  }
  (yy, cb, cr)
}

///|
/// Encode all MCUs. Each MCU is one 8x8 block of Y, Cb and Cr (4:4:4), so
/// the loop is regular and the three DC predictors are independent.
fn entropy_encode(
  image : @color.Rgba8,
  quant_y : Array[Int32],
  quant_c : Array[Int32],
  w : BitWriter,
) -> Unit {
  let (y, cb, cr) = rgb_to_ycbcr(image)
  let dc_y = HuffTable::build(dc_luma_bits, dc_luma_values)
  let ac_y = HuffTable::build(ac_luma_bits, ac_luma_values)
  let dc_c = HuffTable::build(dc_chroma_bits, dc_chroma_values)
  let ac_c = HuffTable::build(ac_chroma_bits, ac_chroma_values)
  let blocks_x = ((image.width + 7L) / 8L).to_int()
  let blocks_y = ((image.height + 7L) / 8L).to_int()
  let mut prev_dc_y = 0
  let mut prev_dc_cb = 0
  let mut prev_dc_cr = 0
  for by in 0..<blocks_y {
    for bx in 0..<blocks_x {
      let planes = [y, cb, cr]
      let quants = [quant_y, quant_c, quant_c]
      let dcs = [dc_y, dc_c, dc_c]
      let acs = [ac_y, ac_c, ac_c]
      let prev = [prev_dc_y, prev_dc_cb, prev_dc_cr]
      for comp in 0..<3 {
        // Gather the block, replicating edge samples past the picture.
        let block = Array::make(64, 0.0)
        for row in 0..<8 {
          for col in 0..<8 {
            let x = (bx * 8 + col).to_int64().min(image.width - 1L)
            let yy2 = (by * 8 + row).to_int64().min(image.height - 1L)
            block[row * 8 + col] = planes[comp][(yy2 * image.width + x).to_int()]
          }
        }
        let coeffs = fdct(block)
        let q = quants[comp]
        let zz = Array::make(64, 0)
        for k in 0..<64 {
          zz[k] = (coeffs[zigzag[k]] / q[k].to_double() + 0.5).to_int()
        }
        let dc = zz[0]
        let diff = dc - prev[comp]
        prev[comp] = dc
        let cat = category(diff)
        dcs[comp].emit(w, cat)
        w.write_bits(amplitude_bits(diff, cat), cat)
        // AC: run/size pairs, ending with EOB or a final ZRL.
        let mut run = 0
        for k in 1..<64 {
          if zz[k] == 0 {
            run += 1
            continue
          }
          while run > 15 {
            acs[comp].emit(w, 0xF0) // ZRL: 16 zero coefficients
            run -= 16
          }
          let size = category(zz[k])
          acs[comp].emit(w, run * 16 + size)
          w.write_bits(amplitude_bits(zz[k], size), size)
          run = 0
        }
        if run > 0 {
          acs[comp].emit(w, 0x00) // EOB
        }
      }
      prev_dc_y = prev[0]
      prev_dc_cb = prev[1]
      prev_dc_cr = prev[2]
    }
  }
  w.flush()
}

///|
/// APP2 ICC profile segments. ICC profiles can exceed one segment's 65533
/// byte payload, so the profile is split into numbered chunks.
fn icc_segments(profile : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let max = 65533 - 14 // "ICC_PROFILE\0" + seq + count
  let mut off = 0
  let mut seq = 1
  let count = (profile.length() + max - 1) / max
  while off < profile.length() {
    let n = (profile.length() - off).min(max)
    let payload : Array[Byte] = []
    for b in b"ICC_PROFILE\x00" {
      payload.push(b)
    }
    payload.push(seq.to_byte())
    payload.push(count.to_byte())
    for b in profile[off:off + n] {
      payload.push(b)
    }
    for b in marker(0xE2, Bytes::from_array(payload)) {
      out.push(b)
    }
    off += n
    seq += 1
  }
  Bytes::from_array(out)
}

///|
/// Encode an RGBA picture to a baseline JPEG.
///
/// Layout: SOI, APP0 (JFIF), optional APP2 (ICC), DQT (two tables), SOF0
/// (3-component 4:4:4), DHT (four tables), SOS, entropy data, EOI. Alpha is
/// composited over white, since JPEG has no alpha channel.
pub fn encode(
  image : @color.Rgba8,
  options~ : EncodeOptions = EncodeOptions::default(),
) -> Bytes raise JpegError {
  if image.width <= 0L ||
    image.height <= 0L ||
    image.width > 1L << 20 ||
    image.height > 1L << 20 {
    raise InvalidImage
  }
  let expected = @safe.mul(@safe.mul(image.width, image.height), 4L)
  if image.data.length().to_int64() < expected {
    raise InvalidImage
  }
  let q = options.quality.clamp(min=1, max=100)
  let quant_y = scale_quant(quant_luma, q)
  let quant_c = scale_quant(quant_chroma, q)
  let out : Array[Byte] = [b'\xFF', b'\xD8']
  for b in marker(0xE0, b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00") {
    out.push(b)
  }
  match options.icc {
    None => ()
    Some(profile) =>
      if profile.length() > 0 {
        for b in icc_segments(profile) {
          out.push(b)
        }
      }
  }
  // DQT: table 0 (luma), table 1 (chroma), values in zig-zag order.
  let dqt : Array[Byte] = []
  dqt.push(b'\x00')
  for v in quant_y {
    dqt.push(v.to_byte())
  }
  dqt.push(b'\x01')
  for v in quant_c {
    dqt.push(v.to_byte())
  }
  for b in marker(0xDB, Bytes::from_array(dqt)) {
    out.push(b)
  }
  // SOF0: 8-bit, height, width, 3 components, 4:4:4 sampling.
  let h = image.height.to_int()
  let w = image.width.to_int()
  let sof0 : Array[Byte] = [
    b'\x08',
    (h / 256).to_byte(),
    (h % 256).to_byte(),
    (w / 256).to_byte(),
    (w % 256).to_byte(),
    b'\x03',
    b'\x01',
    b'\x11',
    b'\x00',
    b'\x02',
    b'\x11',
    b'\x01',
    b'\x03',
    b'\x11',
    b'\x01',
  ]
  for b in marker(0xC0, Bytes::from_array(sof0)) {
    out.push(b)
  }
  // DHT: DC luma (0x00), AC luma (0x10), DC chroma (0x01), AC chroma (0x11).
  let tables : Array[(Int32, Array[Int32], Array[Int32])] = [
    (0x00, dc_luma_bits, dc_luma_values),
    (0x10, ac_luma_bits, ac_luma_values),
    (0x01, dc_chroma_bits, dc_chroma_values),
    (0x11, ac_chroma_bits, ac_chroma_values),
  ]
  for (id, bits, values) in tables {
    let dht : Array[Byte] = [id.to_byte()]
    for n in bits[0:16] {
      dht.push(n.to_byte())
    }
    for v in values {
      dht.push(v.to_byte())
    }
    for b in marker(0xC4, Bytes::from_array(dht)) {
      out.push(b)
    }
  }
  // SOS: 3 components, DC/AC table selectors, spectral 0..63, successive 0.
  let sos : Array[Byte] = [
    b'\x03', b'\x01', b'\x00', b'\x02', b'\x11', b'\x03', b'\x11', b'\x00', b'\x3F',
    b'\x00',
  ]
  for b in marker(0xDA, Bytes::from_array(sos)) {
    out.push(b)
  }
  let w = BitWriter::new()
  entropy_encode(image, quant_y, quant_c, w)
  for b in w.to_bytes() {
    out.push(b)
  }
  out.push(b'\xFF')
  out.push(b'\xD9')
  Bytes::from_array(out)
}
