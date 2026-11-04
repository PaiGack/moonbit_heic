///|
/// `slice_type` of Table 7-6, in the order the field codes them.
pub(all) enum SliceType {
  B
  P
  I
}

///|
/// The numeric value of a slice type, as it is written on the wire.
pub fn SliceType::code(self : SliceType) -> Int32 {
  match self {
    B => 0
    P => 1
    I => 2
  }
}

///|
/// `long_term_ref_pic_set()` of 7.3.7: the SPS-declared entries first, then
/// `num_pics_sps_plus1`.
pub(all) struct LongTermRPS {
  /// How many of the entries come from the SPS rather than this slice.
  mut num_sps : Int32
  mut poc_lsb_lt : Array[Int32]
  mut used_by_curr_pic_lt : Array[Bool]
  mut delta_poc_msb_present : Array[Bool]
  mut delta_poc_msb_cycle : Array[Int32]
}

///|
/// `ref_pic_lists_modification()` of 7.3.6.3.

///|
/// The lists are stored empty when the corresponding flag is zero: an absent
/// list is not an empty one, and the distinction is what a caller rebuilding
/// the reference picture lists reads.
pub(all) struct RefPicListModification {
  mut flag_l0 : Bool
  mut list_entry_l0 : Array[Int32]
  mut flag_l1 : Bool
  mut list_entry_l1 : Array[Int32]
}

///|
/// `pred_weight_table()` of 7.3.6.2.

///|
/// The offsets are already clipped to the half range 7.4.7.3 gives them, so
/// a reader does not repeat the arithmetic per sample. `luma_weight` and
/// friends are indexed `[list][ref_idx]` with the list 0 or 1.
pub(all) struct PredWeightTable {
  mut luma_log2_denom : Int32
  mut chroma_log2_denom : Int32
  mut luma_weight : Array[Array[Int32]]
  mut luma_offset : Array[Array[Int32]]
  mut chroma_weight : Array[Array[Array[Int32]]]
  mut chroma_offset : Array[Array[Array[Int32]]]
}

///|
/// A parsed slice segment header, 7.3.6.1.
///
/// A dependent slice segment repeats none of the fields it inherits, so they
/// are left at the values the defaults give them and `dependent_slice_segment`
/// says so: a caller decodes the picture's first independent segment first and
/// then applies this header's address and entry points to it.
pub(all) struct SliceHeader {
  mut nal_type : NALType
  mut first_slice_segment_in_pic : Bool
  mut no_output_of_prior_pics : Bool
  mut pps_id : Int32
  mut dependent_slice_segment : Bool
  /// In coding tree blocks, from the top left of the picture.
  mut slice_segment_address : Int64
  mut slice_type : SliceType
  mut pic_output_flag : Bool
  mut colour_plane_id : Int32
  mut pic_order_cnt_lsb : Int32
  mut st_rps_from_sps : Bool
  mut st_rps_idx : Int32
  mut st_rps : ShortTermRPS
  mut lt_rps : LongTermRPS
  mut temporal_mvp : Bool
  mut num_poc_total_curr : Int32
  mut sao_luma : Bool
  mut sao_chroma : Bool
  mut num_ref_idx_l0_active : Int32
  mut num_ref_idx_l1_active : Int32
  mut list_modification : RefPicListModification
  mut mvd_l1_zero : Bool
  mut cabac_init : Bool
  mut collocated_from_l0 : Bool
  mut collocated_ref_idx : Int32
  mut max_num_merge_cand : Int32
  mut weights : PredWeightTable
  /// `slice_qp_delta`, and the `QpY` it derives.
  mut qp_delta : Int32
  mut qp_y : Int32
  mut cb_qp_offset : Int32
  mut cr_qp_offset : Int32
  mut cu_chroma_qp_offset : Bool
  mut deblocking_disabled : Bool
  mut beta_offset_div2 : Int32
  mut tc_offset_div2 : Int32
  mut loop_filter_across : Bool
  /// Cumulative byte offsets of the substreams a tile or a wavefront starts,
  /// in the escaped payload: convert with `NALUnit::rbsp_offset`.
  mut entry_point_offsets : Array[Int32]
  /// Where the slice data begins, in bytes into the RBSP.
  mut data_offset : Int64
}

///|
/// `Ceil(Log2(x))` of 7.4.7.1, written for a count of blocks.
fn ceil_log2(n : Int64) -> Int32 {
  if n <= 1L {
    return 0
  }
  let mut bits = 0
  let mut x = n - 1L
  while x > 0L {
    bits = bits + 1
    x = x >> 1
  }
  bits
}

///|
/// `ChromaArrayType` of 7.4.3.2: zero for a separate colour plane whatever the
/// chroma format says.
fn SPS::chroma_array_type(self : SPS) -> Int32 {
  if self.separate_colour_plane {
    0
  } else {
    self.chroma_format_idc
  }
}

///|
fn empty_pred_weight_table() -> PredWeightTable {
  let luma_weight = Array::make(2, Array::make(0, 0))
  let luma_offset = Array::make(2, Array::make(0, 0))
  let chroma_weight = []
  let chroma_offset = []
  for _ in 0..<2 {
    chroma_weight.push(Array::make(0, Array::make(0, 0)))
    chroma_offset.push(Array::make(0, Array::make(0, 0)))
  }
  {
    luma_log2_denom: 0,
    chroma_log2_denom: 0,
    luma_weight,
    luma_offset,
    chroma_weight,
    chroma_offset,
  }
}

///|
fn empty_long_term_rps() -> LongTermRPS {
  {
    num_sps: 0,
    poc_lsb_lt: [],
    used_by_curr_pic_lt: [],
    delta_poc_msb_present: [],
    delta_poc_msb_cycle: [],
  }
}

///|
fn empty_ref_pic_list_modification() -> RefPicListModification {
  { flag_l0: false, list_entry_l0: [], flag_l1: false, list_entry_l1: [], }
}

///|
/// A slice header with every field at the value 7.3.6.1 infers when the syntax
/// behind it is absent.
fn default_slice_header() -> SliceHeader {
  {
    nal_type: TrailN,
    first_slice_segment_in_pic: false,
    no_output_of_prior_pics: false,
    pps_id: 0,
    dependent_slice_segment: false,
    slice_segment_address: 0L,
    slice_type: B,
    pic_output_flag: true,
    colour_plane_id: 0,
    pic_order_cnt_lsb: 0,
    st_rps_from_sps: false,
    st_rps_idx: 0,
    st_rps: { delta_poc_s0: [], delta_poc_s1: [], used_s0: [], used_s1: [], },
    lt_rps: empty_long_term_rps(),
    temporal_mvp: false,
    num_poc_total_curr: 0,
    sao_luma: false,
    sao_chroma: false,
    num_ref_idx_l0_active: 1,
    num_ref_idx_l1_active: 1,
    list_modification: empty_ref_pic_list_modification(),
    mvd_l1_zero: false,
    cabac_init: false,
    collocated_from_l0: true,
    collocated_ref_idx: 0,
    max_num_merge_cand: 5,
    weights: empty_pred_weight_table(),
    qp_delta: 0,
    qp_y: 26,
    cb_qp_offset: 0,
    cr_qp_offset: 0,
    cu_chroma_qp_offset: false,
    deblocking_disabled: false,
    beta_offset_div2: 0,
    tc_offset_div2: 0,
    loop_filter_across: false,
    entry_point_offsets: [],
    data_offset: 0L,
  }
}

///|
/// `slice_segment_header()` of 7.3.6.1.
///
/// `nal` is a whole NAL unit as `split_annex_b` and `split_hvcc` return them,
/// or a payload whose header has already been removed; `sps` and `pps` are the
/// parameter sets it names.
pub fn parse_slice_header(
  nal : Bytes,
  nal_type : NALType,
  sps : SPS,
  pps : PPS,
) -> SliceHeader raise Error {
  let rbsp = nal_payload(nal)
  let c = GetBits::new(rbsp)

  let h : SliceHeader = { ..default_slice_header(), nal_type, }
  h.first_slice_segment_in_pic = c.bit() != 0

  // 7.3.6.1: an IRAP and the broken-link access units carry this.
  let code = nal_type.code()
  if code >= 16 && code <= 23 {
    h.no_output_of_prior_pics = c.bit() != 0
  }

  h.pps_id = c.ue().reinterpret_as_int()
  if h.pps_id != pps.id {
    raise Invalid
  }

  let num_ctbs = sps.pic_width_in_ctbs * sps.pic_height_in_ctbs

  if !h.first_slice_segment_in_pic {
    if pps.dependent_slice_segments_enabled {
      h.dependent_slice_segment = c.bit() != 0
    }

    h.slice_segment_address = c
      .bits(ceil_log2(num_ctbs))
      .reinterpret_as_int()
      .to_int64()
    if h.slice_segment_address < 0L || h.slice_segment_address >= num_ctbs {
      raise Invalid
    }
  }

  h.pic_output_flag = true
  h.collocated_from_l0 = true
  h.max_num_merge_cand = 5
  h.num_ref_idx_l0_active = pps.num_ref_idx_l0_default_active
  h.num_ref_idx_l1_active = pps.num_ref_idx_l1_default_active
  h.deblocking_disabled = pps.deblocking_disabled
  h.beta_offset_div2 = pps.beta_offset_div2
  h.tc_offset_div2 = pps.tc_offset_div2
  h.loop_filter_across = pps.loop_filter_across_slices

  if !h.dependent_slice_segment {
    c.skip(pps.num_extra_slice_header_bits)

    let t = c.ue().reinterpret_as_int()
    if t > 2 {
      raise Invalid
    }
    h.slice_type = match t {
      0 => B
      1 => P
      _ => I
    }

    if pps.output_flag_present {
      h.pic_output_flag = c.bit() != 0
    }

    if sps.separate_colour_plane {
      h.colour_plane_id = c.bits(2).reinterpret_as_int()
    }

    if !nal_type.is_idr() {
      h.pic_order_cnt_lsb = c.bits(sps.log2_max_poc_lsb).reinterpret_as_int()

      h.st_rps_from_sps = c.bit() != 0
      if !h.st_rps_from_sps {
        h.st_rps = parse_short_term_rps(
          c,
          sps.st_rps.length(),
          sps.st_rps.length(),
          sps.st_rps,
        )
      } else {
        if sps.st_rps.length() == 0 {
          raise Invalid
        }
        if sps.st_rps.length() > 1 {
          h.st_rps_idx = c
            .bits(ceil_log2(sps.st_rps.length().to_int64()))
            .reinterpret_as_int()
        }
        if h.st_rps_idx >= sps.st_rps.length() {
          raise Invalid
        }
        h.st_rps = sps.st_rps[h.st_rps_idx]
      }

      if sps.long_term_ref_pics_present {
        h.lt_rps = parse_long_term_rps(c, sps)
      }

      if sps.temporal_mvp_enabled {
        h.temporal_mvp = c.bit() != 0
      }
    }

    h.num_poc_total_curr = num_poc_total_curr(h.st_rps, h.lt_rps)

    if sps.sao_enabled {
      h.sao_luma = c.bit() != 0
      if sps.chroma_array_type() != 0 {
        h.sao_chroma = c.bit() != 0
      }
    }

    if h.slice_type.code() != 2 {
      if c.bit() != 0 {
        h.num_ref_idx_l0_active = c.ue().reinterpret_as_int() + 1
        if h.slice_type.code() == 0 {
          h.num_ref_idx_l1_active = c.ue().reinterpret_as_int() + 1
        }
      }

      if h.num_ref_idx_l0_active > max_refs ||
        h.num_ref_idx_l1_active > max_refs {
        raise Invalid
      }

      if pps.lists_modification_present && h.num_poc_total_curr > 1 {
        h.list_modification = parse_ref_pic_list_modification(
          c,
          h.slice_type,
          h.num_poc_total_curr,
          h.num_ref_idx_l0_active,
          h.num_ref_idx_l1_active,
        )
      }

      if h.slice_type.code() == 0 {
        h.mvd_l1_zero = c.bit() != 0
      }

      if pps.cabac_init_present {
        h.cabac_init = c.bit() != 0
      }

      if h.temporal_mvp {
        if h.slice_type.code() == 0 {
          h.collocated_from_l0 = c.bit() != 0
        }

        let active = if h.collocated_from_l0 {
          h.num_ref_idx_l0_active
        } else {
          h.num_ref_idx_l1_active
        }
        if active > 1 {
          h.collocated_ref_idx = c.ue().reinterpret_as_int()
          if h.collocated_ref_idx >= active {
            raise Invalid
          }
        }
      }

      if (pps.weighted_pred && h.slice_type.code() == 1) ||
        (pps.weighted_bipred && h.slice_type.code() == 0) {
        h.weights = parse_pred_weight_table(
          c,
          h.slice_type,
          h.num_ref_idx_l0_active,
          h.num_ref_idx_l1_active,
          sps,
        )
      }

      let n = c.ue().reinterpret_as_int()
      if n > 4 {
        raise Invalid
      }
      h.max_num_merge_cand = 5 - n
    }

    h.qp_delta = c.se()
    h.qp_y = pps.init_qp + h.qp_delta

    // 7.4.7.1: QpY stays above the bottom of the luma range and below 52.
    if h.qp_y < -(6 * sps.bit_depth_luma - 48) || h.qp_y > 51 {
      raise Invalid
    }

    if pps.slice_chroma_qp_offsets {
      h.cb_qp_offset = c.se()
      h.cr_qp_offset = c.se()
      if h.cb_qp_offset < -12 ||
        h.cb_qp_offset > 12 ||
        h.cr_qp_offset < -12 ||
        h.cr_qp_offset > 12 {
        raise Invalid
      }
    }

    if pps.chroma_qp_offset_list {
      h.cu_chroma_qp_offset = c.bit() != 0
    }

    if pps.deblocking_override && c.bit() != 0 {
      h.deblocking_disabled = c.bit() != 0
      if !h.deblocking_disabled {
        h.beta_offset_div2 = c.se()
        h.tc_offset_div2 = c.se()
        if h.beta_offset_div2 < -6 ||
          h.beta_offset_div2 > 6 ||
          h.tc_offset_div2 < -6 ||
          h.tc_offset_div2 > 6 {
          raise Invalid
        }
      }
    }

    if pps.loop_filter_across_slices &&
      (h.sao_luma || h.sao_chroma || !h.deblocking_disabled) {
      h.loop_filter_across = c.bit() != 0
    }
  }

  if pps.tiles_enabled || pps.entropy_coding_sync {
    let n = c.ue().reinterpret_as_int()
    if n.to_int64() > num_ctbs {
      raise Invalid
    }

    if n > 0 {
      let len_minus1 = c.ue().reinterpret_as_int()
      if len_minus1 > 31 {
        raise Invalid
      }

      let offsets : Array[Int32] = []
      let mut cum : Int64 = 0L
      for _ in 0..<n {
        let v = c.bits(len_minus1 + 1).reinterpret_as_int().to_int64()
        cum = @safe.add(@safe.add(cum, v), 1L)
        offsets.push(@safe.narrow(cum))
      }
      h.entry_point_offsets = offsets
    }
  }

  if pps.slice_header_extension_present {
    let n = c.ue().reinterpret_as_int()
    if n < 0 || n.to_int64() > rbsp.length().to_int64() {
      raise Invalid
    }
    c.skip(n * 8)
  }

  // `slice_segment_header_extension` ends on a byte boundary, so the stop bit
  // and the alignment are both a way of saying "the data starts here".
  if c.bit() != 1 {
    raise Invalid
  }
  c.byte_align()

  if c.err {
    raise Invalid
  }

  h.data_offset = (c.pos() / 8).to_int64()
  h
}

///|
/// `NumPocTotalCurr` of 7.4.7.1: the reference pictures of the lists that
/// belong to the current picture.
fn num_poc_total_curr(st : ShortTermRPS, lt : LongTermRPS) -> Int32 {
  let mut n = 0
  for u in st.used_s0 {
    if u {
      n = n + 1
    }
  }
  for u in st.used_s1 {
    if u {
      n = n + 1
    }
  }
  for u in lt.used_by_curr_pic_lt {
    if u {
      n = n + 1
    }
  }
  n
}

///|
/// `ref_pic_list_modification()` of 7.3.6.3.
fn parse_ref_pic_list_modification(
  c : GetBits,
  slice_type : SliceType,
  num_poc_total_curr : Int32,
  num_ref_idx_l0_active : Int32,
  num_ref_idx_l1_active : Int32,
) -> RefPicListModification raise Error {
  let m : RefPicListModification = empty_ref_pic_list_modification()
  let width = ceil_log2(num_poc_total_curr.to_int64())

  m.flag_l0 = c.bit() != 0
  if m.flag_l0 {
    for _ in 0..<num_ref_idx_l0_active {
      let v = c.bits(width).reinterpret_as_int()
      if v >= num_poc_total_curr {
        raise Invalid
      }
      m.list_entry_l0.push(v)
    }
  }

  if slice_type.code() != 0 {
    return m
  }

  m.flag_l1 = c.bit() != 0
  if m.flag_l1 {
    for _ in 0..<num_ref_idx_l1_active {
      let v = c.bits(width).reinterpret_as_int()
      if v >= num_poc_total_curr {
        raise Invalid
      }
      m.list_entry_l1.push(v)
    }
  }

  m
}

///|
/// `long_term_ref_pic_set()` of 7.3.7.
fn parse_long_term_rps(c : GetBits, sps : SPS) -> LongTermRPS raise Error {
  let lt : LongTermRPS = empty_long_term_rps()

  let mut num_sps = 0
  if sps.lt_ref_pic_poc_lsb.length() > 0 {
    num_sps = c.ue().reinterpret_as_int()
  }
  let num_pics = c.ue().reinterpret_as_int()

  if num_sps > sps.lt_ref_pic_poc_lsb.length() ||
    num_sps + num_pics > max_long_term_ref_pics {
    raise Invalid
  }

  lt.num_sps = num_sps
  for i in 0..<(num_sps + num_pics) {
    if i < num_sps {
      let mut idx = 0
      if sps.lt_ref_pic_poc_lsb.length() > 1 {
        idx = c
          .bits(ceil_log2(sps.lt_ref_pic_poc_lsb.length().to_int64()))
          .reinterpret_as_int()
      }
      if idx < 0 || idx >= sps.lt_ref_pic_poc_lsb.length() {
        raise Invalid
      }
      lt.poc_lsb_lt.push(sps.lt_ref_pic_poc_lsb[idx])
      lt.used_by_curr_pic_lt.push(sps.used_by_curr_pic_lt[idx])
    } else {
      lt.poc_lsb_lt.push(c.bits(sps.log2_max_poc_lsb).reinterpret_as_int())
      lt.used_by_curr_pic_lt.push(c.bit() != 0)
    }

    let present = c.bit() != 0
    lt.delta_poc_msb_present.push(present)
    lt.delta_poc_msb_cycle.push(
      if present {
        c.ue().reinterpret_as_int()
      } else {
        0
      },
    )
  }

  lt
}

///|
/// `pred_weight_table()` of 7.3.6.2.
fn parse_pred_weight_table(
  c : GetBits,
  slice_type : SliceType,
  num_ref_idx_l0_active : Int32,
  num_ref_idx_l1_active : Int32,
  sps : SPS,
) -> PredWeightTable raise Error {
  let w = empty_pred_weight_table()

  let denom = c.ue().reinterpret_as_int()
  if denom > 7 {
    raise Invalid
  }
  w.luma_log2_denom = denom

  let mut chroma_denom = denom
  if sps.chroma_array_type() != 0 {
    chroma_denom = chroma_denom + c.se()
    if chroma_denom < 0 || chroma_denom > 7 {
      raise Invalid
    }
  }
  w.chroma_log2_denom = chroma_denom

  // 7.4.7.3, `WpOffsetHalfRangeC`: the sample depth under
  // high_precision_offsets_enabled_flag, eight bits otherwise.
  let half = if sps.high_precision_offsets {
    1 << (sps.bit_depth_chroma - 1)
  } else {
    128
  }

  let lists = if slice_type.code() == 0 { 2 } else { 1 }
  let counts = [num_ref_idx_l0_active, num_ref_idx_l1_active]

  for list in 0..<lists {
    let n = counts[list]
    // The table is sized for the full reference count a stream may use, so a
    // count past it is the stream's fault and not an allocation to grow.
    if n > max_refs {
      raise Invalid
    }

    let luma_flag : Array[Bool] = Array::make(n, false)
    let chroma_flag : Array[Bool] = Array::make(n, false)
    let lw : Array[Int32] = Array::make(n, 0)
    let lo : Array[Int32] = Array::make(n, 0)
    let cw = Array::make(n, Array::make(2, 0))
    let co = Array::make(n, Array::make(2, 0))

    for i in 0..<n {
      luma_flag[i] = c.bit() != 0
    }
    if sps.chroma_array_type() != 0 {
      for i in 0..<n {
        chroma_flag[i] = c.bit() != 0
      }
    }

    for i in 0..<n {
      if luma_flag[i] {
        lw[i] = (1 << w.luma_log2_denom) + c.se()
        lo[i] = c.se()
      } else {
        lw[i] = 1 << w.luma_log2_denom
      }

      if !chroma_flag[i] {
        cw[i][0] = 1 << w.chroma_log2_denom
        cw[i][1] = 1 << w.chroma_log2_denom
        continue
      }

      for j in 0..<2 {
        let dw = c.se()
        let doff = c.se()
        let weight = (1 << w.chroma_log2_denom) + dw
        cw[i][j] = weight
        // `half + do - (half * weight >> log2_denom)`, kept in `Int64` because
        // `half * weight` overflows a 32-bit `Int` at ten bits with a large
        // weight, and clipping a wrapped value is worse than not clipping.
        let raw = half.to_int64() +
          doff.to_int64() -
          ((half.to_int64() * weight.to_int64()) >> w.chroma_log2_denom)
        co[i][j] = clip3(raw, -half.to_int64(), half.to_int64() - 1L)
      }
    }

    w.luma_weight[list] = lw
    w.luma_offset[list] = lo
    w.chroma_weight[list] = cw
    w.chroma_offset[list] = co
  }

  if c.err {
    raise Invalid
  }
  w
}

///|
/// `Clip3(x, lo, hi)` of 5.6, on the carriers the offsets are computed in.
fn clip3(x : Int64, lo : Int64, hi : Int64) -> Int32 raise Error {
  let v = if x < lo { lo } else if x > hi { hi } else { x }
  @safe.narrow(v)
}

///|
/// The number of reference pictures a single list may hold, 7.4.7.2.
let max_refs : Int32 = 16
