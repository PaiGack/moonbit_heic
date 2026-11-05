// Byte-exact checks of the single-block reconstruction chain against
// golden.mbt: the REAL upstream Go reconstructPlane (8.6.x) output from real
// cabacWriter/encodeResidual CABAC bitstreams. This is where @geometry,
// @recon, @residual and @cabac are first wired together to produce pixels;
// every sample of the prediction-only and fully reconstructed planes must
// match sample for sample.

///|
fn geom_for_cases() -> @geometry.Geometry {
  // The exporter used a 64x64 luma picture, ctb_log2=6, min_tb_log2=2,
  // single tile, slice starting at CTB 0 (simpleAvail).
  @geometry.Geometry::new(64L, 64L, 6, 2)
}

///|
test "reconstruct_block reproduces upstream prediction-only planes" {
  for c in @reconstruct.recon_cases {
    let dec = @cabac.Decoder::new(c.bytes, 0) catch {
      _ => fail("short CABAC init word")
    }
    dec.init_contexts(c.qp, 2, false)
    let plane = c.plane_in.copy()
    let qp_dequant = if c.c_idx == 0 { c.qp } else { @recon.chroma_qp(c.qp, 1) }
    match
      @reconstruct.reconstruct_block(
        geom_for_cases(),
        plane,
        c.stride,
        c.x,
        c.y,
        c.log2,
        c.mode,
        c.c_idx,
        qp_dequant,
        dec,
        false,
      ) {
      Ok(_) => ()
      Err(_) => fail("reconstruct_block (pred only) failed")
    }
    assert_eq(plane, c.pred_plane)
  }
}

///|
test "reconstruct_block reproduces upstream fully reconstructed planes" {
  for c in @reconstruct.recon_cases {
    let dec = @cabac.Decoder::new(c.bytes, 0) catch {
      _ => fail("short CABAC init word")
    }
    dec.init_contexts(c.qp, 2, false)
    let plane = c.plane_in.copy()
    let qp_dequant = if c.c_idx == 0 { c.qp } else { @recon.chroma_qp(c.qp, 1) }
    match
      @reconstruct.reconstruct_block(
        geom_for_cases(),
        plane,
        c.stride,
        c.x,
        c.y,
        c.log2,
        c.mode,
        c.c_idx,
        qp_dequant,
        dec,
        true,
      ) {
      Ok(_) => ()
      Err(_) => fail("reconstruct_block (full) failed")
    }
    assert_eq(plane, c.plane_out)
  }
}

///|
test "reconstruct_block rejects malformed blocks without trapping" {
  let dec = @cabac.Decoder::new(b"\x00\x00\x00\x00\x00\x00\x00\x00", 0) catch {
    _ => fail("short CABAC init word")
  }
  dec.init_contexts(26, 2, false)
  let plane : Array[Int32] = Array::make(64 * 64, 128)
  let bads : Array[(Int32, Int32, Int32, Int32)] = [
    // log2 too small / too large, c_idx out of range, block past plane end.
    (1, 0, 8, 8),
    (6, 0, 8, 8),
    (3, 3, 8, 8),
    (3, 0, 60, 60),
  ]
  for (log2, c_idx, x, y) in bads {
    let r = @reconstruct.reconstruct_block(
      geom_for_cases(),
      plane,
      64,
      x,
      y,
      log2,
      0,
      c_idx,
      26,
      dec,
      false,
    )
    assert_true(r is Err(@reconstruct.InvalidBlock))
  }
}
