///|
/// The `HEVCDecoderConfigurationRecord` of ISO/IEC 14496-15, E.2.3.
///
/// The parameter sets travel in this record rather than in the item data, and
/// the length prefix size is what says how the item data is sliced into NAL
/// units.
pub(all) struct HEVCConfig {
  /// `chroma_format_idc`, 0..=3.
  chroma_format : Int32
  /// Bit depth, already biased: the record stores it minus eight.
  bit_depth_luma : Int32
  bit_depth_chroma : Int32
  /// Bytes of the length prefix in front of each NAL unit, 1..=4.
  length_size : Int32
  /// VPS, SPS, PPS … in the order the record lists them.
  param_sets : Array[Bytes]
  /// `general_profile_idc`, kept for the CLI's one-line description.
  profile_idc : Int32
  level_idc : Int32
}

///|
/// The colour description an item carries, from `nclx` or an ICC profile.
///
/// 23008-12 lets a picture carry both at once, in a `colr` box each, and a
/// `colr` box replaces the description the bitstream's VUI declared whole.
pub(all) struct ColorInfo {
  mut primaries : Int32
  mut transfer : Int32
  mut matrix : Int32
  mut full_range : Bool
  /// The raw ICC profile payload, when the item carries one.
  mut icc : Bytes?
  /// Whether the fields above came from an `nclx` box.
  mut has_nclx : Bool
}

///|
/// Which `colr` box a property holds, since an item may carry two.
pub(all) enum ColrKind {
  Nclx
  ICC
}

///|
/// An `ispe` or `clap` box expressed as the numbers a caller can act on.
pub(all) struct CleanAperture {
  width : Int64
  height : Int64
  horiz_off : Int64
  vert_off : Int64
}

///|
/// One property of an `ipco` box.
///
/// Only the fields a matching box type fills are meaningful; the rest keep
/// their default. A `typ` this port does not implement still gets an entry, so
/// that an essential association to it can be recognised as unsupported
/// instead of silently ignored.
pub(all) struct Property {
  mut typ : BoxType
  mut width : Int64
  mut height : Int64
  mut hvc_c : HEVCConfig?
  mut pixi : Array[Int32]
  mut aux_c : String
  /// Quarter turns anticlockwise, 0..=3.
  mut angle : Int32
  /// 0 for a vertical axis, 1 for horizontal.
  mut axis : Int32
  mut clap : Array[Int64]
  mut colr : ColorInfo?
  mut colr_kind : ColrKind
}

///|
fn Property::new(typ : BoxType) -> Property {
  {
    typ,
    width: 0L,
    height: 0L,
    hvc_c: None,
    pixi: [],
    aux_c: "",
    angle: 0,
    axis: 0,
    clap: [],
    colr: None,
    colr_kind: Nclx,
  }
}

///|
/// The property types this reader implements.
///
/// An item associated *essentially* with anything else must not be processed:
/// the file says a reader that does not understand the box will misrender the
/// picture, which is exactly the case this function exists to detect.
fn known_property(typ : BoxType) -> Bool {
  match typ {
    "ispe" | "hvcC" | "pixi" | "auxC" | "irot" | "imir" | "clap" | "colr" =>
      true
    _ => false
  }
}

///|
/// Reads the `HEVCDecoderConfigurationRecord`.
///
/// Everything before the arrays is fixed width. The profile and level fields
/// are only kept for display: the parameter sets themselves are what a decoder
/// needs, and they are already parsed out here.
fn parse_hvc_c(r : Reader) -> HEVCConfig? {
  let configuration_version = r.u8()
  // profile_space(2) | tier_flag(1) | profile_idc(5)
  let profile_and_tier = r.u8()
  let profile_idc = profile_and_tier & 0x1F
  ignore(r.u32())
  ignore(r.uint(6))
  let level_idc = r.u8()
  ignore(r.u16())
  ignore(r.u8())
  let chroma_format = r.u8() & 3
  // The record stores both depths biased by eight.
  let bit_depth_luma = (r.u8() & 7) + 8
  let bit_depth_chroma = (r.u8() & 7) + 8
  ignore(r.u16())
  let length_size = (r.u8() & 3) + 1
  let arrays = r.u8()
  if r.err || configuration_version != 1 {
    return None
  }
  let param_sets = []
  for _ in 0..<arrays {
    r.skip(1)
    let n = r.u16()
    for _ in 0..<n {
      let len = r.u16()
      match r.bytes(len) {
        None => return None
        Some(nal) => param_sets.push(nal)
      }
    }
  }
  if r.err {
    return None
  }

  Some({
    chroma_format,
    bit_depth_luma,
    bit_depth_chroma,
    length_size,
    param_sets,
    profile_idc,
    level_idc,
  })
}

///|
/// Reads one `ipco` child into a property.
fn parse_property(typ : BoxType, payload : Bytes) -> Property? {
  let p = Property::new(typ)
  let r = Reader::new(payload)

  match typ {
    "ispe" => {
      ignore(r.full_box())
      p.width = r.u32().to_int64()
      p.height = r.u32().to_int64()
    }
    "hvcC" => p.hvc_c = parse_hvc_c(r)
    "pixi" => {
      ignore(r.full_box())
      let n = r.u8()
      for _ in 0..<n {
        p.pixi.push(r.u8())
      }
    }
    "auxC" => {
      ignore(r.full_box())
      p.aux_c = r.cstr()
    }
    "irot" => p.angle = r.u8() & 3
    "imir" => p.axis = r.u8() & 1
    "clap" =>
      for _ in 0..<8 {
        p.clap.push(r.u32().to_int64())
      }
    "colr" => {
      let kind = r.str4()
      let c : ColorInfo = {
        primaries: 2,
        transfer: 2,
        matrix: 2,
        full_range: false,
        icc: None,
        has_nclx: false,
      }
      if kind == "nclx" {
        c.primaries = r.u16()
        c.transfer = r.u16()
        c.matrix = r.u16()
        c.full_range = r.u8() >> 7 != 0
        c.has_nclx = true
        p.colr_kind = Nclx
        p.colr = Some(c)
      } else if kind == "rICC" || kind == "prof" {
        // An ICC profile is opaque to this port; the payload after the type
        // is what a colour management layer would hand upstream.
        c.icc = Some(
          payload.exact_view(start=4, end=payload.length()).to_owned(),
        )
        p.colr_kind = ICC
        p.colr = Some(c)
      }
    }
    _ => ()
  }

  if r.err {
    return None
  }
  Some(p)
}
