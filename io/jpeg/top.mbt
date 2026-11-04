///|
/// JPEG encoding lands in M4, behind libjpeg-turbo semantics.
///
/// Only the marker constants live here so far: the HEIF path needs to know
/// whether the item it decoded was a JPEG-coded thumbnail or a grid of them.
pub suberror NotYetImplemented

///|
/// The two bytes that open a JPEG frame.
pub let soi : Array[Int32] = [0xFF, 0xD8]

///|
/// The two bytes that close it.
pub let eoi : Array[Int32] = [0xFF, 0xD9]

///|
/// Whether `data` starts with SOI and is at least a marker pair long.
pub fn has_soi(data : Bytes) -> Bool {
  guard data.length() >= 2 else { return false }
  data[0].to_int() == soi[0] && data[1].to_int() == soi[1]
}
