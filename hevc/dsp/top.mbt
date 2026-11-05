// The DSP layer of M3: the coefficient scan orders and the inverse transform
// bases that residual decoding and reconstruction read. Every function here
// is pure and small enough to hold against the upstream Go unit tests, which
// is the point of keeping them in their own package: a bit wrong here corrupts
// every pixel above it, and there is no picture to look at until CTU lands.

///|
/// The three scan orders of 6.5, indexed as the upstream does.
pub let scan_diag : Int32 = 0

///|
pub let scan_hor : Int32 = 1

///|
pub let scan_ver : Int32 = 2

///|
pub let n_scan_orders : Int32 = 3

///|
/// Largest log2 block size the scan tables are built for (32x32).
pub let max_scan_log2 : Int32 = 5

///|
/// A position in a coefficient block.
pub(all) struct ScanPos {
  x : Int32
  y : Int32
}

///|
/// `buildDiagScan(size)` of 6.5: walk anti-diagonals, up and to the right
/// within each one. The x/y are packed as one byte each so a scan table is a
/// flat Bytes of `size*size` pairs.
fn build_diag_scan(size : Int32) -> Bytes {
  let out : Array[Byte] = []
  for d in 0..<(2 * size - 1) {
    let y_start = if d < size { d } else { size - 1 }
    let y_end = if d < size { 0 } else { d - size + 1 }
    let mut y = y_start
    while y >= y_end {
      out.push((d - y).to_byte())
      out.push(y.to_byte())
      y = y - 1
    }
  }
  Bytes::from_array(out)
}

///|
/// `buildHorScan(size)`: rows top to bottom, columns left to right.
fn build_hor_scan(size : Int32) -> Bytes {
  let out : Array[Byte] = []
  for y in 0..<size {
    for x in 0..<size {
      out.push(x.to_byte())
      out.push(y.to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
/// `buildVerScan(size)`: columns left to right, rows top to bottom. The
/// transpose of the horizontal order.
fn build_ver_scan(size : Int32) -> Bytes {
  let out : Array[Byte] = []
  for x in 0..<size {
    for y in 0..<size {
      out.push(x.to_byte())
      out.push(y.to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
/// `scanOrder[log2][scanIdx]` as flat Bytes, built at package initialisation
/// exactly once, the way the Go `init` does. Each entry is an (x, y) pair.
let scan_tables : Array[Bytes] = build_scan_tables()

///|
fn build_scan_tables() -> Array[Bytes] {
  let out : Array[Bytes] = []
  for k in 0..<=max_scan_log2 {
    let size = 1 << k
    out.push(build_diag_scan(size))
    out.push(build_hor_scan(size))
    out.push(build_ver_scan(size))
  }
  out
}

///|
/// The number of positions in a scan for a log2 block size and order.
pub fn scan_len(log2 : Int32, order : Int32) -> Int32 {
  let _ = order
  1 << (2 * log2)
}

///|
/// The `(x, y)` at position `i` of `scanOrder[log2][order]`. Out-of-range
/// indices are reported as `None` rather than reading a neighbouring table:
/// a corrupt last-significant-coeff position must not turn into a trap.
pub fn scan_pos(log2 : Int32, order : Int32, i : Int32) -> ScanPos? {
  if log2 < 0 ||
    log2 > max_scan_log2 ||
    order < 0 ||
    order >= n_scan_orders ||
    i < 0 ||
    i >= scan_len(log2, order) {
    return None
  }
  let table = scan_tables[log2 * n_scan_orders + order]
  Some({ x: table[2 * i].to_int(), y: table[2 * i + 1].to_int(), })
}

///|
/// Sign-extend one int8 basis value stored as a raw byte.
fn sign_extend(b : Byte) -> Int32 {
  let v = b.to_int()
  if v >= 128 {
    v - 256
  } else {
    v
  }
}

///|
/// `transMatrix[row][col]` of Table 9-4, sign-extended. `row`/`col` are in
/// 0..32; out-of-range returns None so a caller composing a basis cannot
/// silently read the next row.
pub fn trans_matrix(row : Int32, col : Int32) -> Int32? {
  if row < 0 || row >= 32 || col < 0 || col >= 32 {
    return None
  }
  Some(sign_extend(trans_matrix_bytes[row * 32 + col]))
}

///|
/// `dstMatrix[row][col]` of 8.6.4.1, the 4x4 DST basis.
pub fn dst_matrix(row : Int32, col : Int32) -> Int32? {
  if row < 0 || row >= 4 || col < 0 || col >= 4 {
    return None
  }
  Some(sign_extend(dst_matrix_bytes[row * 4 + col]))
}

///|
/// `naive1D` of 8.6.4.2 as the sum it is defined as: out[i] is the dot of
/// input with basis row `i*stride` where `stride = 32/n`. This is the
/// reference the fast butterfly is checked against; keeping it here means the
/// transform layer has a byte-exact definition even before the butterfly is
/// ported. `n` is one of 4, 8, 16, 32.
pub fn naive_1d(in_ : Array[Int32], n : Int32) -> Array[Int32] {
  let stride = 32 / n
  let out : Array[Int32] = Array::make(n, 0)
  for i in 0..<n {
    let mut v = 0
    for j in 0..<n {
      v += trans_matrix(j * stride, i).unwrap() * in_[j]
    }
    out[i] = v
  }
  out
}

///|
/// The 1D IDST of 8.6.4.1 for a 4-point block, written as its defining sum.
pub fn naive_1d_dst4(in_ : Array[Int32]) -> Array[Int32] {
  let out : Array[Int32] = Array::make(4, 0)
  for i in 0..<4 {
    let mut v = 0
    for j in 0..<4 {
      v += dst_matrix(j, i).unwrap() * in_[j]
    }
    out[i] = v
  }
  out
}
