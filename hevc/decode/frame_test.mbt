///|
test "4:2:0 frame size is 1.5x the luma plane" {
  let frame = @decode.FrameBuffer::new(1920L, 1080L, 2, 2)
  assert_eq(frame.luma_size, 1920L * 1080L)
  assert_eq(frame.chroma_size, 960L * 540L)
  assert_eq(frame.total_size(), 3110400L)
}

///|
test "odd dimensions round the chroma planes up" {
  let frame = @decode.FrameBuffer::new(5L, 5L, 2, 2)
  assert_eq(frame.chroma_size, 9L)
}

///|
test "4:4:4 chroma planes match luma" {
  let frame = @decode.FrameBuffer::new(64L, 64L, 1, 1)
  assert_eq(frame.chroma_size, 4096L)
  assert_eq(frame.total_size(), 4096L * 3L)
}

///|
test "a frame wider than Int is still a number" {
  // 65536 * 65536 = 4 GiB of luma: past MoonBit's 32-bit Int, unremarkable
  // in the Int64 the buffer is sized with.
  let frame = @decode.FrameBuffer::new(65536L, 65536L, 2, 2)
  assert_eq(frame.luma_size, 4294967296L)
  assert_eq(frame.chroma_size, 1073741824L)
  assert_eq(frame.total_size(), 6442450944L)
}

///|
test "a degenerate subsampling factor is refused" {
  assert_true(
    try {
      ignore(@decode.FrameBuffer::new(16L, 16L, 0, 2))
      false
    } catch {
      @safe.Overflow => true
    },
  )
}
