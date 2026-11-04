///|
/// Every malformed input has to come back as an error, not as a trap: this is
/// the "畸形/截断输入返回 HeifError，不 trap" half of the acceptance criteria.
///
/// Each of these would be an out-of-bounds index in a parser that trusted the
/// sizes the file declares.
async test "malformed and truncated inputs return an error" {
  let names = [
    "bad_size.heic", "empty.heic", "no_ftyp.heic", "only_ftyp.heic", "size_lt_head.heic",
    "trunc_header.heic", "trunc_meta.heic",
  ]
  for name in names {
    let data = @fs.read_binary("heif/testdata/malformed/" + name)
    let result = @heif.parse(data)
    assert_true(result is Err(_))
  }
}

///|
async test "a truncated tail stops the walk instead of reading past it" {
  let whole = @fs.read_binary("heif/testdata/minimal.heic")
  // Cut the file at every length in turn: the parser has to stay alive for
  // all of them, whatever it decides about the ones that are still viable.
  for length in 0..<whole.length() {
    let part = whole.exact_view(start=0, end=length).to_owned()
    // The only thing asserted is that this returns: a trap here would abort
    // the whole test binary rather than fail one case.
    let _ = @heif.parse(part)
  }
}

///|
async test "a file that parses but whose primary item does not is an error, not a trap" {
  let data = @fs.read_binary("heif/testdata/malformed/trunc_mdat.heic")
  let f = @heif.parse(data).unwrap()
  // The item tree is intact; only the media data is missing.
  assert_eq(f.meta.primary, 1L)
  assert_true(f.primary_image() is Err(@heif.Invalid))
}

///|
/// Index of the four-byte extent offset `iloc` declares, found by searching
/// for the big-endian payload offset itself.
fn extent_offset_field(data : Bytes, offset : Int64) -> Int32 {
  let needle : Array[Byte] = [
    (offset >> 24).to_int().to_byte(),
    (offset >> 16).to_int().to_byte(),
    (offset >> 8).to_int().to_byte(),
    offset.to_int().to_byte(),
  ]
  find_sub(data, Bytes::from_array(needle))
}

///|
async test "an item pointing outside the file is refused" {
  let data = @fs.read_binary("heif/testdata/minimal.heic")
  let f = @heif.parse(data).unwrap()
  let at = extent_offset_field(data, f.primary_image_offset())
  assert_true(at > 0)
  let mutated = data.to_array()
  // extent_offset is big-endian, four bytes, starting at `at`.
  let field = at
  mutated[field] = b'\x7f'
  mutated[field + 1] = b'\xff'
  mutated[field + 2] = b'\xff'
  mutated[field + 3] = b'\xff'
  let f2 = @heif.parse(Bytes::from_array(mutated)).unwrap()
  assert_true(f2.primary_image() is Err(@heif.Invalid))
  assert_true(f2.item_payload(1L) is Err(@heif.Invalid))
}

///|
/// The trap the issue calls out by name: a stray `0x0000` after the `dref`
/// pair reads as `extent_count == 0`, which parses cleanly and fails much
/// later as "the item has no bytes".
async test "an iloc with a zero extent count parses but yields no payload" {
  let data = @fs.read_binary("heif/testdata/minimal.heic")
  let f = @heif.parse(data).unwrap()
  let at = extent_offset_field(data, f.primary_image_offset())
  assert_true(at > 0)
  let mutated = data.to_array()
  // extent_count sits two bytes before the four-byte extent_offset.
  let field = at - 2
  mutated[field] = b'\x00'
  mutated[field + 1] = b'\x00'
  let f2 = @heif.parse(Bytes::from_array(mutated)).unwrap()
  // The item survives, its size is still declared, and the payload is gone.
  let it = f2.meta.items.get(1L).unwrap()
  assert_eq(it.extents.length(), 0)
  assert_true(f2.item_payload(1L) is Err(@heif.Invalid))
  assert_true(f2.primary_image() is Err(@heif.Invalid))
}
