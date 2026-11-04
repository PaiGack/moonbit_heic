///|
/// YUV → RGB and colour-space handling land in M4.
///
/// The matrix coefficients come straight out of the SPS (`colour_primaries`,
/// `transfer_characteristics`, `matrix_coefficients`), so this package's job is
/// to map those integers onto an actual transform and to keep the arithmetic
/// integer-exact.
pub suberror NotYetImplemented

///|
/// A colour transform, in the fixed-point form the decoder will use.
pub(all) struct ColorMatrix {
  /// Weight of Y in R, etc. Scaled by `shift`.
  kr : Int32
  kb : Int32
  shift : Int32
}

///|
/// Fixed-point shift used by the VUI-derived transforms.
pub let matrix_shift : Int32 = 16

///|
/// Derive the luma weights for a `MatrixCoefficients` value.
///
/// Only the values that show up in HEIC stills are listed; anything else is
/// reported rather than guessed at.
pub fn ColorMatrix::from_matrix_coefficients(
  matrix_coefficients : Int32,
) -> ColorMatrix raise NotYetImplemented {
  match matrix_coefficients {
    1 => { kr: 2126, kb: 715, shift: matrix_shift, } // BT.709
    5 | 6 => { kr: 2990, kb: 1140, shift: matrix_shift, } // BT.601
    9 => { kr: 2627, kb: 595, shift: matrix_shift, } // BT.2020
    _ => raise NotYetImplemented
  }
}
