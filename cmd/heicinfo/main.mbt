///|
/// `heicinfo` — the M1 preview: one line per file, saying what the container
/// holds, without decoding a single sample. Unreadable inputs fail with
/// status 1; an unsupported brand is reported but does not stop the others.

///|
async fn main {
  let args = @env.args()
  let mut rest : Array[String] = []
  if args.length() > 0 {
    rest = args[1:].to_owned()
  }
  match parse_args(rest) {
    Err(message) => {
      @stdio.stderr.write(@utf8.encode("heicinfo: \{message}\n\{usage()}"))
      @env.exit(1)
    }
    Ok(None) => @stdio.stdout.write(@utf8.encode(usage()))
    Ok(Some(paths)) => {
      let mut failed = false
      for path in paths {
        match report(path) {
          Ok(line) => @stdio.stdout.write(@utf8.encode(line + "\n"))
          Err(_) => failed = true
        }
      }
      if failed {
        @env.exit(1)
      }
    }
  }
}

///|
fn usage() -> String {
  "usage: heicinfo <input.heic>...\nPrints what a HEIF container holds, without decoding it.\n"
}

///|
/// `Ok(None)` means "nothing to do, print usage"; `Err` carries the complaint.
fn parse_args(args : Array[String]) -> Result[Array[String]?, String] {
  let paths : Array[String] = []
  for arg in args {
    if arg == "--help" || arg == "-h" {
      return Ok(None)
    }
    if arg.has_prefix("-") {
      return Err("unknown flag \{arg}")
    }
    paths.push(arg)
  }
  if paths.length() == 0 {
    return Ok(None)
  }
  Ok(Some(paths))
}

///|
async fn report(path : String) -> Result[String, Unit] {
  let data = @fs.read_binary(path) catch {
    _ => {
      @stdio.stderr.write(@utf8.encode("heicinfo: cannot read \{path}\n"))
      return Err(())
    }
  }
  let f = match @heif.parse(data) {
    Ok(f) => f
    Err(err) => {
      @stdio.stderr.write(
        @utf8.encode("heicinfo: \{path}: \{describe_error(err)}\n"),
      )
      return Err(())
    }
  }
  if !f.is_hevc() {
    @stdio.stderr.write(
      @utf8.encode(
        "heicinfo: \{path}: brand '\{f.major_brand()}' is not a HEVC image\n",
      ),
    )
    return Err(())
  }
  let img = match f.primary_image() {
    Ok(img) => img
    Err(err) => {
      @stdio.stderr.write(
        @utf8.encode("heicinfo: \{path}: \{describe_error(err)}\n"),
      )
      return Err(())
    }
  }
  Ok("\{path}: \{summarize(img)}")
}

///|
/// The one-line description of an item, in the order a person reads it:
/// size, codec and bit depth, colour, orientation, payload weight. The
/// extras (`grid`, `alpha`, aperture) are appended only when they apply.
fn summarize(img : @heif.ImageItem) -> String {
  let sb = StringBuilder()
  sb.write_string("\{img.width}x\{img.height}")

  sb.write_string(" | ")
  if img.item_type == "grid" {
    match img.grid {
      None => sb.write_string("grid")
      Some(g) =>
        sb.write_string(
          "grid \{g.rows}x\{g.cols} of \{img.tiles.length()} tiles",
        )
    }
  } else {
    sb.write_string("\{img.item_type}")
  }

  sb.write_string(" @ ")
  sb.write_string(
    "\{profile_name(img)} \{img.bit_depth}bit \{chroma_name(img.chroma_format)}",
  )

  sb.write_string(" | ")
  sb.write_string(
    if img.color.has_nclx {
      color_name(img.color.primaries)
    } else if img.color.icc is Some(_) {
      "ICC profile"
    } else {
      "unspecified colour"
    },
  )
  if img.color.full_range {
    sb.write_string(" full-range")
  }

  match img.transform.mirror {
    None => ()
    Some(axis) =>
      sb.write_string(if axis == 0 { " | imir=0" } else { " | imir=1" })
  }
  if img.transform.angle != 0 {
    sb.write_string(" | irot=\{-img.transform.angle * 90}")
  }

  match img.aperture {
    None => ()
    Some(c) =>
      if c.width != img.stored_width || c.height != img.stored_height {
        sb.write_string(
          " | clap \{c.width}x\{c.height}+\{c.horiz_off}+\{c.vert_off}",
        )
      }
  }
  if img.alpha is Some(_) {
    sb.write_string(" | alpha")
  }

  sb.write_string(" | payload \{weight(img.payload.length())}")
  sb.to_string()
}

///|
/// The profile name the decoder configuration record names. A grid item has
/// no record of its own, so the name is simply unknown when there is none.
fn profile_name(img : @heif.ImageItem) -> String {
  let c = match img.hvc_c {
    None => return "HEVC"
    Some(c) => c
  }
  match c.profile_idc {
    1 => "HEVC Main"
    2 => "HEVC Main 10"
    3 => "HEVC Main Still Picture"
    4 => "HEVC Range Extensions"
    _ => "HEVC"
  }
}

///|
fn chroma_name(format : Int32) -> String {
  match format {
    0 => "4:0:0"
    1 => "4:2:0"
    2 => "4:2:2"
    _ => "4:4:4"
  }
}

///|
fn color_name(primaries : Int32) -> String {
  match primaries {
    1 => "BT.709"
    4 => "BT.470M"
    5 => "BT.470BG"
    6 => "SMPTE 170M"
    9 => "BT.2020"
    11 => "SMPTE RP 431-2"
    12 => "SMPTE EG 432-1"
    _ => "unknown primaries \{primaries}"
  }
}

///|
/// A byte count in the unit a person would say it in.
fn weight(n : Int32) -> String {
  if n < 1024 {
    "\{n}B"
  } else if n < 1024 * 1024 {
    "\{(n * 10 / 1024) / 10}.\{(n * 10 / 1024) % 10}KB"
  } else {
    "\{(n * 10 / (1024 * 1024)) / 10}.\{(n * 10 / (1024 * 1024)) % 10}MB"
  }
}

///|
fn describe_error(err : @heif.HeifError) -> String {
  match err {
    Invalid => "invalid file"
    Unsupported => "unsupported image"
    NoThumbnail => "no thumbnail"
  }
}
