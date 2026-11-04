///|
/// A parsed sequence parameter set, 7.3.2.2.
///
/// The range extension flags are kept even when unused: they say which of the
/// tools the bitstream is allowed to use, and the ones this port refuses are
/// reported at parse time rather than papered over at decode time.
pub(all) struct SPS {
  mut vps_id : Int32
  mut max_sub_layers_minus1 : Int32
  mut temporal_id_nesting : Bool
  mut ptl : ProfileTierLevel
  mut id : Int32
  mut chroma_format_idc : Int32
  mut separate_colour_plane : Bool
  /// `SubWidthC` and `SubHeightC` of Table 6-1, derived from the chroma format.
  mut sub_width_c : Int32
  mut sub_height_c : Int32
  mut pic_width_in_luma_samples : Int32
  mut pic_height_in_luma_samples : Int32
  mut conf_win_left : Int32
  mut conf_win_right : Int32
  mut conf_win_top : Int32
  mut conf_win_bottom : Int32
  mut bit_depth_luma : Int32
  mut bit_depth_chroma : Int32
  /// The color description of E.3.1, unspecified unless the VUI says otherwise.
  mut colour_primaries : Int32
  mut transfer_characteristics : Int32
  mut matrix_coefficients : Int32
  mut full_range : Bool
  mut log2_max_poc_lsb : Int32
  mut max_dec_pic_buffering : Int32
  mut max_num_reorder_pics : Int32
  mut max_latency_increase : Int32
  mut min_cb_log2_size_y : Int32
  mut ctb_log2_size_y : Int32
  mut ctb_size_y : Int64
  mut min_tb_log2_size_y : Int32
  mut max_tb_log2_size_y : Int32
  mut max_tr_hier_inter : Int32
  mut max_tr_hier_intra : Int32
  mut pic_width_in_ctbs : Int64
  mut pic_height_in_ctbs : Int64
  mut scaling_list_enabled : Bool
  mut scaling_list : ScalingList
  mut amp_enabled : Bool
  mut sao_enabled : Bool
  mut pcm_enabled : Bool
  mut pcm_bit_depth_luma : Int32
  mut pcm_bit_depth_chroma : Int32
  mut log2_min_pcm_cb_size : Int32
  mut log2_max_pcm_cb_size : Int32
  mut pcm_loop_filter_disabled : Bool
  mut st_rps : Array[ShortTermRPS]
  mut long_term_ref_pics_present : Bool
  mut lt_ref_pic_poc_lsb : Array[Int32]
  mut used_by_curr_pic_lt : Array[Bool]
  mut temporal_mvp_enabled : Bool
  mut strong_intra_smoothing : Bool
  mut transform_skip_rotation : Bool
  mut transform_skip_context : Bool
  mut implicit_rdpcm : Bool
  mut explicit_rdpcm : Bool
  mut extended_precision : Bool
  mut intra_smoothing_disabled : Bool
  mut high_precision_offsets : Bool
  mut persistent_rice_adaptation : Bool
  mut cabac_bypass_alignment : Bool
}

///|
pub fn SPS::cropped_width(self : SPS) -> Int32 {
  let crop = self.sub_width_c * (self.conf_win_left + self.conf_win_right)
  if crop >= self.pic_width_in_luma_samples {
    return 0
  }
  self.pic_width_in_luma_samples - crop
}

///|
pub fn SPS::cropped_height(self : SPS) -> Int32 {
  let crop = self.sub_height_c * (self.conf_win_top + self.conf_win_bottom)
  if crop >= self.pic_height_in_luma_samples {
    return 0
  }
  self.pic_height_in_luma_samples - crop
}

///|
/// Parses a sequence parameter set from a NAL unit, header included.
pub fn parse_sps(nal : Bytes) -> SPS raise Error {
  let c = GetBits::new(nal_payload(nal))

  let s : SPS = {
    vps_id: 0,
    max_sub_layers_minus1: 0,
    temporal_id_nesting: false,
    ptl: {
      profile_space: 0,
      tier_flag: false,
      profile_idc: 0,
      level_idc: 0,
      compat_flags: 0,
    },
    id: 0,
    chroma_format_idc: 1,
    separate_colour_plane: false,
    sub_width_c: 1,
    sub_height_c: 1,
    pic_width_in_luma_samples: 0,
    pic_height_in_luma_samples: 0,
    conf_win_left: 0,
    conf_win_right: 0,
    conf_win_top: 0,
    conf_win_bottom: 0,
    bit_depth_luma: 8,
    bit_depth_chroma: 8,
    colour_primaries: 2,
    transfer_characteristics: 2,
    matrix_coefficients: 2,
    full_range: false,
    log2_max_poc_lsb: 4,
    max_dec_pic_buffering: 0,
    max_num_reorder_pics: 0,
    max_latency_increase: 0,
    min_cb_log2_size_y: 0,
    ctb_log2_size_y: 0,
    ctb_size_y: 0L,
    min_tb_log2_size_y: 0,
    max_tb_log2_size_y: 0,
    max_tr_hier_inter: 0,
    max_tr_hier_intra: 0,
    pic_width_in_ctbs: 0L,
    pic_height_in_ctbs: 0L,
    scaling_list_enabled: false,
    scaling_list: default_scaling_list(),
    amp_enabled: false,
    sao_enabled: false,
    pcm_enabled: false,
    pcm_bit_depth_luma: 8,
    pcm_bit_depth_chroma: 8,
    log2_min_pcm_cb_size: 8,
    log2_max_pcm_cb_size: 0,
    pcm_loop_filter_disabled: false,
    st_rps: [],
    long_term_ref_pics_present: false,
    lt_ref_pic_poc_lsb: [],
    used_by_curr_pic_lt: [],
    temporal_mvp_enabled: false,
    strong_intra_smoothing: false,
    transform_skip_rotation: false,
    transform_skip_context: false,
    implicit_rdpcm: false,
    explicit_rdpcm: false,
    extended_precision: false,
    intra_smoothing_disabled: false,
    high_precision_offsets: false,
    persistent_rice_adaptation: false,
    cabac_bypass_alignment: false,
  }

  s.vps_id = c.bits(4).reinterpret_as_int()
  s.max_sub_layers_minus1 = c.bits(3).reinterpret_as_int()
  if s.max_sub_layers_minus1 > max_sub_layers - 1 {
    raise Invalid
  }

  s.temporal_id_nesting = c.bit() != 0
  s.ptl = parse_profile_tier_level(c, true, s.max_sub_layers_minus1)

  s.id = c.ue().reinterpret_as_int()
  if s.id > 15 {
    raise Invalid
  }

  s.chroma_format_idc = c.ue().reinterpret_as_int()
  if s.chroma_format_idc > 3 {
    raise Invalid
  }

  if s.chroma_format_idc == 3 {
    s.separate_colour_plane = c.bit() != 0
  }

  s.sub_width_c = 1
  s.sub_height_c = 1
  match s.chroma_format_idc {
    1 => {
      s.sub_width_c = 2
      s.sub_height_c = 2
    }
    2 => s.sub_width_c = 2
    _ => ()
  }

  s.pic_width_in_luma_samples = c.ue().reinterpret_as_int()
  s.pic_height_in_luma_samples = c.ue().reinterpret_as_int()
  if s.pic_width_in_luma_samples == 0 ||
    s.pic_height_in_luma_samples == 0 ||
    s.pic_width_in_luma_samples > max_pic_size ||
    s.pic_height_in_luma_samples > max_pic_size {
    raise Invalid
  }

  if c.bit() != 0 {
    s.conf_win_left = c.ue().reinterpret_as_int()
    s.conf_win_right = c.ue().reinterpret_as_int()
    s.conf_win_top = c.ue().reinterpret_as_int()
    s.conf_win_bottom = c.ue().reinterpret_as_int()
  }
  if s.cropped_width() == 0 || s.cropped_height() == 0 {
    raise Invalid
  }

  s.bit_depth_luma = 8 + c.ue().reinterpret_as_int()
  s.bit_depth_chroma = 8 + c.ue().reinterpret_as_int()
  if s.bit_depth_luma > 16 || s.bit_depth_chroma > 16 {
    raise Invalid
  }

  let log2_max_poc_lsb_minus4 = c.ue().reinterpret_as_int()
  if log2_max_poc_lsb_minus4 > 12 {
    raise Invalid
  }
  s.log2_max_poc_lsb = 4 + log2_max_poc_lsb_minus4

  let mut start = s.max_sub_layers_minus1
  if c.bit() != 0 {
    start = 0
  }
  for _ in start..<(s.max_sub_layers_minus1 + 1) {
    s.max_dec_pic_buffering = c.ue().reinterpret_as_int()
    s.max_num_reorder_pics = c.ue().reinterpret_as_int()
    s.max_latency_increase = c.ue().reinterpret_as_int()
    // 7.4.3.2.1 bounds reordering by the declared buffer, and A.4.2 bounds
    // MaxDpbSize above by 16 for every supported level.
    if s.max_dec_pic_buffering >= max_dpb_size ||
      s.max_num_reorder_pics > s.max_dec_pic_buffering {
      raise Invalid
    }
  }

  let log2_min_cb_size_minus3 = c.ue().reinterpret_as_int()
  let log2_diff_max_min_cb_size = c.ue().reinterpret_as_int()
  if log2_min_cb_size_minus3 > 3 || log2_diff_max_min_cb_size > 3 {
    raise Invalid
  }
  s.min_cb_log2_size_y = 3 + log2_min_cb_size_minus3
  s.ctb_log2_size_y = s.min_cb_log2_size_y + log2_diff_max_min_cb_size
  if s.ctb_log2_size_y < min_ctb_log2_size_y ||
    s.ctb_log2_size_y > max_ctb_log2_size_y {
    raise Invalid
  }

  // 7.4.3.2: both dimensions are an integer multiple of MinCbSizeY. Without
  // it a coding unit at the edge extends past the picture.
  let mask = @safe.bit_mask(s.min_cb_log2_size_y)
  if (s.pic_width_in_luma_samples.to_int64() & mask) != 0L ||
    (s.pic_height_in_luma_samples.to_int64() & mask) != 0L {
    raise Invalid
  }

  s.ctb_size_y = (1 << s.ctb_log2_size_y).to_int64()
  s.pic_width_in_ctbs = @safe.div_ceil(
    s.pic_width_in_luma_samples.to_int64(),
    s.ctb_size_y,
  )
  s.pic_height_in_ctbs = @safe.div_ceil(
    s.pic_height_in_luma_samples.to_int64(),
    s.ctb_size_y,
  )

  let log2_min_tb_size_minus2 = c.ue().reinterpret_as_int()
  let log2_diff_max_min_tb_size = c.ue().reinterpret_as_int()
  if log2_min_tb_size_minus2 > 3 || log2_diff_max_min_tb_size > 3 {
    raise Invalid
  }
  s.min_tb_log2_size_y = 2 + log2_min_tb_size_minus2
  s.max_tb_log2_size_y = s.min_tb_log2_size_y + log2_diff_max_min_tb_size

  // 7.4.3.2.1 holds MaxTbLog2SizeY to Min(CtbLog2SizeY, 5), which is 32.
  if s.min_tb_log2_size_y >= s.min_cb_log2_size_y ||
    s.max_tb_log2_size_y > @cmp.minimum(s.ctb_log2_size_y, 5) {
    raise Invalid
  }

  s.max_tr_hier_inter = c.ue().reinterpret_as_int()
  s.max_tr_hier_intra = c.ue().reinterpret_as_int()

  s.scaling_list_enabled = c.bit() != 0
  if s.scaling_list_enabled && c.bit() != 0 {
    parse_scaling_list_data(c, s.scaling_list)
  }

  s.amp_enabled = c.bit() != 0
  s.sao_enabled = c.bit() != 0

  s.pcm_enabled = c.bit() != 0
  if s.pcm_enabled {
    s.pcm_bit_depth_luma = 1 + c.bits(4).reinterpret_as_int()
    s.pcm_bit_depth_chroma = 1 + c.bits(4).reinterpret_as_int()
    if s.pcm_bit_depth_luma > s.bit_depth_luma ||
      s.pcm_bit_depth_chroma > s.bit_depth_chroma {
      raise Invalid
    }

    let log2_min_pcm_cb_size_minus3 = c.ue().reinterpret_as_int()
    let log2_diff_max_min_pcm_cb_size = c.ue().reinterpret_as_int()
    if log2_min_pcm_cb_size_minus3 > 2 || log2_diff_max_min_pcm_cb_size > 2 {
      raise Invalid
    }
    s.log2_min_pcm_cb_size = 3 + log2_min_pcm_cb_size_minus3
    s.log2_max_pcm_cb_size = s.log2_min_pcm_cb_size +
      log2_diff_max_min_pcm_cb_size
    s.pcm_loop_filter_disabled = c.bit() != 0
  }

  let num_st_rps = c.ue().reinterpret_as_int()
  if num_st_rps > max_short_term_rps {
    raise Invalid
  }
  for i in 0..<num_st_rps {
    s.st_rps.push(parse_short_term_rps(c, i, num_st_rps, s.st_rps))
  }

  s.long_term_ref_pics_present = c.bit() != 0
  if s.long_term_ref_pics_present {
    let n = c.ue().reinterpret_as_int()
    if n > max_long_term_ref_pics {
      raise Invalid
    }
    for _ in 0..<n {
      s.lt_ref_pic_poc_lsb.push(c.bits(s.log2_max_poc_lsb).reinterpret_as_int())
      s.used_by_curr_pic_lt.push(c.bit() != 0)
    }
  }

  s.temporal_mvp_enabled = c.bit() != 0
  s.strong_intra_smoothing = c.bit() != 0

  if c.bit() != 0 {
    parse_vui(c, s, s.max_sub_layers_minus1)
  }

  let mut unparsed = false
  if c.bit() != 0 {
    let range_extension = c.bit() != 0
    let multilayer_extension = c.bit() != 0
    let extension_3d = c.bit() != 0
    let scc_extension = c.bit() != 0
    unparsed = c.bits(4) != 0

    if range_extension {
      s.transform_skip_rotation = c.bit() != 0
      s.transform_skip_context = c.bit() != 0
      s.implicit_rdpcm = c.bit() != 0
      s.explicit_rdpcm = c.bit() != 0
      s.extended_precision = c.bit() != 0
      s.intra_smoothing_disabled = c.bit() != 0
      s.high_precision_offsets = c.bit() != 0
      s.persistent_rice_adaptation = c.bit() != 0
      s.cabac_bypass_alignment = c.bit() != 0
    }

    // The tools below are parsed so the extension stays in step, but they are
    // not applied. A stream that uses one is refused rather than decoded into
    // something that merely looks plausible.
    if s.implicit_rdpcm || s.explicit_rdpcm || s.cabac_bypass_alignment {
      raise Unsupported
    }
    if multilayer_extension || extension_3d || scc_extension {
      raise Unsupported
    }
  }

  check_trailing(c, unparsed)
  // The one profile this port decodes is checked here rather than at decode
  // time: a picture outside it has no path through the decoder, and finding
  // that out after allocating a frame buffer helps nobody.
  check_main_profile(s)
  s
}

///|
/// `vui_parameters` of E.2.1. Only the color description is kept; the rest is
/// walked so the bit position stays in step.
fn parse_vui(
  c : GetBits,
  s : SPS,
  max_sub_layers_minus1 : Int32,
) -> Unit raise Error {
  if c.bit() != 0 {
    if c.bits(8) == 255 {
      ignore(c.bits(16))
      ignore(c.bits(16))
    }
  }

  if c.bit() != 0 {
    ignore(c.bit())
  }

  if c.bit() != 0 {
    ignore(c.bits(3))
    s.full_range = c.bit() != 0
    if c.bit() != 0 {
      s.colour_primaries = c.bits(8).reinterpret_as_int()
      s.transfer_characteristics = c.bits(8).reinterpret_as_int()
      s.matrix_coefficients = c.bits(8).reinterpret_as_int()
    }
  }

  if c.bit() != 0 {
    ignore(c.ue())
    ignore(c.ue())
  }

  ignore(c.bit())
  ignore(c.bit())
  ignore(c.bit())

  if c.bit() != 0 {
    ignore(c.ue())
    ignore(c.ue())
    ignore(c.ue())
    ignore(c.ue())
  }

  if c.bit() != 0 {
    ignore(c.bits(32))
    ignore(c.bits(32))
    if c.bit() != 0 {
      ignore(c.ue())
    }
    if c.bit() != 0 {
      parse_hrd(c, true, max_sub_layers_minus1)
    }
  }

  if c.bit() != 0 {
    ignore(c.bit())
    ignore(c.bit())
    ignore(c.bit())
    ignore(c.ue())
    ignore(c.ue())
    ignore(c.ue())
    ignore(c.ue())
    ignore(c.ue())
  }
}

///|
/// `st_ref_pic_set(idx)` of 7.3.7, derived to the picture order count deltas
/// that 8.3.2 then uses.
fn parse_short_term_rps(
  c : GetBits,
  idx : Int32,
  num_st_rps : Int32,
  prev : Array[ShortTermRPS],
) -> ShortTermRPS raise Error {
  let rps : ShortTermRPS = {
    delta_poc_s0: [],
    delta_poc_s1: [],
    used_s0: [],
    used_s1: [],
  }

  let mut inter_pred = false
  if idx != 0 {
    inter_pred = c.bit() != 0
  }

  if inter_pred {
    // 7.4.8: the set is predicted from an earlier one, which a later set may
    // still be written against.
    let delta_idx = if idx == num_st_rps {
      c.ue().reinterpret_as_int() + 1
    } else {
      1
    }
    if delta_idx > idx {
      raise Invalid
    }
    let predicted_from = prev[idx - delta_idx]

    let sign = c.bit() != 0
    let abs_delta_rps_minus1 = c.ue().reinterpret_as_int()
    if abs_delta_rps_minus1 >= 32768 {
      raise Invalid
    }
    let mut delta_rps = abs_delta_rps_minus1 + 1
    if sign {
      delta_rps = -delta_rps
    }

    let n = predicted_from.num_delta_pocs()
    let used = Array::make(n + 1, false)
    let use_delta = Array::make(n + 1, true)
    for j in 0..<(n + 1) {
      used[j] = c.bit() != 0
      if !used[j] {
        use_delta[j] = c.bit() != 0
      }
    }

    let num_neg = predicted_from.delta_poc_s0.length()
    let num_pos = predicted_from.delta_poc_s1.length()

    let mut j = num_pos - 1
    while j >= 0 {
      let d = predicted_from.delta_poc_s1[j] + delta_rps
      if d < 0 && use_delta[num_neg + j] {
        rps.delta_poc_s0.push(d)
        rps.used_s0.push(used[num_neg + j])
      }
      j = j - 1
    }

    if delta_rps < 0 && use_delta[n] {
      rps.delta_poc_s0.push(delta_rps)
      rps.used_s0.push(used[n])
    }

    for j in 0..<num_neg {
      let d = predicted_from.delta_poc_s0[j] + delta_rps
      if d < 0 && use_delta[j] {
        rps.delta_poc_s0.push(d)
        rps.used_s0.push(used[j])
      }
    }

    let mut j = num_neg - 1
    while j >= 0 {
      let d = predicted_from.delta_poc_s0[j] + delta_rps
      if d > 0 && use_delta[j] {
        rps.delta_poc_s1.push(d)
        rps.used_s1.push(used[j])
      }
      j = j - 1
    }

    if delta_rps > 0 && use_delta[n] {
      rps.delta_poc_s1.push(delta_rps)
      rps.used_s1.push(used[n])
    }

    for j in 0..<num_pos {
      let d = predicted_from.delta_poc_s1[j] + delta_rps
      if d > 0 && use_delta[num_neg + j] {
        rps.delta_poc_s1.push(d)
        rps.used_s1.push(used[num_neg + j])
      }
    }

    return rps
  }

  let num_neg = c.ue().reinterpret_as_int()
  let num_pos = c.ue().reinterpret_as_int()
  if num_neg > max_ref_pics_per_rps || num_pos > max_ref_pics_per_rps {
    raise Invalid
  }

  let mut poc = 0
  for _ in 0..<num_neg {
    let d = c.ue().reinterpret_as_int()
    if d >= 32768 {
      raise Invalid
    }
    poc = poc - (d + 1)
    rps.delta_poc_s0.push(poc)
    rps.used_s0.push(c.bit() != 0)
  }

  poc = 0
  for _ in 0..<num_pos {
    let d = c.ue().reinterpret_as_int()
    if d >= 32768 {
      raise Invalid
    }
    poc = poc + (d + 1)
    rps.delta_poc_s1.push(poc)
    rps.used_s1.push(c.bit() != 0)
  }

  rps
}
