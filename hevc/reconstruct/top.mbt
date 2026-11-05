// Single-block reconstruction: the first layer of M3 that actually produces
// pixels. It wires the already byte-exact-checked kernels together in the
// order 8.6.x prescribes --
//
//   gatherRef (8.4.4.2.2)  -> ref.s, substitute
//   filterRef (8.4.4.2.3)  -> @recon.RefSamples::filter_ref
//   intraPredict (8.4.4.2) -> @recon.intra_predict, written into the plane
//   decodeResidual (7.3.8.11) -> @residual.decode_residual, real CABAC bits
//   dequant (8.6.3)        -> @recon.dequant
//   inverseTransform (8.6.4) -> @recon.inverse_transform (DST for 4x4 luma)
//   addResidual (8.6.2/8.6.6) -> residual + clip into the plane
//
// The geometry of the reference samples comes from @geometry (6.5.2 / 6.4.1)
// and the arithmetic decoder from @cabac; both are held to the upstream Go
// value-for-value. hevc/reconstruct/golden.mbt carries the REAL upstream
// reconstructPlane output for 17 blocks (real encodeResidual bitstreams), and
// reconstruct_test.mbt asserts this port reproduces them sample for sample.
//
// Sizes and shifts are Int64 where they can outgrow 2^31 (plane indexing is
// narrowed at the allocation boundary); QP, log2 sizes, modes and samples are
// Int32. A malformed block is returned as Err, never an unchecked index.

///|
/// Why a block could not be reconstructed.
pub(all) enum ReconstructError {
  /// log2_size outside 2..5, c_idx outside 0..2, or a plane too short for
  /// the requested block.
  InvalidBlock
  /// The residual syntax decoder refused the stream (bad bin / bad context).
  BadResidual
}

///|
/// Per-picture switches the CTU loop threads into a single-block
/// reconstruction. The single-block golden tests use `default()` (all off),
/// which is exactly the Main 8-bit 4:2:0 non-extended case those fixtures
/// were exported for; a real I frame derives them from its SPS/PPS.
pub(all) struct ReconConfig {
  /// `sign_data_hiding_enabled_flag` of the PPS: changes the residual
  /// coefficient syntax (7.3.8.11 sign hiding), not just the arithmetic.
  sign_data_hiding : Bool
  /// `strong_intra_smoothing_enabled_flag` of the SPS (8.4.4.2.3).
  strong_intra_smoothing : Bool
  /// `intra_smoothing_disabled_flag` of the SPS.
  intra_smoothing_disabled : Bool
  /// `transquant_bypass_enabled_flag` of the PPS.
  transquant_bypass : Bool
  /// `log2_max_transform_skip_size` of the PPS; zero keeps the tool off.
  max_transform_skip_size : Int32
  /// 7.4.5 ScalingFactor tables: [size_id 0..3][matrix_id 0..5][n*n].
  /// Derived from the SPS/PPS scaling list. Empty when the tool is off.
  scaling : Array[Array[Array[Int32]]]
  /// `scaling_list_enabled_flag` of the SPS.
  scaling_enabled : Bool
  /// `cu_transquant_bypass_enabled_flag` of the PPS: when true, the CTU
  /// loop reads one bypass bin per coding unit and passes the result in.
  transquant_bypass_enabled : Bool
  /// `transform_skip_rotation_enabled_flag` of the SPS (8.6.2).
  transform_skip_rotation : Bool
  /// `transform_skip_enabled_flag` of the PPS. Gates the transform_skip bin.
  transform_skip_enabled : Bool
  /// `transform_skip_context_enabled_flag` of the SPS (9.3.4.2.5).
  transform_skip_context : Bool
}

///|
/// The configuration every single-block golden fixture was exported under:
/// no sign hiding, no strong smoothing, no bypass, no transform skip.
pub fn ReconConfig::default() -> ReconConfig {
  {
    sign_data_hiding: false,
    strong_intra_smoothing: false,
    intra_smoothing_disabled: false,
    transquant_bypass: false,
    max_transform_skip_size: 0,
    scaling: [],
    scaling_enabled: false,
    transquant_bypass_enabled: false,
    transform_skip_rotation: false,
    transform_skip_enabled: false,
    transform_skip_context: false,
  }
}

///|
/// Clip3 on the 32-bit sample carrier.
fn clip3(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
/// `addResidual` of 8.6.2 / 8.6.6: bdShift then the clipped sum. For Main
/// 8-bit without extended precision, `shift` = 20 - bitDepth = 12.
fn add_residual(
  plane : Array[Int32],
  stride : Int32,
  x : Int32,
  y : Int32,
  n : Int32,
  shift : Int32,
  coef : Array[Int32],
  bit_depth : Int32,
) -> Unit {
  let max_v = (1 << bit_depth) - 1
  // 8.6.2 bdShift: with shift <= 0 (a transquant-bypassed unit) the
  // coefficients are the residual directly, with no rounding or shift.
  if shift <= 0 {
    for j in 0..<n {
      for i in 0..<n {
        let idx = (y + j) * stride + x + i
        plane[idx] = clip3(plane[idx] + coef[j * n + i], 0, max_v)
      }
    }
    return
  }
  let rnd = 1 << (shift - 1)
  for j in 0..<n {
    for i in 0..<n {
      let idx = (y + j) * stride + x + i
      let c = coef[j * n + i]
      plane[idx] = clip3(plane[idx] + ((c + rnd) >> shift), 0, max_v)
    }
  }
}

///|
/// Reconstruct one intra transform block into `plane` (samples 0..255), in
/// place. `dec` is the CABAC arithmetic decoder for the slice; with `cbf=false`
/// it is not read (prediction only), with `cbf=true` the residual coefficients
/// are decoded from it. `qp` is Qp'Y (luma) or Qp'C (chroma) of 8.6.3.
///
/// This is the smallest closed loop from a CABAC substream to YUV samples;
/// the CTU quadtree driver will call it once per transform unit, threading a
/// shared decoder and shared geometry across the picture.
fn pick_scaling(
  config : ReconConfig,
  log2_size : Int32,
  c_idx : Int32,
  skip : Bool,
) -> Array[Int32]? {
  if !config.scaling_enabled || (skip && log2_size > 2) {
    return None
  }
  let size_id = log2_size - 2
  if size_id < 0 || size_id >= config.scaling.length() {
    return None
  }
  let mut matrix_id = c_idx // M3 is always intra
  if size_id == 3 && c_idx > 0 {
    matrix_id = 0
  }
  if matrix_id < 0 || matrix_id >= config.scaling[size_id].length() {
    return None
  }
  Some(config.scaling[size_id][matrix_id])
}

///|
/// 8.6.2 `transformSkip`: scale coefficients by 2^(5 + log2(n)); the 4x4
/// intra rotation reverses the block end for end when the SPS enables it.
fn transform_skip(
  coef : Array[Int32],
  rotate : Bool,
  log2_size : Int32,
) -> Unit {
  let shift = 5 + log2_size
  if rotate {
    let n = coef.length()
    let mut i = 0
    let mut j = n - 1
    while i < j {
      let a = coef[i]
      let b = coef[j]
      coef[i] = b << shift
      coef[j] = a << shift
      i += 1
      j -= 1
    }
    if n % 2 == 1 {
      coef[n / 2] = coef[n / 2] << shift
    }
  } else {
    for i in 0..<coef.length() {
      coef[i] = coef[i] << shift
    }
  }
}

///|
/// Full reconstruction of one intra transform block. `bypass` is the
/// `cu_transquant_bypass_flag` the CTU loop read for this coding unit: a
/// bypassed block takes its coefficients as the residual with no scaling and
/// no transform. This is the entry point the CTU driver calls.
pub fn reconstruct_block_full(
  geom : @geometry.Geometry,
  plane : Array[Int32],
  stride : Int32,
  x : Int32,
  y : Int32,
  log2_size : Int32,
  mode : Int32,
  c_idx : Int32,
  qp : Int32,
  dec : @cabac.Decoder,
  cbf : Bool,
  config : ReconConfig,
  bypass : Bool,
) -> Result[Unit, ReconstructError] {
  if log2_size < 2 || log2_size > 5 || c_idx < 0 || c_idx > 2 {
    return Err(InvalidBlock)
  }
  let n = 1 << log2_size
  // Every pixel the prediction writes and the residual adds must be inside
  // the plane; refuse otherwise rather than indexing past the allocation.
  if (y + n - 1) * stride + x + n - 1 >= plane.length() {
    return Err(InvalidBlock)
  }

  // 8.4.4.2.2 gather + substitute, then 8.4.4.2.3 smoothing and 8.4.4.2
  // prediction. chroma_array_type is 1 (4:2:0); the smoothing switches come
  // from the picture's SPS via `config`.
  let gathered = @geometry.gather_ref(geom, plane, stride, x, y, n, c_idx, 2, 2)
  let r = @recon.RefSamples::new(n, gathered.s)
  r.filter_ref(
    mode,
    c_idx,
    8,
    1,
    config.strong_intra_smoothing,
    config.intra_smoothing_disabled,
  )
  let pred = @recon.intra_predict(r, mode, c_idx, 8)
  for j in 0..<n {
    for i in 0..<n {
      plane[(y + j) * stride + x + i] = pred[j * n + i]
    }
  }
  if !cbf {
    return Ok(())
  }

  // 7.3.8.11 residual coefficients, then 8.6.3 -> 8.6.4 -> 8.6.6.
  let coef : Array[Int32] = Array::make(n * n, 0)
  let block : @residual.ResidualBlock = {
    log2_size,
    c_idx,
    pred_mode_intra: mode,
    intra: true,
    transquant_bypass: bypass,
    max_transform_skip_size: config.max_transform_skip_size,
  }
  let params : @residual.ResidualParams = {
    persistent_rice_adaptation: false,
    chroma_array_type: 1,
    coeff_range: 0,
    sign_data_hiding: config.sign_data_hiding,
    transform_skip_enabled: config.transform_skip_enabled,
    transform_skip_context: config.transform_skip_context,
  }
  let stat = [0, 0, 0, 0]
  let skip = match @residual.decode_residual(dec, coef, block, params, stat) {
    Ok(v) => v
    Err(_) => return Err(BadResidual)
  }
  if bypass {
    // 8.6.2: a bypassed unit takes the coefficients as the residual, with no
    // dequantisation, no transform and no bdShift (shift = 0).
    let rotate = config.transform_skip_rotation && log2_size == 2 && c_idx == 0
    if rotate {
      let nn = coef.length()
      let mut i = 0
      let mut j = nn - 1
      while i < j {
        let t = coef[i]
        coef[i] = coef[j]
        coef[j] = t
        i += 1
        j -= 1
      }
    }
    add_residual(plane, stride, x, y, n, 0, coef, 8)
    return Ok(())
  }
  // 8.6.3 scaling: the selected 7.4.5 matrix, or flat-16 when there is none.
  let m = pick_scaling(config, log2_size, c_idx, skip)
  @recon.dequant(coef, m, n, qp, 8, false)
  let dst = c_idx == 0 && log2_size == 2
  if skip {
    // 8.6.2 transformSkip: no 2D transform, just the coefficient scale.
    let rotate = config.transform_skip_rotation && log2_size == 2 && c_idx == 0
    transform_skip(coef, rotate, log2_size)
  } else {
    @recon.inverse_transform(coef, n, dst, 8, false)
  }
  add_residual(plane, stride, x, y, n, 20 - 8, coef, 8)
  Ok(())
}

///|
/// Reconstruction with transquant bypass off (the single-block golden
/// fixtures and every caller that predates the M3 tool completion).
pub fn reconstruct_block(
  geom : @geometry.Geometry,
  plane : Array[Int32],
  stride : Int32,
  x : Int32,
  y : Int32,
  log2_size : Int32,
  mode : Int32,
  c_idx : Int32,
  qp : Int32,
  dec : @cabac.Decoder,
  cbf : Bool,
  config : ReconConfig,
) -> Result[Unit, ReconstructError] {
  reconstruct_block_full(
    geom, plane, stride, x, y, log2_size, mode, c_idx, qp, dec, cbf, config, false,
  )
}
