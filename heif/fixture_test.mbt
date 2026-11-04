///|
/// Reads a fixture out of the package directory.
async fn fixture(name : String) -> Bytes {
  @fs.read_binary("heif/testdata/" + name)
}

///|
async test "a real HEVC still parses into one item with its decoder config" {
  let f = @heif.parse(fixture("basic.heic")).unwrap()
  assert_true(f.is_hevc())
  assert_eq(f.major_brand(), "heic")
  assert_eq(f.meta.primary, 1L)

  let img = f.primary_image().unwrap()
  assert_eq(img.item_type, "hvc1")
  assert_eq(img.width, 320L)
  assert_eq(img.height, 240L)
  assert_eq(img.stored_width, 320L)
  assert_eq(img.stored_height, 240L)
  assert_eq(img.chroma_format, 1)
  assert_eq(img.bit_depth, 8)
  // The `colr` box says BT.709 primaries, sRGB transfer, BT.709 matrix.
  assert_eq(img.color.primaries, 1)
  assert_eq(img.color.transfer, 13)
  assert_eq(img.color.matrix, 6)
  assert_true(img.color.full_range)
  assert_eq(img.transform.angle, 0)
  assert_true(img.transform.mirror is None)
  assert_true(img.grid is None)
  assert_true(img.alpha is None)
  // The payload is the mdat extent, not the whole file.
  assert_eq(img.payload.length(), 18165)
  assert_true(img.payload.length() < fixture("basic.heic").length())
}

///|
async test "the hvcC record carries three parameter sets" {
  let f = @heif.parse(fixture("basic.heic")).unwrap()
  let img = f.primary_image().unwrap()
  let cfg = img.hvc_c.unwrap()
  assert_eq(cfg.length_size, 4)
  assert_eq(cfg.param_sets.length(), 3)
  // VPS, SPS, PPS — each a NAL unit with its two-byte header.
  assert_eq(cfg.param_sets[0].length(), 24)
  assert_eq(cfg.param_sets[1].length(), 43)
  assert_eq(cfg.param_sets[2].length(), 7)
  // The first byte of each NAL header says which it is.
  assert_eq((cfg.param_sets[0][0].to_int() >> 1) & 0x3F, 32)
  assert_eq((cfg.param_sets[1][0].to_int() >> 1) & 0x3F, 33)
  assert_eq((cfg.param_sets[2][0].to_int() >> 1) & 0x3F, 34)
}

///|
async test "an alpha file links its auxiliary item by auxl and auxC" {
  let f = @heif.parse(fixture("alpha.heic")).unwrap()
  assert_eq(f.meta.primary, 1L)
  let img = f.primary_image().unwrap()
  assert_eq(img.alpha, Some(2L))
  let alpha = f.describe_item(2L).unwrap()
  // The alpha plane is monochrome, and coded with the same config.
  assert_eq(alpha.chroma_format, 0)
  assert_eq(alpha.width, 64L)
  // The URN is what makes it alpha rather than a depth or gain map.
  let prop = f.meta.prop(f.meta.items.get(2L).unwrap(), "auxC").unwrap()
  assert_true(@heif.is_alpha_urn(prop.aux_c))
  assert_false(@heif.is_alpha_urn("urn:mpeg:hevc:2015:auxid:2"))
}

///|
async test "a thumbnail is linked by thmb and stays out of the primary path" {
  let f = @heif.parse(fixture("thumb.heic")).unwrap()
  let img = f.primary_image().unwrap()
  // `pitm` names the full picture, and the thumbnail is the other item.
  assert_eq(img.id, 1L)
  assert_eq(img.width, 320L)
  assert_true(img.alpha is None)

  let thumb = f.thumbnail_of(1L).unwrap()
  assert_eq(thumb.id, 2L)
  let thumb_img = f.describe_item(2L).unwrap()
  assert_true(thumb_img.width < img.width)
  // The thumbnail is the one with a clean aperture in this fixture.
  assert_true(thumb_img.aperture is Some(_))
}

///|
async test "a file without a thumbnail says so" {
  let f = @heif.parse(fixture("basic.heic")).unwrap()
  assert_true(f.thumbnail_of(1L) is Err(@heif.NoThumbnail))
}

///|
async test "a grid reports its tiles and the size it declares" {
  let f = @heif.parse(fixture("grid.heic")).unwrap()
  let img = f.primary_image().unwrap()
  assert_eq(img.item_type, "grid")
  assert_eq(img.width, 64L)
  assert_eq(img.height, 64L)
  let g = img.grid.unwrap()
  assert_eq(g.rows, 2)
  assert_eq(g.cols, 2)
  assert_eq(g.width, 64L)
  assert_eq(g.height, 64L)
  assert_eq(img.tiles.length(), 4)
  // The grid's own payload is the header alone; the tiles carry the samples.
  assert_eq(img.payload.length(), 12)
  // Every tile is a coded picture of its own.
  let tile = f.describe_item(img.tiles[0]).unwrap()
  assert_eq(tile.item_type, "hvc1")
  assert_eq(tile.width, 32L)
  assert_eq(tile.height, 32L)
  assert_true(tile.payload.length() > 0)
}

///|
async test "a grid whose tile count disagrees with its header is rejected" {
  let f = @heif.parse(fixture("grid.heic")).unwrap()
  // Pretend the item is a 3x3 grid by rewriting its header byte in place.
  let data = fixture("grid.heic")
  let img = f.primary_image().unwrap()
  let base = img.payload.length()
  ignore(base)
  // The `grid` payload starts with version|flags|rows-1|cols-1, so bumping
  // rows to 3 is a one-byte edit at the payload's third byte.
  let offset = find_sub(data, img.payload)
  let mutated = data.to_array()
  mutated[offset + 2] = b'\x02'
  let f2 = @heif.parse(Bytes::from_array(mutated)).unwrap()
  assert_true(f2.primary_image() is Err(@heif.Invalid))
}

///|
/// Index of `needle` in `haystack`, or -1.
fn find_sub(haystack : Bytes, needle : Bytes) -> Int32 {
  if needle.length() == 0 || needle.length() > haystack.length() {
    return -1
  }
  for i in 0..<=(haystack.length() - needle.length()) {
    let mut same = true
    for j in 0..<needle.length() {
      if haystack[i + j] != needle[j] {
        same = false
        break
      }
    }
    if same {
      return i
    }
  }
  -1
}

///|
async test "10-bit Main 10 reports the depth the record declared" {
  let f = @heif.parse(fixture("deep10.heic")).unwrap()
  let img = f.primary_image().unwrap()
  assert_eq(img.bit_depth, 10)
  assert_eq(img.chroma_bit_depth, 10)
  assert_eq(img.chroma_format, 1)
}

///|
async test "the chroma formats are reported as the record declares them" {
  let cases : Array[(String, Int32)] = [
    ("chroma422.heic", 2),
    ("chroma444.heic", 3),
  ]
  for (name, want) in cases {
    let f = @heif.parse(fixture(name)).unwrap()
    assert_eq(f.primary_image().unwrap().chroma_format, want)
  }
}

///|
async test "item_payload is addressable by id, and unknown ids are errors" {
  let f = @heif.parse(fixture("alpha.heic")).unwrap()
  let main = f.item_payload(1L).unwrap()
  assert_eq(main.length(), 523)
  let alpha = f.item_payload(2L).unwrap()
  assert_true(alpha.length() > 0)
  assert_true(main != alpha)
  assert_true(f.item_payload(99L) is Err(@heif.Invalid))
}

///|
async test "a hand-built minimal file parses field by field" {
  let f = @heif.parse(fixture("minimal.heic")).unwrap()
  assert_true(f.is_hevc())
  assert_eq(f.meta.primary, 1L)
  assert_eq(f.meta.order.length(), 1)
  let img = f.primary_image().unwrap()
  assert_eq(img.width, 16L)
  assert_eq(img.height, 16L)
  assert_eq(img.chroma_format, 1)
  let cfg = img.hvc_c.unwrap()
  assert_eq(cfg.length_size, 4)
  // Two arrays, an SPS and a PPS — no VPS in this file.
  assert_eq(cfg.param_sets.length(), 2)
  assert_eq((cfg.param_sets[0][0].to_int() >> 1) & 0x3F, 33)
  assert_eq((cfg.param_sets[1][0].to_int() >> 1) & 0x3F, 34)
  assert_eq(img.payload.length(), 15)
  assert_eq(img.color.primaries, 1)
  assert_eq(img.color.transfer, 13)
  assert_eq(img.color.matrix, 6)
}

///|
async test "an AVIF is refused even though its container parses" {
  // Same box tree, different codec brand: nothing in the item tree says the
  // samples are not HEVC, so the brand is what has to catch it.
  let data = fixture("minimal.heic")
  let mutated = data.to_array()
  let brand_at = 8
  mutated[brand_at] = b'a'
  mutated[brand_at + 1] = b'v'
  mutated[brand_at + 2] = b'i'
  mutated[brand_at + 3] = b'f'
  // And drop `heic` from the compatible brands so it is not a HEIC either.
  for i in 0..<mutated.length() {
    if i + 4 <= mutated.length() &&
      mutated[i] == b'h' &&
      mutated[i + 1] == b'e' &&
      mutated[i + 2] == b'i' &&
      mutated[i + 3] == b'c' {
      mutated[i] = b'a'
      mutated[i + 1] = b'v'
      mutated[i + 2] = b'i'
      mutated[i + 3] = b'f'
    }
  }
  let f = @heif.parse(Bytes::from_array(mutated)).unwrap()
  assert_false(f.is_hevc())
  assert_eq(f.major_brand(), "avif")
}

///|
/// The snippet in the README has to keep working, so it is a test.
async test "the README example runs" {
  let data = @fs.read_binary("heif/testdata/basic.heic")
  let heic = @heif.parse(data).unwrap()
  let img = heic.primary_image().unwrap()
  assert_eq(
    "\{img.width}x\{img.height} @ \{img.bit_depth}bit",
    "320x240 @ 8bit",
  )
  let payload = heic.item_payload(img.id).unwrap()
  assert_eq(payload.length(), 18165)
}
