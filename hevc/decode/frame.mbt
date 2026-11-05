// The picture buffer and the top-level decode entry point of M3. The
// arithmetic that sizes the planes is real and audited (see FrameBuffer); the
// reconstruction chain that fills them is not part of this increment, and
// decode_i_frame says so with an explicit error rather than returning a
// plausible-looking buffer of zeros or trapping on a malformed stream.

///|
/// Why a frame could not be decoded. Every case is a stream the port refuses
/// on purpose, not a runtime failure: the caller can match on it.
pub(all) enum DecodeError {
  /// A parameter set or slice header the reconstruction cannot use.
  InvalidStream
  /// Not Main 8-bit 4:2:0, the one profile this port accepts.
  UnsupportedProfile
  /// A P or B slice: M3 is I-frame only.
  NotISlice
  /// The plane size does not fit the Int an allocation is indexed with.
  TooLarge
  /// CU/TU/PU reconstruction, inverse transform and loop filters are not
  /// wired up yet; the lower layers (CABAC, scans, bases) are.
  NotImplemented
}

///|
/// A planar 8-bit 4:2:0 picture, the M3 deliverable. Dimensions are Int64
/// because a picture width is a size, and the planes are fixed-size byte
/// arrays sized through FrameBuffer's Int64 arithmetic.
pub(all) struct Yuv420p8 {
  y : FixedArray[Byte]
  u : FixedArray[Byte]
  v : FixedArray[Byte]
  width : Int64
  height : Int64
}

///|
/// Total samples across all three planes, as an Int64. Kept as a size
/// computation so the 32-bit counterexample is visible in the test.
pub fn Yuv420p8::total_samples(self : Yuv420p8) -> Int64 {
  let cw = (self.width + 1L) / 2L
  let ch = (self.height + 1L) / 2L
  @safe.add(self.width * self.height, @safe.mul(cw, ch * 2L))
}

///|
/// A freshly allocated, zeroed picture buffer for a sequence. This is the
/// part of decode_i_frame that is already byte-exact: the plane sizes come
/// from FrameBuffer (Int64), and the narrowing to an allocation index is the
/// one place a too-large picture is refused instead of wrapping or trapping.
pub fn alloc_frame(sps : @hevc.SPS) -> Result[Yuv420p8, DecodeError] {
  let w = sps.pic_width_in_luma_samples.to_int64()
  let h = sps.pic_height_in_luma_samples.to_int64()
  if w <= 0L || h <= 0L {
    return Err(InvalidStream)
  }
  let fb = FrameBuffer::new(w, h, sps.sub_width_c, sps.sub_height_c) catch {
    @safe.Overflow => return Err(TooLarge)
  }
  let luma = @safe.narrow(fb.luma_size) catch {
    @safe.Overflow => return Err(TooLarge)
  }
  let chroma = @safe.narrow(fb.chroma_size) catch {
    @safe.Overflow => return Err(TooLarge)
  }
  Ok({
    y: FixedArray::make(luma, b'\x00'),
    u: FixedArray::make(chroma, b'\x00'),
    v: FixedArray::make(chroma, b'\x00'),
    width: w,
    height: h,
  })
}

///|
/// `decode_i_frame(sps, pps, au)` of the M3 deliverable.
///
/// Validates the profile, rejects any non-I slice, sizes the output planes,
/// and derives the per-picture reconstruction parameters that the CTU loop
/// reads first (see `recon_params`). The reconstruction DSP layers below that
/// loop -- dequantisation, 2D inverse transform, all 35 intra prediction
/// modes, reference-sample smoothing and chroma QP -- are byte-exact checked
/// in `hevc/recon`. The loop-filter kernels of 8.7.2 / 8.7.3 (deblock and SAO)
/// are byte-exact checked in `hevc/loopfilter`, and `loop_filter_params`
/// already derives beta/tc through `@loopfilter.beta_tc` from there.
///
/// What is still unwired is the top of the chain: the CABAC-driven CTU/TU/PU
/// syntax loop that reconstructs the pixels those layers then filter. A valid
/// I frame therefore ends in NotImplemented. Returning an error here is
/// deliberate: a port that fabricates pixels is worse than one that says the
/// work is unfinished, and a malformed stream must never reach an unchecked
/// array index.
pub fn decode_i_frame(
  sps : @hevc.SPS,
  pps : @hevc.PPS,
  au : @hevc.AccessUnit,
) -> Result[Yuv420p8, DecodeError] {
  if sps.bit_depth_luma != 8 ||
    sps.bit_depth_chroma != 8 ||
    sps.chroma_format_idc != 1 ||
    sps.separate_colour_plane {
    return Err(UnsupportedProfile)
  }
  if pps.sps_id != sps.id {
    return Err(InvalidStream)
  }
  if au.slices.length() == 0 {
    return Err(InvalidStream)
  }
  for s in au.slices {
    if s.header.slice_type.code() != 2 {
      return Err(NotISlice)
    }
  }
  let _frame = match alloc_frame(sps) {
    Ok(f) => f
    Err(e) => return Err(e)
  }
  // Derive the reconstruction and loop-filter parameters the CTU loop will
  // read; these are the places the validated recon / loopfilter layers are
  // already consulted by the decode path. The syntax loop that reconstructs
  // pixels and drives deblock_frame / sao_frame is not wired yet.
  let _params = recon_params(sps, pps, au.slices[0].header)
  // The loop-filter switches are pure functions of the slice header, and
  // beta_tc is the first derivation 8.7.2 makes. Deriving them here wires the
  // verified loopfilter kernel into the decode path; the CTU loop that drives
  // deblock_frame / sao_frame over the reconstructed pixels is still unwired.
  let _lf = loop_filter_params(au.slices[0].header)
  Err(NotImplemented)
}
