// The CTU quadtree / PU / TU syntax driver of M3 (7.3.8.2..7.3.8.11). This is
// the top of the reconstruction stack: it walks the coding tree blocks of an
// I slice in raster order, reads the CABAC bins in the exact order the spec
// prescribes, and calls reconstruct_block once per transform unit to produce
// pixels. Every layer below it (CABAC, geometry, recon DSP, residual syntax,
// single-block reconstruction) is already byte-exact checked against the
// upstream Go; this package is what finally wires them into a whole picture.
//
// Scope is locked to the M3 deliverable: I slices only, Main 8-bit 4:2:0,
// single thread, single slice, single tile, no WPP, no PCM, no SAO, no
// transform skip, no scaling lists, no transquant bypass. A stream that
// switches any of these on is refused with Err rather than decoded into
// plausible-looking but wrong pixels -- the loop reads no bin it cannot
// account for, so a rejected tool never desynchronises the arithmetic
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
  /// log2_sao_offset_scale for SAO (unused: SAO is refused).
  sao_luma : Bool
  sao_chroma : Bool
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
/// The mutable state one CTU walk carries across coding tree blocks. The
/// per-min-TB arrays use the same `tb_index` granularity as @geometry, so an
/// availability query and a neighbour-mode lookup address the same cell.
priv struct CtuState {
  dec : @cabac.Decoder
  geom : @geometry.Geometry
  params : CtuParams
  planes : CtuPlanes
  config : @reconstruct.ReconConfig
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
    @reconstruct.reconstruct_block(
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

  // transquant_bypass_enabled is an UnsupportedTool; the loop must not
  // consume a bin for it. The decode layer refuses such a PPS up front.

  // I slice: no cu_skip_flag, pred_mode is implicitly intra.
  st.cur_intra = true

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
  // qPY_PREV carries it to the next quantisation group.
  if r is Ok(_) {
    fill(st, st.qp_y, x, y, size, st.qp_y_cur)
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
) -> Result[Unit, CtuError] {
  let n_tb = geom.min_tb_w * geom.min_tb_h
  let st : CtuState = {
    dec,
    geom,
    params,
    planes,
    config,
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
  }
  let ctb = 1 << params.ctb_log2
  let ctbs_w = (params.width + ctb - 1) / ctb
  let ctbs_h = (params.height + ctb - 1) / ctb
  for cy in 0..<ctbs_h {
    for cx in 0..<ctbs_w {
      let x = cx * ctb
      let y = cy * ctb
      // SAO is refused by the decode layer; no bin is read here.
      match coding_quadtree(st, x, y, params.ctb_log2, 0) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      // 7.3.8.1 end_of_slice_segment_flag via decodeTerminate.
      if dec.decode_terminate() != 0 {
        return Ok(())
      }
    }
  }
  Ok(())
}
