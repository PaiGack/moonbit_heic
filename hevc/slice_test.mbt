///|
/// The parameter sets a slice needs, taken from a fixture the way a decoder
/// takes them from the stream: in order, and whatever the last one said.
fn sets_of(nals : Array[@hevc.NALUnit]) -> (@hevc.SPS, @hevc.PPS) raise Error {
  let mut sps = None
  let mut pps = None
  for n in nals {
    match n.nal_type() {
      Some(@hevc.Sps) => sps = Some(@hevc.parse_sps(n.rbsp))
      Some(@hevc.Pps) => pps = Some(@hevc.parse_pps(n.rbsp))
      _ => ()
    }
  }
  match (sps, pps) {
    (Some(s), Some(p)) => (s, p)
    _ => panic()
  }
}

///|
fn slice_name(t : @hevc.SliceType) -> String {
  match t {
    @hevc.B => "B"
    @hevc.P => "P"
    _ => "I"
  }
}

///|
/// Every VCL unit of a fixture, as its header prints. The three streams are
/// the ones the issue names: 1080p, ctu64_128x128 and tu8.
fn slice_dump(name : String) -> String raise Error {
  let data = match name {
    "1080p" => hd1080
    "ctu64_128x128" => ctu64
    _ => tu8
  }
  let nals = @hevc.split_annex_b(data)
  let (s, p) = sets_of(nals) catch { _ => panic() }
  let sb = StringBuilder()
  for n in nals {
    let t = match n.nal_type() {
      None => continue
      Some(t) => t
    }
    if !t.is_vcl() {
      continue
    }
    let h = @hevc.parse_slice_header(n.rbsp, t, s, p)
    sb.write_string(
      "\{slice_name(h.slice_type)} first=\{h.first_slice_segment_in_pic} addr=\{h.slice_segment_address} poc=\{h.pic_order_cnt_lsb} qp=\{h.qp_y} ep=\{h.entry_point_offsets.length()} off=\{h.data_offset}\n",
    )
  }
  sb.to_string()
}

///|
test "the three acceptance streams parse end to end" {
  assert_eq(
    slice_dump("1080p"),
    "I first=true addr=0 poc=0 qp=25 ep=0 off=2\n" +
    "P first=true addr=0 poc=1 qp=28 ep=0 off=5\n" +
    "P first=true addr=0 poc=2 qp=28 ep=0 off=5\n" +
    "P first=true addr=0 poc=3 qp=28 ep=0 off=5\n" +
    "P first=true addr=0 poc=4 qp=28 ep=0 off=5\n" +
    "P first=true addr=0 poc=5 qp=28 ep=0 off=5\n" +
    "P first=true addr=0 poc=6 qp=28 ep=0 off=5\n" +
    "P first=true addr=0 poc=7 qp=28 ep=0 off=5\n" +
    "P first=true addr=0 poc=8 qp=28 ep=0 off=5\n" +
    "P first=true addr=0 poc=9 qp=28 ep=0 off=5\n",
  )
  assert_eq(
    slice_dump("ctu64_128x128"),
    "I first=true addr=0 poc=0 qp=23 ep=0 off=2\n" +
    "P first=true addr=0 poc=1 qp=26 ep=0 off=4\n",
  )
  assert_eq(slice_dump("tu8"), "I first=true addr=0 poc=0 qp=25 ep=0 off=2\n")
}

///|
test "the sequence parameters of the acceptance streams" {
  let s = @hevc.parse_sps(@hevc.split_annex_b(hd1080)[1].rbsp)
  assert_eq(s.pic_width_in_luma_samples, 1920)
  assert_eq(s.pic_height_in_luma_samples, 1088)
  assert_eq(s.cropped_height(), 1080)
  assert_eq(s.bit_depth_luma, 8)
  assert_eq(s.chroma_format_idc, 1)
  assert_eq(s.ptl.profile_idc, 1)
  assert_eq(s.ptl.level_idc, 120)
  assert_eq(s.pic_width_in_ctbs, 60L)
  assert_eq(s.pic_height_in_ctbs, 34L)
  // 1920x1080 with a 16x16 minimum coding block.
  assert_eq(s.min_cb_log2_size_y, 4)

  let t = @hevc.parse_sps(@hevc.split_annex_b(tu8)[1].rbsp)
  assert_eq(t.pic_width_in_luma_samples, 16)
  assert_eq(t.pic_height_in_luma_samples, 16)
  assert_eq(t.ctb_log2_size_y, 4)
  assert_eq(t.max_tb_log2_size_y, 3)
}

///|
/// A parameter set handed over without its two header bytes has to mean the
/// same thing as a whole NAL unit: `parse_sps` strips a header only when one
/// is there, and an RBSP already stripped must not be stripped twice.
test "a parameter set finds its own header" {
  let nals = @hevc.split_annex_b(ctu64)
  let sps_rbsp = nals[1].rbsp
  let sps_nal = b"\x42\x01" + sps_rbsp
  let a = @hevc.parse_sps(sps_nal)
  let b = @hevc.parse_sps(sps_rbsp)
  assert_eq(a.pic_width_in_luma_samples, b.pic_width_in_luma_samples)
  assert_eq(a.ctb_log2_size_y, b.ctb_log2_size_y)
  assert_eq(a.st_rps.length(), b.st_rps.length())
}

///|
test "an IDR slice carries no picture order count" {
  // ctu64_128x128.h265's IDR: 0x28 0x01 is NAL type 20, IDR_N_LP.
  let nals = @hevc.split_annex_b(ctu64)
  let (sps, pps) = sets_of(nals)
  let h = @hevc.parse_slice_header(
    nals[3].rbsp,
    @hevc.NALType::from_code(20).unwrap(),
    sps,
    pps,
  )
  assert_true(h.first_slice_segment_in_pic)
  assert_false(h.no_output_of_prior_pics)
  assert_false(h.dependent_slice_segment)
  assert_eq(h.slice_segment_address, 0L)
  assert_eq(h.pic_order_cnt_lsb, 0)
  assert_false(h.st_rps_from_sps)
  assert_eq(h.st_rps.num_delta_pocs(), 0)
  // The PPS of this stream does not enable tiles or a wavefront, so there are
  // no entry points, and the data starts right after the header byte pair.
  assert_eq(h.entry_point_offsets.length(), 0)
  assert_eq(h.data_offset, 2L)
  // The picture is 128x128 in 64x64 coding tree blocks: 2x2 of them.
  assert_eq(sps.pic_width_in_ctbs * sps.pic_height_in_ctbs, 4L)
}

///|
test "a slice header naming another picture parameter set is refused" {
  let nals = @hevc.split_annex_b(ctu64)
  let (sps, pps) = sets_of(nals)
  let other = { ..pps, id: 3, }
  let refused = try {
    ignore(
      @hevc.parse_slice_header(nals[3].rbsp, @hevc.NALType::IdrNLp, sps, other),
    )
    false
  } catch {
    @hevc.Invalid => true
    _ => false
  }
  assert_true(refused)
}
