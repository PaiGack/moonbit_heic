///|
/// The `nal_unit_type` field of a NAL unit header, Table 7-1.
pub(all) enum NALType {
  TrailN
  TrailR
  TsaN
  TsaR
  StsaN
  StsaR
  RadlN
  RadlR
  RaslN
  RaslR
  // 10..15 are reserved.
  BlaWLp
  BlaWRadl
  BlaNLp
  IdrWRadl
  IdrNLp
  Cra
  // 22..31 are reserved.
  Vps
  Sps
  Pps
  Aud
  Eos
  Eob
  Fd
  PrefixSei
  SuffixSei
}

///|
/// The numeric value of a type, as it is written on the wire.
pub fn NALType::code(self : NALType) -> Int32 {
  match self {
    TrailN => 0
    TrailR => 1
    TsaN => 2
    TsaR => 3
    StsaN => 4
    StsaR => 5
    RadlN => 6
    RadlR => 7
    RaslN => 8
    RaslR => 9
    BlaWLp => 16
    BlaWRadl => 17
    BlaNLp => 18
    IdrWRadl => 19
    IdrNLp => 20
    Cra => 21
    Vps => 32
    Sps => 33
    Pps => 34
    Aud => 35
    Eos => 36
    Eob => 37
    Fd => 38
    PrefixSei => 39
    SuffixSei => 40
  }
}

///|
/// The type of a numeric value, or `None` for a reserved one.
pub fn NALType::from_code(code : Int32) -> NALType? {
  match code {
    0 => Some(TrailN)
    1 => Some(TrailR)
    2 => Some(TsaN)
    3 => Some(TsaR)
    4 => Some(StsaN)
    5 => Some(StsaR)
    6 => Some(RadlN)
    7 => Some(RadlR)
    8 => Some(RaslN)
    9 => Some(RaslR)
    16 => Some(BlaWLp)
    17 => Some(BlaWRadl)
    18 => Some(BlaNLp)
    19 => Some(IdrWRadl)
    20 => Some(IdrNLp)
    21 => Some(Cra)
    32 => Some(Vps)
    33 => Some(Sps)
    34 => Some(Pps)
    35 => Some(Aud)
    36 => Some(Eos)
    37 => Some(Eob)
    38 => Some(Fd)
    39 => Some(PrefixSei)
    40 => Some(SuffixSei)
    _ => None
  }
}

///|
/// Whether the unit carries a coded slice segment.
pub fn NALType::is_vcl(self : NALType) -> Bool {
  self.code() < 32
}

///|
/// Whether the unit starts an instantaneous decoding refresh picture.
pub fn NALType::is_idr(self : NALType) -> Bool {
  self is IdrWRadl || self is IdrNLp
}

///|
/// Whether the unit starts an intra random access point picture.
pub fn NALType::is_irap(self : NALType) -> Bool {
  self.code() >= 16 && self.code() <= 21
}

///|
/// One parsed NAL unit.
pub(all) struct NALUnit {
  /// The unit type; reserved codes are kept numerically.
  type_ : Int32
  layer_id : Int32
  temporal_id : Int32
  /// The payload with the emulation prevention bytes removed.
  rbsp : Bytes
  /// Payload-relative positions of the removed bytes, needed because entry
  /// point offsets count bytes in the escaped payload.
  epb : Array[Int32]
}

///|
pub fn NALUnit::nal_type(self : NALUnit) -> NALType? {
  NALType::from_code(self.type_)
}

///|
/// Parses a single NAL unit with a two-byte header and no framing.
pub fn parse_nal(data : Bytes) -> NALUnit? {
  if data.length() < 2 {
    return None
  }

  let b0 = data[0].to_int()
  let b1 = data[1].to_int()
  // forbidden_zero_bit, and nuh_temporal_id_plus1 is one based.
  if (b0 & 0x80) != 0 || (b1 & 0x07) == 0 {
    return None
  }

  let (rbsp, epb) = unescape(data, 2)
  Some({
    type_: (b0 >> 1) & 0x3f,
    layer_id: ((b0 & 0x01) << 5) | (b1 >> 3),
    temporal_id: (b1 & 0x07) - 1,
    rbsp,
    epb,
  })
}

///|
/// Splits a start-code delimited byte stream into NAL units.
pub fn split_annex_b(data : Bytes) -> Array[NALUnit] {
  let nals = []
  let first = start_code(data, 0)
  guard first is Some((next, _)) else { return nals }

  let mut i = next

  while i < data.length() {
    let found = start_code(data, i)

    let mut end = data.length()
    let mut next = data.length()
    if found is Some((n, sc_start)) {
      next = n
      end = sc_start
      // The trailing zeros belong to the start code, not to the payload.
      while end > i && data[end - 1] == b'\x00' {
        end = end - 1
      }
    }

    match parse_nal(data.exact_view(start=i, end~).to_owned()) {
      Some(nal) => nals.push(nal)
      None => ()
    }

    if found is None {
      break
    }

    i = next
  }

  nals
}

///|
/// Splits length-prefixed NAL units, as framed inside an `hvcC` record.
pub fn split_hvcc(data : Bytes, length_size : Int32) -> Array[NALUnit] {
  let nals = []
  if length_size < 1 || length_size > 4 {
    return nals
  }

  let mut i = 0
  while i + length_size <= data.length() {
    let mut n = 0
    for j in 0..<length_size {
      n = (n << 8) | data[i + j].to_int()
    }
    i = i + length_size
    if n == 0 || i + n > data.length() {
      break
    }

    match parse_nal(data.exact_view(start=i, end=i + n).to_owned()) {
      Some(nal) => nals.push(nal)
      None => ()
    }

    i = i + n
  }

  nals
}

///|
/// Finds a start code at or after `off`, returning the payload start and the
/// position the start code itself begins at.
fn start_code(data : Bytes, off : Int32) -> (Int32, Int32)? {
  let mut i = off
  while i + 2 < data.length() {
    if data[i] == b'\x00' && data[i + 1] == b'\x00' {
      if data[i + 2] == b'\x01' {
        return Some((i + 3, i))
      }
      if i + 3 < data.length() &&
        data[i + 2] == b'\x00' &&
        data[i + 3] == b'\x01' {
        return Some((i + 4, i))
      }
    }
    i = i + 1
  }
  None
}

///|
/// Strips `00 00 03` emulation prevention bytes, recording their positions.
fn unescape(data : Bytes, from : Int32) -> (Bytes, Array[Int32]) {
  let rbsp = []
  let epb = []
  let mut i = from

  while i < data.length() {
    if i + 2 < data.length() &&
      data[i] == b'\x00' &&
      data[i + 1] == b'\x00' &&
      data[i + 2] == b'\x03' {
      rbsp.push(b'\x00')
      rbsp.push(b'\x00')
      epb.push(i)
      i = i + 3
    } else {
      rbsp.push(data[i])
      i = i + 1
    }
  }

  (Bytes::from_array(rbsp), epb)
}

///|
/// Converts a payload-relative byte position, as entry point offsets count
/// them, into an index into `rbsp`.
pub fn NALUnit::rbsp_offset(self : NALUnit, off : Int32) -> Int32 {
  let mut rbsp = off
  for p in self.epb {
    if p >= off {
      break
    }
    rbsp = rbsp - 1
  }
  rbsp
}

///|
/// The inverse of `rbsp_offset`.
pub fn NALUnit::nal_offset(self : NALUnit, off : Int32) -> Int32 {
  let mut off = off
  for p in self.epb {
    if p > off {
      break
    }
    off = off + 1
  }
  off
}

///|
/// Escapes a payload back into the byte form that carries no emulation
/// prevention ambiguity.
fn escape_rbsp(rbsp : Bytes) -> Bytes {
  let out = []
  let mut zeros = 0
  for b in rbsp {
    if zeros == 2 && b <= b'\x03' {
      out.push(b'\x03')
      zeros = 0
    }
    out.push(b)
    if b == b'\x00' {
      zeros = zeros + 1
    } else {
      zeros = 0
    }
  }
  Bytes::from_array(out)
}

///|
/// Serialises one NAL unit with its two-byte header, no start code.
pub fn marshal_nal(nal : NALUnit) -> Bytes {
  let body = escape_rbsp(nal.rbsp)
  let out = [
    ((nal.type_ << 1) | (nal.layer_id >> 5)).to_byte(),
    (((nal.layer_id & 0x1f) << 3) | ((nal.temporal_id + 1) & 0x07)).to_byte(),
  ]
  out.append(body.to_array())
  Bytes::from_array(out)
}

///|
/// Serialises NAL units as an Annex B stream, four-byte start codes.
pub fn marshal_annex_b(nals : Array[NALUnit]) -> Bytes {
  let out = []
  for nal in nals {
    out.push(b'\x00')
    out.push(b'\x00')
    out.push(b'\x00')
    out.push(b'\x01')
    out.append(marshal_nal(nal).to_array())
  }
  Bytes::from_array(out)
}

///|
/// Serialises NAL units with `length_size` byte length prefixes, as an
/// `hvcC` record frames them. `None` when a unit does not fit the prefix.
pub fn marshal_hvcc(nals : Array[NALUnit], length_size : Int32) -> Bytes? {
  if length_size < 1 || length_size > 4 {
    return None
  }

  let out = []
  for nal in nals {
    let body = marshal_nal(nal)
    if body.length() == 0 ||
      body.length().to_uint64() >= 1UL << (length_size * 8) {
      return None
    }
    for i in 0..<length_size {
      out.push(
        ((body.length() >> ((length_size - 1 - i) * 8)) & 0xff).to_byte(),
      )
    }
    out.append(body.to_array())
  }
  Some(Bytes::from_array(out))
}

///|
/// The RBSP payload of a NAL unit, escaping undone. A payload handed over with
/// the two-byte header already stripped is unescaped too, and an unescaped
/// payload passes through unchanged: a `00 00 03` in RBSP is a start code
/// candidate the encoder had to escape, so it never occurs in a valid RBSP.
fn nal_payload(data : Bytes) -> Bytes {
  let rbsp = []
  for i in 0..<data.length() {
    rbsp.push(data[i])
  }

  let len = rbsp.length()
  if len >= 2 {
    let b0 = rbsp[0].to_int()
    let b1 = rbsp[1].to_int()
    if (b0 & 0x80) == 0 && (b1 & 0x07) != 0 {
      let head = NALType::from_code((b0 >> 1) & 0x3f)
      if head is Some(Vps) || head is Some(Sps) || head is Some(Pps) {
        return unescape_own(Bytes::from_array(rbsp), 2)
      }
    }
  }
  unescape_own(Bytes::from_array(rbsp), 0)
}

///|
/// Strips emulation prevention bytes, dropping the positions: a caller that
/// works on a whole payload does not reorder what it reads.
fn unescape_own(data : Bytes, from : Int32) -> Bytes {
  let (rbsp, _) = unescape(data, from)
  rbsp
}
