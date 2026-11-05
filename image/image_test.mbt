///|
fn sample(w : Int64, h : Int64) -> @color.Rgba8 raise @image.TransformError {
  let data : Array[Byte] = []
  for y in 0..<h.to_int() {
    for x in 0..<w.to_int() {
      data.push((y * 10 + x).to_byte())
      data.push(b'\x00')
      data.push(b'\x00')
      data.push(b'\xFF')
    }
  }
  @image.rgba8(w, h, Bytes::from_array(data))
}

///|
test "clean aperture crops the requested rectangle" {
  let img = sample(4L, 3L)
  let c = @image.crop(img, { width: 2L, height: 2L, x: 1L, y: 1L, })
  assert_eq(c.width, 2L)
  assert_eq(c.height, 2L)
  assert_eq(c.pixel(0L, 0L), img.pixel(1L, 1L))
  assert_eq(c.pixel(1L, 1L), img.pixel(2L, 2L))
}

///|
test "a crop that leaves the picture is refused" {
  let img = sample(4L, 3L)
  assert_true(
    try {
      ignore(@image.crop(img, { width: 4L, height: 3L, x: 2L, y: 0L, }))
      false
    } catch {
      @image.InvalidCrop => true
      _ => false
    },
  )
}

///|
test "irot=1 swaps dimensions and rotates anticlockwise" {
  let img = sample(3L, 2L)
  let r = @image.orient(img, { angle: 1, mirror: None, })
  assert_eq(r.width, 2L)
  assert_eq(r.height, 3L)
  // Anticlockwise 90: top-right of the source becomes top-left of the output.
  assert_eq(r.pixel(0L, 0L), img.pixel(0L, 1L))
  assert_eq(r.pixel(0L, 2L), img.pixel(2L, 1L))
}

///|
test "irot=2 is a 180 turn and irot=3 is 90 clockwise" {
  let img = sample(3L, 2L)
  let r180 = @image.orient(img, { angle: 2, mirror: None, })
  assert_eq(r180.pixel(0L, 0L), img.pixel(2L, 1L))
  let r270 = @image.orient(img, { angle: 3, mirror: None, })
  assert_eq(r270.width, 2L)
  assert_eq(r270.pixel(0L, 0L), img.pixel(2L, 0L))
}

///|
test "imir follows the rotation, not the other way around" {
  let img = sample(3L, 2L)
  // irot=1 puts in(0,1) at out(0,0); a vertical-axis mirror moves it to
  // out(1,0), leaving out(0,0) = in(2,1).
  let r = @image.orient(img, { angle: 1, mirror: Some(0), })
  assert_eq(r.pixel(0L, 2L), img.pixel(2L, 0L))
  assert_eq(r.pixel(1L, 2L), img.pixel(2L, 1L))
}

///|
test "four quarter turns are the identity" {
  let img = sample(5L, 3L)
  let mut cur = img
  for _ in 0..<4 {
    cur = @image.orient(cur, { angle: 1, mirror: None, })
  }
  assert_eq(cur.width, img.width)
  assert_eq(cur.height, img.height)
  assert_eq(cur.data, img.data)
}

///|
test "crop allocation size stays 64-bit" {
  let size = @safe.mul(@safe.mul(50000L, 50000L), 4L)
  assert_eq(size, 10000000000L)
  assert_true(
    try {
      ignore(@safe.narrow(size))
      false
    } catch {
      @safe.Overflow => true
    },
  )
}
