///|
/// MSB-first bit reader over an RBSP.
///
/// Kept deliberately thin for M0: it fixes the cursor arithmetic that the
/// header parsers will share, and the width check goes through `@safe` so a
/// corrupt `num_bits` is reported rather than wrapping the cursor.
pub(all) struct BitReader {
  data : Bytes
  mut bit_pos : Int32
}

///|
pub fn BitReader::new(data : Bytes) -> BitReader {
  { data, bit_pos: 0, }
}

///|
pub fn BitReader::bit_length(self : BitReader) -> Int32 {
  self.data.length() * 8
}

///|
pub fn BitReader::remaining(self : BitReader) -> Int32 {
  self.bit_length() - self.bit_pos
}

///|
pub fn BitReader::peek_bit(self : BitReader) -> Bool raise EndOfStream {
  guard self.bit_pos < self.bit_length() else { raise EndOfStream }
  let byte = self.data[self.bit_pos / 8].to_int()
  ((byte >> (7 - self.bit_pos % 8)) & 1) == 1
}

///|
pub fn BitReader::read_bit(self : BitReader) -> Bool raise EndOfStream {
  let bit = self.peek_bit() catch { EndOfStream => raise EndOfStream }
  self.bit_pos = self.bit_pos + 1
  bit
}

///|
/// Read `n` bits (0 ≤ n ≤ 32) as an unsigned value, MSB first.
pub fn BitReader::read_bits(self : BitReader, n : Int32) -> UInt32 raise Error {
  guard n >= 0 && n <= 32 else { raise Overflow }
  guard self.remaining() >= n else { raise EndOfStream }
  let mut value : UInt32 = 0U
  for _ in 0..<n {
    let bit = self.read_bit() catch { EndOfStream => raise EndOfStream }
    value = (value << 1) | (if bit { 1U } else { 0U })
  }
  value
}
