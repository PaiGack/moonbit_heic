// Unit tests for the M5 CLI decision table: argument parsing, output naming,
// error classification and exit codes. These run under `moon test` without
// touching the filesystem or spawning a process.

///|
fn ok(result : Result[@convert.Options, String]) -> @convert.Options {
  match result {
    Ok(o) => o
    Err(_) => panic()
  }
}

///|
test "parse_args: help and empty argv" {
  assert_eq(ok(@convert.parse_args([])).help, true)
  for flag in ["--help", "-h"] {
    assert_eq(ok(@convert.parse_args([flag])).help, true)
  }
}

///|
test "parse_args: the documented one-liners" {
  // heic2png photo.heic
  let a = ok(@convert.parse_args(["photo.heic"]))
  assert_eq(a.inputs.length(), 1)
  assert_eq(a.inputs[0], "photo.heic")
  assert_eq(a.output, None)
  assert_eq(a.format.is_jpeg(), false)
  // heic2png photo.heic -o out.png (and out.png as a positional)
  let b = ok(@convert.parse_args(["photo.heic", "-o", "out.png"]))
  assert_eq(b.output, Some("out.png"))
  let b2 = ok(@convert.parse_args(["photo.heic", "out.png"]))
  assert_eq(b2.inputs.length(), 1)
  assert_eq(b2.output, Some("out.png"))
  // heic2png -f jpg -q 90 photos/
  let c = ok(@convert.parse_args(["-f", "jpg", "-q", "90", "photos/"]))
  assert_eq(c.format.is_jpeg(), true)
  assert_eq(c.quality, 90)
  assert_eq(c.output, None)
  assert_eq(c.inputs[0], "photos/")
}

///|
fn png_format() -> @convert.Format {
  ok(@convert.parse_args(["a.heic"])).format
}

///|
fn jpeg_format() -> @convert.Format {
  ok(@convert.parse_args(["-f", "jpg", "a.heic"])).format
}

///|
fn format_ok(name : String) -> Bool {
  match @convert.parse_format(name) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
test "parse_args: format aliases and 16-bit" {
  for name in ["png", "PNG", "jpg", "jpeg", "JPG"] {
    assert_eq(format_ok(name), true)
  }
  assert_eq(format_ok("gif"), false)
  let o = ok(@convert.parse_args(["--16bit", "a.heic"]))
  assert_eq(o.bit16, true)
  assert_eq(o.format.is_jpeg(), false)
}

///|
fn args_ok(args : Array[String]) -> Bool {
  match @convert.parse_args(args) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
test "parse_args: rejects bad flags and values" {
  let bad : Array[Array[String]] = [
    ["--bogus"],
    ["-f", "gif", "a.heic"],
    ["-f", "-q", "a.heic"],
    ["-q", "0", "a.heic"],
    ["-q", "101", "a.heic"],
    ["-q", "abc", "a.heic"],
    ["-q"],
    ["-o"],
    ["-j", "0", "a.heic"],
    ["-j", "65", "a.heic"],
    ["-o", "x.png", "a.heic", "b.heic"],
  ]
  for args in bad {
    assert_eq(args_ok(args), false)
  }
}

///|
test "parse_args: three or more inputs are a batch, not an -o conflict" {
  let o = ok(@convert.parse_args(["a.heic", "b.heic", "c.heic"]))
  assert_eq(o.inputs.length(), 3)
  assert_eq(o.output, None)
}

///|
test "parse_args: -j bounds directory concurrency" {
  assert_eq(ok(@convert.parse_args(["-j", "8", "photos/"])).jobs, 8)
  assert_eq(ok(@convert.parse_args(["--jobs", "1", "a.heic"])).jobs, 1)
}

///|
test "default_output swaps the suffix for the chosen format" {
  assert_eq(@convert.default_output("photo.heic", png_format()), "photo.png")
  assert_eq(@convert.default_output("photo.HEIC", png_format()), "photo.png")
  assert_eq(@convert.default_output("photo.heif", jpeg_format()), "photo.jpg")
  assert_eq(
    @convert.default_output("no_suffix", jpeg_format()),
    "no_suffix.jpg",
  )
  assert_eq(
    @convert.default_output("dir/photo.HEIC", png_format()),
    "dir/photo.png",
  )
}

///|
test "is_heic_name accepts the two suffixes case-insensitively" {
  for name in ["a.heic", "A.HEIC", "b.heif", "c.HEIF"] {
    assert_eq(@convert.is_heic_name(name), true)
  }
  for name in ["a.jpg", "a.png", "heic", ".heic.txt"] {
    assert_eq(@convert.is_heic_name(name), false)
  }
}

///|
test "ConvertError maps to the documented exit codes" {
  assert_eq(@convert.Input("x").exit_code(), @convert.exit_input)
  assert_eq(@convert.Unsupported("x").exit_code(), @convert.exit_unsupported)
  assert_eq(@convert.Decode("x").exit_code(), @convert.exit_decode)
  assert_eq(@convert.exit_ok, 0)
  assert_eq(
    @convert.Input("cannot read a.heic").message(),
    "cannot read a.heic",
  )
}

///|
test "usage documents every flag and the exit codes" {
  let u = @convert.usage()
  for flag in ["-f", "-q", "-o", "-j", "--16bit", "--help"] {
    assert_eq(u.contains(flag), true)
  }
  assert_eq(u.contains("0 ok"), true)
  assert_eq(u.contains("3 decode failed"), true)
}
