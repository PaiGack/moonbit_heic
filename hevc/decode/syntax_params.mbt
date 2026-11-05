// The seam between the parsed headers (M2) and the CTU-level CABAC syntax
// layer (hevc/syntax, M3). A CTU decoder needs these per-picture switches
// before it reads its first split/cbf/mode bin: which optional syntax is
// present, the SAO offset scales, the chroma QP offset lists, and the TU
// bounds that pick transform-tree contexts. They are pure functions of the
// parameter sets and the slice, so they can be derived now -- and the
// verified @syntax derivations are consulted here for the context indices and
// the QP wrap, which is the first syntax layer the decode path actually uses.

///|
/// Per-picture parameters the CTU syntax loop reads before decoding any bin.
/// Derived once from the SPS, PPS and the first I slice of an access unit.
pub(all) struct SyntaxParams {
  /// cu_qp_delta_enabled_flag: whether parseCuQPDelta is reachable.
  cu_qp_delta_enabled : Bool
  /// diff_cu_qp_delta_depth: the CB size at which a QP delta group starts.
  diff_cu_qp_delta_depth : Int32
  /// chroma_qp_offset_list_enabled_flag and its list length.
  cu_chroma_qp_offset_enabled : Bool
  chroma_qp_offset_list_len : Int32
  /// log2_sao_offset_scale_luma / _chroma, the SAO offset shift of 7.4.9.3.
  sao_scale_luma : Int32
  sao_scale_chroma : Int32
  /// sign_data_hiding_enabled_flag, transform_skip_enabled_flag.
  sign_data_hiding : Bool
  transform_skip_enabled : Bool
  /// The transform-tree bounds, for split_transform_flag contexts.
  min_tb_log2 : Int32
  max_tb_log2 : Int32
  /// split_transform_flag ctx at MaxTbLog2SizeY, the first derivation the
  /// transform-tree loop makes (7.4.9.11). Uses the checked @syntax kernel.
  root_split_tf_ctx : Int32
  /// cbf_luma ctx at the root TU (trafoDepth 0) and at a nested TU (depth 1).
  cbf_luma_root_ctx : Int32
  cbf_luma_nested_ctx : Int32
  /// Qp'Y of the first QP group, wrapped by the checked 8.6.1 kernel.
  qp_y_wrapped : Int32
}

///|
/// Derives @SyntaxParams from a validated Main 8-bit 4:2:0 access unit.
///
/// The context indices and the QP wrap go through the byte-exact checked
/// @syntax kernels (split_tf_ctx / cbf_luma_ctx / qp_wrap), so the decode
/// path uses the same derivations the CTU loop will, not hand-rolled indices.
pub fn syntax_params(
  sps : @hevc.SPS,
  pps : @hevc.PPS,
  slice : @hevc.SliceHeader,
) -> SyntaxParams {
  {
    cu_qp_delta_enabled: pps.cu_qp_delta_enabled,
    diff_cu_qp_delta_depth: pps.diff_cu_qp_delta_depth,
    cu_chroma_qp_offset_enabled: pps.chroma_qp_offset_list,
    chroma_qp_offset_list_len: pps.chroma_qp_offset_list_len,
    sao_scale_luma: pps.log2_sao_offset_scale_luma,
    sao_scale_chroma: pps.log2_sao_offset_scale_chroma,
    sign_data_hiding: pps.sign_data_hiding_enabled,
    transform_skip_enabled: pps.transform_skip_enabled,
    min_tb_log2: sps.min_tb_log2_size_y,
    max_tb_log2: sps.max_tb_log2_size_y,
    root_split_tf_ctx: @syntax.split_tf_ctx(sps.max_tb_log2_size_y),
    cbf_luma_root_ctx: @syntax.cbf_luma_ctx(0),
    cbf_luma_nested_ctx: @syntax.cbf_luma_ctx(1),
    qp_y_wrapped: @syntax.qp_wrap(slice.qp_y, 0, sps.bit_depth_luma),
  }
}
