///|
/// A parsed picture parameter set, 7.3.2.3.
pub(all) struct PPS {
  mut id : Int32
  mut sps_id : Int32
  mut dependent_slice_segments_enabled : Bool
  mut output_flag_present : Bool
  mut num_extra_slice_header_bits : Int32
  mut sign_data_hiding_enabled : Bool
  mut cabac_init_present : Bool
  mut num_ref_idx_l0_default_active : Int32
  mut num_ref_idx_l1_default_active : Int32
  mut init_qp : Int32
  mut constrained_intra_pred : Bool
  mut transform_skip_enabled : Bool
  mut cu_qp_delta_enabled : Bool
  mut diff_cu_qp_delta_depth : Int32
  mut cb_qp_offset : Int32
  mut cr_qp_offset : Int32
  mut slice_chroma_qp_offsets : Bool
  mut weighted_pred : Bool
  mut weighted_bipred : Bool
  mut transquant_bypass : Bool
  mut tiles_enabled : Bool
  mut entropy_coding_sync : Bool
  mut num_tile_columns : Int32
  mut num_tile_rows : Int32
  mut uniform_spacing : Bool
  mut column_width_minus1 : Array[Int32]
  mut row_height_minus1 : Array[Int32]
  mut loop_filter_across_tiles : Bool
  mut col_widths_in_ctbs : Array[Int64]
  mut row_heights_in_ctbs : Array[Int64]
  mut loop_filter_across_slices : Bool
  mut deblocking_control_present : Bool
  mut deblocking_override : Bool
  mut deblocking_disabled : Bool
  mut beta_offset_div2 : Int32
  mut tc_offset_div2 : Int32
  mut scaling_list_present : Bool
  mut scaling_list : ScalingList
  mut lists_modification_present : Bool
  mut log2_parallel_merge_level : Int32
  mut slice_header_extension_present : Bool
  mut log2_max_transform_skip_size : Int32
  mut cross_component_prediction : Bool
  mut chroma_qp_offset_list : Bool
  mut diff_cu_chroma_qp_offset_depth : Int32
  mut chroma_qp_offset_list_len : Int32
  mut cb_qp_offset_list : Array[Int32]
  mut cr_qp_offset_list : Array[Int32]
  mut log2_sao_offset_scale_luma : Int32
  mut log2_sao_offset_scale_chroma : Int32
}

///|
/// Parses a picture parameter set from a NAL unit, header included.
pub fn parse_pps(nal : Bytes) -> PPS raise Error {
  let c = GetBits::new(nal_payload(nal))

  let p : PPS = {
    id: 0,
    sps_id: 0,
    dependent_slice_segments_enabled: false,
    output_flag_present: false,
    num_extra_slice_header_bits: 0,
    sign_data_hiding_enabled: false,
    cabac_init_present: false,
    num_ref_idx_l0_default_active: 1,
    num_ref_idx_l1_default_active: 1,
    init_qp: 26,
    constrained_intra_pred: false,
    transform_skip_enabled: false,
    cu_qp_delta_enabled: false,
    diff_cu_qp_delta_depth: 0,
    cb_qp_offset: 0,
    cr_qp_offset: 0,
    slice_chroma_qp_offsets: false,
    weighted_pred: false,
    weighted_bipred: false,
    transquant_bypass: false,
    tiles_enabled: false,
    entropy_coding_sync: false,
    num_tile_columns: 1,
    num_tile_rows: 1,
    uniform_spacing: true,
    column_width_minus1: [],
    row_height_minus1: [],
    loop_filter_across_tiles: true,
    col_widths_in_ctbs: [],
    row_heights_in_ctbs: [],
    loop_filter_across_slices: false,
    deblocking_control_present: false,
    deblocking_override: false,
    deblocking_disabled: false,
    beta_offset_div2: 0,
    tc_offset_div2: 0,
    scaling_list_present: false,
    scaling_list: default_scaling_list(),
    lists_modification_present: false,
    log2_parallel_merge_level: 2,
    slice_header_extension_present: false,
    log2_max_transform_skip_size: 2,
    cross_component_prediction: false,
    chroma_qp_offset_list: false,
    diff_cu_chroma_qp_offset_depth: 0,
    chroma_qp_offset_list_len: 0,
    cb_qp_offset_list: [],
    cr_qp_offset_list: [],
    log2_sao_offset_scale_luma: 0,
    log2_sao_offset_scale_chroma: 0,
  }

  p.id = c.ue().reinterpret_as_int()
  p.sps_id = c.ue().reinterpret_as_int()
  if p.id > 63 || p.sps_id > 15 {
    raise Invalid
  }

  p.dependent_slice_segments_enabled = c.bit() != 0
  p.output_flag_present = c.bit() != 0
  p.num_extra_slice_header_bits = c.bits(3).reinterpret_as_int()
  p.sign_data_hiding_enabled = c.bit() != 0
  p.cabac_init_present = c.bit() != 0
  p.num_ref_idx_l0_default_active = c.ue().reinterpret_as_int() + 1
  p.num_ref_idx_l1_default_active = c.ue().reinterpret_as_int() + 1
  if p.num_ref_idx_l0_default_active > 16 ||
    p.num_ref_idx_l1_default_active > 16 {
    raise Invalid
  }

  p.init_qp = c.se() + 26
  p.constrained_intra_pred = c.bit() != 0
  p.transform_skip_enabled = c.bit() != 0

  p.cu_qp_delta_enabled = c.bit() != 0
  if p.cu_qp_delta_enabled {
    p.diff_cu_qp_delta_depth = c.ue().reinterpret_as_int()
  }

  p.cb_qp_offset = c.se()
  p.cr_qp_offset = c.se()
  if p.cb_qp_offset < -12 ||
    p.cb_qp_offset > 12 ||
    p.cr_qp_offset < -12 ||
    p.cr_qp_offset > 12 {
    raise Invalid
  }

  p.slice_chroma_qp_offsets = c.bit() != 0
  p.weighted_pred = c.bit() != 0
  p.weighted_bipred = c.bit() != 0
  p.transquant_bypass = c.bit() != 0
  p.tiles_enabled = c.bit() != 0
  p.entropy_coding_sync = c.bit() != 0

  if p.tiles_enabled {
    p.num_tile_columns = c.ue().reinterpret_as_int() + 1
    p.num_tile_rows = c.ue().reinterpret_as_int() + 1
    if p.num_tile_columns > max_tile_columns || p.num_tile_rows > max_tile_rows {
      raise Invalid
    }

    p.uniform_spacing = c.bit() != 0
    if !p.uniform_spacing {
      for _ in 0..<(p.num_tile_columns - 1) {
        p.column_width_minus1.push(c.ue().reinterpret_as_int())
      }
      for _ in 0..<(p.num_tile_rows - 1) {
        p.row_height_minus1.push(c.ue().reinterpret_as_int())
      }
    }

    p.loop_filter_across_tiles = c.bit() != 0
  }

  p.loop_filter_across_slices = c.bit() != 0

  p.deblocking_control_present = c.bit() != 0
  if p.deblocking_control_present {
    p.deblocking_override = c.bit() != 0
    p.deblocking_disabled = c.bit() != 0
    if !p.deblocking_disabled {
      p.beta_offset_div2 = c.se()
      p.tc_offset_div2 = c.se()
      if p.beta_offset_div2 < -6 ||
        p.beta_offset_div2 > 6 ||
        p.tc_offset_div2 < -6 ||
        p.tc_offset_div2 > 6 {
        raise Invalid
      }
    }
  }

  p.scaling_list_present = c.bit() != 0
  if p.scaling_list_present {
    parse_scaling_list_data(c, p.scaling_list)
  }

  p.lists_modification_present = c.bit() != 0
  p.log2_parallel_merge_level = c.ue().reinterpret_as_int() + 2
  p.slice_header_extension_present = c.bit() != 0

  let mut unparsed = false
  if c.bit() != 0 {
    let range_extension = c.bit() != 0
    let multilayer_extension = c.bit() != 0
    let extension_3d = c.bit() != 0
    let scc_extension = c.bit() != 0
    unparsed = c.bits(4) != 0

    if range_extension {
      if p.transform_skip_enabled {
        p.log2_max_transform_skip_size = c.ue().reinterpret_as_int() + 2
      }

      p.cross_component_prediction = c.bit() != 0

      p.chroma_qp_offset_list = c.bit() != 0
      if p.chroma_qp_offset_list {
        p.diff_cu_chroma_qp_offset_depth = c.ue().reinterpret_as_int()
        p.chroma_qp_offset_list_len = c.ue().reinterpret_as_int() + 1
        if p.chroma_qp_offset_list_len > max_chroma_qp_offsets {
          raise Invalid
        }
        for _ in 0..<p.chroma_qp_offset_list_len {
          p.cb_qp_offset_list.push(c.se())
          p.cr_qp_offset_list.push(c.se())
        }
      }

      p.log2_sao_offset_scale_luma = c.ue().reinterpret_as_int()
      p.log2_sao_offset_scale_chroma = c.ue().reinterpret_as_int()
    }

    // Parsed to keep the extension in step, but not applied.
    if p.cross_component_prediction {
      raise Unsupported
    }
    if multilayer_extension || extension_3d || scc_extension {
      raise Unsupported
    }
  }

  check_trailing(c, unparsed)
  p
}

///|
/// The tile grid in coding tree blocks, 6.5.1. A picture splits evenly unless
/// the parameter set spells out every column and row.
pub fn PPS::resolve_tile_geometry(self : PPS, sps : SPS) -> Unit raise Error {
  let w = sps.pic_width_in_ctbs
  let h = sps.pic_height_in_ctbs

  if !self.tiles_enabled {
    self.col_widths_in_ctbs = [w]
    self.row_heights_in_ctbs = [h]
    return
  }

  // The tile counts are bounded by the picture in CTBs, so comparing them is
  // a comparison of `Int` against `Int64` and not an arithmetic step.
  if self.num_tile_columns.to_int64() > w || self.num_tile_rows.to_int64() > h {
    raise Invalid
  }

  let cols : Array[Int64] = Array::make(self.num_tile_columns, 0L)
  let rows : Array[Int64] = Array::make(self.num_tile_rows, 0L)

  if self.uniform_spacing {
    for i in 0..<self.num_tile_columns {
      let n = i.to_int64()
      let p = self.num_tile_columns.to_int64()
      cols[i] = (n + 1L) * w / p - n * w / p
    }
    for i in 0..<self.num_tile_rows {
      let n = i.to_int64()
      let p = self.num_tile_rows.to_int64()
      rows[i] = (n + 1L) * h / p - n * h / p
    }
  } else {
    let mut sum = 0L
    for i in 0..<self.column_width_minus1.length() {
      cols[i] = self.column_width_minus1[i].to_int64() + 1L
      sum = @safe.add(sum, cols[i])
    }
    if sum >= w {
      raise Invalid
    }
    cols[self.num_tile_columns - 1] = @safe.sub(w, sum)

    sum = 0L
    for i in 0..<self.row_height_minus1.length() {
      rows[i] = self.row_height_minus1[i].to_int64() + 1L
      sum = @safe.add(sum, rows[i])
    }
    if sum >= h {
      raise Invalid
    }
    rows[self.num_tile_rows - 1] = @safe.sub(h, sum)
  }

  self.col_widths_in_ctbs = cols
  self.row_heights_in_ctbs = rows
}
