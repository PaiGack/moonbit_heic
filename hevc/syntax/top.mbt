// CTU-level CABAC syntax layer of M3 (7.3.8.2..7.3.8.10, plus the pure
// derivations of 8.4.2 / 8.6.1 / 9.3.2.2). It sits directly on the
// byte-exact-checked CABAC arithmetic decoder (hevc/cabac) and is the last
// layer below the CTU quadtree/TU/PU driver that reconstructs the pixels.
//
// Every syntax element here is a self-contained parse of one CABAC bitstream:
// the writer side is the real upstream Go cabacWriter and the reader side the
// real upstream ctuDecoder, round-tripped before the bytes ship as truth in
// golden.mbt. The pure derivations (MPM candidates, context indices, chroma
// QP, QP wrap, SAO offset range) are called directly from upstream Go.
//
// Sizes here are log2 block sizes, context indices, QP values and mode numbers
// -- all structurally small -- so Int32 is the carrier throughout, matching
// the upstream's int for these fields. The arithmetic decoder's own 32-bit
// low/rng are kept as UInt32 in hevc/cabac. A malformed bin is returned as
// Err(SyntaxError), never as an unchecked array index or a trap.

///|
/// Why a syntax element could not be parsed. Every case is a stream the port
/// refuses on purpose, not a runtime failure, so the caller can match on it.
pub(all) enum SyntaxError {
  /// A context index the arithmetic decoder refused, or a short stream.
  BadBin
  /// A parameter (list length, bit depth, component index) outside its range.
  InvalidParam
}

///|
/// Wrap the CABAC decoder's raised errors as SyntaxError values. Every bin
/// read goes through these, so a bad context or bypass count is a returned
/// Err rather than a trap.
fn decode_bin(c : @cabac.Decoder, ctx : Int32) -> Result[Int32, SyntaxError] {
  Ok(c.decode_bin(ctx)) catch {
    _ => Err(BadBin)
  }
}

///|
fn decode_bypass_bits(
  c : @cabac.Decoder,
  n : Int32,
) -> Result[UInt32, SyntaxError] {
  Ok(c.decode_bypass_bits(n)) catch {
    _ => Err(BadBin)
  }
}

///|
/// Context offsets of 9.3.2.2 (Table 9-4), the first context of each syntax
/// element this layer reads. Individual ctxInc derivations live in context.mbt.
pub let ctx_sao_merge_flag : Int32 = 0

///|
pub let ctx_sao_type_idx : Int32 = 1

///|
pub let ctx_split_coding_unit_flag : Int32 = 2

///|
pub let ctx_cu_qp_delta : Int32 = 9

///|
/// `cu_transquant_bypass_flag` context of 9.3.2.2 (Table 9-4).
pub let ctx_cu_transquant_bypass_flag : Int32 = 5

///|
pub let ctx_part_mode : Int32 = 13

///|
pub let ctx_prev_intra_luma_pred_flag : Int32 = 17

///|
pub let ctx_intra_chroma_pred_mode : Int32 = 18

///|
pub let ctx_split_transform_flag : Int32 = 37

///|
pub let ctx_cbf_luma : Int32 = 40

///|
pub let ctx_cbf_cbcr : Int32 = 42

///|
pub let ctx_cu_chroma_qp_offset_flag : Int32 = 177

///|
pub let ctx_cu_chroma_qp_offset_idx : Int32 = 178

///|
/// Intra prediction mode code points (Table 8-1 .. 8-5).
pub let intra_planar : Int32 = 0

///|
pub let intra_dc : Int32 = 1

///|
pub let intra_hor : Int32 = 10

///|
pub let intra_ver : Int32 = 26
