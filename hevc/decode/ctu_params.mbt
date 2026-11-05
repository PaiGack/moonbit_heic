// The seam between the parsed headers (M2) and the CTU quadtree/TU/PU syntax
// driver (hevc/ctu, M3). The loop needs the per-picture geometry and every
// tool switch before it reads its first split bin; deriving them here is where
// the decode path first hands a real I frame to the reconstruction chain.
//
// M3 accepts every coding tool that keeps a single slice, single tile and no
// WPP: SAO (7.3.8.3 / 8.7.3), scaling lists (7.4.5 / 8.6.3), PCM (7.3.8.7),
// transform skip, transquant bypass and cu_chroma_qp_offset. Tiles and WPP
// are outside the Issue's single-thread scope and are refused explicitly, so
// a stream never desynchronises the CABAC decoder.

///|
/// The tools this port still refuses: tiles and wavefront parallel decoding,
/// the two the Issue locks out with "single thread (give up WPP/tiles)".
pub(all) enum UnsupportedCtuTool {
  Tiles
  Wpp
}

///|
/// The CTU loop's per-picture parameters, derived from a validated Main
/// 8-bit 4:2:0 I access unit. `slice_data` is the RBSP bytes from the slice
/// header's data_offset to the end of the NAL (single slice, single tile).
pub(all) struct CtuFrameInput {
  params : @ctu.CtuParams
  geom : @geometry.Geometry
  config : @reconstruct.ReconConfig
  qp_y : Int32
  slice_data : Bytes
  /// SAO slice flags, forwarded to the frame-level SAO pass.
  sao_luma : Bool
  sao_chroma : Bool
}

///|
/// Derives the CTU loop input. Tiles/WPP are refused; every other Main-profile
/// tool is wired and its per-picture switches are handed to the CTU loop and
/// the reconstruction config. Scaling factors come from the PPS list when it
/// is present, else the SPS list, else the flat default (empty table).
pub fn ctu_frame_input(
  sps : @hevc.SPS,
  pps : @hevc.PPS,
  slice : @hevc.SliceHeader,
  nal_rbsp : Bytes,
) -> Result[CtuFrameInput, UnsupportedCtuTool] {
  if pps.tiles_enabled {
    return Err(Tiles)
  }
  if pps.entropy_coding_sync {
    return Err(Wpp)
  }
  let w = sps.pic_width_in_luma_samples
  let h = sps.pic_height_in_luma_samples
  let geom = @geometry.Geometry::new(
    w.to_int64(),
    h.to_int64(),
    sps.ctb_log2_size_y,
    sps.min_tb_log2_size_y,
  )
  let ctb = 1 << sps.ctb_log2_size_y
  let ctbs_w = (w + ctb - 1) / ctb
  let ctbs_h = (h + ctb - 1) / ctb
  let slice_addr_rs = @safe.narrow(slice.slice_segment_address) catch {
    _ => return Err(Tiles)
  }
  // 7.4.5: the PPS overrides the SPS scaling list when it carries one.
  let scaling_list = if pps.scaling_list_present {
    pps.scaling_list
  } else {
    sps.scaling_list
  }
  let factors = if sps.scaling_list_enabled || pps.scaling_list_present {
    let f = scaling_list.factors()
    let flat : Array[Array[Array[Int32]]] = []
    for s in f {
      let mats : Array[Array[Int32]] = []
      for m in s {
        mats.push(m.factor)
      }
      flat.push(mats)
    }
    flat
  } else {
    []
  }
  let params : @ctu.CtuParams = {
    width: w,
    height: h,
    ctb_log2: sps.ctb_log2_size_y,
    min_cb_log2: sps.min_cb_log2_size_y,
    min_tb_log2: sps.min_tb_log2_size_y,
    max_tb_log2: sps.max_tb_log2_size_y,
    max_tr_hier_intra: sps.max_tr_hier_intra,
    slice_qp_y: slice.qp_y,
    cb_qp_offset: pps.cb_qp_offset + slice.cb_qp_offset,
    cr_qp_offset: pps.cr_qp_offset + slice.cr_qp_offset,
    cu_qp_delta_enabled: pps.cu_qp_delta_enabled,
    diff_cu_qp_delta_depth: pps.diff_cu_qp_delta_depth,
    sign_data_hiding: pps.sign_data_hiding_enabled,
    strong_intra_smoothing: sps.strong_intra_smoothing,
    intra_smoothing_disabled: sps.intra_smoothing_disabled,
    cu_chroma_qp_offset: pps.chroma_qp_offset_list,
    chroma_qp_offset_list_len: pps.chroma_qp_offset_list_len,
    cb_qp_offset_list: pps.cb_qp_offset_list,
    cr_qp_offset_list: pps.cr_qp_offset_list,
    sao_luma: slice.sao_luma,
    sao_chroma: slice.sao_chroma,
    sao_scale_luma: pps.log2_sao_offset_scale_luma,
    sao_scale_chroma: pps.log2_sao_offset_scale_chroma,
    transquant_bypass_enabled: pps.transquant_bypass,
    pcm_enabled: sps.pcm_enabled,
    log2_min_pcm_cb: sps.log2_min_pcm_cb_size,
    log2_max_pcm_cb: sps.log2_max_pcm_cb_size,
    pcm_bit_depth_luma: sps.pcm_bit_depth_luma,
    pcm_bit_depth_chroma: sps.pcm_bit_depth_chroma,
    pcm_loop_filter_disabled: sps.pcm_loop_filter_disabled,
    ctbs_w,
    ctbs_h,
    slice_addr_rs,
  }
  let config : @reconstruct.ReconConfig = {
    sign_data_hiding: pps.sign_data_hiding_enabled,
    strong_intra_smoothing: sps.strong_intra_smoothing,
    intra_smoothing_disabled: sps.intra_smoothing_disabled,
    transquant_bypass: pps.transquant_bypass,
    max_transform_skip_size: pps.log2_max_transform_skip_size,
    scaling: factors,
    scaling_enabled: sps.scaling_list_enabled || pps.scaling_list_present,
    transquant_bypass_enabled: pps.transquant_bypass,
    transform_skip_rotation: sps.transform_skip_rotation,
    transform_skip_enabled: pps.transform_skip_enabled,
    transform_skip_context: sps.transform_skip_context,
  }
  // data_offset is a byte index into the RBSP; the CABAC decoder reads from
  // there to the end of the NAL. A short slice is caught by Decoder::new.
  let off = @safe.narrow(slice.data_offset) catch {
    _ => return Err(Tiles) // oversized offset is not a valid stream
  }
  let slice_data = if off < nal_rbsp.length() {
    nal_rbsp.exact_view(start=off, end=nal_rbsp.length()).to_owned()
  } else {
    b""
  }
  Ok({
    params,
    geom,
    config,
    qp_y: slice.qp_y,
    slice_data,
    sao_luma: slice.sao_luma,
    sao_chroma: slice.sao_chroma,
  })
}
