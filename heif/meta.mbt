///|
/// Where an item's bytes live: an offset and a length inside a source.
pub(all) struct Extent {
  off : Int64
  len : Int64
}

///|
/// One item of the `meta` box, gathered from `iinf`, `iloc` and `ipma`.
pub(all) struct Item {
  mut id : Int64
  /// The `item_type` of its `infe` box: `hvc1` for a HEVC still, `grid` for a
  /// derived image, `Exif` for the metadata item, …
  mut typ : String
  mut content_type : String
  mut extents : Array[Extent]
  /// `construction_method` of `iloc`: 0 reads the file, 1 reads `idat`.
  mut construction : Int32
  mut base_offset : Int64
  /// `(index into Properties, essential)` pairs, index already zero based.
  mut props : Array[(Int32, Bool)]
  /// Set when an essential association points at a property this port cannot
  /// read — the file says a reader that skips it will misrender the picture.
  mut unsupported : Bool
}

///|
/// One entry of `iref`: an item pointing at others under a relation type.
pub(all) struct ItemRef {
  typ : BoxType
  from : Int64
  to : Array[Int64]
}

///|
/// The parsed `meta` box: every item, property and reference of the file.
pub(all) struct Meta {
  /// The item `pitm` names; 0 when the box is absent.
  mut primary : Int64
  /// Items in the order they first appear, so iteration is deterministic.
  mut order : Array[Int64]
  mut items : Map[Int64, Item]
  mut props : Array[Property]
  mut refs : Array[ItemRef]
  /// The payload of the `idat` box, where construction method 1 reads from.
  mut idat : Bytes
}

///|
fn Meta::ensure_item(self : Meta, id : Int64) -> Item {
  match self.items.get(id) {
    Some(it) => it
    None => {
      let it : Item = {
        id,
        typ: "",
        content_type: "",
        extents: [],
        construction: 0,
        base_offset: 0,
        props: [],
        unsupported: false,
      }
      self.items.set(id, it)
      self.order.push(id)
      it
    }
  }
}

///|
/// Reads `pitm`.
fn Meta::parse_pitm(self : Meta, payload : Bytes) -> Unit raise Invalid {
  let r = Reader::new(payload)
  let header = r.full_box()
  if header.version == 0 {
    self.primary = r.u16().to_int64()
  } else {
    self.primary = r.u32().to_int64()
  }
  if r.err {
    raise Invalid
  }
}

///|
/// Reads `iloc`.
///
/// The one trap worth a note: after the `dref` pair the extents follow, and a
/// stray `0x0000` in front of them is read as `extent_count == 0`. The box then
/// parses cleanly into an item with no extents, which fails much later as a
/// truncated item rather than here. Nothing in this function can tell that
/// apart from a legitimately empty item.
fn Meta::parse_iloc(self : Meta, payload : Bytes) -> Unit raise Invalid {
  let r = Reader::new(payload)
  let header = r.full_box()
  let sizes = r.u8()
  let off_size = sizes >> 4
  let len_size = sizes & 0xf
  let base_size = r.u8()
  let base_size = base_size >> 4
  let mut index_size = 0
  if header.version >= 1 {
    index_size = r.u8() & 0xf
  }
  if r.err {
    raise Invalid
  }
  for n in [off_size, len_size, base_size, index_size] {
    if n != 0 && n != 4 && n != 8 {
      raise Invalid
    }
  }

  let mut count = r.u16()
  if header.version == 2 {
    r.pos = r.pos - 2
    count = r.u32().reinterpret_as_int()
  }
  if r.err {
    raise Invalid
  }

  for _ in 0..<count {
    let id = if header.version < 2 {
      r.u16().to_int64()
    } else {
      r.u32().to_int64()
    }
    ignore(self.ensure_item(id))
    let it = self.ensure_item(id)
    if header.version >= 1 {
      it.construction = r.u16() & 0xf
    }
    r.skip(2)
    it.base_offset = r.uint(base_size)
    let n = r.u16()
    for _ in 0..<n {
      r.skip(index_size)
      let off = r.uint(off_size)
      let len = r.uint(len_size)
      if r.err {
        raise Invalid
      }
      it.extents.push({ off, len, })
    }
    if r.err {
      raise Invalid
    }
  }
}

///|
/// Reads `iinf`, taking the `item_type` of every `infe` inside it.
///
/// Version 0 and 1 `infe` boxes carry no type, and are skipped: a version 1
/// item is an old-style descriptor this port has nothing to decode anyway.
fn Meta::parse_iinf(self : Meta, payload : Bytes) -> Unit raise Invalid {
  let r = Reader::new(payload)
  let header = r.full_box()
  if header.version == 0 {
    r.skip(2)
  } else {
    r.skip(4)
  }
  if r.err {
    raise Invalid
  }

  let walk = each_box(
    payload.exact_view(start=r.pos, end=payload.length()).to_owned(),
    0L,
  )
  if !walk.is_clean() {
    raise Invalid
  }

  for box in walk.boxes {
    if box.typ != "infe" {
      continue
    }
    let rr = Reader::new(box.payload)
    let h = rr.full_box()
    if h.version < 2 {
      continue
    }
    let id = if h.version == 2 {
      rr.u16().to_int64()
    } else {
      rr.u32().to_int64()
    }
    rr.skip(2)
    let item_type = rr.str4()
    if rr.err {
      raise Invalid
    }
    ignore(self.ensure_item(id))
    let it = self.ensure_item(id)
    it.typ = item_type
    if item_type == "mime" {
      ignore(rr.cstr())
      let content_type = rr.cstr()
      if !rr.err {
        it.content_type = content_type
      }
    }
  }
}

///|
/// Reads `iref`.
fn Meta::parse_iref(self : Meta, payload : Bytes) -> Unit raise Invalid {
  let r = Reader::new(payload)
  let header = r.full_box()
  if r.err {
    raise Invalid
  }

  let walk = each_box(
    payload.exact_view(start=r.pos, end=payload.length()).to_owned(),
    0L,
  )
  if !walk.is_clean() {
    raise Invalid
  }

  for box in walk.boxes {
    let rr = Reader::new(box.payload)
    let from = if header.version == 0 {
      rr.u16().to_int64()
    } else {
      rr.u32().to_int64()
    }
    let n = rr.u16()
    let to = []
    for _ in 0..<n {
      let id = if header.version == 0 {
        rr.u16().to_int64()
      } else {
        rr.u32().to_int64()
      }
      to.push(id)
    }
    if rr.err {
      raise Invalid
    }
    self.refs.push({ typ: box.typ, from, to, })
  }
}

///|
/// Reads `ipco`: the property list every item's `ipma` indexes into.
fn Meta::parse_ipco(self : Meta, payload : Bytes) -> Unit raise Invalid {
  let walk = each_box(payload, 0L)
  if !walk.is_clean() {
    raise Invalid
  }
  for box in walk.boxes {
    match parse_property(box.typ, box.payload) {
      None => raise Invalid
      Some(p) => self.props.push(p)
    }
  }
}

///|
/// Reads `ipma`: which properties each item carries, and which of those it
/// cannot do without.
fn Meta::parse_ipma(self : Meta, payload : Bytes) -> Unit raise Invalid {
  let r = Reader::new(payload)
  let header = r.full_box()
  let count = r.u32()
  if r.err {
    raise Invalid
  }

  for _ in 0..<count.reinterpret_as_int() {
    let id = if header.version < 1 {
      r.u16().to_int64()
    } else {
      r.u32().to_int64()
    }
    ignore(self.ensure_item(id))
    let it = self.ensure_item(id)
    let n = r.u8()
    for _ in 0..<n {
      let (index, essential) = if (header.flags & 1) != 0 {
        let v = r.u16()
        (v & 0x7fff, (v & 0x8000) != 0)
      } else {
        let v = r.u8()
        (v & 0x7f, (v & 0x80) != 0)
      }
      if r.err {
        raise Invalid
      }
      // Index 0 means "no property here", which is how a writer pads a list.
      if index == 0 {
        continue
      }
      it.props.push((index - 1, essential))
    }
    if r.err {
      raise Invalid
    }
  }
}

///|
/// Marks every item that associates essentially with a property this port
/// cannot read.
fn Meta::mark_unsupported(self : Meta) -> Unit {
  for id in self.order {
    let it = self.ensure_item(id)
    for (index, essential) in it.props {
      if !essential {
        continue
      }
      let known = if index >= 0 && index < self.props.length() {
        known_property(self.props[index].typ)
      } else {
        false
      }
      if !known {
        it.unsupported = true
        break
      }
    }
  }
}

///|
/// Parses the payload of a `meta` box.
///
/// `meta` is a full box in ISO/IEC 14496-12 (version + flags), and that is the
/// only shape this port accepts: the pre-2015 non-full form is not something a
/// HEIC ever carries.
pub fn parse_meta(payload : Bytes) -> Meta raise Invalid {
  let r = Reader::new(payload)
  ignore(r.full_box())
  if r.err {
    raise Invalid
  }

  let meta : Meta = {
    primary: 0,
    order: [],
    items: Map([]),
    props: [],
    refs: [],
    idat: b"",
  }

  let walk = each_box(
    payload.exact_view(start=r.pos, end=payload.length()).to_owned(),
    0L,
  )
  if !walk.is_clean() {
    raise Invalid
  }

  for box in walk.boxes {
    match box.typ {
      "pitm" => meta.parse_pitm(box.payload)
      "iloc" => meta.parse_iloc(box.payload)
      "iinf" => meta.parse_iinf(box.payload)
      "iref" => meta.parse_iref(box.payload)
      "idat" => meta.idat = box.payload
      "iprp" => {
        let inner = each_box(box.payload, 0L)
        if !inner.is_clean() {
          raise Invalid
        }
        for b in inner.boxes {
          match b.typ {
            "ipco" => meta.parse_ipco(b.payload)
            "ipma" => meta.parse_ipma(b.payload)
            _ => ()
          }
        }
      }
      _ => ()
    }
  }

  meta.mark_unsupported()
  meta
}

///|
/// The property of one type an item is associated with, or `None`.
pub fn Meta::prop(self : Meta, it : Item, typ : BoxType) -> Property? {
  for (index, _) in it.props {
    if index >= 0 && index < self.props.length() && self.props[index].typ == typ {
      return Some(self.props[index])
    }
  }
  None
}

///|
/// The items `from` points at under relation `typ`.
pub fn Meta::refs_to(self : Meta, typ : BoxType, from : Int64) -> Array[Int64] {
  for r in self.refs {
    if r.typ == typ && r.from == from {
      return r.to
    }
  }
  []
}
