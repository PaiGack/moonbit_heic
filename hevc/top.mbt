///|
/// Error of an HEVC bitstream that cannot be decoded.
pub suberror Invalid

///|
/// Error of an HEVC bitstream using a feature this port does not implement.
pub suberror Unsupported

///|
/// Error of a bitstream outside the one profile this port decodes: Main,
/// eight bits, 4:2:0.
///
/// Separate from `Unsupported` because the two say different things to a
/// caller. `Unsupported` is a feature this port has not written yet;
/// `UnsupportedProfile` is a picture this port will never decode, and it
/// carries the three values that put the bitstream out of scope so the
/// complaint names them instead of leaving a reader to guess.
pub suberror UnsupportedProfile {
  /// `general_profile_idc` of Table A.1, then `chroma_format_idc`, then the
  /// luma sample size: the three values that put a bitstream out of scope.
  UnsupportedProfile(
    profile_idc~ : Int32,
    chroma_format_idc~ : Int32,
    bit_depth_luma~ : Int32
  )
}

///|
/// The profile the decoder accepts and nothing else: Main (A.3.2), which is
/// eight-bit 4:2:0. Main Still Picture is the same toolset under another id,
/// so a still coded as one decodes the same way.
let profile_main : Int32 = 1

///|
let profile_main_still : Int32 = 3

///|
/// Whether a sequence parameter set stays inside the one profile this port
/// decodes. A caller that wants to know before parsing a whole picture asks
/// this; `parse_sps` runs it itself and answers with `UnsupportedProfile`.
pub fn check_main_profile(sps : SPS) -> Unit raise Error {
  if sps.ptl.profile_idc != profile_main &&
    sps.ptl.profile_idc != profile_main_still {
    raise UnsupportedProfile(
      profile_idc=sps.ptl.profile_idc,
      chroma_format_idc=sps.chroma_format_idc,
      bit_depth_luma=sps.bit_depth_luma,
    )
  }
  if sps.chroma_format_idc != 1 {
    raise UnsupportedProfile(
      profile_idc=sps.ptl.profile_idc,
      chroma_format_idc=sps.chroma_format_idc,
      bit_depth_luma=sps.bit_depth_luma,
    )
  }
  // Main still allows a separate colour plane, but 4:0:0 is the only format
  // it applies to, and that has already been refused above.
  if sps.separate_colour_plane {
    raise UnsupportedProfile(
      profile_idc=sps.ptl.profile_idc,
      chroma_format_idc=sps.chroma_format_idc,
      bit_depth_luma=sps.bit_depth_luma,
    )
  }
  if sps.bit_depth_luma != 8 || sps.bit_depth_chroma != 8 {
    raise UnsupportedProfile(
      profile_idc=sps.ptl.profile_idc,
      chroma_format_idc=sps.chroma_format_idc,
      bit_depth_luma=sps.bit_depth_luma,
    )
  }
}
