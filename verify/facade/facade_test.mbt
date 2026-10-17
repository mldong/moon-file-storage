///|
// 编排层的失败档，四腿给不出来的一档：**源删不掉时移动必须抛，且不回头删目标**。
//
// 这条需要一个"什么都答应、就是删不成"的平台：对象族与五族全部转给真实的 local，
// 只有 `delete` 回 false。走的必须是**跨平台那一支**（`MoveMode::Cross`）：同平台
// 那一支 `same_move` 已经把源文件搬走了，源在不在原地由那次移动决定，桩的 `delete`
// 回不回 false 根本没机会参与判断——本轮第一版就是这么写成了永真绿。
// 参考件 `MoveActuator` 的两支都是"源没删成就当移动失败"，本库把判据落在
// "源还在不在原地"上（原因写在门面注释里：hutool 的 del 对不存在的
// 路径回 true，直接照抄那条返回值判据会变成本库的永真红）。

///|
struct UndeletablePlatform {
  inner : @local.LocalPlatform
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn name(self) -> String {
  self.inner.name()
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn capabilities(_self) -> @model.Capabilities {
  // 声称支持 same_move：这一档要判的是"删源失败"，不是"这一族没有"。
  @model.Capabilities::{
    multipart_upload: true,
    list_files: true,
    presigned_url: false,
    acl: false,
    metadata: true,
    same_copy: true,
    same_move: true,
  }
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn save(
  self,
  info : @model.FileInfo,
  source : @model.UploadSource,
) -> @model.FileInfo? raise @model.StorageError {
  self.inner.save(info, source)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn get_file(
  self,
  url : String,
) -> @model.FileInfo? raise @model.StorageError {
  self.inner.get_file(url)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn exists(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  self.inner.exists(info)
}

///|
/// 唯一的差别：删不动。对象与它的字节都还在原地。
pub impl @platform.Platform for UndeletablePlatform with fn delete(
  _self,
  _info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  false
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn download(
  self,
  info : @model.FileInfo,
  writer : &@io.Writer,
) -> Unit raise @model.StorageError {
  self.inner.download(info, writer)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn init_multipart(
  self,
  info : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  self.inner.init_multipart(info)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn upload_part(
  self,
  info : @model.FileInfo,
  part_number : Int32,
  source : @model.UploadSource,
) -> @model.FilePartInfo raise @model.StorageError {
  self.inner.upload_part(info, part_number, source)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn list_parts(
  self,
  info : @model.FileInfo,
  part_number_marker : Int32,
) -> @model.PartPage raise @model.StorageError {
  self.inner.list_parts(info, part_number_marker)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn complete_multipart(
  self,
  info : @model.FileInfo,
  parts : Array[@model.FilePartInfo],
) -> @model.FileInfo raise @model.StorageError {
  self.inner.complete_multipart(info, parts)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn abort_multipart(
  self,
  info : @model.FileInfo,
) -> Unit raise @model.StorageError {
  self.inner.abort_multipart(info)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn presigned_url(
  self,
  info : @model.FileInfo,
  verb : @model.PresignMethod,
  expires_seconds : Int32,
) -> String raise @model.StorageError {
  self.inner.presigned_url(info, verb, expires_seconds)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn same_copy(
  self,
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  self.inner.same_copy(src, dest)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn same_move(
  self,
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  self.inner.same_move(src, dest)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn list_files(
  self,
  path : String,
  filename_prefix : String,
  marker : String?,
) -> @model.FileListing raise @model.StorageError {
  self.inner.list_files(path, filename_prefix, marker)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn set_file_acl(
  self,
  info : @model.FileInfo,
  acl : @model.CannedAcl,
) -> Unit raise @model.StorageError {
  self.inner.set_file_acl(info, acl)
}

///|
pub impl @platform.Platform for UndeletablePlatform with fn close(self) -> Unit {
  self.inner.close()
}

///|
pub extend UndeletablePlatform with @platform.Platform::{
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
fn describe(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(detail) => "InvalidInput: " + detail
    @model.StorageError::NotSupported(detail) => "NotSupported: " + detail
    @model.StorageError::NotFound(detail) => "NotFound: " + detail
    @model.StorageError::Platform(detail) => "Platform: " + detail
    @model.StorageError::Recorder(detail) => "Recorder: " + detail
  }
}

///|
async fn present_on_disk(path : String) -> Bool {
  @fs.exists(path) catch {
    _ => false
  }
}

///|

///|
// 第二条桩：声称"没有同平台复制/移动"，但端口那两个方法**真做得到**。
// 门面那条 `mode=Same` 的拒绝只有在这种平台上才判得出来——全声称没有的桩腿里，
// 端口自己也会抛 `NotSupported`，两道红叠成一道，摘掉门面的判断照样绿。
struct ReluctantPlatform {
  inner : @local.LocalPlatform
  copy_calls : @ref.Ref[Int32]
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn name(self) -> String {
  self.inner.name()
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn capabilities(_self) -> @model.Capabilities {
  @model.Capabilities::{
    multipart_upload: true,
    list_files: true,
    presigned_url: false,
    acl: false,
    metadata: true,
    same_copy: false,
    same_move: false,
  }
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn save(
  self,
  info : @model.FileInfo,
  source : @model.UploadSource,
) -> @model.FileInfo? raise @model.StorageError {
  self.inner.save(info, source)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn get_file(
  self,
  url : String,
) -> @model.FileInfo? raise @model.StorageError {
  self.inner.get_file(url)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn exists(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  self.inner.exists(info)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn delete(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  self.inner.delete(info)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn download(
  self,
  info : @model.FileInfo,
  writer : &@io.Writer,
) -> Unit raise @model.StorageError {
  self.inner.download(info, writer)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn init_multipart(
  self,
  info : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  self.inner.init_multipart(info)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn upload_part(
  self,
  info : @model.FileInfo,
  part_number : Int32,
  source : @model.UploadSource,
) -> @model.FilePartInfo raise @model.StorageError {
  self.inner.upload_part(info, part_number, source)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn list_parts(
  self,
  info : @model.FileInfo,
  part_number_marker : Int32,
) -> @model.PartPage raise @model.StorageError {
  self.inner.list_parts(info, part_number_marker)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn complete_multipart(
  self,
  info : @model.FileInfo,
  parts : Array[@model.FilePartInfo],
) -> @model.FileInfo raise @model.StorageError {
  self.inner.complete_multipart(info, parts)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn abort_multipart(
  self,
  info : @model.FileInfo,
) -> Unit raise @model.StorageError {
  self.inner.abort_multipart(info)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn presigned_url(
  self,
  info : @model.FileInfo,
  verb : @model.PresignMethod,
  expires_seconds : Int32,
) -> String raise @model.StorageError {
  self.inner.presigned_url(info, verb, expires_seconds)
}

///|
/// 声称没有这一族，被问到还是做得到——门面必须替调用方拦住"强制走这一族"的请求。
pub impl @platform.Platform for ReluctantPlatform with fn same_copy(
  self,
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  self.copy_calls.val = self.copy_calls.val + 1
  self.inner.same_copy(src, dest)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn same_move(
  self,
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  self.copy_calls.val = self.copy_calls.val + 1
  self.inner.same_move(src, dest)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn list_files(
  self,
  path : String,
  filename_prefix : String,
  marker : String?,
) -> @model.FileListing raise @model.StorageError {
  self.inner.list_files(path, filename_prefix, marker)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn set_file_acl(
  self,
  info : @model.FileInfo,
  acl : @model.CannedAcl,
) -> Unit raise @model.StorageError {
  self.inner.set_file_acl(info, acl)
}

///|
pub impl @platform.Platform for ReluctantPlatform with fn close(self) -> Unit {
  self.inner.close()
}

///|
pub extend ReluctantPlatform with @platform.Platform::{
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
async test "a forced same-platform call is refused before the port is asked" {
  let root = @fs.tmpdir(prefix="moonfs-facade-reluctant") catch {
    err => fail("tmpdir: " + err.to_string())
  }
  let _ = @fs.mkdir(root, recursive=true, allow_exist=true) catch {
    err => fail("mkdir: " + err.to_string())
  }
  let platform = ReluctantPlatform::{
    inner: @local.LocalPlatform::new(@local.LocalConfig::{
      platform: "reluctant-1",
      root_dir: root,
      domain: "https://reluctant.contract.invalid",
      base_path: "uploads",
    }),
    copy_calls: @ref.Ref(0),
  }
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root + "/records",
  })
  let service = @storage.Service::new([platform], recorder)
  let intent = @model.FileInfo::draft(
    "reluctant-1", "uploads", "one.txt", "txt",
  )
  let source = service.save(
    intent,
    @model.UploadSource::Bytes(@utf8.encode("reluctant payload")),
  ) catch {
    err => fail("save raised " + describe(err))
  }
  let dest = @model.FileInfo::draft("reluctant-1", "uploads", "two.txt", "txt")
  let copy_outcome = try {
    let _ = service.copy(source, dest, mode=@model.CopyMode::Same)
    "no-error"
  } catch {
    err => describe(err)
  }
  let move_outcome = try {
    let _ = service.move_file(source, dest, mode=@model.MoveMode::Same)
    "no-error"
  } catch {
    err => describe(err)
  }
  let calls = platform.copy_calls.val
  let _ = @fs.rmdir(root, recursive=true) catch {
    err => println("cleanup raised " + err.to_string())
  }
  if !copy_outcome.has_prefix("NotSupported") {
    fail("forced same copy answered " + copy_outcome)
  }
  if !move_outcome.has_prefix("NotSupported") {
    fail("forced same move answered " + move_outcome)
  }
  // 拒绝必须发生在问端口之前：调到过一次，这条判据就退化成"端口自己会抛"。
  assert_eq(calls, 0)
}

///|
async test "a move whose source cannot be deleted reports the failure and keeps both copies" {
  let root = @fs.tmpdir(prefix="moonfs-facade-undelete") catch {
    error => fail("tmpdir: " + error.to_string())
  }
  let _ = @fs.mkdir(root, recursive=true, allow_exist=true) catch {
    error => fail("mkdir: " + error.to_string())
  }
  let platform = UndeletablePlatform::{
    inner: @local.LocalPlatform::new(@local.LocalConfig::{
      platform: "undeletable-1",
      root_dir: root,
      domain: "https://undelete.contract.invalid",
      base_path: "uploads",
    }),
  }
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root + "/records",
  })
  let service = @storage.Service::new([platform], recorder)
  let intent = @model.FileInfo::draft(
    "undeletable-1", "uploads", "source.txt", "txt",
  )
  let source = service.save(
    intent,
    @model.UploadSource::Bytes(@utf8.encode("the byte that will not go away")),
  ) catch {
    error => fail("save raised " + describe(error))
  }
  let dest = @model.FileInfo::draft(
    "undeletable-1", "uploads", "target.txt", "txt",
  )
  let outcome = try {
    let _ = service.move_file(source, dest, mode=@model.MoveMode::Cross)
    "no-error"
  } catch {
    error => describe(error)
  }
  // 失败必须响亮：静默"移动成功"就是把一次删除失败藏成一次不可见的成功。
  if !outcome.has_prefix("Platform") {
    fail("undeletable source produced " + outcome)
  }
  // 目标已就位，源也还在——两份都留着，正是参考件的行为；门面不许回滚目标。
  let target_there = present_on_disk(root + "/uploads/target.txt")
  let source_there = present_on_disk(root + "/uploads/source.txt")
  let _ = @fs.rmdir(root, recursive=true) catch {
    error => println("cleanup " + root + " raised " + error.to_string())
  }
  assert_true(target_there)
  assert_true(source_there)
}
