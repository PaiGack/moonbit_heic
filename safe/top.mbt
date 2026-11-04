///|
/// Error of an arithmetic step that the input makes meaningless: a zero
/// divisor, a negative count, a shift the 64-bit carrier cannot hold.
///
/// Note what is *not* here any more: a 32-bit range check. Everything wide is
/// carried as `Int64` from the start, so "the result does not fit in `Int`" is
/// no longer a runtime question — it is a question about whether the choice of
/// `Int64` was right, and that is decided by the types, not by a guard.
pub(all) suberror Overflow

///|
/// Widest value a 32-bit `Int` survives a round trip through. Kept for the
/// genuinely 32-bit fields that `narrow` / `clamp` guard.
pub let int_max : Int64 = 2147483647L

///|
/// Narrowest value a 32-bit `Int` survives a round trip through.
pub let int_min : Int64 = -2147483648L

///|
/// Widest value an `Int64` survives a round trip through.
pub let int64_max : Int64 = 9223372036854775807L

///|
/// Narrowest value an `Int64` survives a round trip through.
pub let int64_min : Int64 = -9223372036854775808L
