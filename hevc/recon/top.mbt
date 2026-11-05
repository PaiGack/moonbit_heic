// The reconstruction DSP layer of M3: the pure, byte-exact arithmetic that
// turns decoded coefficients and neighbour samples into residual and
// predicted pixels. It sits above hevc/dsp (scans and transform bases) and
// below the CTU syntax driver: everything here is a self-contained function
// that the upstream Go suite checks with a second, independently written
// implementation, so a pixel error at the top can be traced to one layer.
//
// Coefficients and samples are `Int` (32-bit, the width the spec's
// TransCoeffLevel and sample values actually have). Every *product* that can
// leave that width — dequantisation above all — is carried in `Int64`, the
// one place a 32-bit port silently wraps. Sizes and shifts are `Int64`.

///|
/// `Clip3` of 5.6 on 32-bit carriers.
fn clip3(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn abs(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
/// `Floor(Log2(x))`, used for transform and prediction block sizes.
fn log2_int(n : Int32) -> Int32 {
  let mut k = 0
  let mut x = n
  while x > 1 {
    x = x >> 1
    k = k + 1
  }
  k
}
