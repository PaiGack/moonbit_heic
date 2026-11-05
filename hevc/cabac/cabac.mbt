// CABAC arithmetic decoder, 9.3 of H.265, ported from gen2brain/h265
// hevc/cabac.go. Every quantity that the upstream Go keeps in a uint32 stays
// a UInt32 here: the renormalisation loop relies on the wrap, and widening it
// would silently change the decoded bins.

///|
/// Number of context models, one per syntax element context of 9.3.2.2.
pub let n_contexts : Int32 = 179

///|
/// `cabacBits` of 9.3.4: the decoder carries sixteen fractional bits.
let cabac_bits : Int32 = 16

///|
let cabac_mask : UInt32 = 0xFFFFU

///|
/// The stream ended in the middle of the two-byte CABAC initial word.
pub suberror InvalidInit

///|
/// A context index outside the 179 the decoder allocates.
pub suberror BadContext

///|
/// A bypass bit count the caller cannot represent.
pub suberror BadBypassCount

///|
/// `rangeTabLPS` of Table 9-46 rearranged the way `decodeBin` indexes it:
/// `[range group][state]`, with the state duplicated into its even and odd
/// forms so the MPS bit does not need masking on the hot path.
let lps_range : Bytes = build_lps_range()

///|
/// `transState` of 9.3.4.4: the 256-entry state transition table, built from
/// `transIdxLPS` and the MPS rule at initialisation, exactly as upstream does.
let trans_state : Bytes = build_trans_state()

///|
fn build_lps_range() -> Bytes {
  let out : Array[Byte] = Array::make(4 * 128, b'\x00')
  for g in 0..<4 {
    for st in 0..<64 {
      let v = range_tab_lps[st * 4 + g]
      out[g * 128 + 2 * st] = v
      out[g * 128 + 2 * st + 1] = v
    }
  }
  Bytes::from_array(out)
}

///|
fn build_trans_state() -> Bytes {
  let out : Array[Byte] = Array::make(256, b'\x00')
  for st in 0..<64 {
    let mut mps = st + 1
    if st >= 62 {
      mps = st
    }
    let lps = trans_idx_lps[st].to_int()
    for v in 0..<2 {
      let s = 2 * st + v
      out[128 + s] = (2 * mps + v).to_byte()
      let flipped = if st == 0 { 1 - v } else { v }
      out[127 - s] = (2 * lps + flipped).to_byte()
    }
  }
  Bytes::from_array(out)
}

///|
/// `normShift(r)` of 9.3.4.2: `9 - Len32(r)`, written as `clz(r) - 23` so it
/// needs no 64-bit carrier. `r` is in 1..511, where the shift stays in 0..8.
fn norm_shift(r : UInt32) -> Int32 {
  r.clz() - 23
}

///|
/// Which of the three Table 9-4 rows a slice initialises its contexts from.
/// `init_type` is `2 - slice_type_code(I=2, P=1, B=0)`, flipped for P/B when
/// `cabac_init` is set.
fn init_type(slice_type_code : Int32, cabac_init : Bool) -> Int32 {
  let mut n = 2 - slice_type_code
  if cabac_init && slice_type_code != 2 {
    n = n ^ 3
  }
  n
}

///|
/// `initState(v, qp)` of 9.3.2.2. The `s ^= s >> 31` is the absolute value of
/// a negative `s`, kept as the upstream wrote it: clipping qp to 0..51 and the
/// arithmetic right shift are both load-bearing for states near the ends.
fn init_state(v : Int32, qp : Int32) -> Int32 {
  let m = (v >> 4) * 5 - 45
  let n = (v & 0x0F) * 8 - 16
  let q = if qp < 0 { 0 } else if qp > 51 { 51 } else { qp }
  let mut s = 2 * (((m * q) >> 4) + n) - 127
  s = s ^ (s >> 31)
  if s > 124 {
    s = 124 + (s & 1)
  }
  s
}

///|
/// The arithmetic decoder state of 9.3.4. `low` and `rng` are UInt32 by
/// design: `refill` and `decodeBypass` add and shift them modulo 2^32, and a
/// widened carrier would decode a different bitstream.
pub(all) struct Decoder {
  mut low : UInt32
  mut rng : UInt32
  data : Bytes
  mut pos : Int32
  mut state : Array[Int32]
}

///|
/// `cabac.init` of 9.3.4. Reads the two-byte initial word plus the stop bit
/// and leaves the cursor at the first byte of the coded data. A short buffer
/// or a negative offset is an error rather than a read past the end.
pub fn Decoder::new(data : Bytes, off : Int32) -> Decoder raise InvalidInit {
  guard off >= 0 && off + 2 <= data.length() else { raise InvalidInit }
  {
    low: (data[off].to_uint() << 18) +
    (data[off + 1].to_uint() << 10) +
    (1U << 9),
    rng: 0x1FEU,
    data,
    pos: off + 2,
    state: Array::make(n_contexts, 0),
  }
}

///|
/// 9.3.1 / 7.3.8.7: restart the arithmetic decoder at a byte boundary (the
/// word after a PCM block) while KEEPING the context states. Upstream
/// cabac.init only resets low/rng/pos; the contexts carry across PCM.
pub fn Decoder::restart_at(
  self : Decoder,
  off : Int32,
) -> Unit raise InvalidInit {
  guard off >= 0 && off + 2 <= self.data.length() else { raise InvalidInit }
  self.low = (self.data[off].to_uint() << 18) +
    (self.data[off + 1].to_uint() << 10) +
    (1U << 9)
  self.rng = 0x1FEU
  self.pos = off + 2
}

///|
/// `initContexts` of 9.3.2.2: all 179 contexts from one Table 9-4 row.
pub fn Decoder::init_contexts(
  self : Decoder,
  qp : Int32,
  slice_type_code : Int32,
  cabac_init : Bool,
) -> Unit {
  let row = init_type(slice_type_code, cabac_init)
  for i in 0..<n_contexts {
    self.state[i] = init_state(init_values[row * n_contexts + i].to_int(), qp)
  }
}

///|
/// A byte past the end reads as zero, which is what lets a truncated stream
/// decode its last bins instead of trapping.
fn Decoder::byte_at(self : Decoder, i : Int32) -> UInt32 {
  if i < self.data.length() {
    self.data[i].to_uint()
  } else {
    0U
  }
}

///|
/// `refill` of 9.3.4: brings in the next two bytes.
fn Decoder::refill(self : Decoder) -> Unit {
  self.low = self.low +
    (self.byte_at(self.pos) << 9) +
    (self.byte_at(self.pos + 1) << 1) -
    cabac_mask
  self.pos = self.pos + 2
}

///|
/// `refillShifted`: the leading zeros left in `low` are the bits the two new
/// bytes have to be aligned to. `ctz(low) - 16` is non-negative whenever this
/// is called, because it only is when `low`'s low sixteen bits are zero.
fn Decoder::refill_shifted(self : Decoder) -> Unit {
  let i = self.low.ctz() - cabac_bits
  let x = (self.byte_at(self.pos) << 9) +
    (self.byte_at(self.pos + 1) << 1) -
    cabac_mask
  self.low = self.low + (x << i)
  self.pos = self.pos + 2
}

///|
/// `decodeBin(ctx)` of 9.3.4.2. The `mask` is the sign bit of
/// `rng<<(bits+1) - low` spread to all ones; the three updates below it are
/// the branchless MPS/LPS split upstream uses.
pub fn Decoder::decode_bin(
  self : Decoder,
  ctx : Int32,
) -> Int32 raise BadContext {
  guard ctx >= 0 && ctx < n_contexts else { raise BadContext }
  let s = self.state[ctx]
  let lps = lps_range[((self.rng >> 6) & 3U).reinterpret_as_int() * 128 + s].to_uint()
  self.rng = self.rng - lps
  let scaled_rng = self.rng << (cabac_bits + 1)
  let mask = ((scaled_rng - self.low).reinterpret_as_int() >> 31).reinterpret_as_uint()
  self.low = self.low - (scaled_rng & mask)
  self.rng = self.rng + ((lps - self.rng) & mask)
  let signed = s ^ mask.reinterpret_as_int()
  self.state[ctx] = trans_state[128 + signed].to_int()
  let shift = norm_shift(self.rng)
  self.rng = self.rng << shift
  self.low = self.low << shift
  if (self.low & cabac_mask) == 0U {
    self.refill_shifted()
  }
  signed & 1
}

///|
/// `decodeBypass` of 9.3.4.3, the equiprobable bin.
pub fn Decoder::decode_bypass(self : Decoder) -> Int32 {
  self.low = self.low + self.low
  if (self.low & cabac_mask) == 0U {
    self.refill()
  }
  let r = self.rng << (cabac_bits + 1)
  if self.low < r {
    0
  } else {
    self.low = self.low - r
    1
  }
}

///|
/// `decodeBypassBits(n)`, MSB first, `n` in 0..=32.
pub fn Decoder::decode_bypass_bits(
  self : Decoder,
  n : Int32,
) -> UInt32 raise BadBypassCount {
  guard n >= 0 && n <= 32 else { raise BadBypassCount }
  let mut v : UInt32 = 0U
  for _ in 0..<n {
    v = (v << 1) | self.decode_bypass().reinterpret_as_uint()
  }
  v
}

///|
/// `decodeTerminate` of 9.3.4.5, the terminating bin against the fixed range
/// of two.
pub fn Decoder::decode_terminate(self : Decoder) -> Int32 {
  self.rng = self.rng - 2U
  if self.low >= self.rng << (cabac_bits + 1) {
    return 1
  }
  if self.rng < 256U {
    self.rng = self.rng << 1
    self.low = self.low << 1
    if (self.low & cabac_mask) == 0U {
      self.refill()
    }
  }
  0
}

///|
/// `pcmOffset` of 9.3.4: the byte the PCM alignment lands on. Kept because a
/// caller aligning to a PCM block has to undo the fractional bits `low` holds.
pub fn Decoder::pcm_offset(self : Decoder) -> Int32 {
  let mut n = self.pos
  if (self.low & 1U) != 0U {
    n = n - 1
  }
  if (self.low & 0x1FFU) != 0U {
    n = n - 1
  }
  n
}

///|
/// The raw context states, for the tests that check them stay in range and
/// for a debugger following a syntax element back to its context.
pub fn Decoder::states(self : Decoder) -> Array[Int32] {
  let out : Array[Int32] = []
  for s in self.state {
    out.push(s)
  }
  out
}
