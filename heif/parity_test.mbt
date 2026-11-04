///|
/// The same dump with keys in the order `tools/fixtures/heic/*.json` uses, so a
/// string compare against the fixture is meaningful. The fixture file was
/// written by `encoding/json` with sorted keys; this reproduces that order
/// rather than the order a person would read the fields in.
fn canonical_dump(data : Bytes) -> String {
  let f = match @heif.parse(data) {
    Ok(f) => f
    Err(err) => return "{\"error\":\"\{error_name(err)}\"}"
  }
  let sb = StringBuilder()
  let fields : Array[String] = []

  fields.push("\"height\":\{primary_height(f)}")
  fields.push("\"items\":\{items_json(f)}")
  fields.push("\"primary\":\{f.meta.primary}")
  fields.push("\"primary_image\":\{primary_json(f)}")
  fields.push("\"props\":\{props_json(f)}")
  fields.push("\"refs\":\{refs_json(f)}")
  match f.thumbnail_of(f.meta.primary) {
    Ok(th) => fields.push("\"thumbnail\":\{th.id}")
    Err(_) => ()
  }
  fields.push("\"width\":\{primary_width(f)}")
  sb.write_string("\{json_object(fields)}")
  sb.to_string()
}

///|
fn json_object(fields : Array[String]) -> String {
  let sb = StringBuilder()
  sb.write_string("{")
  let mut first = true
  for f in fields {
    if !first {
      sb.write_string(",")
    }
    first = false
    sb.write_string(f)
  }
  sb.write_string("}")
  sb.to_string()
}

///|
fn json_array(items : Array[String]) -> String {
  let sb = StringBuilder()
  sb.write_string("[")
  let mut first = true
  for item in items {
    if !first {
      sb.write_string(",")
    }
    first = false
    sb.write_string(item)
  }
  sb.write_string("]")
  sb.to_string()
}

///|
fn items_json(f : @heif.HeifFile) -> String {
  let out : Array[String] = []
  for id in f.meta.order {
    let it = f.meta.items.get(id).unwrap()
    let props : Array[String] = []
    for pair in it.props {
      let (index, essential) = pair
      props.push("[\{index},\{if essential { 1 } else { 0 }}]")
    }
    out.push(
      "{\"construction\":\{it.construction},\"extents\":\{it.extents.length()},\"id\":\{id},\"props\":\{json_array(props)},\"type\":\"\{it.typ}\",\"unsupported\":\{it.unsupported}}",
    )
  }
  json_array(out)
}

///|
fn props_json(f : @heif.HeifFile) -> String {
  let out : Array[String] = []
  for p in f.meta.props {
    out.push("\"\{p.typ}\"")
  }
  json_array(out)
}

///|
fn refs_json(f : @heif.HeifFile) -> String {
  let out : Array[String] = []
  for r in f.meta.refs {
    let to : Array[String] = []
    for id in r.to {
      to.push("\{id}")
    }
    out.push(
      "{\"from\":\{r.from},\"to\":\{json_array(to)},\"typ\":\"\{r.typ}\"}",
    )
  }
  json_array(out)
}

///|
fn primary_width(f : @heif.HeifFile) -> String {
  match f.primary_image() {
    Ok(img) => "\{img.width}"
    Err(_) => "0"
  }
}

///|
fn primary_height(f : @heif.HeifFile) -> String {
  match f.primary_image() {
    Ok(img) => "\{img.height}"
    Err(_) => "0"
  }
}

///|
fn primary_json(f : @heif.HeifFile) -> String {
  let img = match f.primary_image() {
    Ok(img) => img
    Err(err) => return "{\"error\":\"\{error_name(err)}\"}"
  }
  let fields : Array[String] = []
  match img.alpha {
    None => ()
    Some(id) => fields.push("\"alpha\":\{id}")
  }
  match img.transform.angle {
    0 => ()
    angle => fields.push("\"angle\":\{angle}")
  }
  match img.transform.mirror {
    None => ()
    Some(axis) => fields.push("\"axis\":\{axis}")
  }
  match img.hvc_c {
    None => ()
    Some(c) => {
      fields.push("\"bit_depth_chroma\":\{c.bit_depth_chroma}")
      fields.push("\"bit_depth_luma\":\{c.bit_depth_luma}")
      fields.push("\"chroma_format\":\{c.chroma_format}")
    }
  }
  match img.aperture {
    None => ()
    Some(c) =>
      fields.push(
        "\"clap\":[\{c.width},1,\{c.height},1,\{c.horiz_off},1,\{c.vert_off},1]",
      )
  }
  if img.color.has_nclx {
    fields.push("\"full_range\":\{img.color.full_range}")
  }
  match img.grid {
    None => ()
    Some(g) =>
      fields.push(
        "\"grid\":{\"cols\":\{g.cols},\"height\":\{g.height},\"rows\":\{g.rows},\"width\":\{g.width}}",
      )
  }
  fields.push("\"height\":\{img.height}")
  fields.push("\"id\":\{img.id}")
  match img.color.icc {
    None => ()
    Some(profile) => fields.push("\"icc_len\":\{profile.length()}")
  }
  match img.hvc_c {
    None => ()
    Some(c) => fields.push("\"length_size\":\{c.length_size}")
  }
  if img.color.has_nclx {
    fields.push("\"matrix\":\{img.color.matrix}")
  }
  match img.hvc_c {
    None => ()
    Some(c) => {
      let sets : Array[String] = []
      for set in c.param_sets {
        sets.push("\"\{hex(set)}\"")
      }
      fields.push("\"param_sets\":\{json_array(sets)}")
    }
  }
  fields.push("\"payload_len\":\{img.payload.length()}")
  if img.color.has_nclx {
    fields.push("\"primaries\":\{img.color.primaries}")
  }
  fields.push("\"stored_height\":\{img.stored_height}")
  fields.push("\"stored_width\":\{img.stored_width}")
  match img.grid {
    None => ()
    Some(_) => {
      let tiles : Array[String] = []
      for tile in img.tiles {
        tiles.push("\{tile}")
      }
      fields.push("\"tiles\":\{json_array(tiles)}")
    }
  }
  if img.color.has_nclx {
    fields.push("\"transfer\":\{img.color.transfer}")
  }
  fields.push("\"type\":\"\{img.item_type}\"")
  fields.push("\"width\":\{img.width}")
  json_object(fields)
}

///|
fn error_name(err : @heif.HeifError) -> String {
  match err {
    Invalid => "heic: invalid file"
    Unsupported => "heic: unsupported image"
    NoThumbnail => "heic: no thumbnail"
  }
}

///|
fn hex(data : Bytes) -> String {
  let chars = "0123456789abcdef"
  let sb = StringBuilder()
  for b in data {
    let v = b.to_int()
    sb.write_char(chars.to_array()[(v >> 4) & 0xF])
    sb.write_char(chars.to_array()[v & 0xF])
  }
  sb.to_string()
}

///|
/// The M1 acceptance test: every fixture's dump has to equal the one upstream
/// wrote, field for field.
///
/// The fixture is the upstream `encoding/json` output with sorted keys and no
/// spaces; `canonical_dump` prints the same shape, so this is a string compare
/// and a failure points at the first differing byte.
test "fixture dumps match the upstream Go output" {
  let names = [
    "alpha.heic", "basic.heic", "chroma422.heic", "chroma444.heic", "deep10.heic",
    "enc422.heic", "enc444.heic", "grid.heic", "lossless.heic", "main10.heic", "minimal.heic",
    "thumb.heic",
  ]
  for name in names {
    let data = fixtures(name)
    let expected = tools_fixture(name)
    let want = @utf8.decode(expected).trim().to_owned()
    let got = canonical_dump(data)
    assert_eq(got, want)
  }
}
