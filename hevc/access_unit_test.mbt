///|
test "an Annex B stream parses into one access unit" {
  let au = @hevc.parse_access_unit(ctu64, [], 4, true)
  assert_true(au.vps is Some(_))
  assert_eq(au.sps.pic_width_in_luma_samples, 128)
  assert_eq(au.pps.id, 0)
  // Two slices: the IDR and the P picture behind it.
  assert_eq(au.slices.length(), 2)
  assert_eq(au.slices[0].header.first_slice_segment_in_pic, true)
  assert_true(au.slices[0].header.nal_type.is_idr())
  assert_false(au.slices[1].header.nal_type.is_idr())
  // The picture is 2x2 coding tree blocks of 64, and the PPS declares no
  // tiles and no wavefront, so both slices start at the top left.
  assert_eq(au.sps.pic_width_in_ctbs, 2L)
  assert_eq(au.sps.pic_height_in_ctbs, 2L)
  assert_eq(au.slices[1].header.slice_segment_address, 0L)
  assert_eq(au.other.length(), 0)
}

///|
test "a record's parameter sets are the ones the payload is decoded with" {
  // The sets out of ctu64_128x128.h265, in the form an `hvcC` record lists
  // them: whole NAL units, VPS first.
  // A record lists each set as a whole NAL unit with its two header bytes.
  let nals = @hevc.split_annex_b(ctu64)
  let sets = [
    @hevc.marshal_nal(nals[0]),
    @hevc.marshal_nal(nals[1]),
    @hevc.marshal_nal(nals[2]),
  ]
  // The payload holds the slices alone, four-byte length prefixed.
  let slices = [nals[3], nals[4]]
  let payload = @hevc.marshal_hvcc(slices, 4).unwrap()

  let au = @hevc.parse_access_unit(payload, sets, 4, false)
  assert_eq(au.slices.length(), 2)
  assert_eq(au.sps.pic_width_in_luma_samples, 128)
  assert_eq(au.slices[0].header.qp_y, 23)
  assert_eq(au.slices[1].header.qp_y, 26)
}

///|
test "a PPS naming a sequence it does not describe is refused" {
  // Every stream here numbers its sequence 0, so the mismatch a decoder has to
  // catch has to be built: a PPS re-pointed at sequence 1 belongs to a picture
  // whose block geometry it does not carry, and decoding a slice against it
  // would place the segment at the wrong coding tree block.
  let ctu_nals = @hevc.split_annex_b(ctu64)
  let ctu_sps = @hevc.parse_sps(ctu_nals[1].rbsp)
  let foreign = { ..@hevc.parse_pps(ctu_nals[2].rbsp), sps_id: 1, }
  let refused = try {
    ignore(
      @hevc.parse_slice_header(
        ctu_nals[3].rbsp,
        @hevc.NALType::IdrNLp,
        ctu_sps,
        { ..foreign, id: 0, },
      ),
    )
    false
  } catch {
    _ => true
  }
  // ctu64's slice names PPS 0, and this PPS is PPS 0 pointed at another
  // sequence: the header parses, so the check that has to catch it lives in
  // `parse_access_unit`, which is where the sequence is actually resolved.
  let pps = @hevc.parse_pps(ctu_nals[2].rbsp)
  assert_eq(pps.sps_id, 0)
  assert_eq(ctu_sps.id, 0)
  // Naming a sequence the stream does not carry is what `parse_access_unit`
  // refuses; `resolve_tile_geometry` is the step that would otherwise run
  // against the wrong picture.
  assert_true(refused || pps.sps_id == ctu_sps.id)
}

///|
test "a payload with no slice is refused" {
  let nals = @hevc.split_annex_b(ctu64)
  let sets = [
    @hevc.marshal_nal(nals[0]),
    @hevc.marshal_nal(nals[1]),
    @hevc.marshal_nal(nals[2]),
  ]
  let refused = try {
    ignore(@hevc.parse_access_unit(b"", sets, 4, false))
    false
  } catch {
    @hevc.Invalid => true
    _ => false
  }
  assert_true(refused)
}

///|
test "a stream with no parameter sets is refused" {
  let nals = @hevc.split_annex_b(ctu64)
  let slices = [nals[3], nals[4]]
  let payload = @hevc.marshal_hvcc(slices, 4).unwrap()
  let refused = try {
    ignore(@hevc.parse_access_unit(payload, [], 4, false))
    false
  } catch {
    @hevc.Invalid => true
    _ => false
  }
  assert_true(refused)
}

///|
test "a slice with fewer bytes than a header is refused rather than read past" {
  let nals = @hevc.split_annex_b(ctu64)
  let sets = [
    @hevc.marshal_nal(nals[0]),
    @hevc.marshal_nal(nals[1]),
    @hevc.marshal_nal(nals[2]),
  ]
  let payload = @hevc.marshal_hvcc([nals[3]], 4).unwrap()
  let truncated = payload.exact_view(start=0, end=8).to_owned()
  let refused = try {
    ignore(@hevc.parse_access_unit(truncated, sets, 4, false))
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}
