// Picture buffer sizing for M3. FrameBuffer carries every plane size as an
// Int64: the upstream Go sized these with a 64-bit int, and a 32-bit wrap
// would hand the reconstruction a stride that points outside the allocation.

///|
/// A planar 8-bit picture buffer.
///
/// The allocation arithmetic is real: `width * height` plus the two chroma
/// planes at `sub_width_c` / `sub_height_c` subsampling — exactly the
/// expression upstream wrote assuming a 64-bit `int`. `alloc_frame` in
/// frame.mbt narrows these sizes once, at the allocation boundary.
pub(all) struct FrameBuffer {
  width : Int64
  height : Int64
  sub_width_c : Int32
  sub_height_c : Int32
  luma_size : Int64
  chroma_size : Int64
}

///|
pub fn FrameBuffer::new(
  width : Int64,
  height : Int64,
  sub_width_c : Int32,
  sub_height_c : Int32,
) -> FrameBuffer raise @safe.Overflow {
  guard sub_width_c > 0 && sub_height_c > 0 else { raise @safe.Overflow }
  let luma = @safe.mul(width, height)
  let chroma = @safe.mul(
    @safe.div_ceil(width, sub_width_c.to_int64()),
    @safe.div_ceil(height, sub_height_c.to_int64()),
  )
  {
    width,
    height,
    sub_width_c,
    sub_height_c,
    luma_size: luma,
    chroma_size: chroma,
  }
}

///|
pub fn FrameBuffer::total_size(self : FrameBuffer) -> Int64 {
  @safe.add(self.luma_size, @safe.mul(self.chroma_size, 2L))
}
