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
  // prediction. chroma_array_type is 1 (4:2:0); strong intra smoothing is off
  // and intra smoothing is not disabled for Main 8-bit, matching the upstream.
  let gathered = @geometry.gather_ref(geom, plane, stride, x, y, n, c_idx, 2, 2)
  let r = @recon.RefSamples::new(n, gathered.s)
  r.filter_ref(mode, c_idx, 8, 1, false, false)
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
    transquant_bypass: false,
    max_transform_skip_size: 0,
  }
  let params = @residual.ResidualParams::main_420_8bit()
  let stat = [0, 0, 0, 0]
  match @residual.decode_residual(dec, coef, block, params, stat) {
    Ok(_) => ()
    Err(_) => return Err(BadResidual)
  }
  // Flat-16 default scaling list; 4x4 intra luma uses the DST (8.6.4.1).
  @recon.dequant(coef, None, n, qp, 8, false)
  let dst = c_idx == 0 && log2_size == 2
  @recon.inverse_transform(coef, n, dst, 8, false)
  add_residual(plane, stride, x, y, n, 20 - 8, coef, 8)
  Ok(())
}
