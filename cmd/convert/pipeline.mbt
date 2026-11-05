// The M5 conversion pipeline shared by the CLI. `convert` classifies every
// failure into one of the four exit buckets so `heic2png` never prints a
// stack trace for a picture it simply refuses.

///|
/// Why one input could not be turned into a file, with the exit code attached.
pub(all) enum ConvertError {
  /// The file does not exist / could not be read / could not be written, or
  /// the command line was unusable. Exit 1.
  Input(String)
  /// The container or bitstream is a profile this port never decodes: 10-bit,
  /// 4:2:2 / 4:4:4, P/B frames, grid, multi-slice, WPP/tiles. Exit 2.
  Unsupported(String)
  /// A Main 8-bit 4:2:0 I frame that malformed or could not be decoded, or
  /// the colour / encoder stage failed. Exit 3.
  Decode(String)
}

///|
pub fn ConvertError::message(self : ConvertError) -> String {
  match self {
    Input(m) | Unsupported(m) | Decode(m) => m
  }
}

///|
pub fn ConvertError::exit_code(self : ConvertError) -> Int32 {
  match self {
    Input(_) => exit_input
    Unsupported(_) => exit_unsupported
    Decode(_) => exit_decode
  }
}

///|
/// The whole pipeline: container → access unit → YUV → RGBA → encoded file.
/// `opts.format` decides the encoder; a 16-bit request is ignored for JPEG,
/// which is 8-bit by definition.
pub fn convert(data : Bytes, opts : Options) -> Result[Bytes, ConvertError] {
  let file = match @heif.parse(data) {
    Ok(f) => f
    Err(_) => return Err(Input("invalid HEIF container"))
  }
  let item = match file.primary_image() {
    Ok(it) => it
    Err(_) => return Err(Unsupported("no readable primary image"))
  }
  if item.item_type == "grid" {
    return Err(Unsupported("grid images are not supported by this port"))
  }
  let cfg = match item.hvc_c {
    None =>
      return Err(Unsupported("primary item has no HEVC decoder configuration"))
    Some(c) => c
  }
  // The container's decoder configuration record declares the profile up
  // front. A Main 10 / 4:2:2 / deep picture is out of scope regardless of
  // what the SPS later says, so refuse it before touching the bitstream.
  if cfg.profile_idc != 1 && cfg.profile_idc != 3 {
    return Err(
      Unsupported(
        "HEVC profile_idc \{cfg.profile_idc} (Main / Main Still Picture only)",
      ),
    )
  }
  if cfg.chroma_format != 1 {
    return Err(Unsupported("chroma format \{cfg.chroma_format} (4:2:0 only)"))
  }
  if cfg.bit_depth_luma != 8 || cfg.bit_depth_chroma != 8 {
    return Err(Unsupported("\{cfg.bit_depth_luma}-bit luma (8-bit only)"))
  }
  let au = @hevc.parse_access_unit(
    item.payload,
    cfg.param_sets,
    cfg.length_size,
    false,
  ) catch {
    @hevc.UnsupportedProfile(profile_idc~, chroma_format_idc~, bit_depth_luma~) =>
      return Err(
        Unsupported(
          "unsupported profile (idc=\{profile_idc}, chroma=\{chroma_format_idc}, depth=\{bit_depth_luma})",
        ),
      )
    _ => return Err(Decode("cannot parse the HEVC access unit"))
  }
  // The SPS is the authority on what the picture actually is; a stale or
  // optimistic hvcC must not let a 10-bit / 4:2:2 stream through.
  if au.sps.bit_depth_luma != 8 || au.sps.bit_depth_chroma != 8 {
    return Err(Unsupported("\{au.sps.bit_depth_luma}-bit luma (8-bit only)"))
  }
  if au.sps.chroma_format_idc != 1 || au.sps.separate_colour_plane {
    return Err(
      Unsupported("chroma format \{au.sps.chroma_format_idc} (4:2:0 only)"),
    )
  }
  let frame = match @decode.decode_i_frame(au.sps, au.pps, au) {
    Ok(f) => f
    Err(err) => return Err(decode_failure(err))
  }
  let desc = if item.color.has_nclx {
    @color.ColorDescription::new(
      item.color.matrix,
      item.color.transfer,
      item.color.full_range,
    )
  } else if au.sps.matrix_coefficients == 1 ||
    au.sps.matrix_coefficients == 5 ||
    au.sps.matrix_coefficients == 6 ||
    au.sps.matrix_coefficients == 9 {
    @color.ColorDescription::new(
      au.sps.matrix_coefficients,
      au.sps.transfer_characteristics,
      au.sps.full_range,
    )
  } else {
    @color.ColorDescription::default()
  }
  let crop_rect = match item.aperture {
    None => None
    Some(c) =>
      Some(@image.Crop::new(c.width, c.height, c.horiz_off, c.vert_off))
  }
  let alpha = decode_alpha(file, item)
  let input : @image.RenderInput = {
    y: Bytes::from_array(frame.y),
    u: Bytes::from_array(frame.u),
    v: Bytes::from_array(frame.v),
    width: frame.width,
    height: frame.height,
    color: desc,
    orientation: { angle: item.transform.angle, mirror: item.transform.mirror, },
    crop_rect,
    alpha,
    icc: item.color.icc,
  }
  let rgba = @image.render(input) catch {
    _ => return Err(Decode("colour / transform pipeline failed"))
  }
  let icc = item.color.icc
  if opts.format.is_jpeg() {
    let bytes = @jpeg.encode(rgba, options={ quality: opts.quality, icc, }) catch {
      _ => return Err(Decode("JPEG encoding failed"))
    }
    Ok(bytes)
  } else {
    let bytes = @png.encode(rgba, options={
      bit_depth: if opts.bit16 {
        16
      } else {
        8
      },
      compression_level: 6,
      icc,
    }) catch {
      _ => return Err(Decode("PNG encoding failed"))
    }
    Ok(bytes)
  }
}

///|
/// M3 refuses some streams on purpose; those are scope refusals (exit 2),
/// everything else is a genuine decode failure (exit 3).
fn decode_failure(err : @decode.DecodeError) -> ConvertError {
  match err {
    UnsupportedProfile => Unsupported("HEVC profile outside Main 8-bit 4:2:0")
    NotISlice => Unsupported("P / B slices are not decoded (I frames only)")
    NotImplemented =>
      Unsupported("multi-slice / tiles / WPP are not implemented")
    InvalidStream | TooLarge => Decode("M3 decoder refused the frame")
  }
}

///|
/// Decode the `auxC` alpha item when the file links one. Its luma plane is
/// the alpha channel; a decode failure simply means no alpha, matching
/// libheif's "auxiliary image is optional" behaviour.
fn decode_alpha(file : @heif.HeifFile, item : @heif.ImageItem) -> Bytes? {
  let id = match item.alpha {
    None => return None
    Some(a) => a
  }
  let aux = match file.describe_item(id) {
    Ok(a) => a
    Err(_) => return None
  }
  let cfg = match aux.hvc_c {
    None => return None
    Some(c) => c
  }
  let au = @hevc.parse_access_unit(
    aux.payload,
    cfg.param_sets,
    cfg.length_size,
    false,
  ) catch {
    _ => return None
  }
  match @decode.decode_i_frame(au.sps, au.pps, au) {
    Ok(f) => Some(Bytes::from_array(f.y))
    Err(_) => None
  }
}
