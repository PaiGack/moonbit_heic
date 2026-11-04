///|
/// Bit reader over an RBSP payload. Reads past the end set `err` and return
/// zeros, so a caller validates once at the end of a syntax structure instead
/// of at every field.
priv struct GetBits {
  mut state : UInt64
  mut bits_left : Int32
  mut err : Bool
  mut index : Int32
  /// The payload, with the emulation prevention bytes already removed.
  data : Bytes
}

///|
fn GetBits::new(data : Bytes) -> GetBits {
  { state: 0UL, bits_left: 0, err: false, index: 0, data, }
}

///|
fn GetBits::refill(self : GetBits, n : Int32) -> Unit {
  let mut state : UInt32 = 0
  while true {
    if self.index >= self.data.length() {
      self.err = true
      if state != 0 {
        break
      }
      return
    }
    state = (state << 8) | self.data[self.index].to_uint()
    self.index = self.index + 1
    self.bits_left = self.bits_left + 8
    if n <= self.bits_left {
      break
    }
  }
  self.state = self.state | (state.to_uint64() << (64 - self.bits_left))
}

///|
fn GetBits::bit(self : GetBits) -> UInt32 {
  if self.bits_left == 0 {
    self.refill(1)
  }
  let state = self.state
  self.bits_left = self.bits_left - 1
  self.state = state << 1
  (state >> 63).to_uint()
}

///|
/// Reads `n` bits, `n` in 0..=32.
fn GetBits::bits(self : GetBits, n : Int32) -> UInt32 {
  if n == 0 {
    return 0
  }
  if n > self.bits_left {
    self.refill(n)
  }
  let state = self.state
  self.bits_left = self.bits_left - n
  self.state = state << n
  (state >> (64 - n)).to_uint()
}

///|
fn GetBits::skip(self : GetBits, n : Int32) -> Unit {
  let mut n = n
  while n > 32 {
    ignore(self.bits(32))
    n = n - 32
  }
  ignore(self.bits(n))
}

///|
/// `ue(v)` of 9.2: the unsigned Exp-Golomb code.
fn GetBits::ue(self : GetBits) -> UInt32 {
  let mut n = 0
  while self.bit() == 0 {
    n = n + 1
    if n > 31 {
      self.err = true
      return 0
    }
  }
  if n == 0 {
    return 0
  }
  ((1 << n) - 1).reinterpret_as_uint() + self.bits(n)
}

///|
/// `se(v)` of 9.2: the signed Exp-Golomb code.
fn GetBits::se(self : GetBits) -> Int32 {
  let v = self.ue()
  let k = ((v + 1) / 2).reinterpret_as_int()
  if (v & 1).reinterpret_as_int() == 0 {
    -k
  } else {
    k
  }
}

///|
fn GetBits::pos(self : GetBits) -> Int32 {
  self.index * 8 - self.bits_left
}

///|
/// Skips to the next byte boundary, as `byte_alignment()` of 7.3 does.
fn GetBits::byte_align(self : GetBits) -> Unit {
  let n = self.pos() & 7
  if n != 0 {
    self.skip(8 - n)
  }
}

///|
/// Whether more RBSP data follows, ignoring the `rbsp_stop_one_bit` and the
/// zero bits that pad the last byte (7.3.2).
fn GetBits::more_rbsp_data(self : GetBits) -> Bool {
  let p = self.pos()
  let byte_off = p >> 3
  let bit_off = p & 7
  if byte_off >= self.data.length() {
    return false
  }
  let mut last = self.data.length()
  while last > byte_off && self.data[last - 1] == b'\x00' {
    last = last - 1
  }
  if last <= byte_off {
    return false
  }
  if byte_off < last - 1 {
    return true
  }
  bit_off < 7 - self.data[byte_off].to_uint().ctz()
}

///|
/// `MoreRBSPData()` of 9.2, as a test entry point: whether anything but the
/// `rbsp_stop_one_bit` and its zero padding is left. A caller assembling a
/// syntax structure by hand needs it to prove the structure ends where it
/// claims to.
pub fn more_rbsp_data(data : Bytes, bit_pos : Int32) -> Bool {
  let c = GetBits::new(data)
  if bit_pos > 0 {
    c.skip(bit_pos)
  }
  c.more_rbsp_data()
}

///|
/// The bit position a reader over `data` reaches after `bits` bits have been
/// consumed, for the tests that compare a cursor against a hand-written
/// expectation.
pub fn pos_after(data : Bytes, bits : Int32) -> Int32 {
  let c = GetBits::new(data)
  if bits > 0 {
    c.skip(bits)
  }
  c.pos()
}

///|
/// `bits(n)` from a bit position, for the tests.
pub fn bits_at(data : Bytes, bit_pos : Int32, n : Int32) -> UInt32 {
  let c = GetBits::new(data)
  if bit_pos > 0 {
    c.skip(bit_pos)
  }
  c.bits(n)
}

///|
/// The first `count` `ue(v)` values of a buffer, for the tests.
pub fn ue_seq(data : Bytes, count : Int32) -> Array[UInt32] {
  let c = GetBits::new(data)
  let out : Array[UInt32] = []
  for _ in 0..<count {
    out.push(c.ue())
  }
  out
}

///|
/// The first `count` `se(v)` values of a buffer, for the tests.
pub fn se_seq(data : Bytes, count : Int32) -> Array[Int32] {
  let c = GetBits::new(data)
  let out : Array[Int32] = []
  for _ in 0..<count {
    out.push(c.se())
  }
  out
}

///|
/// Whether reading `n` bits past the end of a buffer is reported, rather than
/// answering with the zeros a stalled refill leaves behind.
pub fn read_past_end(data : Bytes) -> Bool {
  let c = GetBits::new(data)
  c.skip(data.length() * 8)
  ignore(c.bits(8))
  c.err
}

///|
/// Whether a buffer whose Exp-Golomb prefix runs on without a terminator is
/// reported as an error. This is the difference between an error and a hang:
/// 9.2 stops the count at 32 leading zeros, and a port that keeps counting
/// reads the whole stream looking for a one that is not there.
pub fn ue_overflows(data : Bytes) -> Bool {
  let c = GetBits::new(data)
  ignore(c.ue())
  c.err
}
