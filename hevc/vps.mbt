///|
/// A parsed video parameter set, 7.3.2.1.
pub(all) struct VPS {
  mut id : Int32
  mut max_layers_minus1 : Int32
  mut max_sub_layers_minus1 : Int32
  mut temporal_id_nesting : Bool
  mut ptl : ProfileTierLevel
  mut max_dec_pic_buffering : Array[Int32]
  mut max_num_reorder_pics : Array[Int32]
  mut max_latency_increase : Array[Int32]
}

///|
/// Parses a video parameter set from a NAL unit, header included, as
/// `split_annex_b` and `split_hvcc` return them. A payload handed straight
/// over, header already removed, is taken as is.
pub fn parse_vps(nal : Bytes) -> VPS raise Error {
  let c = GetBits::new(nal_payload(nal))
  let v : VPS = {
    id: c.bits(4).reinterpret_as_int(),
    max_layers_minus1: 0,
    max_sub_layers_minus1: 0,
    temporal_id_nesting: false,
    ptl: {
      profile_space: 0,
      tier_flag: false,
      profile_idc: 0,
      level_idc: 0,
      compat_flags: 0,
    },
    max_dec_pic_buffering: [],
    max_num_reorder_pics: [],
    max_latency_increase: [],
  }

  ignore(c.bits(2))
  v.max_layers_minus1 = c.bits(6).reinterpret_as_int()
  v.max_sub_layers_minus1 = c.bits(3).reinterpret_as_int()
  if v.max_sub_layers_minus1 > max_sub_layers - 1 {
    raise Invalid
  }

  v.temporal_id_nesting = c.bit() != 0

  // reserved_zero_2bits
  if c.bits(16) != 0xffff {
    raise Invalid
  }

  v.ptl = parse_profile_tier_level(c, true, v.max_sub_layers_minus1)

  let mut start = v.max_sub_layers_minus1
  if c.bit() != 0 {
    start = 0
  }
  for _ in 0..<max_sub_layers {
    v.max_dec_pic_buffering.push(0)
    v.max_num_reorder_pics.push(0)
    v.max_latency_increase.push(0)
  }
  for i in start..<(v.max_sub_layers_minus1 + 1) {
    v.max_dec_pic_buffering[i] = c.ue().reinterpret_as_int()
    v.max_num_reorder_pics[i] = c.ue().reinterpret_as_int()
    v.max_latency_increase[i] = c.ue().reinterpret_as_int()
  }

  let max_layer_id = c.bits(6).reinterpret_as_int()

  let num_layer_sets_minus1 = c.ue().reinterpret_as_int()
  if num_layer_sets_minus1 > 1023 {
    raise Invalid
  }
  for _ in 0..<num_layer_sets_minus1 {
    c.skip(max_layer_id + 1)
  }

  if c.bit() != 0 {
    ignore(c.bits(32))
    ignore(c.bits(32))
    if c.bit() != 0 {
      ignore(c.ue())
    }

    let num_hrd = c.ue().reinterpret_as_int()
    if num_hrd > 1024 {
      raise Invalid
    }
    for i in 0..<num_hrd {
      ignore(c.ue())
      let common_inf_present = if i > 0 { c.bit() != 0 } else { true }
      parse_hrd(c, common_inf_present, v.max_sub_layers_minus1)
    }
  }

  let extension = c.bit() != 0
  check_trailing(c, extension)

  v
}
