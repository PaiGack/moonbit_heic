///|
/// CABAC arithmetic decoding lands in M3.
///
/// This package holds the context model and the arithmetic decoder state. It
/// stays a stub in M0; the only thing worth fixing now is that every width and
/// shift it will need is `Int64`, because the CABAC renormalisation loop is
/// where a wrapped multiplication would corrupt an entire CTU.
pub suberror NotYetImplemented

///|
/// Number of context models the decoder allocates, by syntax element class.
///
/// Upstream sizes this from SPS fields; `ctb_log2_size_y` is the only one that
/// matters for the initial allocation. One entry per luma sample of a CTB is
/// the granularity upstream indexes its per-coefficient contexts with.
pub fn context_table_size(
  ctb_log2_size_y : Int32,
) -> Int64 raise @safe.Overflow {
  let side = @safe.shl(1L, ctb_log2_size_y)
  @safe.mul(side, side)
}
