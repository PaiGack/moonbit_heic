///|
/// Error of an arithmetic step that would overflow the 32-bit `Int` that
/// MoonBit uses on every backend.
///
/// The upstream Go implementation computes in 64-bit `int` and never worries
/// about this; a port that keeps the same expressions silently wraps here.
/// Everything in this package turns that wrap into a reported error instead.
pub(all) suberror Overflow

///|
/// Widest value that survives a round trip through `Int`.
pub let int_max : Int64 = 2147483647L

///|
/// Narrowest value that survives a round trip through `Int`.
pub let int_min : Int64 = -2147483648L
