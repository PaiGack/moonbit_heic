///|
/// Entry point for the CLI. The library parses a stream that is already in
/// memory; reading it off the disk is the embedder's business until a file
/// package is in place.
fn main {
  let args = @env.args()
  println("hevc: \{args.length() - 1} argument(s)")
}
