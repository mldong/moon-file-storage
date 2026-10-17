///|
// A platform that claims the multipart, presigned and copy/move families absent.
// The object family is delegated to the real local filesystem, so the shared
// contract still runs its object cases here — only the three new families take
// their `false` branch. Without this leg, "a `false` claim must be refused" would
// never be executed by any caller: both real platforms claim `true`.

///|
struct RefusingPlatform {
  inner : @local.LocalPlatform
}

///|
pub impl @platform.Platform for RefusingPlatform with fn name(self) -> String {
  self.inner.name()
}

///|
pub impl @platform.Platform for RefusingPlatform with fn capabilities(_self) -> @model.Capabilities {
  @model.Capabilities::{
    multipart_upload: false,
    list_files: false,
    presigned_url: false,
    acl: false,
    metadata: false,
    same_copy: false,
    same_move: false,
  }
}

///|
pub impl @platform.Platform for RefusingPlatform with fn save(
  self,
  info : @model.FileInfo,
  source : @model.UploadSource,
) -> @model.FileInfo? raise @model.StorageError {
  self.inner.save(info, source)
}

///|
pub impl @platform.Platform for RefusingPlatform with fn get_file(
  self,
  url : String,
) -> @model.FileInfo? raise @model.StorageError {
  self.inner.get_file(url)
}

///|
pub impl @platform.Platform for RefusingPlatform with fn exists(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  self.inner.exists(info)
}

///|
pub impl @platform.Platform for RefusingPlatform with fn delete(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  self.inner.delete(info)
}

///|
pub impl @platform.Platform for RefusingPlatform with fn download(
  self,
  info : @model.FileInfo,
  writer : &@io.Writer,
) -> Unit raise @model.StorageError {
  self.inner.download(info, writer)
}

///|
/// Every family method refuses **before** looking at its arguments: a platform
/// that validated the key first would answer `InvalidInput` and the contract
/// would never see the refusal it is supposed to prove.
pub impl @platform.Platform for RefusingPlatform with fn init_multipart(
  self,
  _info : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  raise NotSupported(self.name() + " has no multipart upload")
}

///|
pub impl @platform.Platform for RefusingPlatform with fn upload_part(
  self,
  _info : @model.FileInfo,
  _part_number : Int32,
  _source : @model.UploadSource,
) -> @model.FilePartInfo raise @model.StorageError {
  raise NotSupported(self.name() + " has no multipart upload")
}

///|
pub impl @platform.Platform for RefusingPlatform with fn list_parts(
  self,
  _info : @model.FileInfo,
  _part_number_marker : Int32,
) -> @model.PartPage raise @model.StorageError {
  raise NotSupported(self.name() + " has no multipart upload")
}

///|
pub impl @platform.Platform for RefusingPlatform with fn complete_multipart(
  self,
  _info : @model.FileInfo,
  _parts : Array[@model.FilePartInfo],
) -> @model.FileInfo raise @model.StorageError {
  raise NotSupported(self.name() + " has no multipart upload")
}

///|
pub impl @platform.Platform for RefusingPlatform with fn abort_multipart(
  self,
  _info : @model.FileInfo,
) -> Unit raise @model.StorageError {
  raise NotSupported(self.name() + " has no multipart upload")
}

///|
pub impl @platform.Platform for RefusingPlatform with fn presigned_url(
  self,
  _info : @model.FileInfo,
  _method : @model.PresignMethod,
  _expires_seconds : Int32,
) -> String raise @model.StorageError {
  raise NotSupported(self.name() + " signs nothing")
}

///|
pub impl @platform.Platform for RefusingPlatform with fn same_copy(
  self,
  _src : @model.FileInfo,
  _dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  raise NotSupported(self.name() + " cannot copy on platform")
}

///|
pub impl @platform.Platform for RefusingPlatform with fn same_move(
  self,
  _src : @model.FileInfo,
  _dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  raise NotSupported(self.name() + " cannot move on platform")
}

///|
pub impl @platform.Platform for RefusingPlatform with fn list_files(
  self,
  _path : String,
  _filename_prefix : String,
  _marker : String?,
) -> @model.FileListing raise @model.StorageError {
  raise NotSupported(self.name() + " cannot list files")
}

///|
pub impl @platform.Platform for RefusingPlatform with fn set_file_acl(
  self,
  _info : @model.FileInfo,
  _acl : @model.CannedAcl,
) -> Unit raise @model.StorageError {
  raise NotSupported(self.name() + " has no object ACL")
}

///|
pub impl @platform.Platform for RefusingPlatform with fn close(self) -> Unit {
  self.inner.close()
}

///|
pub extend RefusingPlatform with @platform.Platform::{
  name,
  capabilities,
  save,
  get_file,
  exists,
  delete,
  download,
  init_multipart,
  upload_part,
  list_parts,
  complete_multipart,
  abort_multipart,
  presigned_url,
  same_copy,
  same_move,
  list_files,
  set_file_acl,
  close,
}

///|
async test "a platform claiming the families absent is refused step by step" {
  let root = @fs.tmpdir(prefix="moonfs-contract-refuse") catch {
    error => fail("tmpdir: " + error.to_string())
  }
  let domain = "https://refuse.contract.invalid"
  let inner = @local.LocalPlatform::new(@local.LocalConfig::{
    platform: "refusing-1",
    root_dir: root,
    domain,
    base_path: "uploads",
  })
  let platform = RefusingPlatform::{ inner, }
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root + "/records",
  })
  let service = @storage.Service::new([platform], recorder)
  @contract.run_contract(@contract.Fixture::{
    label: "refusing",
    platform: "refusing-1",
    base_path: "uploads",
    domain,
    service,
    recorder,
    port: platform,
    presigned_markers: [],
  })
  // Refusing must also mean "did nothing": the object family cleaned up after
  // itself, and no session directory or signed URL was ever produced.
  let left = @fs.readdir(root + "/uploads") catch {
    error => fail("readdir " + root + "/uploads: " + error.to_string())
  }
  let _ = @fs.rmdir(root, recursive=true) catch {
    error => println("cleanup " + root + " raised " + error.to_string())
  }
  assert_eq(left.length(), 0)
}
