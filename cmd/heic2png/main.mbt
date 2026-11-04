///|
/// `heic2png` — the CLI from M5.
///
/// Its shape is fixed now, on purpose: read the file, hand the bytes to
/// `@heif`, write the first still out as PNG. Until the decoder and the file
/// package exist it classifies the input and says so, which is enough to keep
/// the flag parsing and the diagnostics honest.
///
/// A bad argument list aborts with status 2, an unusable input with status 1;
/// `--help` is status 0 and only prints usage.
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
    Ok(Some(path)) => run(path)
  }
}

///|
fn usage() -> String {
  "usage: heic2png <input.heic>\nConverts a HEVC-coded still to PNG.\n"
}

///|
/// Parse the argument vector (without the program name).
///
/// `Ok(None)` means "nothing to do, print usage"; `Err` carries the complaint.
fn parse_args(args : Array[String]) -> Result[String?, String] {
  match args {
    [] => Ok(None)
    ["--help"] | ["-h"] => Ok(None)
    [path] =>
      if path.has_prefix("-") {
        Err("unknown flag \{path}")
      } else {
        Ok(Some(path))
      }
    _ => Err("expected exactly one input file, got \{args.length()}")
  }
}

///|
async fn run(path : String) -> Unit {
  let data = @fs.read_binary(path) catch {
    _ => {
      write_err("heic2png: cannot read \{path}\n")
      @prelude.abort("input")
    }
  }
  match classify(data) {
    "png" => {
      write_err("heic2png: \{path} is already a PNG\n")
      @prelude.abort("input")
    }
    kind => {
      write_err("heic2png: \{path} looks like \{kind}; decoding lands in M3\n")
      @prelude.abort("unimplemented")
    }
  }
}

///|
fn classify(data : Bytes) -> String {
  if @png.has_signature(data) {
    "png"
  } else if data.length() >= 8 &&
    data[4] == b'f' &&
    data[5] == b't' &&
    data[6] == b'y' &&
    data[7] == b'p' {
    "isobmff"
  } else {
    "an unknown container"
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
