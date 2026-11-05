// The residual-coefficient syntax layer of M3 (7.3.8.11). It sits directly on
// top of the CABAC arithmetic decoder (hevc/cabac) and the coefficient scan
// orders (hevc/dsp), and feeds the reconstruction DSP layer (hevc/recon):
// decode_residual turns a slice of an I-frame's CABAC stream into a transform
// block of coefficient levels.
//
// All sizes here are log2 block sizes (2..5) and 4x4 sub-block coordinates,
// structurally small, so Int32 is the right carrier. Coefficient levels are
// Int32 (the width of TransCoeffLevel). The syntax reads bins through the
// already byte-exact checked @cabac.Decoder; every context index is derived
// here from the spec and held to the upstream derivations by golden.mbt.
