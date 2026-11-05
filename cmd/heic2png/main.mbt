// `heic2png` — the M5 CLI: read a HEIC still, decode it through M1/M3,
// colour-convert and transform through M4, write PNG or JPEG. A directory
// input converts every .heic/.heif inside it with bounded concurrency.

///|
async fn main {
  let args = @env.args()
  let mut rest : Array[String] = []
  if args.length() > 0 {
    rest = args[1:].to_owned()
  }
  match @convert.parse_args(rest) {
    Err(message) => {
      @cli.write_err("heic2png: \{message}\n\{@convert.usage()}\n")
      @cli.finish(@convert.exit_input)
    }
    Ok(opts) => {
      if opts.help {
        @cli.write_out(@convert.usage())
        @cli.finish(@convert.exit_ok)
      }
      @cli.finish(@cli.run(opts))
    }
  }
}
