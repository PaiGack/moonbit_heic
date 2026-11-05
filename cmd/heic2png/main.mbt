// `heic2png` — the M4/M5 CLI: read a HEIC still, decode it through M1/M3,
// colour-convert and transform through M4, write PNG or JPEG.
//
// A bad argument list aborts with status 2, an unusable input with status 1;
// `--help` is status 0 and only prints usage.

///|
async fn main {
  let args = @env.args()
  let mut rest : Array[String] = []
  if args.length() > 0 {
    rest = args[1:].to_owned()
  }
  match parse_args(rest) {
    Err(message) => {
      write_err("heic2png: \{message}\n\{usage()}\n")
      @prelude.abort("usage")
    }
    Ok(None) => write_out(usage())
    Ok(Some(opts)) => run(opts)
  }
}

///|
fn usage() -> String {
  "usage: heic2png [options] <input.heic> [output]\n" +
  "  --jpeg            write a baseline JPEG instead of PNG\n" +
  "  --quality <1-100> JPEG quality (default 85)\n" +
  "  --16bit           write a 16-bit PNG container (default 8-bit)\n" +
  "  -o <path>         output path (default: input with .png/.jpg)\n" +
  "  --help, -h        print this help\n"
}

///|
struct Options {
  input : String
  output : String?
  jpeg : Bool
  bit16 : Bool
  quality : Int32
}

///|
fn parse_args(args : Array[String]) -> Result[Options?, String] {
  let mut input : String? = None
  let mut output : String? = None
  let mut jpeg = false
  let mut bit16 = false
  let mut quality = 85
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--help" || arg == "-h" {
      return Ok(None)
    }
    if arg == "--jpeg" {
      jpeg = true
    } else if arg == "--16bit" {
      bit16 = true
    } else if arg == "--quality" || arg == "-q" {
      i += 1
      if i >= args.length() {
        return Err("--quality needs a value")
      }
      let mut value = 0
      let mut valid = true
      for c in args[i] {
        if c >= '0' && c <= '9' {
          value = value * 10 + c.to_int() - '0'.to_int()
        } else {
          valid = false
        }
      }
      if !valid || value < 1 || value > 100 {
        return Err("invalid --quality value (expected 1..100)")
      }
      quality = value
    } else if arg == "-o" {
      i += 1
      if i >= args.length() {
        return Err("-o needs a path")
      }
      output = Some(args[i])
    } else if arg.has_prefix("-") {
      return Err("unknown flag \{arg}")
    } else if input is None {
      input = Some(arg)
    } else if output is None {
      output = Some(arg)
    } else {
      return Err("expected at most one input and one output path")
    }
    i += 1
  }
  match input {
    None => Ok(None)
    Some(path) => Ok(Some({ input: path, output, jpeg, bit16, quality, }))
  }
}

///|
fn default_output(input : String, jpeg : Bool) -> String {
  let suffix = if jpeg { ".jpg" } else { ".png" }
  if input.has_suffix(".heic") || input.has_suffix(".HEIC") {
    input[:input.length() - 5].to_owned() + suffix
  } else if input.has_suffix(".heif") || input.has_suffix(".HEIF") {
    input[:input.length() - 5].to_owned() + suffix
  } else {
    input + suffix
  }
}

///|
async fn run(opts : Options) -> Unit {
  let data = @fs.read_binary(opts.input) catch {
    _ => {
      write_err("heic2png: cannot read \{opts.input}\n")
      @prelude.abort("input")
    }
  }
  let out_path = match opts.output {
    None => default_output(opts.input, opts.jpeg)
    Some(p) => p
  }
  match convert(data, opts) {
    Ok(bytes) =>
      @fs.write_binary(out_path, bytes) catch {
        _ => {
          write_err("heic2png: cannot write \{out_path}\n")
          @prelude.abort("input")
        }
      }
    Err(msg) => {
      write_err("heic2png: \{opts.input}: \{msg}\n")
      @prelude.abort("input")
    }
  }
}

///|
/// The whole pipeline: container → access unit → YUV → RGBA → encoded file.
fn convert(data : Bytes, opts : Options) -> Result[Bytes, String] {
  let file = match @heif.parse(data) {
    Ok(f) => f
    Err(_) => return Err("invalid HEIF container")
  }
  let item = match file.primary_image() {
    Ok(it) => it
    Err(_) => return Err("no primary image")
  }
  let cfg = match item.hvc_c {
    None => return Err("primary item has no HEVC decoder configuration")
    Some(c) => c
  }
  if item.item_type == "grid" {
    return Err("grid images are not supported by this port")
  }
  let au = @hevc.parse_access_unit(
    item.payload,
    cfg.param_sets,
    cfg.length_size,
    false,
  ) catch {
    _ => return Err("cannot parse the HEVC access unit")
  }
  let frame = match @decode.decode_i_frame(au.sps, au.pps, au) {
    Ok(f) => f
    Err(_) =>
      return Err("M3 cannot decode this frame (I-frame, Main 8-bit 4:2:0 only)")
  }
  // Colour: `nclx` replaces the VUI description whole; without it the VUI
  // fields on the parsed SPS speak, with BT.709 limited range as fallback.
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
    _ => return Err("colour/transform pipeline failed")
  }
  let icc = item.color.icc
  let bytes = if opts.jpeg {
    @jpeg.encode(rgba, options={ quality: opts.quality, icc, }) catch {
      _ => return Err("JPEG encoding failed")
    }
  } else {
    @png.encode(rgba, options={
      bit_depth: if opts.bit16 {
        16
      } else {
        8
      },
      compression_level: 6,
      icc,
    }) catch {
      _ => return Err("PNG encoding failed")
    }
  }
  Ok(bytes)
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

///|
async fn write_out(text : String) -> Unit {
  @stdio.stdout.write(@utf8.encode(text))
}

///|
async fn write_err(text : String) -> Unit {
  @stdio.stderr.write(@utf8.encode(text))
}
