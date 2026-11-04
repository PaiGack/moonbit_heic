///|
/// A cursor over a byte range.
///
/// Upstream's `reader` never reports failure at the call site: a short read
/// sticks the cursor at the end and sets `err`, and the caller checks once
/// when the structure is complete. Keeping that shape is what makes the port
/// comparable line by line, and it is also the reason a truncated file comes
/// out as `Invalid` instead of an array index trap.
priv struct Reader {
  data : Bytes
  mut pos : Int32
  mut err : Bool
}

///|
fn Reader::new(data : Bytes) -> Reader {
  { data, pos: 0, err: false, }
}

///|
fn Reader::remaining(self : Reader) -> Int32 {
  if self.err {
    return 0
  }
  self.data.length() - self.pos
}

///|
fn Reader::fail(self : Reader) -> Unit {
  self.err = true
  self.pos = self.data.length()
}

///|
fn Reader::bytes(self : Reader, n : Int32) -> Bytes? {
  if n < 0 || self.remaining() < n {
    self.fail()
    return None
  }
  let view = self.data.exact_view(start=self.pos, end=self.pos + n)
  self.pos = self.pos + n
  Some(view.to_owned())
}

///|
fn Reader::skip(self : Reader, n : Int32) -> Unit {
  ignore(self.bytes(n))
}

///|
fn Reader::u8(self : Reader) -> Int32 {
  match self.bytes(1) {
    None => 0
    Some(b) => b[0].to_int()
  }
}

///|
fn Reader::uint(self : Reader, n : Int32) -> Int64 {
  let b = self.bytes(n)
  let mut v = 0L
  if b is Some(b) {
    for i in 0..<n {
      v = (v << 8) | b[i].to_int64()
    }
  }
  v
}

///|
fn Reader::u16(self : Reader) -> Int32 {
  self.uint(2).to_int()
}

///|
fn Reader::u32(self : Reader) -> UInt32 {
  let v = self.uint(4)
  (v & 0xFFFFFFFFL).to_int().reinterpret_as_uint()
}

///|
fn Reader::u64(self : Reader) -> Int64 {
  // The top bit of a 64-bit box size would be a file larger than any we can
  // hold, so the sign bit is simply not representable here; reading it as a
  // negative size is caught by the `size < head` guard in `each_box`.
  self.uint(8)
}

///|
/// The four-character type of a box.
fn Reader::str4(self : Reader) -> String {
  match self.bytes(4) {
    None => ""
    Some(b) => @utf8.decode_lossy(b)
  }
}

///|
/// A NUL-terminated string, as several boxes carry their URN in.
fn Reader::cstr(self : Reader) -> String {
  let chars = []
  let mut done = false
  while !done {
    match self.bytes(1) {
      None => done = true
      Some(b) => if b[0] == b'\x00' { done = true } else { chars.push(b[0]) }
    }
  }
  @utf8.decode_lossy(Bytes::from_array(chars))
}

///|
/// Version and flags of a full box, as one word then split.
fn Reader::full_box(self : Reader) -> FullBoxHeader {
  let w = self.u32()
  if self.err {
    return { version: 0, flags: 0, }
  }
  read_full_box_header(w)
}

///|
/// One box as it appears in its parent's payload.
pub(all) struct BoxView {
  typ : String
  payload : Bytes
  /// Where the payload starts in the container this box was found in, which is
  /// only meaningful for the file itself; the API reports offsets against it.
  offset : Int64
}

///|
/// The result of walking a box list: the boxes that fit, and whether the list
/// ended in something that did not.
///
/// A truncated box stops the walk. A parser that only cares about the boxes it
/// names reports `Invalid` when it sees `truncated`; one that is looking for a
/// `meta` box before the damage does not have to.
pub(all) struct BoxWalk {
  boxes : Array[BoxView]
  truncated : Bool
}

///|
/// Walks every box in `data`.
///
/// `base` is the file offset of `data[0]`, so a payload keeps its position in
/// the file rather than in its parent.
pub fn each_box(data : Bytes, base : Int64) -> BoxWalk {
  let boxes = []
  let r = Reader::new(data)
  let mut truncated = false

  while r.remaining() >= 8 {
    let start = r.pos
    let declared = r.u32().to_int64()
    let typ = r.str4()
    let mut head = 8L
    let mut size = declared
    if size == 1L {
      size = r.u64()
      head = 16L
    } else if size == 0L {
      size = data.length().to_int64() - start.to_int64()
    }
    let available = data.length().to_int64() - start.to_int64()
    if r.err || size < head || size > available {
      truncated = true
      break
    }
    let end = start + head.to_int()
    let body = data.exact_view(start=end, end=start + size.to_int()).to_owned()
    // A `uuid` box carries a sixteen byte type this port never branches on,
    // and its payload is skipped on the size alone.
    if typ != "uuid" {
      boxes.push({
        typ,
        payload: body,
        offset: base + (start + head.to_int()).to_int64(),
      })
    }
    r.pos = start + size.to_int()
  }

  if r.err {
    truncated = true
  }

  { boxes, truncated, }
}

///|
/// Whether a walk of nested boxes came out clean.
///
/// The meta box is the one place a damaged tail is fatal: the item tree is the
/// whole payload there, so a half-read one is a file we cannot describe.
pub fn BoxWalk::is_clean(self : BoxWalk) -> Bool {
  !self.truncated
}
