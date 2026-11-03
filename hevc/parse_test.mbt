///|
/// Cross-checked against the Go implementation this port follows: the same
/// streams, parsed and printed field by field. A drift in either the field
/// order or a derived value shows up here, not a thousand lines later in a
/// decoder that only looks plausible.

///|
fn tf(x : Bool) -> String {
  if x {
    "true"
  } else {
    "false"
  }
}

///|
fn vps_summary(v : @hevc.VPS) -> String {
  "vps id=\{v.id} maxLayers=\{v.max_layers_minus1} maxSub=\{v.max_sub_layers_minus1} nesting=\{tf(v.temporal_id_nesting)} ptl=\{profile_summary(v.ptl)} buffering=\{list(v.max_dec_pic_buffering)} reorder=\{list(v.max_num_reorder_pics)} latency=\{list(v.max_latency_increase)}"
}

///|
fn sps_summary(s : @hevc.SPS) -> String {
  "sps vps=\{s.vps_id} maxSub=\{s.max_sub_layers_minus1} nesting=\{tf(s.temporal_id_nesting)} ptl=\{profile_summary(s.ptl)} id=\{s.id} chroma=\{s.chroma_format_idc} sep=\{tf(s.separate_colour_plane)} w=\{s.pic_width_in_luma_samples} h=\{s.pic_height_in_luma_samples} crop=\{s.conf_win_left},\{s.conf_win_right},\{s.conf_win_top},\{s.conf_win_bottom} bd=\{s.bit_depth_luma},\{s.bit_depth_chroma} log2poc=\{s.log2_max_poc_lsb} mincb=\{s.min_cb_log2_size_y} ctb=\{s.ctb_log2_size_y} mintb=\{s.min_tb_log2_size_y} maxtb=\{s.max_tb_log2_size_y} amp=\{tf(s.amp_enabled)} sao=\{tf(s.sao_enabled)} pcm=\{tf(s.pcm_enabled)} strps=\{s.st_rps.length()} lt=\{tf(s.long_term_ref_pics_present)} tmvp=\{tf(s.temporal_mvp_enabled)} sis=\{tf(s.strong_intra_smoothing)} cp=\{s.colour_primaries} tc=\{s.transfer_characteristics} mc=\{s.matrix_coefficients} full=\{tf(s.full_range)} tmS=\{tf(s.transform_skip_rotation)} tiles=\{s.max_dec_pic_buffering}"
}

///|
fn pps_summary(p : @hevc.PPS) -> String {
  "pps id=\{p.id} sps=\{p.sps_id} dep=\{tf(p.dependent_slice_segments_enabled)} out=\{tf(p.output_flag_present)} extra=\{p.num_extra_slice_header_bits} sign=\{tf(p.sign_data_hiding_enabled)} cabac=\{tf(p.cabac_init_present)} l0=\{p.num_ref_idx_l0_default_active} l1=\{p.num_ref_idx_l1_default_active} qp=\{p.init_qp} cip=\{tf(p.constrained_intra_pred)} ts=\{tf(p.transform_skip_enabled)} cuqp=\{tf(p.cu_qp_delta_enabled)} cb=\{p.cb_qp_offset} cr=\{p.cr_qp_offset} chromaqp=\{tf(p.slice_chroma_qp_offsets)} wp=\{tf(p.weighted_pred)} wbp=\{tf(p.weighted_bipred)} tb=\{tf(p.transquant_bypass)} tiles=\{tf(p.tiles_enabled)} wpp=\{tf(p.entropy_coding_sync)} col=\{p.num_tile_columns} row=\{p.num_tile_rows}"
}

///|
fn profile_summary(p : @hevc.ProfileTierLevel) -> String {
  let brace_close = "}"
  "{profileSpace:" +
  p.profile_space.to_string() +
  " tierFlag:" +
  tf(p.tier_flag) +
  " profileIDC:" +
  p.profile_idc.to_string() +
  " levelIDC:" +
  p.level_idc.to_string() +
  " compatFlags:" +
  p.compat_flags.to_string() +
  brace_close
}

///|
fn list(xs : Array[Int32]) -> String {
  "[" + xs.map(x => x.to_string()).join(" ") + "]"
}

///|
fn parse_10bit_128x128() -> Unit raise Error {
  // The first VPS, SPS and PPS of 10bit_128x128.h265.
  let vps = b"\x40\x01\x0c\x01\xff\xff\x02\x20\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\xba\x02\x40"
  let sps = b"\x42\x01\x01\x02\x20\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\xa0\x10\x20\x20\x4d\x96\xe9\x6f\x0b\x80\x40\x00\x00\xfa\x00\x00\x1d\x4c\x02"
  let pps = b"\x44\x01\xc0\x71\x81\xa4\x80"

  let v = @hevc.parse_vps(vps)
  assert_eq(
    vps_summary(v),
    "vps id=0 maxLayers=0 maxSub=0 nesting=true ptl={profileSpace:0 tierFlag:false profileIDC:2 levelIDC:30 compatFlags:536870912} buffering=[2 0 0 0 0 0 0] reorder=[0 0 0 0 0 0 0] latency=[1 0 0 0 0 0 0]",
  )

  let s = @hevc.parse_sps(sps)
  assert_eq(
    sps_summary(s),
    "sps vps=0 maxSub=0 nesting=true ptl={profileSpace:0 tierFlag:false profileIDC:2 levelIDC:30 compatFlags:536870912} id=0 chroma=1 sep=false w=128 h=128 crop=0,0,0,0 bd=10,10 log2poc=8 mincb=4 ctb=4 mintb=2 maxtb=4 amp=false sao=false pcm=false strps=0 lt=false tmvp=true sis=true cp=2 tc=2 mc=2 full=false tmS=false tiles=2",
  )

  let p = @hevc.parse_pps(pps)
  assert_eq(
    pps_summary(p),
    "pps id=0 sps=0 dep=false out=false extra=0 sign=false cabac=false l0=1 l1=1 qp=26 cip=false ts=false cuqp=false cb=0 cr=0 chromaqp=false wp=false wbp=false tb=false tiles=false wpp=false col=1 row=1",
  )
}

///|
test "parse_10bit_128x128" {
  parse_10bit_128x128()
}

///|
fn parse_ctu64_128x128() -> Unit raise Error {
  // The first VPS, SPS and PPS of ctu64_128x128.h265.
  let vps = b"\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\x92\x80\x90"
  let sps = b"\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\xa0\x10\x20\x20\x59\x64\xa9\x24\xc2\xe0\x10\x00\x00\x3e\x80\x00\x07\x53\x00\x80"
  let pps = b"\x44\x01\xc1\x71\x81\xa4\x80"

  let v = @hevc.parse_vps(vps)
  assert_eq(
    vps_summary(v),
    "vps id=0 maxLayers=0 maxSub=0 nesting=true ptl={profileSpace:0 tierFlag:false profileIDC:1 levelIDC:30 compatFlags:1610612736} buffering=[3 0 0 0 0 0 0] reorder=[0 0 0 0 0 0 0] latency=[1 0 0 0 0 0 0]",
  )

  let s = @hevc.parse_sps(sps)
  assert_eq(
    sps_summary(s),
    "sps vps=0 maxSub=0 nesting=true ptl={profileSpace:0 tierFlag:false profileIDC:1 levelIDC:30 compatFlags:1610612736} id=0 chroma=1 sep=false w=128 h=128 crop=0,0,0,0 bd=8,8 log2poc=8 mincb=3 ctb=6 mintb=2 maxtb=5 amp=false sao=false pcm=false strps=0 lt=false tmvp=true sis=true cp=2 tc=2 mc=2 full=false tmS=false tiles=3",
  )

  let p = @hevc.parse_pps(pps)
  assert_eq(
    pps_summary(p),
    "pps id=0 sps=0 dep=false out=false extra=0 sign=true cabac=false l0=1 l1=1 qp=26 cip=false ts=false cuqp=false cb=0 cr=0 chromaqp=false wp=false wbp=false tb=false tiles=false wpp=false col=1 row=1",
  )
}

///|
test "parse_ctu64_128x128" {
  parse_ctu64_128x128()
}

///|
fn parse_bframes3_128x128() -> Unit raise Error {
  // The first VPS, SPS and PPS of bframes3_128x128.h265.
  let vps = b"\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\x95\x94\x09"
  let sps = b"\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\xa0\x10\x20\x20\x59\x65\x65\x5b\xc2\xe0\x10\x00\x00\x3e\x80\x00\x07\x53\x00\x80"
  let pps = b"\x44\x01\xc0\x71\x81\xa4\x80"

  let v = @hevc.parse_vps(vps)
  assert_eq(
    vps_summary(v),
    "vps id=0 maxLayers=0 maxSub=0 nesting=true ptl={profileSpace:0 tierFlag:false profileIDC:1 levelIDC:30 compatFlags:1610612736} buffering=[4 0 0 0 0 0 0] reorder=[2 0 0 0 0 0 0] latency=[4 0 0 0 0 0 0]",
  )

  let s = @hevc.parse_sps(sps)
  assert_eq(
    sps_summary(s),
    "sps vps=0 maxSub=0 nesting=true ptl={profileSpace:0 tierFlag:false profileIDC:1 levelIDC:30 compatFlags:1610612736} id=0 chroma=1 sep=false w=128 h=128 crop=0,0,0,0 bd=8,8 log2poc=8 mincb=4 ctb=4 mintb=2 maxtb=4 amp=false sao=false pcm=false strps=0 lt=false tmvp=true sis=true cp=2 tc=2 mc=2 full=false tmS=false tiles=4",
  )

  let p = @hevc.parse_pps(pps)
  assert_eq(
    pps_summary(p),
    "pps id=0 sps=0 dep=false out=false extra=0 sign=false cabac=false l0=1 l1=1 qp=26 cip=false ts=false cuqp=false cb=0 cr=0 chromaqp=false wp=false wbp=false tb=false tiles=false wpp=false col=1 row=1",
  )
}

///|
test "parse_bframes3_128x128" {
  parse_bframes3_128x128()
}

///|
fn parse_culossless_176x144() -> Unit raise Error {
  // The first VPS, SPS and PPS of culossless_176x144.h265.
  let vps = b"\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\x95\x98\x09"
  let sps = b"\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\xa0\x16\x20\x24\x59\x65\x66\x92\x4c\xae\x01\x00\x00\x03\x03\xe8\x00\x00\x03\x03\xe8\x08"
  let pps = b"\x44\x01\xc1\x71\xab\x12"

  let v = @hevc.parse_vps(vps)
  assert_eq(
    vps_summary(v),
    "vps id=0 maxLayers=0 maxSub=0 nesting=true ptl={profileSpace:0 tierFlag:false profileIDC:1 levelIDC:30 compatFlags:1610612736} buffering=[4 0 0 0 0 0 0] reorder=[2 0 0 0 0 0 0] latency=[5 0 0 0 0 0 0]",
  )

  let s = @hevc.parse_sps(sps)
  assert_eq(
    sps_summary(s),
    "sps vps=0 maxSub=0 nesting=true ptl={profileSpace:0 tierFlag:false profileIDC:1 levelIDC:30 compatFlags:1610612736} id=0 chroma=1 sep=false w=176 h=144 crop=0,0,0,0 bd=8,8 log2poc=8 mincb=3 ctb=6 mintb=2 maxtb=5 amp=false sao=true pcm=false strps=0 lt=false tmvp=true sis=true cp=2 tc=2 mc=2 full=false tmS=false tiles=4",
  )

  let p = @hevc.parse_pps(pps)
  assert_eq(
    pps_summary(p),
    "pps id=0 sps=0 dep=false out=false extra=0 sign=true cabac=false l0=1 l1=1 qp=26 cip=false ts=false cuqp=false cb=0 cr=0 chromaqp=false wp=true wbp=false tb=true tiles=false wpp=true col=1 row=1",
  )
}

///|
test "parse_culossless_176x144" {
  parse_culossless_176x144()
}

///|
fn parse_ctu64_wpp() -> Unit raise Error {
  // The first VPS, SPS and PPS of ctu64_wpp.h265.
  let vps = b"\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x3c\x91\x30\x24"
  let sps = b"\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x3c\xa0\x0a\x08\x0f\x16\x59\x13\x92\x4c\x2e\x01\x00\x00\x03\x03\xe8\x00\x00\x75\x30\x08"
  let pps = b"\x44\x01\xc1\x71\x83\xa4\x80"

  let v = @hevc.parse_vps(vps)
  assert_eq(
    vps_summary(v),
    "vps id=0 maxLayers=0 maxSub=0 nesting=true ptl={profileSpace:0 tierFlag:false profileIDC:1 levelIDC:60 compatFlags:1610612736} buffering=[3 0 0 0 0 0 0] reorder=[1 0 0 0 0 0 0] latency=[2 0 0 0 0 0 0]",
  )

  let s = @hevc.parse_sps(sps)
  assert_eq(
    sps_summary(s),
    "sps vps=0 maxSub=0 nesting=true ptl={profileSpace:0 tierFlag:false profileIDC:1 levelIDC:60 compatFlags:1610612736} id=0 chroma=1 sep=false w=320 h=240 crop=0,0,0,0 bd=8,8 log2poc=8 mincb=3 ctb=6 mintb=2 maxtb=5 amp=false sao=false pcm=false strps=0 lt=false tmvp=true sis=true cp=2 tc=2 mc=2 full=false tmS=false tiles=3",
  )

  let p = @hevc.parse_pps(pps)
  assert_eq(
    pps_summary(p),
    "pps id=0 sps=0 dep=false out=false extra=0 sign=true cabac=false l0=1 l1=1 qp=26 cip=false ts=false cuqp=false cb=0 cr=0 chromaqp=false wp=false wbp=false tb=false tiles=false wpp=true col=1 row=1",
  )
}

///|
test "parse_ctu64_wpp" {
  parse_ctu64_wpp()
}
