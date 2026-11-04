///|
/// PNG encoding lands in M4.
///
/// The encoder itself is small; what this package owns in M0 is the PNG
/// signature, which is the one piece of the format every later test will
/// assert against.
pub suberror NotYetImplemented

///|
/// The eight bytes every PNG stream starts with.
pub let signature : Bytes = b"\x89PNG\r\n\x1a\n"

///|
/// Whether `data` starts with the PNG signature.
pub fn has_signature(data : Bytes) -> Bool {
  guard data.length() >= 8 else { return false }
  for i in 0..<8 {
    guard data[i] == signature[i] else { return false }
  }
  true
}
