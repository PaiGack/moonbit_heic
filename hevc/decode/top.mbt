///|
/// CTU / TU / PU reconstruction lands in M3.
///
/// This is where the picture buffer lives and where the hardest size audit
/// will be: every stride, offset and plane size in the reconstruction path is
/// a multiplication, so all of them are carried as `Int64`.
pub suberror NotYetImplemented

///|
/// A planar 8-bit picture buffer.
///
/// Only the allocation arithmetic is real in M0 — `width * height` plus the
/// two chroma planes at `sub_width_c` / `sub_height_c` subsampling — because
/// that is exactly the expression upstream wrote assuming a 64-bit `int`.
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
