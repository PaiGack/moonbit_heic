///|
/// The parameter sets and the pictures of one HEIC item, parsed.
///
/// This is the end of M2: a decoder given a `HeifItem` asks for its
/// `AccessUnit`, and everything the slice data needs to be read — the sequence,
/// the picture, and one header per coded slice — is here in the order the
/// element stream holds it.
pub(all) struct AccessUnit {
  vps : VPS?
  sps : SPS
  pps : PPS
  /// One per slice segment NAL unit, in stream order.
  slices : Array[SliceSegment]
  /// NAL units that carry no syntax this milestone reads: SEI, an access unit
  /// delimiter, an end of sequence.
  other : Array[NALUnit]
}

///|
/// One coded slice segment: its header, and the NAL unit it came out of.
///
/// The unit is kept rather than a copy of the slice data because entry point
/// offsets count bytes of the *escaped* payload, and `NALUnit::rbsp_offset`
/// is what converts one into an index into `rbsp`.
pub(all) struct SliceSegment {
  header : SliceHeader
  nal : NALUnit
}

///|
/// The parameter sets a HEIC item brings, in the order 23008-12 frames them.
///
/// Either the item carries a decoder configuration record and the sets are
/// length prefixed inside it, or the payload is an Annex B stream that starts
/// with them.
pub(all) struct HevcParams {
  /// The VPS, when the stream has one. A HEIC encodes one, but nothing in
  /// 7.4.3.1 makes it mandatory.
  vps : Bytes?
  sps : Bytes
  pps : Bytes
  /// The length prefix width of the record's parameter sets, 4 when they came
  /// out of the payload.
  length_size : Int32
  /// The coded slice segments and everything else, as they follow the sets.
  rest : Bytes
}

///|
/// Splits a stream into its parameter sets and the NAL units behind them.
///
/// Both framings arrive here: an `hvcC` record's length-prefixed body, and an
/// Annex B byte stream with start codes. Whichever it is, the last parameter
/// set of each kind wins, which is what a decoder does when a stream
/// re-declares them — and only the sets ahead of the first slice count,
/// because a parameter set after a slice belongs to the next picture.
pub fn HevcParams::split(
  stream : Bytes,
  length_size : Int32,
  annex_b : Bool,
) -> HevcParams raise Error {
  let nals = if annex_b {
    split_annex_b(stream)
  } else {
    split_hvcc(stream, length_size)
  }

  let mut vps : Bytes? = None
  let mut sps : Bytes? = None
  let mut pps : Bytes? = None
  let rest : Array[NALUnit] = []
  let mut seen_slice = false

  for n in nals {
    let kind = n.nal_type()
    if kind is Some(Vps) || kind is Some(Sps) || kind is Some(Pps) {
      if !seen_slice {
        match kind {
          Some(Vps) => vps = Some(n.rbsp)
          Some(Sps) => sps = Some(n.rbsp)
          Some(Pps) => pps = Some(n.rbsp)
          _ => ()
        }
      }
      continue
    }
    match kind {
      Some(t) => if t.is_vcl() { seen_slice = true }
      None => ()
    }
    rest.push(n)
  }

  match (sps, pps) {
    (Some(sps), Some(pps)) =>
      { vps, sps, pps, length_size, rest: marshal_annex_b(rest), }
    _ => raise Invalid
  }
}

///|
/// Parses a whole HEIC item into the structure M3 decodes from.
///
/// `payload` is the item's bytes as `iloc` addresses them; `param_sets` and
/// `length_size` are what the item's `hvcC` record lists, empty when the
/// payload carries the sets itself.
pub fn parse_access_unit(
  payload : Bytes,
  param_sets : Array[Bytes],
  length_size : Int32,
  annex_b : Bool,
) -> AccessUnit raise Error {
  let params = if param_sets.length() > 0 {
    // The record lists VPS, SPS, PPS each as a whole NAL unit, and the item
    // payload is the slice data framed the same way.
    let mut sps = None
    let mut pps = None
    let mut vps = None
    for set in param_sets {
      match parse_nal(set) {
        None => raise Invalid
        Some(n) =>
          match n.nal_type() {
            Some(Vps) => vps = Some(n.rbsp)
            Some(Sps) => sps = Some(n.rbsp)
            Some(Pps) => pps = Some(n.rbsp)
            _ => ()
          }
      }
    }
    match (sps, pps) {
      (Some(sps), Some(pps)) => { vps, sps, pps, length_size, rest: payload, }
      _ => raise Invalid
    }
  } else {
    HevcParams::split(payload, length_size, annex_b)
  }

  let sps = parse_sps_rbsp(params.sps)
  let pps = parse_pps_rbsp(params.pps)
  let vps = match params.vps {
    None => None
    Some(b) => Some(parse_vps_rbsp(b))
  }
  // A picture parameter set names the sequence it belongs to; one pointing
  // somewhere else describes a different picture, and decoding it would use
  // block geometry that does not match the slice addresses.
  if pps.sps_id != sps.id {
    raise Invalid
  }
  pps.resolve_tile_geometry(sps)

  let slices : Array[SliceSegment] = []
  let other : Array[NALUnit] = []
  let nals = if annex_b {
    split_annex_b(params.rest)
  } else {
    split_hvcc(params.rest, length_size)
  }
  for n in nals {
    match n.nal_type() {
      Some(t) =>
        if t.is_vcl() {
          slices.push({
            header: parse_slice_header_rbsp(n.rbsp, t, sps, pps),
            nal: n,
          })
        } else {
          other.push(n)
        }
      None => other.push(n)
    }
  }

  if slices.length() == 0 {
    raise Invalid
  }

  { vps, sps, pps, slices, other, }
}
