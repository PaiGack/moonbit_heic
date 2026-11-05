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
  /// The stream uses a coding tool or framing this I-frame increment does
  /// not support yet (multi-slice, dependent slice, entry points, SAO, PCM,
  /// scaling lists, transform skip, transquant bypass, tiles, WPP). The
  /// CTU loop itself is wired for the accepted subset.
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
/// then drives the CTU quadtree / TU / PU syntax loop over the single slice
/// (`hevc/ctu`). That loop reads the CABAC bins in the order 7.3.8 prescribes
/// and calls `reconstruct_block` once per transform unit; the DSP layers below
/// it (dequantisation, 2D inverse transform, all 35 intra prediction modes,
/// reference-sample smoothing, chroma QP, residual coefficient syntax, CABAC)
/// are byte-exact checked in `hevc/recon`, `hevc/residual`, `hevc/cabac`,
/// `hevc/geometry` and `hevc/reconstruct`. The working planes are Int32
/// samples and are copied into the returned `Yuv420p8` bytes at the end.
///
/// Scope is deliberately narrow: a single slice, single tile, no WPP, no SAO,
/// no PCM, no scaling lists, no transform skip and no transquant bypass.
/// `ctu_frame_input` derives those switches and refuses a stream that enables
/// one; multi-slice streams are refused too, since each slice is its own
/// CABAC substream. Frame-level deblocking (8.7.2) is wired: the CTU walk
/// records the real TU/PU boundary state and `deblock_frame` filters the
/// reconstructed picture before it is copied into the returned bytes. SAO is
/// still refused. A malformed bin or a bad geometry returns `DecodeError`
/// rather than reaching an unchecked array index, so a corrupt stream never
/// traps.
///
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
  let frame = match alloc_frame(sps) {
    Ok(f) => f
    Err(e) => return Err(e)
  }
  // Single slice, single tile: M3's CTU loop decodes the first I slice's
  // RBSP into the picture. A second slice is a separate CABAC substream this
  // increment does not stitch, so refuse it rather than decode a half frame.
  if au.slices.length() != 1 {
    return Err(NotImplemented)
  }
  let slice = au.slices[0].header
  if slice.dependent_slice_segment || slice.entry_point_offsets.length() > 0 {
    return Err(NotImplemented)
  }
  let input = match ctu_frame_input(sps, pps, slice, au.slices[0].nal.rbsp) {
    Ok(v) => v
    Err(_) => return Err(NotImplemented)
  }
  let dec = @cabac.Decoder::new(input.slice_data, 0) catch {
    _ => return Err(InvalidStream)
  }
  // 9.3.2.2: contexts are seeded from SliceQpY and the I slice row.
  dec.init_contexts(input.qp_y, 2, slice.cabac_init)
  // Working planes are Int32 samples (0..255); the Yuv420p8 bytes are filled
  // from them once the CTU loop has produced the picture.
  let luma : Array[Int32] = Array::make(frame.y.length(), 0)
  let chroma : Array[Int32] = Array::make(frame.u.length(), 0)
  let chroma2 : Array[Int32] = Array::make(frame.v.length(), 0)
  let planes : @ctu.CtuPlanes = {
    y: luma,
    cb: chroma,
    cr: chroma2,
    stride_y: @safe.narrow(frame.width) catch {
      _ => return Err(TooLarge)
    },
    stride_c: @safe.narrow((frame.width + 1L) / 2L) catch {
      _ => return Err(TooLarge)
    },
  }
  let deblock = match
    @ctu.decode_ctu_frame(dec, input.geom, input.params, planes, input.config) {
    Ok(state) => state
    Err(_) => return Err(InvalidStream)
  }
  // 8.7.2 frame-level deblocking: the CTU walk recorded the real 4x4-raster
  // TU/PU boundaries, per-block QP and noFilter, so filter exactly the edges
  // the upstream deblock() filters. The pure kernels behind deblock_frame are
  // byte-exact checked in hevc/loopfilter; this is the first time the decode
  // path drives them over a whole reconstructed picture. A stream with
  // deblocking disabled skips the pass (it is a no-op for those streams,
  // asserted byte for byte against the upstream reference YUV).
  let lf = loop_filter_params(slice)
  let fst = match
    @loopfilter.filter_state_from_blocks(
      input.params.width,
      input.params.height,
      sps.ctb_log2_size_y,
      deblock.intra,
      deblock.cbf,
      deblock.tu_v,
      deblock.tu_h,
      deblock.pu_v,
      deblock.pu_h,
      deblock.qp_y,
      deblock.no_filter,
    ) {
    Ok(v) => v
    Err(_) => return Err(InvalidStream)
  }
  match
    @loopfilter.deblock_frame(
      { y: luma, cb: chroma, cr: chroma2, },
      fst,
      slice.qp_y,
      lf.beta_off_div2,
      lf.tc_off_div2,
      lf.deblocking_disabled,
    ) {
    Ok(_) => ()
    Err(_) => return Err(InvalidStream)
  }
  for i in 0..<frame.y.length() {
    frame.y[i] = luma[i].to_byte()
  }
  for i in 0..<frame.u.length() {
    frame.u[i] = chroma[i].to_byte()
  }
  for i in 0..<frame.v.length() {
    frame.v[i] = chroma2[i].to_byte()
  }
  Ok(frame)
}
