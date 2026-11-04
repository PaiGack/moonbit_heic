///|
/// Four-character box type, kept as a plain string.
///
/// `meta`, `pitm`, `iloc`, `iprp` … the container is a tree of these, and the
/// interesting ones are worth a name. Anything else stays textual until M1
/// has a reason to branch on it.
pub type BoxType = String

///|
/// Version and flags of a box, read as two big-endian values.
pub(all) struct FullBoxHeader {
  version : Int32
  flags : Int32
}

///|
/// Read the 4-byte version + flags word that follows the header of a full box.
pub fn read_full_box_header(version_and_flags : UInt32) -> FullBoxHeader {
  {
    version: (version_and_flags >> 24).reinterpret_as_int(),
    flags: (version_and_flags & 0x00FFFFFFU).reinterpret_as_int(),
  }
}
