// Process-level glue: read / write / list files, run every input, and exit
// with the worst status seen. Kept separate from `@convert.convert` so the pure
// decision logic stays unit-testable.

///|
pub async fn write_out(text : String) -> Unit {
  @stdio.stdout.write(@utf8.encode(text))
}

///|
pub async fn write_err(text : String) -> Unit {
  @stdio.stderr.write(@utf8.encode(text))
}

///|
/// Terminate with one of the four documented codes. `@env.exit` is a clean
/// process exit: the message has already been written to stderr.
pub fn finish(code : Int32) -> Unit {
  @env.exit(code)
}

///|
/// One file, or every `.heic`/`.heif` directly inside a directory. A path
/// that is neither is an input error. Directory order is sorted so a batch
/// failure is reproducible.
async fn collect_input(path : String) -> Result[Array[String], String] {
  let kind = @fs.kind(path) catch { _ => return Err("cannot stat \{path}") }
  if kind == Directory {
    let names = @fs.readdir(path, sort=true) catch {
      _ => return Err("cannot list \{path}")
    }
    let out : Array[String] = []
    let base = path.trim_end(chars="/")
    for name in names {
      if @convert.is_heic_name(name) {
        out.push("\{base}/\{name}")
      }
    }
    Ok(out)
  } else {
    Ok([path])
  }
}

///|
/// Convert one input file, returning its exit status. Errors go to stderr and
/// are never swallowed: the message names the file and the reason.
async fn convert_one(
  path : String,
  out_path : String,
  opts : @convert.Options,
) -> Int32 {
  let data = @fs.read_binary(path) catch {
    _ => {
      write_err("heic2png: cannot read \{path}\n")
      return @convert.exit_input
    }
  }
  match @convert.convert(data, opts) {
    Ok(bytes) => {
      @fs.write_binary(out_path, bytes) catch {
        _ => {
          write_err("heic2png: cannot write \{out_path}\n")
          return @convert.exit_input
        }
      }
      @convert.exit_ok
    }
    Err(err) => {
      write_err("heic2png: \{path}: \{err.message()}\n")
      err.exit_code()
    }
  }
}

///|
/// Run the whole command. Returns the worst exit code across all inputs;
/// the caller turns it into a process status.
pub async fn run(opts : @convert.Options) -> Int32 {
  let files : Array[String] = []
  for path in opts.inputs {
    match collect_input(path) {
      Ok(more) =>
        for f in more {
          files.push(f)
        }
      Err(msg) => {
        write_err("heic2png: \{msg}\n")
        return @convert.exit_input
      }
    }
  }
  let mut worst = @convert.exit_ok
  if files.length() <= 1 {
    for f in files {
      let out_path = match opts.output {
        None => @convert.default_output(f, opts.format)
        Some(p) => p
      }
      let code = convert_one(f, out_path, opts)
      if code > worst {
        worst = code
      }
    }
  } else {
    // Directory / multi-file batch: cap concurrency with a task group. Every
    // input gets its own default output name; the worst status wins.
    let results = Array::make(files.length(), @convert.exit_ok)
    @async.with_task_group() <| tg => {
      let sem = @async.Semaphore(opts.jobs)
      for i, f in files {
        sem.acquire()
        tg.spawn_bg(allow_failure=true) <| () => {
          defer sem.release()
          let out_path = @convert.default_output(f, opts.format)
          results[i] = convert_one(f, out_path, opts)
        }
      }
    }
    for code in results {
      if code > worst {
        worst = code
      }
    }
  }
  worst
}
