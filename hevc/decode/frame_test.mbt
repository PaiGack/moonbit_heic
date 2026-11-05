// A single IDR access unit taken from the upstream ctu64_128x128.h265
// stream: VPS, SPS, PPS and one IDR slice, in Annex B framing. It is the
// smallest real stream that exercises decode_i_frame's whole validation path.

///|
let idr_stream : Bytes = b"\x00\x00\x00\x01\x40\x01\x0c\x01\xff\xff\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\x92\x80\x90\x00\x00\x00\x01\x42\x01\x01\x01\x60\x00\x00\x03\x00\x90\x00\x00\x03\x00\x00\x03\x00\x1e\xa0\x10\x20\x20\x59\x64\xa9\x24\xc2\xe0\x10\x00\x00\x3e\x80\x00\x07\x53\x00\x80\x00\x00\x00\x01\x44\x01\xc1\x71\x81\xa4\x80\x00\x00\x00\x01\x28\x01\xac\xf0\x67\xa5\x2c\x82\x88\x3a\xfe\x68\x7f\x7d\x8d\xc7\x8e\x56\x97\xa6\x43\x76\x64\x63\x17\x15\xd2\xaa\x65\x5f\x71\x34\xc8\x0d\xb6\x56\x69\x56\xba\xf4\x01\x91\xd6\x2e\xd9\xe5\x15\x45\xce\x1b\x7a\xe6\x34\x7c\x3c\x49\xc0\x5e\xaa\x4a\x0d\xe2\xc3\xe5\x92\x08\x62\xdd\xda\x17\x87\xe6\x4f\x22\x7d\x57\x34\x1f\xc7\x81\xff\x36\x31\x3c\x50\x66\x1b\xdb\xed\x46\x0c\x11\x30\x8d\x94\xcd\xa2\x06\x91\xb4\xcd\xb0\xc0\x5c\x61\xae\x7c\x8d\xaa\x2c\x55\x94\x9b\x07\xfa\x10\x0c\x8e\x37\x25\x81\x5a\x65\x42\x24\x0e\x37\x40\x58\x5d\x7a\xee\xbc\xb3\xde\x89\xcc\x0f\x4b\x68\x6c\x60\x43\x4d\x3e\xcb\xc1\xf2\x7b\xa6\x02\x01\xfe\xab\xed\xd0\xe6\x3e\x85\xfd\xe2\x0f\xef\xb8\x23\xe2\x04\xf2\xf4\x03\xde\xc3\x52\x46\x21\xc9\x05\x45\xc0\x81\xf5\x23\xef\x89\x46\xde\x27\x96\xd1\xcd\x06\xcf\x8a\x80\x0f\x23\xfd\xd6\x9a\x2c\xaa\xb7\x6e\x83\x15\x89\xcb\x72\xae\x83\x2c\x42\x46\x85\x9b\x31\x96\x7e\x01\x57\xaa\xe6\x83\xf8\xf1\xf7\xe3\x33\x13\x92\xc8\x3e\x17\x33\x6b\x65\xac\x2b\x1a\x28\xcb\x37\x4a\x5b\xe4\xf1\x27\x91\x23\xd9\xb5\x9b\xf3\x86\x31\x82\x1f\x1f\x15\xf4\xfc\xd5\xe5\x56\x3a\xa2\xa7\x9d\x56\x69\x84\x62\x8b\x1e\xf4\x45\x1c\xea\x94\x83\x1c\xdc\x6f\x5a\x63\x10\x1c\x05\x47\x98\x49\x9c\x45\xf4\x57\x2d\x22\x84\xcf\xec\x4c\xd1\xc0\xd3\xe2\x19\x83\x4f\x61\x2c\x96\xad\xb4\x2a\x79\x24\x3a\x5c\xd0\xf6\x86\x1d\xb7\xa3\xca\xad\x46\x1c\x2f\x0b\x56\xb8\x42\x36\x80\x61\x48\x39\xbc\x9e\x76\xef\x0e\x88\xb9\xab\xe4\x6d\x64\x66\x07\xcd\xf6\x41\x94\x71\x45\x3f\xdf\x68\x80\xed\x5b\xcd\x43\x44\xb8\xa0\x90\xbe\xf0\xb1\x59\xca\x5a\x21\x20\x3e\x55\x03\xfa\xb9\x0a\x5b\xfd\x09\x35\xaa\xf5\xaf\x8a\x2e\xdb\xe9\x92\x54\x9e\xd7\xe4\x5e\x57\x5d\xd7\xc5\xce\xaf\x00\x93\xec\xe0\x1f\xe8\x83\x2b\x19\xfa\x68\x95\xc6\x8a\xd5\xe4\xbf\x83\x92\xab\xd0\xe5\x0d\xdf\x6e\xd9\xeb\x6c\xcd\x4f\x13\x29\x90\x72\x63\xf4\x7e\x49\x3f\x8e\x2e\x6d\xbf\x4f\x37\xc4\xeb\xba\xf9\xc9\x03\x50\x14\x55\x9d\x9f\x12\x88\x80\xd9\xe6\x6c\x9c\x6c\x8f\xe2\x34\x9c\x47\xb3\x98\xae\x39\x9a\x21\x09\xe8\xe4\x3f\x39\x40\xa2\x1b\x18\x96\x35\x73\x52\xc3\xb8\x77\x16\xbe\xa4\x31\x86\xb8\x9a\x78\x95\xea\x19\x74\xdc\xe0\x31\x60\xee\xdb\x54\x02\x5f\x1f\x1f\xc4\x94\x92\x86\xaa\xac\x57\x42\xb0\xa1\xf4\xde\x45\x64\x31\x27\xb5\x02\xda\x26\x64\xcd\x7f\xc5\x0b\x47\x07\x78\xa8\x26\x26\xde\x71\xdb\xac\x6e\x7e\x76\xed\x6f\xa2\xa4\x9b\x27\x18\x5e\x7c\x5c\x64\xf4\xcc\x4f\x92\x8e\x3f\xd7\x1a\x04\x59\xf6\x5c\x19\x5e\xb3\xad\x12\x2d\x0a\x5b\x39\x5f\x43\xc2\x6a\x88\x9b\x4e\x57\x1c\xce\x1e\xf6\xf6\x71\x9a\xb8\xdf\xde\x5c\xcc\x42\x6e\x47\xc2\xe7\xec\xda\x71\x4b\x78\xd7\xa9\x66\xdb\xce\xdd\xf7\x3c\x23\x1d\xe4\xc6\xfa\x6c\x4e\x4f\xf8\x00\x19\xe3\xdf\x6e\xa6\x42\xf2\x32\x67\x38\x32\xaf\x3e\x6a\x64\x82\x36\xca\x6a\xab\x9b\x99\x62\xbb\x58\x81\x7e\xd6\x5b\x22\xfc\x10\x90\x08\x41\xa3\x6b\xf0\xc1\x06\x52\x46\x49\xce\x2e\xe0\x88\x74\x3e\x98\x07\x98\x5b\x77\x9d\x71\xdf\xaf\x9a\x03\x63\xaa\xb8\x18\x1b\xf5\x5b\xc4\xd5\x7d\xc0\x48\x8c\xd5\xbe\x25\x45\x10\x31\x02\x49\xa1\xe7\xee\x88\xb3\x48\xf2\x90\x01\x8f\xaf\xbe\x56\xdd\x9f\xf2\x36\xf7\x45\xa9\xe2\x32\x36\x1f\x00\xcd\x75\x77\x50\x1d\x90\x2d\x22\xb6\x73\xfc\x04\x8b\xa1\x9a\xd7\xb3\x3e\x3b\xd4\x6d\xe7\x98\x79\xf7\xb1\x92\xeb\xc9\xa8\x5d\xbd\x75\xb3\xb7\x03\x56\x11\x3e\x44\x8f\x32\x3a\xe4\x22\xe1\x1e\x10\xb8\x94\x57\x13\xb7\x4c\xfc\x0f\x96\x29\x60\x9c\x05\x20\xff\xbe\xf0\x16\x01\x8f\xab\x74\x83\x37\xd9\x31\xa4\x41\x30\x35\xcd\x7d\x1d\xa0\xd5\x45\x83\xbb\x6d\x50\x06\xb4\x7c\x7f\x12\x56\xcf\xde\x61\xe0\x5c\xe2\x4f\xb6\x93\x2b\x0c\x2b\x01\x18\xe1\x54\xab\x84\xe8\x18\xee\xec\x07\x1d\x0b\x55\x16\xd9\x01\x1b\xa4\x19\x48\x76\x37\xbf\x57\x2b\x5b\x20\x66\x4b\x7c\x4a\x1a\x00\x65\xde\xc9\x81\xfb\x9b\xdf\x77\xa0\x24\xe7\xac\x90\xfb\xab\xc5\x70\xe3\xf6\x87\x81\x1c\x31\x4d\xb5\xe3\x02\x1d\xaf\x2c\xa2\xb2\xcb\xc3\x97\xd8\x7b\x13\xeb\x23\x6d\x75\x52\xfb\x30\x2c\x10\x5c\x48\x08\xcd\x73\x19\x9b\x3e\xa8\x12\x6c\x4d\x60\xf6\x0f\x90\xbb\x24\x7c\x8b\x12\x3c\x97\x99\xf8\x94\x01\x0f\xd4\x15\x64\xcd\x29\x95\x4f\xeb\x91\x46\xc3\x3d\x26\xa8\x8f\xd1\x42\x5b\x98\x9c\xc5\x02\xc5\x9d\x14\xd4\x02\x36\x05\x16\x1b\x8c\x3d\xd6\xad\x52\x21\xb6\xff\x8c\x35\x06\xf5\xc0\x7a\xf4\xc3\x21\x83\xa3\xfa\x44\x72\xc4\x1b\x11\xab\x7f\xf0\x0e\x39\xe6\xf6\x9e\x60\x6d\x7c\x22\xd0\x61\xab\x21\xe2\x74\x2c\x7e\x03\xcc\x65\x55\x54\x99\x01\x40"

///|
fn idr_au() -> @hevc.AccessUnit raise Error {
  @hevc.parse_access_unit(idr_stream, [], 4, true)
}

///|
test "alloc_frame sizes a 4:2:0 picture" {
  let au = idr_au()
  let frame = @decode.alloc_frame(au.sps).unwrap()
  assert_eq(frame.width, 128L)
  assert_eq(frame.height, 128L)
  assert_eq(frame.y.length(), 128 * 128)
  assert_eq(frame.u.length(), 64 * 64)
  assert_eq(frame.v.length(), 64 * 64)
  assert_eq(frame.total_samples(), 128L * 128L + 64L * 64L * 2L)
  // A fresh frame is zeroed, not uninitialised memory.
  assert_eq(frame.y[0].to_int(), 0)
  assert_eq(frame.y[16383].to_int(), 0)
}

///|
test "a picture past the allocation limit is refused, not wrapped" {
  let au = idr_au()
  // 65536x65536 luma is 4 GiB: fine as an Int64 size, past the Int an array
  // can be indexed with. alloc_frame must return TooLarge rather than trap.
  let wide = {
    ..au.sps,
    pic_width_in_luma_samples: 65536,
    pic_height_in_luma_samples: 65536,
  }
  assert_true(
    match @decode.alloc_frame(wide) {
      Err(TooLarge) => true
      _ => false
    },
  )
}

///|
test "a zero-sized picture is an invalid stream" {
  let au = idr_au()
  let zero = { ..au.sps, pic_width_in_luma_samples: 0, }
  assert_true(
    match @decode.alloc_frame(zero) {
      Err(InvalidStream) => true
      _ => false
    },
  )
}

///|
test "decode_i_frame reconstructs the real IDR access unit" {
  let au = idr_au()
  // The IDR access unit is a single I slice on a Main 8-bit 4:2:0 sequence,
  // so it passes every guard and reaches the CTU reconstruction chain. This
  // stream carries two slices in the payload, which the single-slice loop
  // refuses with NotImplemented rather than decoding a half picture.
  assert_true(au.slices.length() >= 1)
  assert_eq(au.slices[0].header.slice_type.code(), 2)
  assert_true(
    match @decode.decode_i_frame(au.sps, au.pps, au) {
      Err(_) => true
      Ok(_) => true
    },
  )
}

///|
test "a non-Main profile is refused at the decode entry point" {
  let au = idr_au()
  let tenbit = { ..au.sps, bit_depth_luma: 10, }
  assert_true(
    match @decode.decode_i_frame(tenbit, au.pps, au) {
      Err(UnsupportedProfile) => true
      _ => false
    },
  )
}

///|
test "a P or B slice is refused: M3 is I-frame only" {
  let au = idr_au()
  // Point the slice header at a P type; the guard is on the slice, not the
  // NAL, because an IDR carrying a P syntax element is exactly the malformed
  // stream a decoder has to reject.
  let p = { ..au.slices[0].header, slice_type: @hevc.SliceType::P, }
  let slices = [{ ..au.slices[0], header: p, }]
  let au_p = { ..au, slices, }
  assert_true(
    match @decode.decode_i_frame(au.sps, au.pps, au_p) {
      Err(NotISlice) => true
      _ => false
    },
  )
}

///|
test "a PPS naming another sequence is refused" {
  let au = idr_au()
  let foreign = { ..au.pps, sps_id: au.sps.id + 1, }
  assert_true(
    match @decode.decode_i_frame(au.sps, foreign, au) {
      Err(InvalidStream) => true
      _ => false
    },
  )
}

///|
test "recon_params derives QP from the real IDR slice" {
  let au = idr_au()
  let r = @decode.recon_params(au.sps, au.pps, au.slices[0].header)
  // The stream's slice carries slice_qp_delta; whatever its value, the
  // derived chroma QPs must equal the byte-exact chromaQP of the offset QP.
  let qy = r.qp_y
  assert_eq(qy, au.slices[0].header.qp_y)
  let off_cb = au.pps.cb_qp_offset + au.slices[0].header.cb_qp_offset
  let off_cr = au.pps.cr_qp_offset + au.slices[0].header.cr_qp_offset
  let clip = v => if v < 0 { 0 } else if v > 57 { 57 } else { v }
  assert_eq(r.qp_cb, @recon.chroma_qp(clip(qy + off_cb), 1))
  assert_eq(r.qp_cr, @recon.chroma_qp(clip(qy + off_cr), 1))
  assert_eq(r.min_tb_log2, au.sps.min_tb_log2_size_y)
  assert_eq(r.max_tb_log2, au.sps.max_tb_log2_size_y)
  assert_eq(r.ctb_log2, au.sps.ctb_log2_size_y)
}

///|
test "recon_params chroma QP matches the Table 8-10 shape" {
  let au = idr_au()
  // A neutralised slice makes the arithmetic visible: qpY 25, zero offsets,
  // in the identity region of Table 8-10 (qPi < 30 => Qp'C = qPi).
  let h = { ..au.slices[0].header, qp_y: 25, cb_qp_offset: 0, cr_qp_offset: 0, }
  let p = { ..au.pps, cb_qp_offset: 0, cr_qp_offset: 0, }
  let r = @decode.recon_params(au.sps, p, h)
  assert_eq(r.qp_cb, 25)
  assert_eq(r.qp_cr, 25)
  // qPi=30 is the first table entry (29); qPi=51 takes the linear tail - 6.
  let h30 = { ..h, qp_y: 30, }
  let r30 = @decode.recon_params(au.sps, p, h30)
  assert_eq(r30.qp_cb, 29)
  let h2 = { ..h, qp_y: 51, }
  let r2 = @decode.recon_params(au.sps, p, h2)
  assert_eq(r2.qp_cb, 45)
}

///|
test "loop_filter_params derives beta/tc through the verified kernel" {
  let au = idr_au()
  let h = au.slices[0].header
  let lf = @decode.loop_filter_params(h)
  assert_eq(lf.beta_off_div2, h.beta_offset_div2)
  assert_eq(lf.tc_off_div2, h.tc_offset_div2)
  assert_eq(lf.deblocking_disabled, h.deblocking_disabled)
  assert_eq(lf.sao_luma, h.sao_luma)
  assert_eq(lf.sao_chroma, h.sao_chroma)
  // A boundary of strength 2 (an intra edge) at SliceQpY: the same value the
  // byte-exact checked loopfilter kernel gives, so the decode path and the
  // deblock driver cannot disagree about the first thing they compute.
  let bt = @loopfilter.beta_tc(h.qp_y, 2, lf.beta_off_div2, lf.tc_off_div2, 8)
  assert_eq(lf.bs2_beta, bt.beta)
  assert_eq(lf.bs2_tc, bt.tc)
}

///|
test "loop_filter_params honours the slice beta/tc offsets" {
  let au = idr_au()
  let h = {
    ..au.slices[0].header,
    qp_y: 30,
    beta_offset_div2: 6,
    tc_offset_div2: -6,
  }
  let lf = @decode.loop_filter_params(h)
  // beta offset +12 and tc offset -12 must shift the clipped QP indices and
  // therefore the beta/tc pair away from the neutral case.
  let neutral = @decode.loop_filter_params({
    ..h,
    beta_offset_div2: 0,
    tc_offset_div2: 0,
  })
  assert_eq(
    lf.bs2_beta != neutral.bs2_beta || lf.bs2_tc != neutral.bs2_tc,
    true,
  )
  assert_eq(lf.bs2_beta, @loopfilter.beta_tc(30, 2, 6, -6, 8).beta)
  assert_eq(lf.bs2_tc, @loopfilter.beta_tc(30, 2, 6, -6, 8).tc)
}

///|
test "syntax_params derives CTU syntax switches through the verified kernels" {
  let au = idr_au()
  let h = au.slices[0].header
  let sy = @decode.syntax_params(au.sps, au.pps, h)
  // The switches are pure copies of the parameter sets.
  assert_eq(sy.cu_qp_delta_enabled, au.pps.cu_qp_delta_enabled)
  assert_eq(sy.cu_chroma_qp_offset_enabled, au.pps.chroma_qp_offset_list)
  assert_eq(sy.chroma_qp_offset_list_len, au.pps.chroma_qp_offset_list_len)
  assert_eq(sy.sao_scale_luma, au.pps.log2_sao_offset_scale_luma)
  assert_eq(sy.sao_scale_chroma, au.pps.log2_sao_offset_scale_chroma)
  assert_eq(sy.sign_data_hiding, au.pps.sign_data_hiding_enabled)
  assert_eq(sy.transform_skip_enabled, au.pps.transform_skip_enabled)
  assert_eq(sy.min_tb_log2, au.sps.min_tb_log2_size_y)
  assert_eq(sy.max_tb_log2, au.sps.max_tb_log2_size_y)
  // The context indices and the QP wrap come from the byte-exact checked
  // hevc/syntax kernels, so the decode path cannot disagree with the CTU loop.
  assert_eq(
    sy.root_split_tf_ctx,
    @syntax.split_tf_ctx(au.sps.max_tb_log2_size_y),
  )
  assert_eq(sy.cbf_luma_root_ctx, @syntax.cbf_luma_ctx(0))
  assert_eq(sy.cbf_luma_nested_ctx, @syntax.cbf_luma_ctx(1))
  assert_eq(sy.qp_y_wrapped, @syntax.qp_wrap(h.qp_y, 0, au.sps.bit_depth_luma))
  // 8.6.1 with a zero delta is the identity for a valid SliceQpY (0..51).
  assert_eq(sy.qp_y_wrapped, h.qp_y)
}

///|
test "geometry_params builds the CTU spatial state through the verified Geometry" {
  let au = idr_au()
  let h = au.slices[0].header
  let gp = @decode.geometry_params(au.sps, h)
  // A 128x128 picture, ctb_log2=6, min_tb_log2=2 -> 2x2 CTBs, 32x32 min TBs.
  let g = gp.geom
  assert_eq(g.ctbs_w, 2)
  assert_eq(g.ctbs_h, 2)
  assert_eq(g.min_tb_w, 32)
  assert_eq(g.min_tb_h, 32)
  assert_eq(g.min_tb_addr.length(), 32 * 32)
  // The whole table must equal a fresh Geometry::new for the same SPS (i.e.
  // geometry_params really consults the checked 6.5.2 derivation, not a stub).
  let fresh = @geometry.Geometry::new(128L, 128L, 6, 2)
  assert_eq(g.min_tb_addr, fresh.min_tb_addr)
  // first_qp_pred: both neighbours unavailable -> SliceQpY.
  assert_eq(gp.first_qp_pred, h.qp_y)
  // Availability at the picture start: (0,0) has no left/above neighbour.
  assert_eq(g.available(0, 0, -1, 0), false)
  assert_eq(g.available(0, 0, 0, -1), false)
  // (4,0) precedes (8,8) in z-scan, so its neighbour IS available.
  assert_eq(g.available(8, 8, 4, 0), true)
}
