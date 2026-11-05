// The seam between the parsed SPS (M2) and the CTU spatial-state layer
// (hevc/geometry, M3). Before the quadtree loop reads its first split bin it
// must have the z-scan MinTbAddrZs table of 6.5.2, because every neighbour
// lookup (split_cu ctx, qPY_PRED, MPM candidates, gatherRef) is an
// availability query against that table. Deriving it here is where the decode
// path first uses the byte-exact checked @geometry.Geometry::new.

///|
/// Per-picture spatial state the CTU loop reads before decoding any bin.
pub(all) struct GeometryParams {
  /// The whole 6.5.2 table, built from the SPS dimensions and log2 sizes.
  geom : @geometry.Geometry
  /// qPY_PRED at the first CTB (8,8): with both neighbours unavailable at the
  /// picture start it falls back to SliceQpY. The checked predict_qp kernel is
  /// consulted here rather than recomputed by hand.
  first_qp_pred : Int32
}

///|
/// Builds the CTU spatial state for one I picture. M3 is single-thread,
/// single-slice, single-tile, so the MinTbAddrZs table reduces to the pure
/// z-scan address derivation (rsToTs is the identity); that simplification
/// is held to the upstream Go by hevc/geometry/golden.mbt.
pub fn geometry_params(
  sps : @hevc.SPS,
  slice : @hevc.SliceHeader,
) -> GeometryParams {
  let w = sps.pic_width_in_luma_samples.to_int64()
  let h = sps.pic_height_in_luma_samples.to_int64()
  let geom = @geometry.Geometry::new(
    w,
    h,
    sps.ctb_log2_size_y,
    sps.min_tb_log2_size_y,
  )
  // At the first CTB neither the left nor the above QP neighbour exists, so
  // qPY_PRED is SliceQpY (8.6.1). The kernel is still called so the decode
  // path uses the same verified derivation the loop will.
  let first_qp_pred = @geometry.predict_qp(
    slice.qp_y,
    slice.qp_y,
    slice.qp_y,
    sps.ctb_log2_size_y,
    8,
    8,
    false,
    false,
  )
  { geom, first_qp_pred, }
}
