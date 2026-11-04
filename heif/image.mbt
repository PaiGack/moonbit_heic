///|
/// How a picture is oriented: the `irot` quarter turns and the `imir` axis, in
/// the order MIAF 7.3.6.7 says to apply them.
pub(all) struct Transform {
  /// Quarter turns anticlockwise, 0..=3.
  angle : Int32
  /// `Some(axis)` when an `imir` box is present: 0 mirrors about a vertical
  /// axis, 1 about a horizontal one.
  mirror : Int32?
}

///|
/// What one decoded picture of the file looks like before any decoding: the
/// geometry, the bit depth, the colour description and the decoder
/// configuration the bitstream needs.
///
/// This is the structure M1 delivers. Everything downstream — CABAC, residual
/// reconstruction, YUV to RGB — takes an `ImageItem` plus its payload.
pub(all) struct ImageItem {
  id : Int64
  /// `hvc1`, `grid`, … as the file declares it.
  item_type : String
  /// The stored size, inside any clean aperture the item declares.
  width : Int64
  height : Int64
  /// The size before the aperture: what `ispe` says.
  stored_width : Int64
  stored_height : Int64
  /// The clean aperture in effect, or `None` when the item declares none.
  aperture : CleanAperture?
  /// Luma bit depth, 8 for an 8-bit profile and 10 for Main 10.
  bit_depth : Int32
  chroma_bit_depth : Int32
  /// `chroma_format_idc`: 0 mono, 1 4:2:0, 2 4:2:2, 3 4:4:4.
  chroma_format : Int32
  color : ColorInfo
  /// The `hvcC` record, parameter sets included. A grid has none of its own
  /// and takes its first tile's.
  hvc_c : HEVCConfig?
  /// The item's bytes, exactly as `iloc` addresses them.
  payload : Bytes
  transform : Transform
  /// Set when the picture is a stitch of tiles rather than one coded frame.
  grid : GridInfo?
  /// The item ids of the tiles, when it is a grid.
  tiles : Array[Int64]
  /// The auxiliary item carrying alpha, when the file has one.
  alpha : Int64?
}

///|
/// The item's size the way the file states it, aperture applied.
#warnings("-result_error_return")
fn HeifFile::item_size(
  self : HeifFile,
  it : Item,
) -> Result[(Int64, Int64), HeifError] {
  let ispe = match self.meta.prop(it, "ispe") {
    None => return Err(Invalid)
    Some(p) => p
  }
  if ispe.width <= 0L ||
    ispe.height <= 0L ||
    ispe.width > 1L << 20 ||
    ispe.height > 1L << 20 {
    return Err(Invalid)
  }
  let (sw, sh) = self.subsampling_of(it)
  match self.aperture_of(it, ispe.width, ispe.height, sw, sh) {
    Some(c) => Ok((c.width, c.height))
    None => Ok((ispe.width, ispe.height))
  }
}

///|
/// `SubWidthC` and `SubHeightC` of Table 6-1, from the item's decoder
/// configuration — a grid takes its first tile's, as libheif reads it.
fn HeifFile::subsampling_of(self : HeifFile, it : Item) -> (Int64, Int64) {
  let mut cfg = self.meta.prop(it, "hvcC")
  if cfg is None && it.typ == "grid" {
    let tiles = self.meta.refs_to("dimg", it.id)
    if tiles.length() > 0 {
      match self.meta.items.get(tiles[0]) {
        Some(tile) => cfg = self.meta.prop(tile, "hvcC")
        None => ()
      }
    }
  }
  match cfg {
    None => (2L, 2L)
    Some(p) =>
      match p.hvc_c {
        None => (2L, 2L)
        Some(c) =>
          match c.chroma_format {
            0 | 3 => (1L, 1L)
            1 => (2L, 2L)
            _ => (2L, 1L)
          }
      }
  }
}

///|
/// The item's clean aperture, when it has one that lands on the chroma grid.
///
/// An aperture that does not align with the subsampling grid is one a decoder
/// cannot apply without resampling, so it is ignored rather than approximated.
fn HeifFile::aperture_of(
  self : HeifFile,
  it : Item,
  w : Int64,
  h : Int64,
  sw : Int64,
  sh : Int64,
) -> CleanAperture? {
  let p = match self.meta.prop(it, "clap") {
    None => return None
    Some(p) => p
  }
  match crop_rect(p.clap, w, h) {
    None => None
    Some(c) =>
      if c.horiz_off % sw != 0L || c.vert_off % sh != 0L {
        None
      } else {
        Some(c)
      }
  }
}

///|
/// The colour description of an item.
///
/// The bitstream's VUI declares one, and a `colr` box replaces it whole — but
/// only the `nclx` half does; an ICC profile travels alongside rather than
/// instead. A grid without a description of its own takes its first tile's.
fn HeifFile::color_of(self : HeifFile, it : Item) -> ColorInfo {
  let ci : ColorInfo = {
    primaries: 2,
    transfer: 2,
    matrix: 2,
    full_range: false,
    icc: None,
    has_nclx: false,
  }
  let mut nclx = None
  let mut icc = None
  for (index, _) in it.props {
    if index < 0 || index >= self.meta.props.length() {
      continue
    }
    let p = self.meta.props[index]
    if p.typ != "colr" {
      continue
    }
    match p.colr {
      None => ()
      Some(c) => {
        if c.has_nclx {
          nclx = Some(c)
        }
        match c.icc {
          None => ()
          Some(profile) => icc = Some(profile)
        }
      }
    }
  }

  if it.typ == "grid" && (nclx is None || icc is None) {
    for tile in self.meta.refs_to("dimg", it.id) {
      let t = match self.meta.items.get(tile) {
        None => continue
        Some(t) => t
      }
      let tc = self.color_of(t)
      if nclx is None && tc.has_nclx {
        nclx = Some(tc)
      }
      match tc.icc {
        None => ()
        Some(profile) => if icc is None { icc = Some(profile) }
      }
    }
  }

  match nclx {
    Some(c) => {
      ci.primaries = c.primaries
      ci.transfer = c.transfer
      ci.matrix = c.matrix
      ci.full_range = c.full_range
      ci.has_nclx = true
    }
    None => ()
  }
  ci.icc = icc
  ci
}

///|
/// The orientation boxes of an item.
fn HeifFile::transform_of(self : HeifFile, it : Item) -> Transform {
  let angle = match self.meta.prop(it, "irot") {
    None => 0
    Some(p) => p.angle
  }
  let mirror = match self.meta.prop(it, "imir") {
    None => None
    Some(p) => Some(p.axis)
  }
  { angle, mirror, }
}

///|
/// Describes an item without decoding it: geometry, bit depth, colour, the
/// decoder configuration and the payload bytes.
///
/// This is the "掏出来" half of M1: everything a decoder needs to be handed,
/// and nothing that would make a reader pay for the media data of a file it
/// only wants the header of.
#warnings("-result_error_return")
pub fn HeifFile::describe_item(
  self : HeifFile,
  item_id : Int64,
) -> Result[ImageItem, HeifError] {
  let it = match self.meta.items.get(item_id) {
    None => return Err(Invalid)
    Some(it) => it
  }
  if it.unsupported {
    return Err(Unsupported)
  }

  let (width, height) = match self.item_size(it) {
    Ok(size) => size
    Err(_) => return Err(Invalid)
  }
  let ispe = match self.meta.prop(it, "ispe") {
    None => return Err(Invalid)
    Some(p) => p
  }
  let (sw, sh) = self.subsampling_of(it)
  let aperture = self.aperture_of(it, ispe.width, ispe.height, sw, sh)

  let payload = match self.item_payload(item_id) {
    Ok(p) => p
    Err(err) => return Err(err)
  }

  let cfg = self.meta.prop(it, "hvcC")

  let mut grid = None
  let mut tiles = []
  if it.typ == "grid" {
    match self.grid_info(item_id) {
      Ok(g) => {
        grid = Some(g)
        tiles = match self.grid_tiles(item_id) {
          Ok(t) => t
          Err(err) => return Err(err)
        }
      }
      Err(err) => return Err(err)
    }
  }

  let alpha = match self.alpha_of(item_id) {
    None => None
    Some(a) => Some(a.id)
  }

  let item_type = it.typ
  let mut bit_depth = 8
  let mut chroma_bit_depth = 8
  let mut chroma_format = 1
  // A grid carries no configuration of its own; its tiles do, and the first
  // one speaks for all of them.
  let mut config_source = cfg
  if config_source is None && it.typ == "grid" && tiles.length() > 0 {
    match self.meta.items.get(tiles[0]) {
      None => ()
      Some(tile) => config_source = self.meta.prop(tile, "hvcC")
    }
  }
  let mut hvc_config = None
  match cfg {
    None => ()
    Some(p) =>
      match p.hvc_c {
        None => ()
        Some(c) => {
          bit_depth = c.bit_depth_luma
          chroma_bit_depth = c.bit_depth_chroma
          chroma_format = c.chroma_format
          hvc_config = Some(c)
        }
      }
  }
  // The record a caller needs to feed a decoder is the item's own; for a grid
  // it is the first tile's, and `tiles` says where the rest live.
  if hvc_config is None {
    match config_source {
      None => ()
      Some(p) =>
        match p.hvc_c {
          None => ()
          Some(c) => {
            bit_depth = c.bit_depth_luma
            chroma_bit_depth = c.bit_depth_chroma
            chroma_format = c.chroma_format
          }
        }
    }
  }

  Ok({
    id: item_id,
    item_type,
    width,
    height,
    stored_width: ispe.width,
    stored_height: ispe.height,
    aperture,
    bit_depth,
    chroma_bit_depth,
    chroma_format,
    color: self.color_of(it),
    hvc_c: hvc_config,
    payload,
    transform: self.transform_of(it),
    grid,
    tiles,
    alpha,
  })
}

///|
/// The picture the file is *about*: `pitm`, described.
///
/// A file whose primary item is a thumbnail is not one this port tries to
/// second-guess — `pitm` is authoritative. What the thumbnail relation buys is
/// `thumbnail_of`, so a caller that wants the small one asks for it by name.
#warnings("-result_error_return")
pub fn HeifFile::primary_image(self : HeifFile) -> Result[ImageItem, HeifError] {
  let it = match self.primary_item() {
    Ok(it) => it
    Err(err) => return Err(err)
  }
  self.describe_item(it.id)
}
