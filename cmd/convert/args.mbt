// CLI argument parsing shared by `heic2png` and `heicinfo`. Keeping it in a
// plain package (no `async`, no file I/O) means the decision table is testable
// with `moon test` instead of only through a process.

///|
/// Exit codes the M5 CLI promises: 0 success, 1 input unreadable, 2 profile
/// not supported, 3 decode failed. A malformed command line is a decode-side
/// refusal with code 1, matching the "input unusable" bucket.
pub let exit_ok : Int32 = 0

///|
pub let exit_input : Int32 = 1

///|
pub let exit_unsupported : Int32 = 2

///|
pub let exit_decode : Int32 = 3

///|
pub enum Format {
  Png
  Jpeg
}

///|
pub fn Format::is_jpeg(self : Format) -> Bool {
  match self {
    Jpeg => true
    Png => false
  }
}

///|
/// Recognised `-f` spellings. Anything else is a usage error.
pub fn parse_format(name : String) -> Result[Format, String] {
  match name.to_lower() {
    "png" => Ok(Png)
    "jpg" | "jpeg" => Ok(Jpeg)
    _ => Err("unknown format '\{name}' (expected png / jpg / jpeg)")
  }
}

///|
pub fn Format::extension(self : Format) -> String {
  match self {
    Png => ".png"
    Jpeg => ".jpg"
  }
}

///|
pub struct Options {
  inputs : Array[String]
  output : String?
  format : Format
  quality : Int32
  bit16 : Bool
  jobs : Int32
  help : Bool
}

///|
pub fn Options::default() -> Options {
  {
    inputs: [],
    output: None,
    format: Png,
    quality: 85,
    bit16: false,
    jobs: 4,
    help: false,
  }
}

///|
/// The `heic2png` usage line, kept here so the parser and the printer never
/// disagree about which flags exist.
pub fn usage() -> String {
  "usage: heic2png [-f png|jpg] [-q 1-100] [-o out] [-j N] [--16bit] <input|dir>...\n" +
  "  -f, --format   output format (default png; -f jpg implies .jpg)\n" +
  "  -q, --quality  JPEG quality 1..100 (default 85)\n" +
  "  -o             output path for a single input\n" +
  "  -j, --jobs     directory batch concurrency (default 4)\n" +
  "  --16bit        write a 16-bit PNG container\n" +
  "  --help, -h     print this help\n" +
  "exit: 0 ok / 1 input unreadable / 2 unsupported profile / 3 decode failed\n"
}

///|
fn parse_uint(
  text : String,
  label : String,
  lo : Int32,
  hi : Int32,
) -> Result[Int32, String] {
  let mut value = 0
  let mut valid = text.length() > 0
  for c in text {
    if c >= '0' && c <= '9' {
      value = value * 10 + c.to_int() - '0'.to_int()
      if value > hi {
        valid = false
      }
    } else {
      valid = false
    }
  }
  if !valid || value < lo {
    return Err("invalid \{label} (expected \{lo}..\{hi})")
  }
  Ok(value)
}

///|
/// Parse the whole `argv` (without the executable prefix). `Ok(help=true)`
/// means "print usage and exit 0"; `Err` is a usage error.
pub fn parse_args(args : Array[String]) -> Result[Options, String] {
  let opts = Options::default()
  let inputs : Array[String] = []
  let mut output : String? = None
  let mut format = Png
  let mut quality = 85
  let mut bit16 = false
  let mut jobs = 4
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--help" || arg == "-h" {
      return Ok({ ..opts, help: true, })
    }
    if arg == "--16bit" {
      bit16 = true
    } else if arg == "-f" || arg == "--format" {
      i += 1
      if i >= args.length() {
        return Err("\{arg} needs a value")
      }
      match parse_format(args[i]) {
        Ok(f) => format = f
        Err(e) => return Err(e)
      }
    } else if arg == "-q" || arg == "--quality" {
      i += 1
      if i >= args.length() {
        return Err("\{arg} needs a value")
      }
      match parse_uint(args[i], "quality", 1, 100) {
        Ok(v) => quality = v
        Err(e) => return Err(e)
      }
    } else if arg == "-o" || arg == "--output" {
      i += 1
      if i >= args.length() {
        return Err("\{arg} needs a path")
      }
      output = Some(args[i])
    } else if arg == "-j" || arg == "--jobs" {
      i += 1
      if i >= args.length() {
        return Err("\{arg} needs a value")
      }
      match parse_uint(args[i], "jobs", 1, 64) {
        Ok(v) => jobs = v
        Err(e) => return Err(e)
      }
    } else if arg.has_prefix("-") {
      return Err("unknown flag \{arg}")
    } else {
      inputs.push(arg)
    }
    i += 1
  }
  if inputs.length() == 0 {
    return Ok({ ..opts, help: true, })
  }
  // Two positionals are the original M4 spelling `heic2png in.heic out.png`;
  // more than two is a multi-file batch, where `-o` has no meaning.
  let paths = inputs
  if paths.length() == 2 {
    if output is Some(_) {
      return Err("use either -o or a positional output, not both")
    }
    return Ok({
      inputs: [paths[0]],
      output: Some(paths[1]),
      format,
      quality,
      bit16,
      jobs,
      help: false,
    })
  }
  if output is Some(_) && paths.length() > 1 {
    return Err("-o is only valid with a single input")
  }
  Ok({ inputs: paths, output, format, quality, bit16, jobs, help: false, })
}

///|
/// Default output for one input: swap the .heic/.heif suffix for the format's
/// own extension, or append it when there is no such suffix.
pub fn default_output(input : String, format : Format) -> String {
  let lower = input.to_lower()
  if lower.has_suffix(".heic") || lower.has_suffix(".heif") {
    input[:input.length() - 5].to_owned() + format.extension()
  } else {
    input + format.extension()
  }
}

///|
/// Whether a directory entry looks like a HEIC still we should convert.
pub fn is_heic_name(name : String) -> Bool {
  let lower = name.to_lower()
  lower.has_suffix(".heic") || lower.has_suffix(".heif")
}
