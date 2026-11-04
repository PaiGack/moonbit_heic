///|
/// Error of an ISOBMFF / HEIF structure that cannot be read.
pub suberror Invalid

///|
/// Error of a construct this port knows about but does not read yet.
pub suberror Unsupported

///|
/// An item linked to its picture by `thmb` when the file carries none.
pub suberror NoThumbnail

///|
/// Everything `heif` reports up front: a stream it cannot read, one it reads
/// only partly, and the absence of an optional part.
pub suberror HeifError {
  Invalid
  Unsupported
  NoThumbnail
}
