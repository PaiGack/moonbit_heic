// The seam between the parsed headers (M2) and the CTU quadtree/TU/PU syntax
// driver (hevc/ctu, M3). The loop needs a handful of per-picture geometry and
// tool switches before it reads its first split bin; deriving them here is
// where the decode path first hands a real I frame to the reconstruction
// chain. A tool the single-thread I-frame loop does not implement is refused
// explicitly, so a stream never desynchronises the CABAC decoder.

///|
/// The tools this increment of the CTU loop refuses, as a value the decode
/// layer matches on. Keeping the list explicit makes it obvious what the
/// next increment has to wire (SAO, PCM, transform skip, scaling lists,
/// transquant bypass, tiles/WPP, multi-slice).
pub(all) enum UnsupportedCtuTool {
  Sao
  Pcm
  TransformSkip
  ScalingList
  TransquantBypass
  Tiles
  Wpp
  CuChromaQpOffset
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
}

///|
/// Derives the CTU loop input, or the first unsupported tool the loop would
/// need to consume a bin for. The order matters: a stream with SAO on reads
/// SAO bins before the quadtree, so it cannot be decoded by silently
/// skipping them.
pub fn ctu_frame_input(
  sps : @hevc.SPS,
  pps : @hevc.PPS,
  slice : @hevc.SliceHeader,
  nal_rbsp : Bytes,
) -> Result[CtuFrameInput, UnsupportedCtuTool] {
  if sps.sao_enabled || slice.sao_luma || slice.sao_chroma {
    return Err(Sao)
  }
  if sps.pcm_enabled {
    return Err(Pcm)
  }
  if pps.transform_skip_enabled {
    return Err(TransformSkip)
  }
  if sps.scaling_list_enabled || pps.scaling_list_present {
    return Err(ScalingList)
  }
  if pps.transquant_bypass {
    return Err(TransquantBypass)
  }
  if pps.tiles_enabled {
    return Err(Tiles)
  }
  if pps.entropy_coding_sync {
    return Err(Wpp)
  }
  if pps.chroma_qp_offset_list {
    return Err(CuChromaQpOffset)
  }
  let w = sps.pic_width_in_luma_samples
  let h = sps.pic_height_in_luma_samples
  let geom = @geometry.Geometry::new(
    w.to_int64(),
    h.to_int64(),
    sps.ctb_log2_size_y,
    sps.min_tb_log2_size_y,
  )
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
    cu_chroma_qp_offset: false,
    chroma_qp_offset_list_len: 1,
    cb_qp_offset_list: [0],
    cr_qp_offset_list: [0],
    sao_luma: false,
    sao_chroma: false,
  }
  let config : @reconstruct.ReconConfig = {
    sign_data_hiding: pps.sign_data_hiding_enabled,
    strong_intra_smoothing: sps.strong_intra_smoothing,
    intra_smoothing_disabled: sps.intra_smoothing_disabled,
    transquant_bypass: false,
    max_transform_skip_size: 0,
  }
  // data_offset is a byte index into the RBSP; the CABAC decoder reads from
  // there to the end of the NAL. A short slice is caught by Decoder::new.
  let off = @safe.narrow(slice.data_offset) catch {
    _ => return Err(ScalingList) // oversized offset is not a valid stream
  }
  let slice_data = if off < nal_rbsp.length() {
    nal_rbsp.exact_view(start=off, end=nal_rbsp.length()).to_owned()
  } else {
    b""
  }
  Ok({ params, geom, config, qp_y: slice.qp_y, slice_data, })
}
