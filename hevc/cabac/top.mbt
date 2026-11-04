// CABAC, the arithmetic decoder of H.265 9.3. This package is the bottom of
// the M3 reconstruction stack: it owns the context model and the arithmetic
// state, and every layer above it (residual syntax, CTU, intra prediction)
// reads bins through it.

///|
/// A helper from M0, kept for the size audit: one context per luma sample of
/// a coding tree block is the granularity the per-coefficient contexts use.
/// The real decoder allocates a fixed 179 contexts (9.3.2.2); this function is
/// only about the Int64 arithmetic a CTB-sized allocation would need.
pub fn context_table_size(
  ctb_log2_size_y : Int32,
) -> Int64 raise @safe.Overflow {
  let side = @safe.shl(1L, ctb_log2_size_y)
  @safe.mul(side, side)
}
