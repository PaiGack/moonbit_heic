// The CTU quadtree / PU / TU syntax driver of M3 (7.3.8.2..7.3.8.11). This is
// the top of the reconstruction stack: it walks the coding tree blocks of an
// I slice in raster order, reads the CABAC bins in the exact order the spec
// prescribes, and calls reconstruct_block once per transform unit to produce
// pixels. Every layer below it (CABAC, geometry, recon DSP, residual syntax,
// single-block reconstruction) is already byte-exact checked against the
// upstream Go; this package is what finally wires them into a whole picture.
//
// Scope: I slices only, Main 8-bit 4:2:0, single thread, single slice,
// single tile, no WPP. Every other Main-profile tool is implemented here:
// SAO syntax (7.3.8.3, with merge), PCM (7.3.8.7), cu_transquant_bypass,
// and the reconstruction config carries scaling lists / transform skip.
// Tiles and WPP are refused by the decode layer before any bin is read; a
// stream outside the accepted framing never desynchronises the arithmetic
// decoder.
//
// Sizes are Int32 where they index a plane (a CTB is at most 64x64 in Main),
// and Int64 where they size the picture. Context indices, QP, modes and log2
// sizes are Int32. A malformed bin or an out-of-range geometry returns Err,
// never an unchecked array index or a trap.

///|
/// Why a picture could not be reconstructed by the CTU loop.
pub(all) enum CtuError {
  /// A CABAC bin, bypass count or context the decoder refused.
  BadBin
  /// A syntax element parsed to a value outside its legal range.
  BadSyntax
  /// A geometry (block position, transform size) that cannot be
  /// reconstructed into the picture planes.
  BadGeometry
  /// The stream switches on a tool this single-thread I-frame port refuses.
  UnsupportedTool
  /// A transform unit's reconstruction (DSP/residual) failed.
  BadReconstruct
}

///|
/// The per-picture switches the CTU loop derives from the SPS/PPS/slice.
/// They are the subset of 7.3.8 the loop actually reads; everything else is
/// fixed for Main 8-bit 4:2:0 and asserted by UnsupportedTool above.
pub(all) struct CtuParams {
  /// Picture luma dimensions, as Int32 plane coordinates.
  width : Int32
  height : Int32
  ctb_log2 : Int32
  min_cb_log2 : Int32
  min_tb_log2 : Int32
  max_tb_log2 : Int32
  /// max_transform_hierarchy_depth_intra (7.4.3.2).
  max_tr_hier_intra : Int32
  /// SliceQpY, the QP a picture starts from.
  slice_qp_y : Int32
  /// pps.cb_qp_offset + slice.cb_qp_offset (and cr), the chroma QP offsets
  /// of 8.6.1 that enter the Table 8-10 lookup.
  cb_qp_offset : Int32
  cr_qp_offset : Int32
  /// cu_qp_delta_enabled_flag and its group depth.
  cu_qp_delta_enabled : Bool
  diff_cu_qp_delta_depth : Int32
  /// sign_data_hiding_enabled_flag of the PPS.
  sign_data_hiding : Bool
  /// strong_intra_smoothing_enabled_flag of the SPS.
  strong_intra_smoothing : Bool
  /// intra_smoothing_disabled_flag of the SPS.
  intra_smoothing_disabled : Bool
  /// cu_chroma_qp_offset_enabled_flag and its lists.
  cu_chroma_qp_offset : Bool
  chroma_qp_offset_list_len : Int32
  cb_qp_offset_list : Array[Int32]
  cr_qp_offset_list : Array[Int32]
  /// SAO slice flags (7.3.8.3); the CTB loop parses one SAO syntax per CTB.
  sao_luma : Bool
  sao_chroma : Bool
  /// log2_sao_offset_scale_luma / _chroma of the PPS (7.4.9.3).
  sao_scale_luma : Int32
  sao_scale_chroma : Int32
  /// `cu_transquant_bypass_enabled_flag` of the PPS; one bypass bin per CU.
  transquant_bypass_enabled : Bool
  /// `pcm_enabled_flag` and the PCM block-size / bit-depth bounds (SPS).
  pcm_enabled : Bool
  log2_min_pcm_cb : Int32
  log2_max_pcm_cb : Int32
  pcm_bit_depth_luma : Int32
  pcm_bit_depth_chroma : Int32
  pcm_loop_filter_disabled : Bool
  /// Number of CTBs across / down the picture (for SAO merge neighbours).
  ctbs_w : Int32
  ctbs_h : Int32
  /// Slice segment address (in CTBs) for SAO merge availability.
  slice_addr_rs : Int32
}

///|
/// Planes the loop reconstructs into, as Int32 samples (0..255). The decode
/// layer converts these to the Yuv420p8 bytes once the loop returns.
pub(all) struct CtuPlanes {
  y : Array[Int32]
  cb : Array[Int32]
  cr : Array[Int32]
  stride_y : Int32
  stride_c : Int32
}

///|
/// The 8.7.2 boundary state the quadtree/TU/PU walk records for the
/// frame-level deblocking pass. Every array is a linear 4x4-raster grid
/// (mv_w x mv_h), matching the upstream blk/qpY/noFilter layout: index
/// (y >> 2) * mv_w + (x >> 2). This is deliberately independent of the
/// z-scan min-TB addressing geometry.tb_index uses for reconstruction,
/// because the upstream deblock reads its block state in raster order.
pub(all) struct DeblockState {
  mv_w : Int32
  mv_h : Int32
  intra : Array[Bool]
  cbf : Array[Bool]
  tu_v : Array[Bool]
  tu_h : Array[Bool]
  pu_v : Array[Bool]
  pu_h : Array[Bool]
  qp_y : Array[Int32]
  no_filter : Array[Bool]
}

///|
pub fn new_deblock_state(width : Int32, height : Int32) -> DeblockState {
  let mv_w = (width + 3) / 4
  let mv_h = (height + 3) / 4
  let n = mv_w * mv_h
  {
    mv_w,
    mv_h,
    intra: Array::make(n, false),
    cbf: Array::make(n, false),
    tu_v: Array::make(n, false),
    tu_h: Array::make(n, false),
    pu_v: Array::make(n, false),
    pu_h: Array::make(n, false),
    qp_y: Array::make(n, 0),
    no_filter: Array::make(n, false),
  }
}

///|
/// ceil of the number of 4x4 blocks a square region covers inside the
/// picture, mirroring the upstream blocksIn(x, y, w, h, log2=2).
fn deblock_blocks_in(
  st : CtuState,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
) -> (Int32, Int32) {
  let nw = (clip_i32(x + w, 0, st.params.width) - x + 3) / 4
  let nh = (clip_i32(y + h, 0, st.params.height) - y + 3) / 4
  (nw, nh)
}

///|
/// 8.7.2.2 markTU: the left column and top row of a transform/coding block
/// are real deblocking edges; cbf marks the covered blocks when set.
fn mark_tu(st : CtuState, x : Int32, y : Int32, w : Int32, cbf : Bool) -> Unit {
  let (nw, nh) = deblock_blocks_in(st, x, y, w, w)
  for j in 0..<nh {
    let row = ((y >> 2) + j) * st.deblock.mv_w + (x >> 2)
    if cbf {
      for i in 0..<nw {
        let idx = row + i
        if idx >= 0 && idx < st.deblock.cbf.length() {
          st.deblock.cbf[idx] = true
        }
      }
    }
    if j == 0 {
      for i in 0..<nw {
        let idx = row + i
        if idx >= 0 && idx < st.deblock.tu_h.length() {
          st.deblock.tu_h[idx] = true
        }
      }
    }
    if row >= 0 && row < st.deblock.tu_v.length() {
      st.deblock.tu_v[row] = true
    }
  }
}

///|
/// 8.7.2.2 markPU: every covered block is intra for an I slice; the left
/// column and top row are prediction-block edges.
fn mark_pu(
  st : CtuState,
  x : Int32,
  y : Int32,
  w : Int32,
  intra : Bool,
) -> Unit {
  let (nw, nh) = deblock_blocks_in(st, x, y, w, w)
  for j in 0..<nh {
    let row = ((y >> 2) + j) * st.deblock.mv_w + (x >> 2)
    for i in 0..<nw {
      let idx = row + i
      if idx >= 0 && idx < st.deblock.intra.length() {
        st.deblock.intra[idx] = intra
      }
    }
    if j == 0 {
      for i in 0..<nw {
        let idx = row + i
        if idx >= 0 && idx < st.deblock.pu_h.length() {
          st.deblock.pu_h[idx] = true
        }
      }
    }
    if row >= 0 && row < st.deblock.pu_v.length() {
      st.deblock.pu_v[row] = true
    }
  }
}

///|
/// 8.6.1 setQP: qpYCur covers the whole coding unit in the 4x4 grid, and
/// 8.7.2 reads it back as the average QP of the two sides of an edge.
fn set_deblock_qp(st : CtuState, x : Int32, y : Int32, w : Int32) -> Unit {
  let (nw, nh) = deblock_blocks_in(st, x, y, w, w)
  for j in 0..<nh {
    let row = ((y >> 2) + j) * st.deblock.mv_w + (x >> 2)
    for i in 0..<nw {
      let idx = row + i
      if idx >= 0 && idx < st.deblock.qp_y.length() {
        st.deblock.qp_y[idx] = st.qp_y_cur
      }
    }
  }
}

///|
/// The mutable state one CTU walk carries across coding tree blocks. The
/// per-min-TB arrays use the same `tb_index` granularity as @geometry, so an
/// availability query and a neighbour-mode lookup address the same cell.
priv struct CtuState {
  dec : @cabac.Decoder
  geom : @geometry.Geometry
  params : CtuParams
  planes : CtuPlanes
  config : @reconstruct.ReconConfig
  deblock : DeblockState
  /// Per-min-TB state, indexed by geom.tb_index(x, y). Arrays are mutable by
  /// reference; the scalar fields below are marked mut because the loop
  /// carries them across CUs/CTBs.
  intra_mode : Array[Int32]
  intra_mode_c : Array[Int32]
  cu_depth : Array[Int32]
  qp_y : Array[Int32]
  /// 8.6.1 quantisation-group state, one group at a time.
  mut qp_y_prev : Int32
  mut qp_y_pred : Int32
  mut qp_y_cur : Int32
  mut qp_coded : Bool
  mut cu_off_coded : Bool
  mut cu_off_cb : Int32
  mut cu_off_cr : Int32
  /// Current CU's intra flag (always true for an I slice).
  mut cur_intra : Bool
  /// Per-CTB, per-component SAO parameters (7.3.8.3), one entry per CTB.
  sao : Array[Array[@syntax.SaoParams]]
  /// `cu_transquant_bypass_flag` of the current coding unit.
  mut bypass : Bool
}

///|
fn clip_i32(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
/// Wrap a raw decoder bin into a CtuError, so a bad context is a value.
fn bin(dec : @cabac.Decoder, ctx : Int32) -> Result[Int32, CtuError] {
  Ok(dec.decode_bin(ctx)) catch {
    _ => Err(BadBin)
  }
}

///|
fn bypass_bits(dec : @cabac.Decoder, n : Int32) -> Result[Int32, CtuError] {
  Ok(dec.decode_bypass_bits(n).reinterpret_as_int()) catch {
    _ => Err(BadBin)
  }
}

///|
/// `fill` of the upstream: write one value across every min-TB a coding
/// block covers. `size` is the block side in luma samples.
fn fill(
  st : CtuState,
  dst : Array[Int32],
  x : Int32,
  y : Int32,
  size : Int32,
  v : Int32,
) -> Unit {
  let m = st.params.min_tb_log2
  let min_tb = 1 << m
  let nw = (clip_i32(x + size, 0, st.params.width) - x + min_tb - 1) / min_tb
  let nh = (clip_i32(y + size, 0, st.params.height) - y + min_tb - 1) / min_tb
  for j in 0..<nh {
    for i in 0..<nw {
      let idx = st.geom.tb_index(x + i * min_tb, y + j * min_tb)
      if idx >= 0 && idx < dst.length() {
        dst[idx] = v
      }
    }
  }
}

///|
/// 9.3.4.2.2: split_cu_flag context from the two neighbours' CU depths.
fn split_cu_ctx(st : CtuState, x : Int32, y : Int32, depth : Int32) -> Int32 {
  let mut ctx = 0
  let idx_l = st.geom.tb_index(x - 1, y)
  let idx_a = st.geom.tb_index(x, y - 1)
  if x > 0 &&
    st.geom.available(x, y, x - 1, y) &&
    idx_l < st.cu_depth.length() &&
    st.cu_depth[idx_l] > depth {
    ctx += 1
  }
  if y > 0 &&
    st.geom.available(x, y, x, y - 1) &&
    idx_a < st.cu_depth.length() &&
    st.cu_depth[idx_a] > depth {
    ctx += 1
  }
  ctx
}

///|
/// 8.6.1 qPY_PRED: average of the available left/above QP inside the CTB,
/// otherwise the previous QP. Mirrors @geometry.predict_qp; the neighbour
/// QPs are read from the per-min-TB qp_y array the loop maintains.
fn predict_qp(st : CtuState, x : Int32, y : Int32) -> Int32 {
  let mut a = st.qp_y_prev
  let mut b = st.qp_y_prev
  let mask = -(1 << st.params.ctb_log2)
  let il = st.geom.tb_index(x - 1, y)
  let ia = st.geom.tb_index(x, y - 1)
  if x > 0 &&
    st.geom.available(x, y, x - 1, y) &&
    ((x - 1) & mask) == (x & mask) &&
    il < st.qp_y.length() {
    a = st.qp_y[il]
  }
  if y > 0 &&
    st.geom.available(x, y, x, y - 1) &&
    ((y - 1) & mask) == (y & mask) &&
    ia < st.qp_y.length() {
    b = st.qp_y[ia]
  }
  (a + b + 1) >> 1
}

///|
/// 9.3.3.10 cu_qp_delta_abs + sign: unary prefix (capped at 5), Exp-Golomb
/// suffix, one sign bit. Returns the signed delta.
fn parse_cu_qp_delta(st : CtuState) -> Result[Int32, CtuError] {
  let mut prefix = 0
  for k in 0..<5 {
    let b = match
      bin(st.dec, @syntax.ctx_cu_qp_delta + (if k == 0 { 0 } else { 1 })) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if b == 0 {
      break
    }
    prefix += 1
  }
  let mut v = prefix
  if prefix > 4 {
    let mut k = 0
    for _ in 0..<6 {
      if st.dec.decode_bypass() != 0 {
        k += 1
      } else {
        break
      }
    }
    let bits = match bypass_bits(st.dec, k) {
      Ok(x) => x
      Err(e) => return Err(e)
    }
    v = 5 + (1 << k) - 1 + bits
  }
  if v != 0 && st.dec.decode_bypass() != 0 {
    v = -v
  }
  Ok(v)
}

///|
/// 7.3.8.10 cu_chroma_qp_offset_flag + truncated-Rice index, selecting one
/// entry out of the PPS lists. Returns (cb, cr).
fn parse_cu_chroma_qp_offset(st : CtuState) -> Result[(Int32, Int32), CtuError] {
  let len = st.params.chroma_qp_offset_list_len
  if len < 1 ||
    st.params.cb_qp_offset_list.length() < len ||
    st.params.cr_qp_offset_list.length() < len {
    return Err(BadSyntax)
  }
  let flag = match bin(st.dec, @syntax.ctx_cu_chroma_qp_offset_flag) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if flag == 0 {
    return Ok((0, 0))
  }
  let mut idx = 0
  for _ in 0..<(len - 1) {
    let b = match bin(st.dec, @syntax.ctx_cu_chroma_qp_offset_idx) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if b == 0 {
      break
    }
    idx += 1
  }
  Ok((st.params.cb_qp_offset_list[idx], st.params.cr_qp_offset_list[idx]))
}

///|
/// 8.4.2 MPM candidates from the left/above intra modes. A neighbour that
/// is absent or sits above the CTB row contributes INTRA_DC (1).
fn mpm_candidates(st : CtuState, x : Int32, y : Int32) -> Array[Int32] {
  let mut cand_a = @syntax.intra_dc
  let mut cand_b = @syntax.intra_dc
  let mask = -(1 << st.params.ctb_log2)
  let il = st.geom.tb_index(x - 1, y)
  let ia = st.geom.tb_index(x, y - 1)
  if x > 0 && st.geom.available(x, y, x - 1, y) && il < st.intra_mode.length() {
    cand_a = st.intra_mode[il]
  }
  if y > 0 &&
    st.geom.available(x, y, x, y - 1) &&
    y - 1 >= (y & mask) &&
    ia < st.intra_mode.length() {
    cand_b = st.intra_mode[ia]
  }
  @syntax.mpm_cand(cand_a, cand_b)
}

///|
/// 7.3.8.5 / 8.4.2: finish one luma intra mode after its prev flag has been
/// read (`prev` is passed in so the caller controls the read order).
fn intra_luma_mode_with_flag(
  st : CtuState,
  cand : Array[Int32],
  prev : Bool,
) -> Result[Int32, CtuError] {
  if cand.length() != 3 {
    return Err(BadSyntax)
  }
  if prev {
    let mut idx = 0
    if st.dec.decode_bypass() != 0 {
      idx = 1
      if st.dec.decode_bypass() != 0 {
        idx = 2
      }
    }
    return Ok(cand[idx])
  }
  let sorted = [cand[0], cand[1], cand[2]]
  if sorted[0] > sorted[1] {
    let t = sorted[0]
    sorted[0] = sorted[1]
    sorted[1] = t
  }
  if sorted[0] > sorted[2] {
    let t = sorted[0]
    sorted[0] = sorted[2]
    sorted[2] = t
  }
  if sorted[1] > sorted[2] {
    let t = sorted[1]
    sorted[1] = sorted[2]
    sorted[2] = t
  }
  let bits = match bypass_bits(st.dec, 5) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let mut mode = bits
  for m in sorted {
    if mode >= m {
      mode += 1
    }
  }
  Ok(mode)
}

///|
/// 7.3.8.5 / Table 8-2: intra_chroma_pred_mode. Zero flag inherits the luma
/// mode; otherwise a 2-bit index picks one of four defaults (mode 34 on a
/// collision). 4:2:0 needs no Table 8-3 remap.
fn intra_chroma_mode(st : CtuState, luma : Int32) -> Result[Int32, CtuError] {
  let flag = match bin(st.dec, @syntax.ctx_intra_chroma_pred_mode) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if flag == 0 {
    return Ok(luma)
  }
  let idx = match bypass_bits(st.dec, 2) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let table = [
    @syntax.intra_planar, @syntax.intra_ver, @syntax.intra_hor, @syntax.intra_dc,
  ]
  if idx < 0 || idx >= table.length() {
    return Err(BadSyntax)
  }
  let mut mode = table[idx]
  if mode == luma {
    mode = 34
  }
  Ok(mode)
}

///|
/// The QP a transform unit reconstructs a component with (8.6.3). Luma is
/// Qp'Y; chroma goes through Table 8-10 with the slice/PPS/cu offsets, all
/// clipped as 8.6.1 prescribes.
fn component_qp(st : CtuState, c_idx : Int32, luma_qp : Int32) -> Int32 {
  if c_idx == 0 {
    return luma_qp
  }
  // 8.6.3: Qp'C = chromaQP(clip3(Qp'Y + pps/slice/cu offsets, -offC, 57),
  // CAT) + offC. offC is zero for 8-bit; the three offsets all feed the
  // table lookup, not the luma QP.
  let off = if c_idx == 2 {
    st.params.cr_qp_offset + st.cu_off_cr
  } else {
    st.params.cb_qp_offset + st.cu_off_cb
  }
  @recon.chroma_qp(clip_i32(luma_qp + off, 0, 57), 1)
}

///|
/// Reconstruct one transform block (luma or chroma) into its plane. `qp` is
/// already the component QP of 8.6.3. `cbf` decides whether residual syntax
/// is read from the shared CABAC decoder.
fn reconstruct_tb(
  st : CtuState,
  x : Int32,
  y : Int32,
  log2_size : Int32,
  c_idx : Int32,
  mode : Int32,
  qp : Int32,
  cbf : Bool,
) -> Result[Unit, CtuError] {
  let plane = if c_idx == 0 {
    st.planes.y
  } else if c_idx == 1 {
    st.planes.cb
  } else {
    st.planes.cr
  }
  let stride = if c_idx == 0 { st.planes.stride_y } else { st.planes.stride_c }
  match
    @reconstruct.reconstruct_block_full(
      st.geom,
      plane,
      stride,
      x,
      y,
      log2_size,
      mode,
      c_idx,
      qp,
      st.dec,
      cbf,
      st.config,
      st.bypass,
    ) {
    Ok(_) => Ok(())
    Err(_) => Err(BadReconstruct)
  }
}

///|
/// 7.3.8.9 transform_unit: mark QP, optionally parse the QP deltas, then
/// reconstruct luma and the two chroma transform blocks.
fn transform_unit(
  st : CtuState,
  x : Int32,
  y : Int32,
  x_base : Int32,
  y_base : Int32,
  log2_size : Int32,
  blk_idx : Int32,
  luma_modes : Array[Int32],
  cbf_luma : Bool,
  cbf_cb : Bool,
  cbf_cr : Bool,
) -> Result[Unit, CtuError] {
  let mode = if st.cur_intra {
    let i = st.geom.tb_index(x, y)
    if i < 0 || i >= st.intra_mode.length() {
      return Err(BadGeometry)
    }
    st.intra_mode[i]
  } else {
    luma_modes[0]
  }

  // (cbf_luma || cbf_chroma) && cu_qp_delta_enabled && !qp_coded
  if (cbf_luma || cbf_cb || cbf_cr) &&
    st.params.cu_qp_delta_enabled &&
    !st.qp_coded {
    let delta = match parse_cu_qp_delta(st) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    st.qp_coded = true
    st.qp_y_cur = @syntax.qp_wrap(st.qp_y_pred, delta, 8)
  }
  if (cbf_cb || cbf_cr) && st.params.cu_chroma_qp_offset && !st.cu_off_coded {
    let (cb, cr) = match parse_cu_chroma_qp_offset(st) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    st.cu_off_cb = cb
    st.cu_off_cr = cr
    st.cu_off_coded = true
  }

  // 8.7.2.2: the transform block's left/top edges are real deblocking
  // edges, and cbfLuma marks the covered 4x4 blocks (upstream markTU).
  mark_tu(st, x, y, 1 << log2_size, cbf_luma)

  let qp_luma = st.qp_y_cur
  let qp_chroma = component_qp(st, 1, qp_luma)
  let qp_chroma2 = component_qp(st, 2, qp_luma)

  // Luma transform block.
  match reconstruct_tb(st, x, y, log2_size, 0, mode, qp_luma, cbf_luma) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }

  // 4:2:0 chroma: one TB per component at log2_size-1, except a 4x4 luma
  // TU (log2_size 2) whose chroma is deferred to the last of four siblings
  // (blkIdx == 3) at the parent's base coordinates.
  if log2_size > 2 {
    let c_log2 = log2_size - 1
    let cx = x / 2
    let cy = y / 2
    let cm_i = st.geom.tb_index(x_base, y_base)
    let cm = if cm_i >= 0 && cm_i < st.intra_mode_c.length() {
      st.intra_mode_c[cm_i]
    } else {
      mode
    }
    match reconstruct_tb(st, cx, cy, c_log2, 1, cm, qp_chroma, cbf_cb) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match reconstruct_tb(st, cx, cy, c_log2, 2, cm, qp_chroma2, cbf_cr) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else if blk_idx == 3 {
    let cx = x_base / 2
    let cy = y_base / 2
    let cm_i = st.geom.tb_index(x_base, y_base)
    let cm = if cm_i >= 0 && cm_i < st.intra_mode_c.length() {
      st.intra_mode_c[cm_i]
    } else {
      mode
    }
    match reconstruct_tb(st, cx, cy, 2, 1, cm, qp_chroma, cbf_cb) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match reconstruct_tb(st, cx, cy, 2, 2, cm, qp_chroma2, cbf_cr) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok(())
}

///|
/// 7.3.8.8 transform_tree: split_transform_flag, cbf_cb/cr, then four
/// children or a transform_unit. `cbf_cb_up`/`cbf_cr_up` are the parent's
/// chroma flags that gate whether a nested level reads them.
fn transform_tree(
  st : CtuState,
  x : Int32,
  y : Int32,
  x_base : Int32,
  y_base : Int32,
  log2_size : Int32,
  depth : Int32,
  blk_idx : Int32,
  luma_modes : Array[Int32],
  part_mode : Int32,
  cbf_cb_up : Bool,
  cbf_cr_up : Bool,
) -> Result[Unit, CtuError] {
  let intra_split = st.cur_intra && part_mode == 3
  let mut max_depth = st.params.max_tr_hier_intra
  if intra_split {
    max_depth += 1
  }
  let mut split = log2_size > st.params.max_tb_log2 ||
    (intra_split && depth == 0)
  if log2_size <= st.params.max_tb_log2 &&
    log2_size > st.params.min_tb_log2 &&
    depth < max_depth &&
    !(intra_split && depth == 0) {
    let ctx = @syntax.split_tf_ctx(log2_size)
    let b = match bin(st.dec, ctx) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    split = b != 0
  }

  let mut cbf_cb = cbf_cb_up
  let mut cbf_cr = cbf_cr_up
  // ChromaArrayType != 0 and (log2Size > 2 or 4:4:4): read cbf_cb/cr.
  if log2_size > 2 {
    if depth == 0 || cbf_cb_up {
      let b = match bin(st.dec, @syntax.cbf_cbcr_ctx(depth)) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      cbf_cb = b != 0
    }
    if depth == 0 || cbf_cr_up {
      let b = match bin(st.dec, @syntax.cbf_cbcr_ctx(depth)) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      cbf_cr = b != 0
    }
  }

  if split {
    let half = 1 << (log2_size - 1)
    for i in 0..<4 {
      let nx = x + (i & 1) * half
      let ny = y + (i >> 1) * half
      match
        transform_tree(
          st,
          nx,
          ny,
          x,
          y,
          log2_size - 1,
          depth + 1,
          i,
          luma_modes,
          part_mode,
          cbf_cb,
          cbf_cr,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    return Ok(())
  }

  // 7.3.8.8: cbf_luma is inferred true only for a non-intra root TU with
  // no chroma coefficients; an I slice always codes it.
  let mut cbf_luma = true
  if depth != 0 || cbf_cb || cbf_cr || st.cur_intra {
    let b = match bin(st.dec, @syntax.cbf_luma_ctx(depth)) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    cbf_luma = b != 0
  }
  transform_unit(
    st, x, y, x_base, y_base, log2_size, blk_idx, luma_modes, cbf_luma, cbf_cb, cbf_cr,
  )
}

///|
/// 7.3.8.5 coding_unit (intra branch of an I slice): transquant bypass is
/// refused, part_mode, prev flags for every prediction block, the luma
/// modes, the chroma mode, then the transform tree.
fn coding_unit(
  st : CtuState,
  x : Int32,
  y : Int32,
  log2_size : Int32,
  depth : Int32,
) -> Result[Unit, CtuError] {
  let size = 1 << log2_size
  fill(st, st.cu_depth, x, y, size, depth)

  // 7.3.8.5: cu_transquant_bypass_flag, read once per coding unit when the
  // PPS enables the tool. A bypassed CU carries its coefficients as the
  // residual with no scaling and no transform (8.6.2), and its samples are
  // excluded from the loop filters.
  st.bypass = false
  if st.params.transquant_bypass_enabled {
    let b = match bin(st.dec, @syntax.ctx_cu_transquant_bypass_flag) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    st.bypass = b != 0
    if st.bypass {
      let (nw, nh) = deblock_blocks_in(st, x, y, size, size)
      for j in 0..<nh {
        let row = ((y >> 2) + j) * st.deblock.mv_w + (x >> 2)
        for i in 0..<nw {
          let idx = row + i
          if idx >= 0 && idx < st.deblock.no_filter.length() {
            st.deblock.no_filter[idx] = true
          }
        }
      }
    }
  }

  // I slice: no cu_skip_flag, pred_mode is implicitly intra.
  st.cur_intra = true
  // 8.7.2.2: every covered 4x4 block is intra, and the CU's left/top edges
  // are prediction-block boundaries (upstream markPU).
  mark_pu(st, x, y, size, true)

  // 7.3.8.5: part_mode is only present when the CU can be split into
  // prediction blocks -- for an I slice that is exactly the smallest CB.
  // A larger intra CU is implicitly PART_2Nx2N and reads no bin here.
  let mut part_mode = 0
  if log2_size == st.params.min_cb_log2 {
    let b = match bin(st.dec, @syntax.ctx_part_mode) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    part_mode = if b != 0 { 0 } else { 3 }
  }
  if part_mode != 0 && part_mode != 3 {
    return Err(UnsupportedTool)
  }

  // 7.3.8.7: pcm_flag is a terminate bin, present only when the PCM tool is
  // on and the CU size falls inside the SPS bounds and part_mode is 2Nx2N.
  if st.params.pcm_enabled &&
    log2_size >= st.params.log2_min_pcm_cb &&
    log2_size <= st.params.log2_max_pcm_cb &&
    part_mode == 0 {
    if st.dec.decode_terminate() != 0 {
      match pcm_sample(st, x, y, log2_size) {
        Ok(new_off) => {
          // Restart the arithmetic decoder at the byte after the PCM samples,
          // keeping the context states (upstream cabac.init does the same).
          st.dec.restart_at(new_off) catch {
            _ => return Err(BadBin)
          }
          // 8.6.1: qPY_PREV carries the CU's QP to the next quantisation
          // group even for a PCM CU; the CU's own QP is unchanged.
          fill(st, st.qp_y, x, y, size, st.qp_y_cur)
          set_deblock_qp(st, x, y, size)
          st.qp_y_prev = st.qp_y_cur
          return Ok(())
        }
        Err(e) => return Err(e)
      }
    }
  }

  let parts = if part_mode == 3 { 4 } else { 1 }
  let pb_size = if part_mode == 3 { size / 2 } else { size }

  // 7.3.8.5: all prev_intra_luma_pred_flags precede the mode indices.
  let prev_flags : Array[Bool] = []
  for _ in 0..<parts {
    let b = match bin(st.dec, @syntax.ctx_prev_intra_luma_pred_flag) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    prev_flags.push(b != 0)
  }

  let luma_modes : Array[Int32] = []
  for i in 0..<parts {
    let px = x + (i & 1) * pb_size
    let py = y + (i >> 1) * pb_size
    let cand = mpm_candidates(st, px, py)
    let m = match intra_luma_mode_with_flag(st, cand, prev_flags[i]) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if m < 0 || m > 34 {
      return Err(BadSyntax)
    }
    luma_modes.push(m)
    fill(st, st.intra_mode, px, py, pb_size, m)
  }

  // 7.3.8.5: one intra_chroma_pred_mode per CU for 4:2:0.
  let cm = match intra_chroma_mode(st, luma_modes[0]) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  fill(st, st.intra_mode_c, x, y, size, cm)

  let r = transform_tree(
    st, x, y, x, y, log2_size, 0, 0, luma_modes, part_mode, false, false,
  )
  // 8.6.1: QpY covers the whole coding unit, even one with no residual, and
  // qPY_PREV carries it to the next quantisation group. 8.7.2.2 also marks
  // the coding block boundary with no cbf and records QpY for deblocking.
  if r is Ok(_) {
    fill(st, st.qp_y, x, y, size, st.qp_y_cur)
    mark_tu(st, x, y, size, false)
    set_deblock_qp(st, x, y, size)
    st.qp_y_prev = st.qp_y_cur
  }
  r
}

///|
/// 7.3.8.2 coding_quadtree: split_cu_flag, quantisation-group restart, then
/// four children or a coding_unit. Blocks crossing the picture edge are
/// skipped, exactly as upstream does not code them.
fn coding_quadtree(
  st : CtuState,
  x : Int32,
  y : Int32,
  log2_size : Int32,
  depth : Int32,
) -> Result[Unit, CtuError] {
  let mut split = log2_size > st.params.min_cb_log2
  if log2_size > st.params.min_cb_log2 &&
    x + (1 << log2_size) <= st.params.width &&
    y + (1 << log2_size) <= st.params.height {
    let ctx = @syntax.ctx_split_coding_unit_flag + split_cu_ctx(st, x, y, depth)
    let b = match bin(st.dec, ctx) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    split = b != 0
  }

  // 8.6.1 quantisation group restart.
  if st.params.cu_qp_delta_enabled &&
    log2_size >= st.params.ctb_log2 - st.params.diff_cu_qp_delta_depth {
    st.qp_coded = false
    st.qp_y_pred = predict_qp(st, x, y)
    st.qp_y_cur = st.qp_y_pred
  }
  if st.params.cu_chroma_qp_offset &&
    log2_size >= st.params.ctb_log2 - st.params.diff_cu_qp_delta_depth {
    st.cu_off_coded = false
    st.cu_off_cb = 0
    st.cu_off_cr = 0
  }

  if !split {
    return coding_unit(st, x, y, log2_size, depth)
  }
  let half = 1 << (log2_size - 1)
  for i in 0..<4 {
    let nx = x + (i & 1) * half
    let ny = y + (i >> 1) * half
    if nx >= st.params.width || ny >= st.params.height {
      continue
    }
    match coding_quadtree(st, nx, ny, log2_size - 1, depth + 1) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok(())
}

///|
/// The frame-level state the CTU walk hands back: the 8.7.2 deblocking
/// boundary state plus the per-CTB, per-component SAO parameters of 7.3.8.3
/// (one @syntax.SaoParams for each of Y, Cb, Cr). SAO is applied by the
/// decode layer after deblocking, reading the reconstructed picture as the
/// filter left it.
pub(all) struct CtuFrameState {
  deblock : DeblockState
  sao : Array[Array[@syntax.SaoParams]]
}

///|
/// 7.3.8.3 SAO for one CTB. Single tile: rsToTs is the identity, so the
/// merge-left / merge-up availability reduces to a raster-order check inside
/// the slice segment. The merge bins are read through the same CABAC decoder
/// as the quadtree, and the per-component syntax through the byte-exact
/// checked @syntax.decode_sao.
fn parse_sao_ctb(st : CtuState, rs : Int32) -> Result[Unit, CtuError] {
  let w = st.params.ctbs_w
  let left_avail = rs % w > 0 && rs - 1 >= st.params.slice_addr_rs
  let up_avail = rs >= w && rs - w >= st.params.slice_addr_rs
  let mut merge_left = false
  let mut merge_up = false
  if left_avail {
    let b = match bin(st.dec, @syntax.ctx_sao_merge_flag) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    merge_left = b != 0
  }
  if !merge_left && up_avail {
    let b = match bin(st.dec, @syntax.ctx_sao_merge_flag) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    merge_up = b != 0
  }
  if merge_left {
    st.sao[rs] = st.sao[rs - 1]
    return Ok(())
  }
  if merge_up {
    st.sao[rs] = st.sao[rs - w]
    return Ok(())
  }
  let p = match
    @syntax.decode_sao(
      st.dec,
      8,
      st.params.sao_scale_luma,
      st.params.sao_scale_chroma,
      st.params.sao_luma,
      st.params.sao_chroma,
    ) {
    Ok(v) => v
    Err(_) => return Err(BadBin)
  }
  st.sao[rs] = p
  Ok(())
}

///|
/// 7.3.8.7 / 8.4.4.1 PCM samples: read from the byte-aligned bitstream at
/// the arithmetic decoder's pcmOffset, then restart the arithmetic decoder
/// there. `cIdx` planes are written directly with no prediction/residual.
/// Returns the byte offset the CABAC decoder must restart at, or Err.
fn pcm_sample(
  st : CtuState,
  x : Int32,
  y : Int32,
  log2_size : Int32,
) -> Result[Int32, CtuError] {
  let off = st.dec.pcm_offset()
  let data = st.dec.data
  if off < 0 || off >= data.length() {
    return Err(BadBin)
  }
  let size = 1 << log2_size
  let depth_y = st.params.pcm_bit_depth_luma
  let depth_c = st.params.pcm_bit_depth_chroma
  // MSB-first bit reader over the bytes from off.
  let mut bit_pos = 0
  let read_bits = fn(n : Int32) -> Int32 {
    let mut v = 0
    for _ in 0..<n {
      let byte = off + bit_pos / 8
      if byte >= data.length() {
        return -1
      }
      let shift = 7 - bit_pos % 8
      v = (v << 1) | ((data[byte].to_int() >> shift) & 1)
      bit_pos += 1
    }
    v
  }
  let scale_y = 8 - depth_y
  let scale_c = 8 - depth_c
  for j in 0..<size {
    for i in 0..<size {
      let v = read_bits(depth_y)
      if v < 0 {
        return Err(BadBin)
      }
      let idx = (y + j) * st.planes.stride_y + x + i
      if idx >= 0 && idx < st.planes.y.length() {
        st.planes.y[idx] = v << scale_y
      }
    }
  }
  let sw = 2
  let sh = 2
  let cs = size / 2
  for c_idx in 1..<3 {
    let plane = if c_idx == 1 { st.planes.cb } else { st.planes.cr }
    for j in 0..<cs {
      for i in 0..<cs {
        let v = read_bits(depth_c)
        if v < 0 {
          return Err(BadBin)
        }
        let idx = (y / sh + j) * st.planes.stride_c + x / sw + i
        if idx >= 0 && idx < plane.length() {
          plane[idx] = v << scale_c
        }
      }
    }
  }
  // Mark the covered blocks as intra / PU / TU edges with no coefficients,
  // exactly as upstream markPU / markTU / setQP do for a PCM CU.
  fill(st, st.intra_mode, x, y, size, @syntax.intra_dc)
  mark_pu(st, x, y, size, true)
  mark_tu(st, x, y, size, false)
  set_deblock_qp(st, x, y, size)
  if st.params.pcm_loop_filter_disabled {
    let (nw, nh) = deblock_blocks_in(st, x, y, size, size)
    for j in 0..<nh {
      let row = ((y >> 2) + j) * st.deblock.mv_w + (x >> 2)
      for i in 0..<nw {
        let idx = row + i
        if idx >= 0 && idx < st.deblock.no_filter.length() {
          st.deblock.no_filter[idx] = true
        }
      }
    }
  }
  // Byte-align the arithmetic decoder restart offset.
  Ok(off + (bit_pos + 7) / 8)
}

///|
/// Reconstruct one whole I picture's CTU layer into `planes`. The CABAC
/// decoder must already be initialised at the slice data and its contexts
/// seeded for the slice QP/type. CTBs are visited in raster order (single
/// tile), each followed by an end_of_slice_segment_flag terminate bin; a
/// terminating bin ends the walk.
///
/// This is the frame-level orchestration M3 was missing: it is the first
/// entry point that turns a slice's CABAC substream into a whole picture of
/// pixels, by driving the quadtree/TU/PU syntax in spec order.
pub fn decode_ctu_frame(
  dec : @cabac.Decoder,
  geom : @geometry.Geometry,
  params : CtuParams,
  planes : CtuPlanes,
  config : @reconstruct.ReconConfig,
) -> Result[CtuFrameState, CtuError] {
  let n_tb = geom.min_tb_w * geom.min_tb_h
  let deblock = new_deblock_state(params.width, params.height)
  let ctbs_w = (params.width + (1 << params.ctb_log2) - 1) /
    (1 << params.ctb_log2)
  let ctbs_h = (params.height + (1 << params.ctb_log2) - 1) /
    (1 << params.ctb_log2)
  let sao : Array[Array[@syntax.SaoParams]] = Array::make(ctbs_w * ctbs_h, [
    { type_idx: 0, offset: [0, 0, 0, 0], band: 0, class_: 0, },
    { type_idx: 0, offset: [0, 0, 0, 0], band: 0, class_: 0, },
    { type_idx: 0, offset: [0, 0, 0, 0], band: 0, class_: 0, },
  ])
  let st : CtuState = {
    dec,
    geom,
    params,
    planes,
    config,
    deblock,
    intra_mode: Array::make(n_tb, @syntax.intra_dc),
    intra_mode_c: Array::make(n_tb, @syntax.intra_dc),
    cu_depth: Array::make(n_tb, 0),
    qp_y: Array::make(n_tb, params.slice_qp_y),
    qp_y_prev: params.slice_qp_y,
    qp_y_pred: params.slice_qp_y,
    qp_y_cur: params.slice_qp_y,
    qp_coded: false,
    cu_off_coded: false,
    cu_off_cb: 0,
    cu_off_cr: 0,
    cur_intra: true,
    sao,
    bypass: false,
  }
  let ctb = 1 << params.ctb_log2
  for cy in 0..<ctbs_h {
    for cx in 0..<ctbs_w {
      let x = cx * ctb
      let y = cy * ctb
      let rs = cy * ctbs_w + cx
      // 7.3.8.2: SAO syntax precedes the quadtree for each CTB.
      if params.sao_luma || params.sao_chroma {
        match parse_sao_ctb(st, rs) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
      match coding_quadtree(st, x, y, params.ctb_log2, 0) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      // 7.3.8.1 end_of_slice_segment_flag via decodeTerminate. Use st.dec
      // (not the outer binding) so a PCM restart stays in step.
      if st.dec.decode_terminate() != 0 {
        return Ok({ deblock: st.deblock, sao: st.sao, })
      }
    }
  }
  Ok({ deblock: st.deblock, sao: st.sao, })
}
