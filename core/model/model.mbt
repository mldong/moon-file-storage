///|
/// `NotFound` is the one place where "the object is not there" is an error
/// instead of an answer: `get_file` returns `None`, `exists` and `delete` return
/// `false`. A copy or move names a source that has to exist, so absence there is
/// a failure the caller cannot proceed past — and both legs must raise it for the
/// same situation rather than one raising and the other returning quietly.
pub(all) suberror StorageError {
  InvalidInput(String)
  NotSupported(String)
  NotFound(String)
  Platform(String)
  Recorder(String)
}

///|
pub(all) struct HashInfo {
  md5 : String?
  sha1 : String?
  sha256 : String?
} derive(Eq, @json.ToJson, @json.FromJson)

///|
pub(all) struct FileInfo {
  id : String?
  url : String
  size : Int64?
  filename : String
  original_filename : String
  base_path : String
  path : String
  ext : String
  content_type : String?
  platform : String
  th_url : String?
  th_filename : String?
  th_size : Int64?
  th_content_type : String?
  object_id : String?
  object_type : String?
  metadata : Map[String, String]
  user_metadata : Map[String, String]
  th_metadata : Map[String, String]
  th_user_metadata : Map[String, String]
  attr : Map[String, Json]
  file_acl : Json?
  th_file_acl : Json?
  hash_info : HashInfo?
  upload_id : String?
  upload_status : String?
  create_time : Int64
} derive(Eq, @json.ToJson, @json.FromJson)

///|
pub(all) enum UploadSource {
  Bytes(Bytes)
  Path(String)
  Stream(&@io.Reader, Int64?)
}

///|
pub(all) struct FilePartInfo {
  platform : String
  upload_id : String
  part_number : Int32
  size : Int64
  etag : String
} derive(Eq, @json.ToJson, @json.FromJson)

///|
/// One page of the parts already uploaded under an `upload_id`. The marker is the
/// part number after which the next page would start, and `is_truncated` says
/// whether there is one — the same shape the S3 `ListParts` response has.
pub(all) struct PartPage {
  parts : Array[FilePartInfo]
  is_truncated : Bool
  next_part_number_marker : Int32?
}

///|
/// Which verb the presigned URL is meant for: `Get` hands a reader a URL that
/// needs no credentials, `Put` hands a client a URL it can upload to directly.
pub(all) enum PresignMethod {
  Get
  Put
}

///|
/// Self-report of what this storage family can do — the counterpart of the
/// reference framework's `isSupportXxx` gates. The flag answers "does this
/// storage have the family", not "will this call succeed": a platform that
/// reports `false` must refuse with `NotSupported` rather than accept and do
/// nothing, and one that reports `true` must really carry out the port call.
///
/// Of these seven flags, every one now has a place to be observed:
/// `@platform.Platform` carries methods for `list_files`, `multipart_upload`,
/// `presigned_url`, `acl`, `same_copy` and `same_move`, and the facade enforces
/// `metadata` at write time (an upload carrying user metadata against a storage
/// that reports `false` is refused rather than silently stripped).
pub(all) struct Capabilities {
  multipart_upload : Bool
  list_files : Bool
  presigned_url : Bool
  acl : Bool
  metadata : Bool
  same_copy : Bool
  same_move : Bool
}

///|
/// Canned ACL, the counterpart of the reference framework's
/// `CannedAccessControlList`. The reference takes an untyped `Object` and
/// converts it, returning `false` when the value cannot be understood; here an
/// un-understandable value cannot be built at all, so that `false` branch has no
/// place to occur. `header_value` is the wire form the object store expects in
/// `x-amz-acl`.
pub(all) enum CannedAcl {
  Private
  PublicRead
  PublicReadWrite
} derive(Eq)

///|
/// Which storage the copy/move goes through. Same name, same three档位 as the
/// reference framework's `Constant.CopyMode` / `Constant.MoveMode`:
/// `Auto` picks the platform's own copy when source and destination are the same
/// storage and that storage has the family, and otherwise falls back to the
/// general "read it, then upload it" path; `Same` demands the platform path and
/// reports a refusal when the storage does not have it; `Cross` never uses it.
pub(all) enum CopyMode {
  Auto
  Same
  Cross
} derive(Eq)

///|
pub(all) enum MoveMode {
  Auto
  Same
  Cross
} derive(Eq)

///|
/// The two values the reference framework keeps on a record while a multipart
/// upload is in flight (`Constant.FileInfoUploadStatus`, INITIATE = 1, COMPLETE =
/// 2). The names are the same; the encoding is the readable one, because this
/// library's rows are JSON lines rather than a column of another system's ints.
pub let upload_status_initiate = "INITIATE"

///|
pub let upload_status_complete = "COMPLETE"

///|
pub fn CannedAcl::header_value(self : CannedAcl) -> String {
  match self {
    Private => "private"
    PublicRead => "public-read"
    PublicReadWrite => "public-read-write"
  }
}

///|
/// One directory entry from `list_files`: `path` is the full key prefix (the
/// common prefix the store answered with), `name` is its last segment.
pub(all) struct ListedDir {
  path : String
  name : String
} derive(Eq)

///|
/// One object entry from `list_files`, single level only — a nested key shows up
/// under its directory, not flattened here.
pub(all) struct ListedFile {
  path : String
  name : String
  size : Int64
  last_modified : String?
  etag : String?
} derive(Eq)

///|
/// The one-level listing: `dirs` from the store's common prefixes, `files` from
/// its object summaries, and the continuation token for the next page when the
/// store truncated. Same split the reference framework's `ListFilesResult` uses.
pub(all) struct FileListing {
  dirs : Array[ListedDir]
  files : Array[ListedFile]
  is_truncated : Bool
  next_continuation_token : String?
}
