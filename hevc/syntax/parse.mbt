// CTU-level CABAC syntax elements, 7.3.8.2..7.3.8.10. Each function parses
// exactly one element from a validated @cabac.Decoder and returns a Result,
// so a malformed stream is a value the caller can match rather than a trap.
// The writer side is the real upstream Go cabacWriter and the reader side the
// real upstream ctuDecoder; golden.mbt holds the exact bitstreams and the
// values they decode to, cross-checked by tools/crosscheck_syntax.mjs.

///|
/// 7.3.8.5: prev_intra_luma_pred_flag + mpm_idx / rem_intra_luma_pred_mode.
/// `cand` is the three MPM candidates from mpm_cand (8.4.2). Returns the
/// luma intra prediction mode in 0..34.
pub fn decode_intra_luma_mode(
  c : @cabac.Decoder,
  cand : Array[Int32],
) -> Result[Int32, SyntaxError] {
  guard cand.length() == 3 else { Err(InvalidParam) }
  let prev = match decode_bin(c, ctx_prev_intra_luma_pred_flag) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if prev != 0 {
    let mut idx = 0
    if c.decode_bypass() != 0 {
      idx = 1
      if c.decode_bypass() != 0 {
        idx = 2
      }
    }
    return Ok(cand[idx])
  }
  // Sort the three candidates, then bump rem past each one it reaches.
  let sorted : Array[Int32] = [cand[0], cand[1], cand[2]]
  if sorted[0] > sorted[1] {
    let t = sorted[0]
    sorted[0] = sorted[1]
    sorted[1] = t
  }
  if sorted[0] > sorted[2] {
    let t = sorted[0]
    sorted[0] = sorted[2]
    sorted[2] = t
  }
  if sorted[1] > sorted[2] {
    let t = sorted[1]
    sorted[1] = sorted[2]
    sorted[2] = t
  }
  let bits = match decode_bypass_bits(c, 5) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let mut mode = bits.reinterpret_as_int()
  for m in sorted {
    if mode >= m {
      mode += 1
    }
  }
  Ok(mode)
}

///|
/// 7.3.8.5 / Table 8-2: intra_chroma_pred_mode. A zero flag means the chroma
/// mode equals the luma mode; otherwise a 2-bit index selects one of the four
/// defaults, with mode 34 substituting a collision. chroma_format_idc = 2
/// applies the 4:2:2 remap of Table 8-3.
pub fn decode_intra_chroma_mode(
  c : @cabac.Decoder,
  luma : Int32,
  chroma_format_idc : Int32,
) -> Result[Int32, SyntaxError] {
  let mut mode = luma
  let flag = match decode_bin(c, ctx_intra_chroma_pred_mode) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if flag != 0 {
    let bits = match decode_bypass_bits(c, 2) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let idx = bits.reinterpret_as_int()
    let table = [intra_planar, intra_ver, intra_hor, intra_dc]
    mode = table[idx]
    if mode == luma {
      mode = 34
    }
  }
  if chroma_format_idc == 2 {
    let mapped = match chroma422(mode) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    mode = mapped
  }
  Ok(mode)
}

///|
/// 7.3.8.9 / 9.3.3.10: cu_qp_delta_abs and cu_qp_delta_sign_flag. The prefix
/// is up to five unary bins at ctxCUQPDelta+{0,1}, then an Exp-Golomb suffix
/// of k bypass bins, then one sign bit. Returns the signed delta.
pub fn decode_cu_qp_delta(c : @cabac.Decoder) -> Result[Int32, SyntaxError] {
  let mut prefix = 0
  for k in 0..<5 {
    let ctx = if k == 0 { 0 } else { 1 }
    let bin = match decode_bin(c, ctx_cu_qp_delta + ctx) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if bin == 0 {
      break
    }
    prefix += 1
  }
  let mut v = prefix
  if prefix > 4 {
    // Exp-Golomb: k leading ones (capped at 6), then k suffix bits. The
    // terminating zero is consumed by the loop, exactly as upstream does.
    let mut k = 0
    for _ in 0..<6 {
      if c.decode_bypass() != 0 {
        k += 1
      } else {
        break
      }
    }
    let bits = match decode_bypass_bits(c, k) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    v = 5 + (1 << k) - 1 + bits.reinterpret_as_int()
  }
  if v != 0 && c.decode_bypass() != 0 {
    v = -v
  }
  Ok(v)
}

///|
/// 7.3.8.10: cu_chroma_qp_offset_flag and cu_chroma_qp_offset_idx. A zero
/// flag leaves both offsets at zero; otherwise a truncated-Rice index selects
/// one entry out of the PPS lists. `len`, `cb_list`, `cr_list` are the PPS's
/// chroma_qp_offset_list_len and its two lists, all bounded by the header
/// parser. Returns (cb, cr).
pub fn decode_cu_chroma_qp_offset(
  c : @cabac.Decoder,
  len : Int32,
  cb_list : Array[Int32],
  cr_list : Array[Int32],
) -> Result[(Int32, Int32), SyntaxError] {
  guard len >= 1 else { Err(InvalidParam) }
  guard cb_list.length() >= len && cr_list.length() >= len else {
    Err(InvalidParam)
  }
  let flag = match decode_bin(c, ctx_cu_chroma_qp_offset_flag) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if flag == 0 {
    return Ok((0, 0))
  }
  let c_max = len - 1
  let mut idx = 0
  for _ in 0..<c_max {
    let bin = match decode_bin(c, ctx_cu_chroma_qp_offset_idx) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if bin == 0 {
      break
    }
    idx += 1
  }
  Ok((cb_list[idx], cr_list[idx]))
}

///|
/// 7.3.8.5: part_mode, intra branch. One bin: 1 => PART_2Nx2N (0), 0 =>
/// PART_NxN (3). Inter/AMP splits are out of scope for this I-frame port.
pub fn decode_part_mode_intra(c : @cabac.Decoder) -> Result[Int32, SyntaxError] {
  match decode_bin(c, ctx_part_mode) {
    Ok(v) => Ok(if v != 0 { 0 } else { 3 })
    Err(e) => Err(e)
  }
}

///|
/// A single syntax bin at a caller-derived context (split_cu_flag,
/// split_transform_flag, cbf_luma, cbf_cb/cr). The context index is validated
/// by the arithmetic decoder itself, so a bad one returns BadBin.
pub fn decode_flag(
  c : @cabac.Decoder,
  ctx : Int32,
) -> Result[Int32, SyntaxError] {
  decode_bin(c, ctx)
}

///|
/// Per-component SAO parameters of 7.3.8.3, the shape 8.7.3 applies.
pub(all) struct SaoParams {
  type_idx : Int32
  offset : Array[Int32]
  band : Int32
  class_ : Int32
}

///|
/// 7.3.8.3: SAO for one CTB. This covers the single-CTB, no-merge case the
/// upstream writer exercises; merge flags are the caller's (CTB geometry)
/// concern. Returns one SaoParams per component present (3 for 4:2:0).
///
/// `scale_luma` / `scale_chroma` are log2_sao_offset_scale from the PPS,
/// already bounded by the header parser. cIdx 2 shares cIdx 1's type and
/// edge class, as 7.4.9.3 requires.
pub fn decode_sao(
  c : @cabac.Decoder,
  bit_depth : Int32,
  scale_luma : Int32,
  scale_chroma : Int32,
  sao_luma : Bool,
  sao_chroma : Bool,
) -> Result[Array[SaoParams], SyntaxError] {
  let c_max = sao_offset_cmax(bit_depth)
  guard scale_luma >= 0 && scale_luma < 31 else { Err(InvalidParam) }
  guard scale_chroma >= 0 && scale_chroma < 31 else { Err(InvalidParam) }
  let sao_type : Array[Int32] = [0, 0, 0]
  let eo_class : Array[Int32] = [0, 0]
  let out : Array[SaoParams] = []
  for c_idx in 0..<3 {
    if c_idx == 0 && !sao_luma {
      out.push({ type_idx: 0, offset: [0, 0, 0, 0], band: 0, class_: 0, })
      continue
    }
    if c_idx > 0 && !sao_chroma {
      out.push({ type_idx: 0, offset: [0, 0, 0, 0], band: 0, class_: 0, })
      continue
    }
    let mut type_idx = 0
    if c_idx != 2 {
      let t = match decode_bin(c, ctx_sao_type_idx) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if t != 0 {
        type_idx = 1
        if c.decode_bypass() != 0 {
          type_idx = 2
        }
      }
      sao_type[c_idx] = type_idx
    } else {
      type_idx = sao_type[1]
    }
    if type_idx == 0 {
      out.push({ type_idx: 0, offset: [0, 0, 0, 0], band: 0, class_: 0, })
      continue
    }
    // Four unary sao_offset_abs magnitudes, each capped at cMax.
    let off_abs : Array[Int32] = []
    for _ in 0..<4 {
      let mut v = 0
      while v < c_max && c.decode_bypass() != 0 {
        v += 1
      }
      off_abs.push(v)
    }
    let scale = if c_idx > 0 { scale_chroma } else { scale_luma }
    let offset : Array[Int32] = [0, 0, 0, 0]
    let mut band = 0
    let mut class_ = 0
    if type_idx == 1 {
      // Band: sign bit per nonzero offset, then a 5-bit band position.
      for i in 0..<4 {
        offset[i] = off_abs[i] << scale
        if off_abs[i] != 0 && c.decode_bypass() != 0 {
          offset[i] = -offset[i]
        }
      }
      let bits = match decode_bypass_bits(c, 5) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      band = bits.reinterpret_as_int()
    } else {
      // Edge: offsets 2,3 are negative by position, then a 2-bit class.
      for i in 0..<4 {
        offset[i] = off_abs[i] << scale
        if i >= 2 {
          offset[i] = -offset[i]
        }
      }
      if c_idx != 2 {
        let bits = match decode_bypass_bits(c, 2) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        eo_class[c_idx] = bits.reinterpret_as_int()
      }
      class_ = eo_class[if c_idx < 1 { c_idx } else { 1 }]
    }
    out.push({ type_idx, offset, band, class_, })
  }
  Ok(out)
}
