// Backend bench driver. Times N pure `convert()` calls over the baked-in
// 64x64 HEIC (fixture.mbt) and prints the per-call wall time and output size.
// No async / fs / stdio APIs, so it compiles on native, wasm, wasm-gc and js:
// this is what the M5 "three backends" performance record measures.

///|
fn parse_iters(text : String) -> Int32 {
  let mut n = 0
  let mut ok = text.length() > 0
  for c in text {
    if c >= '0' && c <= '9' {
      n = n * 10 + c.to_int() - '0'.to_int()
    } else {
      ok = false
    }
  }
  if ok && n > 0 && n <= 100 {
    n
  } else {
    1
  }
}

///|
fn main {
  let args = @env.args()
  let iters = parse_iters(if args.length() > 1 { args[1] } else { "1" })
  let opts = @convert.Options::default()
  let start = @env.now()
  let mut last = 0
  let mut warm = 0
  for _ in 0..<iters {
    match @convert.convert(bench_heic, opts) {
      Ok(bytes) => {
        last = bytes.length()
        warm += 1
      }
      Err(err) => {
        println("error: \{err.message()} (exit \{err.exit_code()})")
        return
      }
    }
  }
  let elapsed = @env.now().reinterpret_as_int64() - start.reinterpret_as_int64()
  let ns = elapsed * 1000000L / warm.to_int64()
  println("iters=\{warm} ns_per_call=\{ns} bytes=\{last}")
}
