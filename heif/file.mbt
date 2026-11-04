///|
/// The brands that mean "this file holds a HEVC coded image".
///
/// `mif1` / `msf1` alone say only that the file is a HEIF, and an AVIF is the
/// same container with a different codec; a HEIC names one of these in its
/// compatible brands.
let hevc_brands : Array[String] = [
  "heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs",
]

///|
/// A parsed HEIF file: the box tree's interesting boxes, plus the raw bytes
/// they address.
///
/// The media data is never copied here. An item's payload is sliced out of
/// `data` on demand, so parsing a 4 MB photo costs the header alone until a
/// caller asks for the picture.
pub(all) struct HeifFile {
  /// The `ftyp` box, when the file has one at the front.
  ftyp : BoxView?
  meta : Meta
  /// The whole file, which is what `iloc` offsets are relative to.
  data : Bytes
}

///|
/// Parses a HEIF file.
///
/// The top level is walked once, taking `ftyp` and the first `meta`. A
/// `mdat` is not read here: items point into it and are read when asked.
#warnings("-result_error_return")
pub fn parse(data : Bytes) -> Result[HeifFile, HeifError] {
  if data.length() < 8 {
    return Err(Invalid)
  }

  let walk = each_box(data, 0L)
  let mut ftyp = None
  let mut meta = None
  for box in walk.boxes {
    match box.typ {
      "ftyp" => if ftyp is None { ftyp = Some(box) }
      "meta" =>
        if meta is None {
          meta = Some(
            parse_meta(box.payload) catch {
              _ => return Err(Invalid)
            },
          )
        }
      // The MinimizedImageBox of the low overhead profile replaces `meta`
      // whole, so a file built on it is one we can read nothing from rather
      // than a malformed one.
      "mini" => return Err(Unsupported)
      _ => ()
    }
  }

  guard ftyp is Some(_) else { return Err(Invalid) }
  guard meta is Some(m) else { return Err(Invalid) }
  Ok({ ftyp, meta: m, data, })
}

///|
/// Whether the `ftyp` box names a HEVC brand, either as the major brand or in
/// the compatible list.
///
/// This is the check that keeps an AVIF — same container, same item tree —
/// from being parsed as a HEIC and then failing at the decoder with a
/// confusing message.
pub fn HeifFile::is_hevc(self : HeifFile) -> Bool {
  match self.ftyp {
    None => false
    Some(box) => {
      if box.payload.length() < 8 {
        return false
      }
      let r = Reader::new(box.payload)
      let major = r.str4()
      if hevc_brands.contains(major) {
        return true
      }
      r.skip(4)
      while r.remaining() >= 4 {
        if hevc_brands.contains(r.str4()) {
          return true
        }
      }
      false
    }
  }
}

///|
/// The `major_brand` of the file, for diagnostics.
pub fn HeifFile::major_brand(self : HeifFile) -> String {
  match self.ftyp {
    None => ""
    Some(box) =>
      if box.payload.length() < 4 {
        ""
      } else {
        Reader::new(box.payload).str4()
      }
  }
}

///|
/// The item a file describes itself with, per `pitm`.
#warnings("-result_error_return")
pub fn HeifFile::primary_item(self : HeifFile) -> Result[Item, HeifError] {
  match self.meta.items.get(self.meta.primary) {
    None => Err(Invalid)
    Some(it) => if it.unsupported { Err(Unsupported) } else { Ok(it) }
  }
}

///|
/// An item's bytes, gathered from its extents.
///
/// Construction method 0 reads the file, method 1 reads the `idat` box; every
/// other method is one this port does not know how to address.
#warnings("-result_error_return")
pub fn HeifFile::item_payload(
  self : HeifFile,
  item_id : Int64,
) -> Result[Bytes, HeifError] {
  guard self.meta.items.get(item_id) is Some(it) else { return Err(Invalid) }
  let source = match it.construction {
    0 => self.data
    1 => self.meta.idat
    _ => return Err(Invalid)
  }
  let size = source.length().to_int64()

  if it.extents.length() == 1 {
    let e = it.extents[0]
    let off = it.base_offset + e.off
    let end = match extent_len(off, e, size) {
      Ok(length) => off + length
      Err(_) => return Err(Invalid)
    }
    return Ok(
      source.exact_view(start=off.to_int(), end=end.to_int()).to_owned(),
    )
  }
  if it.extents.length() == 0 {
    return Err(Invalid)
  }

  let out : Array[Byte] = []
  for e in it.extents {
    let off = it.base_offset + e.off
    let end = match extent_len(off, e, size) {
      Ok(length) => off + length
      Err(_) => return Err(Invalid)
    }
    out.append(
      source
      .exact_view(start=off.to_int(), end=end.to_int())
      .to_owned()
      .to_array(),
    )
  }
  Ok(Bytes::from_array(out))
}

///|
/// Resolves one extent against the source, treating a zero length as "to the
/// end of the source" as `iloc` defines it.
#warnings("-result_error_return")
fn extent_len(
  off : Int64,
  e : Extent,
  size : Int64,
) -> Result[Int64, HeifError] {
  let n = if e.len == 0L { size - off } else { e.len }
  if off < 0L || off > size || n < 0L || n > size - off {
    return Err(Invalid)
  }
  Ok(n)
}

///|
/// The absolute offset of the primary item's first extent, or -1 when it has
/// none.
///
/// This is the number `iloc` stores, which a test that wants to corrupt the
/// file has to find without re-parsing the box.
pub fn HeifFile::primary_image_offset(self : HeifFile) -> Int64 {
  match self.meta.items.get(self.meta.primary) {
    None => -1L
    Some(it) =>
      if it.extents.length() == 0 {
        -1L
      } else {
        it.base_offset + it.extents[0].off
      }
  }
}

///|
/// The `grid` payload: how many tiles the derived image is made of.
pub(all) struct GridInfo {
  rows : Int32
  cols : Int32
  width : Int64
  height : Int64
}

///|
/// Reads a `grid` item's payload.
#warnings("-result_error_return")
pub fn HeifFile::grid_info(
  self : HeifFile,
  item_id : Int64,
) -> Result[GridInfo, HeifError] {
  let payload = self.item_payload(item_id)
  let data = match payload {
    Ok(data) => data
    Err(err) => return Err(err)
  }
  guard data.length() >= 8 else { return Err(Invalid) }
  let r = Reader::new(data)
  r.skip(1)
  let flags = r.u8()
  let rows = r.u8() + 1
  let cols = r.u8() + 1
  let width = if (flags & 1) != 0 {
    r.u32().to_int64()
  } else {
    r.u16().to_int64()
  }
  let height = if (flags & 1) != 0 {
    r.u32().to_int64()
  } else {
    r.u16().to_int64()
  }
  if r.err || width == 0L || height == 0L {
    return Err(Invalid)
  }
  Ok({ rows, cols, width, height, })
}

///|
/// The tile ids of a grid item, in raster order, checked against the count the
/// grid itself declares.
#warnings("-result_error_return")
pub fn HeifFile::grid_tiles(
  self : HeifFile,
  item_id : Int64,
) -> Result[Array[Int64], HeifError] {
  let info = self.grid_info(item_id)
  let g = match info {
    Ok(g) => g
    Err(err) => return Err(err)
  }
  let tiles = self.meta.refs_to("dimg", item_id)
  if tiles.length() != g.rows * g.cols {
    return Err(Invalid)
  }
  Ok(tiles)
}

///|
/// The item linked to `item_id` by a `thmb` reference — a thumbnail.
///
/// This is the one relation a caller needs to *skip*: without it, a file whose
/// primary item happens to be small would look like a thumbnail on its own.
#warnings("-result_error_return")
pub fn HeifFile::thumbnail_of(
  self : HeifFile,
  item_id : Int64,
) -> Result[Item, HeifError] {
  for r in self.meta.refs {
    if r.typ != "thmb" || !r.to.contains(item_id) {
      continue
    }
    match self.meta.items.get(r.from) {
      None => continue
      Some(it) =>
        if it.unsupported {
          return Err(Unsupported)
        } else {
          return Ok(it)
        }
    }
  }
  Err(NoThumbnail)
}

///|
/// The auxiliary item carrying `item_id`'s alpha channel, if the file has one.
///
/// The association is `auxl` from the alpha item to the picture, and the alpha
/// item says so itself in its `auxC` URN. Both are required: an `auxl`
/// reference alone points at depth or gain maps too.
pub fn HeifFile::alpha_of(self : HeifFile, item_id : Int64) -> Item? {
  for link in self.meta.refs {
    if link.typ != "auxl" || link.to.length() == 0 || link.to[0] != item_id {
      continue
    }
    let it = match self.meta.items.get(link.from) {
      None => continue
      Some(it) => it
    }
    if it.unsupported {
      continue
    }
    match self.meta.prop(it, "auxC") {
      Some(p) => if is_alpha_urn(p.aux_c) { return Some(it) }
      None => ()
    }
  }
  None
}

///|
/// Whether an `auxC` type URN names an alpha plane.
pub fn is_alpha_urn(urn : String) -> Bool {
  urn == "urn:mpeg:mpegB:cicp:systems:auxiliary:alpha" ||
  urn == "urn:mpeg:hevc:2015:auxid:1"
}
