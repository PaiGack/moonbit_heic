///|
test "4:2:0 frame size is 1.5x the luma plane" {
  let frame = @decode.FrameBuffer::new(1920, 1080, 2, 2)
  assert_eq(frame.luma_size, 1920 * 1080)
  assert_eq(frame.chroma_size, 960 * 540)
  assert_eq(frame.total_size(), 3110400)
}

///|
test "odd dimensions round the chroma planes up" {
  let frame = @decode.FrameBuffer::new(5, 5, 2, 2)
  assert_eq(frame.chroma_size, 3 * 3)
}

///|
test "4:4:4 chroma planes match luma" {
  let frame = @decode.FrameBuffer::new(64, 64, 1, 1)
  assert_eq(frame.chroma_size, 4096)
  assert_eq(frame.total_size(), 4096 * 3)
}

///|
test "a frame too large for Int is refused" {
  // 65536 * 65536 = 4 GiB of luma, which Go's int holds and MoonBit's does not.
  assert_true(
    try {
      ignore(@decode.FrameBuffer::new(65536, 65536, 2, 2))
      false
    } catch {
      @safe.Overflow => true
    },
  )
  assert_true(
    try {
      ignore(@decode.FrameBuffer::new(16, 16, 0, 2))
      false
    } catch {
      @safe.Overflow => true
    },
  )
}
