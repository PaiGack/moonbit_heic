///|
/// Slice-layer parsing lands in M2.
///
/// `@hevc` already parses VPS / SPS / PPS in place; this package is where
/// `slice_segment_header()` and its dependent-parameter-set neighbours go, so
/// that `@hevc` keeps owning only the parameter sets. Creating the package in
/// M0 fixes its position in the tree — and the rule that anything it adds
/// reaches for `@safe` rather than doing 32-bit arithmetic by hand.
pub suberror NotYetImplemented

///|
/// Width of the picture in luma samples, after conformance cropping.
///
/// The real implementation reads an SPS; this stub exists so the package has
/// one exercised entry point in M0.
pub fn cropped_width(
  pic_width_in_luma_samples : Int32,
  conf_win_left : Int32,
  conf_win_right : Int32,
) -> Int32 raise @safe.Overflow {
  let width = @safe.sub(
    pic_width_in_luma_samples,
    @safe.add(conf_win_left, conf_win_right),
  )
  guard width > 0 else { raise @safe.Overflow }
  width
}
