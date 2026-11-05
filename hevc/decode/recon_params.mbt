// The seam between the parsed headers (M2) and the reconstruction DSP layer
// (M3). A CTU decoder needs a handful of per-picture derived parameters
// before it can read a single coefficient: the luma QP, the chroma QP the
// dequantiser scales by, the transform size bounds, and the loop-filter
// switches. They are pure functions of the parameter sets and the slice, so
// they can be filled in now even though the CTU syntax loop above them is
// still unwired -- and the chroma QP goes through the byte-exact checked
// @recon.chroma_qp rather than being recomputed by hand.

///|
/// Per-picture parameters the reconstruction chain reads first. Derived once
/// from the SPS, PPS and the first I slice of an access unit.
pub(all) struct ReconParams {
  /// `SliceQpY` (already Qp'Y of 8.6.1 for an 8-bit Main picture).
  qp_y : Int32
  /// `Qp'Cb` / `Qp'Cr`, from `chromaQP` of Table 8-10 plus the offsets.
  qp_cb : Int32
  qp_cr : Int32
  /// `MinTbLog2SizeY` / `MaxTbLog2SizeY`, the TU bounds of 7.4.3.2.
  min_tb_log2 : Int32
  max_tb_log2 : Int32
  /// `CtbLog2SizeY`, the CTU size.
  ctb_log2 : Int32
  sao_luma : Bool
  sao_chroma : Bool
  deblocking_disabled : Bool
}

///|
/// `clip3` on the QP carrier before the chroma-QP table lookup.
fn clip_qp(v : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > 57 {
    57
  } else {
    v
  }
}

///|
/// Derives @ReconParams from a validated Main 8-bit 4:2:0 access unit.
///
/// `chroma_qp` is the one layer already wired into the reconstruction: the
/// dequantiser scales chroma coefficients by `Qp'C`, and getting it wrong is
/// a whole-plane error. `q_pi` is clipped to 0..57 as 8.6.1 requires, then
/// each plane adds its offset (clamped to -12..12 by the header parser).
pub fn recon_params(
  sps : @hevc.SPS,
  pps : @hevc.PPS,
  slice : @hevc.SliceHeader,
) -> ReconParams {
  let qp_y = slice.qp_y
  // 8.6.1: Qp'C = chromaQP(clip3(Qp'Y + offset, -offC, 57), cat) + offC,
  // where offC = 6*(bitDepthChroma-8) is zero for this 8-bit port. The
  // offset goes INTO the table lookup, not added again after it.
  let off_cb = pps.cb_qp_offset + slice.cb_qp_offset
  let off_cr = pps.cr_qp_offset + slice.cr_qp_offset
  let qp_cb = @recon.chroma_qp(clip_qp(qp_y + off_cb), 1)
  let qp_cr = @recon.chroma_qp(clip_qp(qp_y + off_cr), 1)
  {
    qp_y,
    qp_cb,
    qp_cr,
    min_tb_log2: sps.min_tb_log2_size_y,
    max_tb_log2: sps.max_tb_log2_size_y,
    ctb_log2: sps.ctb_log2_size_y,
    sao_luma: slice.sao_luma,
    sao_chroma: slice.sao_chroma,
    deblocking_disabled: slice.deblocking_disabled,
  }
}

///|
/// The slice-level loop-filter switches of 7.4.7.1, derived from the parsed
/// header. `betaTc` of 8.7.2.5.3 is the first thing the deblocking driver
/// computes for an edge; going through the byte-exact checked
/// `@loopfilter.beta_tc` here means the decode path uses the same verified
/// kernel the CTU loop will, not a hand-rolled QP lookup.
pub(all) struct LoopFilterParams {
  beta_off_div2 : Int32
  tc_off_div2 : Int32
  deblocking_disabled : Bool
  sao_luma : Bool
  sao_chroma : Bool
  /// beta / tc at the slice QP for a boundary of strength 2 (an intra edge),
  /// the first derivation the deblock pass makes.
  bs2_beta : Int32
  bs2_tc : Int32
}

///|
/// Derives the loop-filter parameters for one I slice. `qp_y` is SliceQpY;
/// the offsets are already clipped to -6..6 by the header parser, so beta_tc
/// cannot be driven into an out-of-table index.
pub fn loop_filter_params(slice : @hevc.SliceHeader) -> LoopFilterParams {
  let bt = @loopfilter.beta_tc(
    slice.qp_y,
    2,
    slice.beta_offset_div2,
    slice.tc_offset_div2,
    8,
  )
  {
    beta_off_div2: slice.beta_offset_div2,
    tc_off_div2: slice.tc_offset_div2,
    deblocking_disabled: slice.deblocking_disabled,
    sao_luma: slice.sao_luma,
    sao_chroma: slice.sao_chroma,
    bs2_beta: bt.beta,
    bs2_tc: bt.tc,
  }
}
