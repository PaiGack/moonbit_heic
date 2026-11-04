///|
/// CTU / TU / PU reconstruction lands in M3.
///
/// This is where the picture buffer lives and where the hardest `@safe` audit
/// will be: every stride, offset and plane size in the reconstruction path is
/// a multiplication that upstream wrote assuming 64-bit `int`.
pub suberror NotYetImplemented

///|
/// A planar 8-bit picture buffer.
///
/// Only the allocation arithmetic is real in M0 — `width * height` plus the
/// two chroma planes at `sub_width_c` / `sub_height_c` subsampling — because
/// that is exactly the expression that has to stay inside 32 bits.
pub(all) struct FrameBuffer {
  width : Int32
  height : Int32
  sub_width_c : Int32
  sub_height_c : Int32
  luma_size : Int32
  chroma_size : Int32
}

///|
pub fn FrameBuffer::new(
  width : Int32,
  height : Int32,
  sub_width_c : Int32,
  sub_height_c : Int32,
) -> FrameBuffer raise @safe.Overflow {
  guard sub_width_c > 0 && sub_height_c > 0 else { raise @safe.Overflow }
  let luma = @safe.mul(width, height)
  let chroma = @safe.mul(
    @safe.div_ceil(width, sub_width_c),
    @safe.div_ceil(height, sub_height_c),
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
pub fn FrameBuffer::total_size(
  self : FrameBuffer,
) -> Int32 raise @safe.Overflow {
  @safe.add(self.luma_size, @safe.mul(self.chroma_size, 2))
}
