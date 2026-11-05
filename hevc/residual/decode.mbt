// The residual_coding syntax of 7.3.8.11. Every bin is read through the
// byte-exact checked @cabac.Decoder; the scan orders come from @dsp.scan_pos.
// Sizes are log2 block sizes (2..5), sub-block counts and 4x4 coordinates,
// all structurally small, so Int32 is the carrier throughout. Coefficient
// levels are Int32 (the width of TransCoeffLevel).
//
// Malformed streams are returned as Err(ResidualError), never as an
// unchecked array index or a trap (Issue M3: "越界必须可见").

///|
/// Why a residual block could not be decoded, as a value for the caller.
pub(all) enum ResidualError {
  /// `log2_size` outside 2..5, `c_idx` outside 0..2, or a coef array whose
  /// length is not `1 << (2*log2_size)`.
  InvalidBlock
  /// A context index the arithmetic decoder refused, or a short stream.
  BadBin
  /// The last significant coefficient lies outside the block, or the reverse
  /// scan could not find its sub-block.
  InvalidLastSignificant
}

///|
/// Wrap the CABAC decoder's raised errors as ResidualError values. Every bin
/// read goes through these, so a bad context or bypass count is a returned
/// Err rather than a trap.
fn decode_bin(c : @cabac.Decoder, ctx : Int32) -> Result[Int32, ResidualError] {
  Ok(c.decode_bin(ctx)) catch {
    _ => Err(BadBin)
  }
}

///|
fn decode_bypass_bits(
  c : @cabac.Decoder,
  n : Int32,
) -> Result[UInt32, ResidualError] {
  Ok(c.decode_bypass_bits(n)) catch {
    _ => Err(BadBin)
  }
}

///|
/// A transform block whose residual syntax is about to be decoded.
pub(all) struct ResidualBlock {
  log2_size : Int32
  c_idx : Int32
  pred_mode_intra : Int32
  intra : Bool
  transquant_bypass : Bool
  /// `log2_max_transform_skip_size` of the PPS; zero when the tool is off.
  max_transform_skip_size : Int32
}

///|
/// Per-picture switches the syntax reads (all fixed for Main 8-bit 4:2:0
/// non-extended, but kept explicit so a corrupt header cannot drive an
/// out-of-range index).
pub(all) struct ResidualParams {
  /// `persistent_rice_adaptation_enabled_flag`.
  persistent_rice_adaptation : Bool
  /// `ChromaArrayType` (1 for 4:2:0).
  chroma_array_type : Int32
  /// `sps.coeffRange(cIdx)`; zero when extended precision is off.
  coeff_range : Int32
  /// `sign_data_hiding_enabled_flag`.
  sign_data_hiding : Bool
  /// `transform_skip_enabled_flag`.
  transform_skip_enabled : Bool
  /// `transform_skip_context_enabled_flag`.
  transform_skip_context : Bool
}

///|
pub fn ResidualParams::main_420_8bit() -> ResidualParams {
  {
    persistent_rice_adaptation: false,
    chroma_array_type: 1,
    coeff_range: 0,
    sign_data_hiding: false,
    transform_skip_enabled: false,
    transform_skip_context: false,
  }
}

///|
/// Truncated Rice prefix of the last-significant-coefficient position
/// (9.3.3.2 with the context derivation of 9.3.4.2.3).
fn last_sig_coeff_prefix(
  c : @cabac.Decoder,
  base : Int32,
  log2_size : Int32,
  c_idx : Int32,
) -> Result[Int32, ResidualError] {
  let c_max = log2_size * 2 - 1
  let mut v = 0
  while v < c_max {
    let bin = match
      decode_bin(c, base + last_sig_coeff_ctx(log2_size, c_idx, v)) {
      Ok(x) => x
      Err(_) => return Err(BadBin)
    }
    if bin == 0 {
      break
    }
    v += 1
  }
  Ok(v)
}

///|
fn last_sig_coeff_suffix(
  c : @cabac.Decoder,
  prefix : Int32,
) -> Result[Int32, ResidualError] {
  if prefix <= 3 {
    return Ok(prefix)
  }
  let n = (prefix >> 1) - 1
  let suffix = match decode_bypass_bits(c, n) {
    Ok(x) => x
    Err(_) => return Err(BadBin)
  }
  Ok((1 << n) * (2 + (prefix & 1)) + suffix.reinterpret_as_int())
}

///|
/// `coeff_abs_level_remaining` of 9.3.3.11 (the limited form when
/// `rng > 0`). All bypass bits, so no context modelling is involved.
fn coeff_abs_level_remaining(
  c : @cabac.Decoder,
  rice : Int32,
  rng : Int32,
) -> Result[Int32, ResidualError] {
  let limit = if rng > 0 { 32 - rng } else { 32 }
  let mut prefix = 0
  while prefix < limit {
    if c.decode_bypass() == 0 {
      break
    }
    prefix += 1
  }
  if prefix < 3 {
    return match decode_bypass_bits(c, rice) {
      Ok(bits) => Ok((prefix << rice) + bits.reinterpret_as_int())
      Err(_) => Err(BadBin)
    }
  }
  let k = prefix - 3
  let base = ((1 << k) + 2) << rice
  if rng > 0 && prefix == limit {
    return match decode_bypass_bits(c, rng) {
      Ok(bits) => Ok(base + bits.reinterpret_as_int())
      Err(_) => Err(BadBin)
    }
  }
  match decode_bypass_bits(c, k + rice) {
    Ok(bits) => Ok(base + bits.reinterpret_as_int())
    Err(_) => Err(BadBin)
  }
}

///|
fn min(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn any_true_except0(v : Array[Bool]) -> Bool {
  for i in 1..<v.length() {
    if v[i] {
      return true
    }
  }
  false
}

///|
/// `residualState` of 9.3.4.2.6: the greater1 context carries across the
/// sub-blocks of one transform block.
priv struct ResidualState {
  mut started : Bool
  mut greater1_ctx : Int32
  mut last_greater1 : Bool
}

///|
/// Look up a scan position, reporting a corrupt scan table as a value.
fn scan_xy(
  log2 : Int32,
  order : Int32,
  i : Int32,
) -> Result[(Int32, Int32), ResidualError] {
  match @dsp.scan_pos(log2, order, i) {
    Some(s) => Ok((s.x, s.y))
    None => Err(InvalidLastSignificant)
  }
}

///|
/// `decode_residual` of 7.3.8.11, scaled in place: `coef` receives the
/// transform coefficient levels in raster order and must be zeroed by the
/// caller. `stat_coeff` is the persistent-Rice adaptation state (unused for
/// the Main 8-bit 4:2:0 default, but threaded so the layer is complete).
///
/// Returns `transformSkip` for the caller's inverse-transform decision, or a
/// ResidualError for a malformed stream.
pub fn decode_residual(
  c : @cabac.Decoder,
  coef : Array[Int32],
  b : ResidualBlock,
  p : ResidualParams,
  stat_coeff : Array[Int32],
) -> Result[Bool, ResidualError] {
  let log2 = b.log2_size
  if log2 < 2 || log2 > 5 || b.c_idx < 0 || b.c_idx > 2 {
    return Err(InvalidBlock)
  }
  let n = 1 << log2
  if coef.length() != n * n {
    return Err(InvalidBlock)
  }

  // transform_skip_flag (only read when the tool is enabled).
  let mut transform_skip = false
  if p.transform_skip_enabled &&
    !b.transquant_bypass &&
    log2 <= b.max_transform_skip_size {
    match decode_bin(c, 47 + min(b.c_idx, 1)) {
      Ok(bin) => transform_skip = bin != 0
      Err(_) => return Err(BadBin)
    }
  }
  // 9.3.4.2.5 gives a transform-skip block one significance context.
  let flat_ctx = p.transform_skip_context &&
    (transform_skip || b.transquant_bypass)

  let scan_idx = scan_index(
    log2,
    b.c_idx,
    b.pred_mode_intra,
    b.intra,
    p.chroma_array_type,
  )
  let x_prefix = match last_sig_coeff_prefix(c, ctx_last_sig_x, log2, b.c_idx) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let y_prefix = match last_sig_coeff_prefix(c, ctx_last_sig_y, log2, b.c_idx) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let mut last_x = match last_sig_coeff_suffix(c, x_prefix) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let mut last_y = match last_sig_coeff_suffix(c, y_prefix) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if scan_idx == scan_ver {
    let t = last_x
    last_x = last_y
    last_y = t
  }
  if last_x >= n || last_y >= n {
    return Err(InvalidLastSignificant)
  }

  // Reverse-scan for the sub-block / position holding the last coefficient.
  let sb_log2 = log2 - 2
  let sb_len = @dsp.scan_len(sb_log2, scan_idx)
  let mut last_sub_block = sb_len - 1
  let mut last_scan_pos = 16
  let mut found = false
  while last_sub_block >= 0 {
    if last_scan_pos == 0 {
      last_scan_pos = 16
      last_sub_block -= 1
      if last_sub_block < 0 {
        break
      }
    }
    last_scan_pos -= 1
    let (sx, sy) = match scan_xy(sb_log2, scan_idx, last_sub_block) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let (qx, qy) = match scan_xy(2, scan_idx, last_scan_pos) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if sx * 4 + qx == last_x && sy * 4 + qy == last_y {
      found = true
      break
    }
  }
  if !found {
    return Err(InvalidLastSignificant)
  }

  let csbf : Array[Bool] = Array::make(64, false)
  let st : ResidualState = {
    started: false,
    greater1_ctx: 0,
    last_greater1: false,
  }
  let sb_width = 1 << sb_log2
  let sig : Array[Bool] = Array::make(16, false)

  let mut i = last_sub_block
  while i >= 0 {
    let (x_s, y_s) = match scan_xy(sb_log2, scan_idx, i) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let csbf_idx = y_s * sb_width + x_s
    let mut infer_sb_dc_sig = false
    if i < last_sub_block && i > 0 {
      let mut ctx = 0
      if x_s + 1 < sb_width && csbf[y_s * sb_width + x_s + 1] {
        ctx += 1
      }
      if y_s + 1 < sb_width && csbf[(y_s + 1) * sb_width + x_s] {
        ctx += 1
      }
      let base = ctx_sig_group + (if b.c_idx > 0 { 2 } else { 0 })
      match decode_bin(c, base + min(ctx, 1)) {
        Ok(bin) => csbf[csbf_idx] = bin != 0
        Err(_) => return Err(BadBin)
      }
      infer_sb_dc_sig = true
    } else {
      csbf[csbf_idx] = true
    }
    if !csbf[csbf_idx] {
      i -= 1
      continue
    }

    let mut prev_csbf = 0
    if x_s + 1 < sb_width && csbf[y_s * sb_width + x_s + 1] {
      prev_csbf += 1
    }
    if y_s + 1 < sb_width && csbf[(y_s + 1) * sb_width + x_s] {
      prev_csbf += 2
    }
    let mut start = 15
    if i == last_sub_block {
      start = last_scan_pos - 1
    }
    for k in 0..<16 {
      sig[k] = false
    }
    if i == last_sub_block {
      sig[last_scan_pos] = true
    }
    let sig_set = SigCtxSet::new(
      x_s,
      y_s,
      log2,
      b.c_idx,
      scan_idx,
      prev_csbf,
      flat_ctx,
    )
    let mut k = start
    while k >= 0 {
      if k == 0 && infer_sb_dc_sig && !any_true_except0(sig) {
        sig[0] = true
        k -= 1
        continue
      }
      let (x, y) = match scan_xy(2, scan_idx, k) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let ctx = sig_set.at(x, y)
      match decode_bin(c, ctx_sig_flag + ctx) {
        Ok(bin) => sig[k] = bin != 0
        Err(_) => return Err(BadBin)
      }
      k -= 1
    }
    match
      decode_sub_block_levels(
        c, coef, b, p, sig, i, n, x_s, y_s, scan_idx, stat_coeff, st,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    i -= 1
  }
  Ok(transform_skip)
}

///|
/// The three level passes of 7.3.8.11 for one 4x4 sub-block (greater1,
/// greater2, sign hiding, remaining levels), visiting only significant
/// coefficients.
fn decode_sub_block_levels(
  c : @cabac.Decoder,
  coef : Array[Int32],
  b : ResidualBlock,
  p : ResidualParams,
  sig : Array[Bool],
  sub_block : Int32,
  n : Int32,
  x_s : Int32,
  y_s : Int32,
  scan_idx : Int32,
  stat_coeff : Array[Int32],
  st : ResidualState,
) -> Result[Unit, ResidualError] {
  let mut ctx_set = 0
  if sub_block > 0 && b.c_idx == 0 {
    ctx_set = 2
  }
  let mut last_ctx = 1
  if st.started {
    last_ctx = st.greater1_ctx
    if last_ctx > 0 {
      last_ctx = if st.last_greater1 { 0 } else { last_ctx + 1 }
    }
  }
  if last_ctx == 0 {
    ctx_set += 1
  }
  st.started = true

  // Gather significant positions once, highest scan index first.
  let pos : Array[Int32] = []
  let mut k = 15
  while k >= 0 {
    if sig[k] {
      pos.push(k)
    }
    k -= 1
  }
  if pos.length() == 0 {
    return Ok(())
  }
  let first_sig = pos[pos.length() - 1]
  let last_sig = pos[0]

  let greater1 : Array[Bool] = Array::make(16, false)
  let mut last_greater1 = -1
  let mut num_greater1 = 0
  let mut greater1_ctx = 1
  for kk in pos {
    if num_greater1 < 8 {
      let mut ctx = ctx_set * 4 + min(3, greater1_ctx)
      if b.c_idx > 0 {
        ctx += 16
      }
      let bin = match decode_bin(c, ctx_greater1 + ctx) {
        Ok(x) => x
        Err(_) => return Err(BadBin)
      }
      greater1[kk] = bin != 0
      num_greater1 += 1
      st.greater1_ctx = greater1_ctx
      st.last_greater1 = bin != 0
      if greater1[kk] {
        greater1_ctx = 0
        if last_greater1 < 0 {
          last_greater1 = kk
        }
      } else if greater1_ctx > 0 {
        greater1_ctx += 1
      }
    }
  }
  let mut greater2 = false
  if last_greater1 >= 0 {
    let ctx = ctx_set + (if b.c_idx > 0 { 4 } else { 0 })
    match decode_bin(c, ctx_greater2 + ctx) {
      Ok(bin) => greater2 = bin != 0
      Err(_) => return Err(BadBin)
    }
  }

  let sign_hidden = last_sig - first_sig > 3 && !b.transquant_bypass
  let signs : Array[Bool] = Array::make(16, false)
  for kk in pos {
    if p.sign_data_hiding && sign_hidden && kk == first_sig {
      continue
    }
    signs[kk] = c.decode_bypass() != 0
  }

  let mut rice = 0
  let stat_idx = if b.c_idx == 0 { 0 } else { 2 }
  if p.persistent_rice_adaptation {
    rice = stat_coeff[stat_idx] / 4
  }
  let mut num_sig = 0
  let mut sum_abs = 0
  let mut first_remaining = true
  for kk in pos {
    let mut base = 1
    if greater1[kk] {
      base += 1
    }
    if kk == last_greater1 && greater2 {
      base += 1
    }
    let mut want = 1
    if num_sig < 8 {
      want = 2
      if kk == last_greater1 {
        want = 3
      }
    }
    let mut level = base
    if base == want {
      let rem = match coeff_abs_level_remaining(c, rice, p.coeff_range) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      level = base + rem
      if p.persistent_rice_adaptation && first_remaining {
        let s = stat_coeff[stat_idx]
        if rem >= 3 << (s / 4) {
          stat_coeff[stat_idx] = s + 1
        } else if 2 * rem < 1 << (s / 4) && s > 0 {
          stat_coeff[stat_idx] = s - 1
        }
        first_remaining = false
      }
      if level > 3 << rice {
        rice = min(rice + 1, 4)
      }
    }
    sum_abs += level
    if signs[kk] {
      level = -level
    }
    if p.sign_data_hiding && sign_hidden && kk == first_sig && sum_abs % 2 == 1 {
      level = -level
    }
    let (x, y) = match scan_xy(2, scan_idx, kk) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let x_c = x_s * 4 + x
    let y_c = y_s * 4 + y
    coef[y_c * n + x_c] = level
    num_sig += 1
  }
  Ok(())
}
