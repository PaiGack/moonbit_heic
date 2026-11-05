///|
let max_sub_layers : Int32 = 7

///|
let max_short_term_rps : Int32 = 64

///|
let max_long_term_ref_pics : Int32 = 32

///|
let max_ref_pics_per_rps : Int32 = 16

///|
let max_dpb_size : Int32 = 16

///|
let max_tile_columns : Int32 = 22

///|
let max_tile_rows : Int32 = 20

///|
let max_pic_size : Int32 = 16384

///|
let max_chroma_qp_offsets : Int32 = 6

///|
let min_ctb_log2_size_y : Int32 = 4

///|
let max_ctb_log2_size_y : Int32 = 6

///|
let max_scaling_list_sizes : Int32 = 4

///|
let max_scaling_list_mats : Int32 = 6

///|
/// `profile_tier_level` of E.2.3, general part only: the sub-layer profiles a
/// still picture never uses are parsed and dropped.
pub(all) struct ProfileTierLevel {
  mut profile_space : Int32
  mut tier_flag : Bool
  mut profile_idc : Int32
  mut level_idc : Int32
  mut compat_flags : UInt32
}

///|
/// A `st_ref_pic_set` of 7.4.8, in the derived form: the picture order count
/// deltas rather than the coding order they are signalled in.
pub(all) struct ShortTermRPS {
  delta_poc_s0 : Array[Int32]
  delta_poc_s1 : Array[Int32]
  used_s0 : Array[Bool]
  used_s1 : Array[Bool]
}

///|
pub fn ShortTermRPS::num_delta_pocs(self : ShortTermRPS) -> Int32 {
  self.delta_poc_s0.length() + self.delta_poc_s1.length()
}

///|
/// `scaling_list_data` of 7.3.4, as the factors each matrix stands for after
/// the delta coding is undone.
pub(all) struct ScalingList {
  /// `sl[size_id][matrix_id]`, 64 entries of a matrix, row major.
  sl : Array[Array[Array[Int32]]]
  /// `dc[size_id - 2][matrix_id]`. Only the 16x16 and 32x32 sizes have one.
  dc : Array[Array[Int32]]
}

///|
/// The lists a sequence or picture parameter set starts from when it carries
/// none of its own (7.4.5).
pub fn default_scaling_list() -> ScalingList {
  let sl = []
  let dc = []
  for _ in 0..<max_scaling_list_sizes {
    let mats = []
    for _ in 0..<max_scaling_list_mats {
      // [64]uint8 upstream: the 4x4 list only uses the first 16, but every
      // matrix is a full 64-entry array so 8x8 parsing can index it safely.
      mats.push(Array::make(64, 16))
    }
    sl.push(mats)
  }
  for _ in 0..<2 {
    // dc[size_id-2][matrix_id], i.e. 2 rows of 6 entries, flat value 16.
    dc.push(Array::make(max_scaling_list_mats, 16))
  }
  for s in 1..<max_scaling_list_sizes {
    for m in 0..<max_scaling_list_mats {
      sl[s][m] = if m < 3 {
        default_scaling_list_intra
      } else {
        default_scaling_list_inter
      }
    }
  }
  { sl, dc, }
}

///|
let default_scaling_list_intra : Array[Int32] = [
  16, 16, 16, 16, 17, 18, 21, 24, 16, 16, 16, 16, 17, 19, 22, 25, 16, 16, 17, 18,
  20, 22, 25, 29, 16, 16, 18, 21, 24, 27, 31, 36, 17, 17, 20, 24, 30, 35, 41, 47,
  18, 19, 22, 27, 35, 44, 54, 65, 21, 22, 25, 31, 41, 54, 70, 88, 24, 25, 29, 36,
  47, 65, 88, 115,
]

///|
let default_scaling_list_inter : Array[Int32] = [
  16, 16, 16, 16, 17, 18, 20, 24, 16, 16, 16, 17, 18, 20, 24, 25, 16, 16, 17, 18,
  20, 24, 25, 28, 16, 17, 18, 20, 24, 25, 28, 33, 17, 18, 20, 24, 25, 28, 33, 41,
  18, 20, 24, 25, 28, 33, 41, 54, 20, 24, 25, 28, 33, 41, 54, 71, 24, 25, 28, 33,
  41, 54, 71, 91,
]

///|
/// `scaling_list_data` of 7.3.4, overriding the defaults it starts from.
fn parse_scaling_list_data(c : GetBits, sl : ScalingList) -> Unit raise Error {
  for size_id in 0..<max_scaling_list_sizes {
    let step = if size_id == 3 { 3 } else { 1 }
    let mut matrix_id = 0
    while matrix_id < max_scaling_list_mats {
      if c.bit() == 0 {
        let delta = c.ue().reinterpret_as_int() * step
        if delta > matrix_id {
          raise Invalid
        }

        matrix_id = matrix_id + step
        if delta == 0 {
          continue
        }

        let copy_from = matrix_id - step - delta
        sl.sl[size_id][matrix_id - step] = sl.sl[size_id][copy_from]
        if size_id > 1 {
          sl.dc[size_id - 2][matrix_id - step] = sl.dc[size_id - 2][copy_from]
        }
        continue
      }

      let mut next = 8
      if size_id > 1 {
        let dc = c.se()
        if dc < -7 || dc > 247 {
          raise Invalid
        }
        next = dc + 8
        sl.dc[size_id - 2][matrix_id] = next
      }

      let (scan, size) = if size_id == 0 {
        (diag_scan(2), 4)
      } else {
        (diag_scan(3), 8)
      }

      for p in scan {
        let d = c.se()
        if d < -128 || d > 127 {
          raise Invalid
        }
        next = next + d
        next = (next % 256 + 256) % 256
        sl.sl[size_id][matrix_id][p.1 * size + p.0] = next
      }

      matrix_id = matrix_id + step
    }
  }

  if c.err {
    raise Invalid
  }
}

///|
/// ScanOrder[log2][diag] of 6.5, as (x, y) pairs.
fn diag_scan(log2 : Int32) -> Array[(Int32, Int32)] {
  let size = 1 << log2
  let scan = []
  for d in 0..<(2 * size - 1) {
    let mut y = if d < size { d } else { size - 1 }
    while y >= 0 && y > d - size {
      scan.push((d - y, y))
      y = y - 1
    }
  }
  scan
}

///|
/// The twelve bytes from `general_profile_space` through `general_level_idc`,
/// as a container's decoder configuration record repeats them (E.2.3).
pub fn profile_tier_level_bytes(sps_rbsp : Bytes) -> Bytes? {
  if sps_rbsp.length() < 13 {
    return None
  }
  Some(sps_rbsp.exact_view(start=1, end=13).to_owned())
}

///|
/// The chroma format and the two sample sizes a sequence parameter set
/// declares. A container's decoder configuration record repeats them, and a
/// reader that trusts it over the bitstream has to be told the truth.
pub fn sps_format(sps_rbsp : Bytes) -> (Int32, Int32, Int32)? {
  let s = parse_sps(sps_rbsp) catch { _ => return None }
  Some((s.chroma_format_idc, s.bit_depth_luma, s.bit_depth_chroma))
}

///|
/// `profile_tier_level` of E.2.3. The sub-layer profiles and levels are
/// skipped: no still picture this port decodes depends on them, and skipping
/// keeps the field widths in one place.
fn parse_profile_tier_level(
  c : GetBits,
  profile_present : Bool,
  max_sub_layers_minus1 : Int32,
) -> ProfileTierLevel {
  let p : ProfileTierLevel = {
    profile_space: 0,
    tier_flag: false,
    profile_idc: 0,
    level_idc: 0,
    compat_flags: 0,
  }

  if profile_present {
    p.profile_space = c.bits(2).reinterpret_as_int()
    p.tier_flag = c.bit() != 0
    p.profile_idc = c.bits(5).reinterpret_as_int()
    p.compat_flags = c.bits(32)
    c.skip(48)
  }

  p.level_idc = c.bits(8).reinterpret_as_int()

  if max_sub_layers_minus1 == 0 {
    return p
  }

  let profile_present_sub = Array::make(max_sub_layers, false)
  let level_present_sub = Array::make(max_sub_layers, false)
  for i in 0..<max_sub_layers_minus1 {
    profile_present_sub[i] = c.bit() != 0
    level_present_sub[i] = c.bit() != 0
  }
  ignore(c.bits((8 - max_sub_layers_minus1) * 2))

  for i in 0..<max_sub_layers_minus1 {
    if profile_present_sub[i] {
      c.skip(88)
    }
    if level_present_sub[i] {
      ignore(c.bits(8))
    }
  }

  p
}

///|
/// `sub_layer_hrd_parameters` of E.2.3.
fn parse_sub_layer_hrd(
  c : GetBits,
  cpb_cnt : Int32,
  sub_pic_present : Bool,
) -> Unit {
  for _ in 0..<cpb_cnt {
    ignore(c.ue())
    ignore(c.ue())
    if sub_pic_present {
      ignore(c.ue())
      ignore(c.ue())
    }
    ignore(c.bit())
  }
}

///|
/// `hrd_parameters` of E.2.3. Parsed to keep the bit position in step; the
/// timing it describes is not used.
fn parse_hrd(
  c : GetBits,
  common_inf_present : Bool,
  max_sub_layers_minus1 : Int32,
) -> Unit raise Error {
  let mut nal_hrd = false
  let mut vcl_hrd = false
  let mut sub_pic_present = false

  if common_inf_present {
    nal_hrd = c.bit() != 0
    vcl_hrd = c.bit() != 0
    if nal_hrd || vcl_hrd {
      sub_pic_present = c.bit() != 0
      if sub_pic_present {
        ignore(c.bits(8))
        ignore(c.bits(5))
        ignore(c.bits(5))
        ignore(c.bit())
        ignore(c.bits(5))
      }
      ignore(c.bits(4))
      ignore(c.bits(4))
      if sub_pic_present {
        ignore(c.bits(4))
      }
      ignore(c.bits(5))
      ignore(c.bits(5))
      ignore(c.bits(5))
    }
  }

  for _ in 0..<(max_sub_layers_minus1 + 1) {
    let mut fixed_rate = c.bit() != 0
    if !fixed_rate {
      fixed_rate = c.bit() != 0
    }

    let mut low_delay = false
    if fixed_rate {
      ignore(c.ue())
    } else {
      low_delay = c.bit() != 0
    }

    let mut cpb_cnt = 1
    if !low_delay {
      let n = c.ue().reinterpret_as_int()
      if n > 31 {
        raise Invalid
      }
      cpb_cnt = n + 1
    }

    if nal_hrd {
      parse_sub_layer_hrd(c, cpb_cnt, sub_pic_present)
    }
    if vcl_hrd {
      parse_sub_layer_hrd(c, cpb_cnt, sub_pic_present)
    }
  }
}

///|
fn check_trailing(c : GetBits, extension : Bool) -> Unit raise Error {
  if c.err {
    raise Invalid
  }
  if !extension && c.more_rbsp_data() {
    raise Invalid
  }
}
