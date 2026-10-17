///|
// The facade is tested against stub ports, not against a real storage: what this
// layer owns is ordering and compensation. The counters are `@ref` cells because
// "the platform was never asked to delete" is the assertion that proves a
// recorder failure does not become data loss.

///|
struct StubPlatform {
  platform : String
  declines : Bool
  writes : @ref.Ref[Int32]
  deletes : @ref.Ref[Int32]
  reads : @ref.Ref[Int32]
  caps : @model.Capabilities
}

///|
fn stub_platform(
  name : String,
  declines : Bool,
  metadata : Bool,
) -> StubPlatform {
  StubPlatform::{
    platform: name,
    declines,
    writes: @ref.Ref(0),
    deletes: @ref.Ref(0),
    reads: @ref.Ref(0),
    caps: @model.Capabilities::{
      multipart_upload: true,
      list_files: true,
      presigned_url: true,
      acl: false,
      metadata,
      same_copy: true,
      same_move: true,
    },
  }
}

///|
pub impl @platform.Platform for StubPlatform with fn name(self) -> String {
  self.platform
}

///|
pub impl @platform.Platform for StubPlatform with fn capabilities(self) -> @model.Capabilities {
  self.caps
}

///|
pub impl @platform.Platform for StubPlatform with fn save(
  self,
  info : @model.FileInfo,
  _source : @model.UploadSource,
) -> @model.FileInfo? raise @model.StorageError {
  if self.declines {
    None
  } else {
    self.writes.val = self.writes.val + 1
    Some(
      info.stamped(@model.Stamp::{
        platform: None,
        path: Some("uploads/stub.txt"),
        url: Some("stub://" + self.platform + "/uploads/stub.txt"),
        size: Some(7L),
        create_time: None,
        upload_id: None,
        upload_status: None,
        user_metadata: None,
      }),
    )
  }
}

///|
pub impl @platform.Platform for StubPlatform with fn get_file(
  self,
  url : String,
) -> @model.FileInfo? raise @model.StorageError {
  self.reads.val = self.reads.val + 1
  let base = @model.FileInfo::draft(self.platform, "uploads", "stub.txt", "txt")
  Some(
    base.stamped(@model.Stamp::{
      platform: None,
      path: Some("uploads/stub.txt"),
      url: Some(url),
      size: Some(7L),
      create_time: None,
      upload_id: None,
      upload_status: None,
      user_metadata: None,
    }),
  )
}

///|
pub impl @platform.Platform for StubPlatform with fn exists(
  self,
  _info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  self.writes.val > 0
}

///|
pub impl @platform.Platform for StubPlatform with fn delete(
  self,
  _info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  self.deletes.val = self.deletes.val + 1
  true
}

///|
pub impl @platform.Platform for StubPlatform with fn download(
  _self,
  _info : @model.FileInfo,
  writer : &@io.Writer,
) -> Unit raise @model.StorageError {
  writer.write(@utf8.encode("stub-body")) catch {
    error => raise Platform("stub sink refused: " + error.to_string())
  }
}

///|
pub impl @platform.Platform for StubPlatform with fn close(_self) -> Unit {
  ()
}

///|
/// The facade tests do not drive the multipart, presigned or copy families, so
/// the stub refuses them — a stub that quietly returned `Ok` here would let a
/// future facade method be "tested" against a platform that did nothing.
pub impl @platform.Platform for StubPlatform with fn init_multipart(
  self,
  info : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  if self.declines {
    raise NotSupported("stub has no multipart")
  }
  self.writes.val = self.writes.val + 1
  info.stamped(@model.Stamp::{
    platform: Some(self.platform),
    path: Some("uploads/stub.txt"),
    url: Some("stub://" + self.platform + "/uploads/stub.txt"),
    size: None,
    create_time: None,
    upload_id: Some("stub-upload"),
    upload_status: None,
    user_metadata: None,
  })
}

///|
pub impl @platform.Platform for StubPlatform with fn upload_part(
  _self,
  _info : @model.FileInfo,
  _part_number : Int32,
  _source : @model.UploadSource,
) -> @model.FilePartInfo raise @model.StorageError {
  raise NotSupported("stub has no multipart")
}

///|
pub impl @platform.Platform for StubPlatform with fn list_parts(
  _self,
  _info : @model.FileInfo,
  _part_number_marker : Int32,
) -> @model.PartPage raise @model.StorageError {
  raise NotSupported("stub has no multipart")
}

///|
pub impl @platform.Platform for StubPlatform with fn complete_multipart(
  _self,
  _info : @model.FileInfo,
  _parts : Array[@model.FilePartInfo],
) -> @model.FileInfo raise @model.StorageError {
  raise NotSupported("stub has no multipart")
}

///|
pub impl @platform.Platform for StubPlatform with fn abort_multipart(
  _self,
  _info : @model.FileInfo,
) -> Unit raise @model.StorageError {
  raise NotSupported("stub has no multipart")
}

///|
pub impl @platform.Platform for StubPlatform with fn presigned_url(
  _self,
  _info : @model.FileInfo,
  _method : @model.PresignMethod,
  _expires_seconds : Int32,
) -> String raise @model.StorageError {
  raise NotSupported("stub signs nothing")
}

///|
pub impl @platform.Platform for StubPlatform with fn same_copy(
  _self,
  _src : @model.FileInfo,
  _dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  raise NotSupported("stub cannot copy")
}

///|
pub impl @platform.Platform for StubPlatform with fn same_move(
  _self,
  _src : @model.FileInfo,
  _dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  raise NotSupported("stub cannot move")
}

///|
pub impl @platform.Platform for StubPlatform with fn list_files(
  _self,
  _path : String,
  _filename_prefix : String,
  _marker : String?,
) -> @model.FileListing raise @model.StorageError {
  raise NotSupported("stub lists nothing")
}

///|
pub impl @platform.Platform for StubPlatform with fn set_file_acl(
  _self,
  _info : @model.FileInfo,
  _acl : @model.CannedAcl,
) -> Unit raise @model.StorageError {
  raise NotSupported("stub has no ACL")
}

///|
pub extend StubPlatform with @platform.Platform::{
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
struct StubRecorder {
  duplicate : Bool
  broken : Bool
  saves : @ref.Ref[Int32]
  deletes : @ref.Ref[Int32]
  rows : @ref.Ref[Array[@model.FileInfo]]
}

///|
fn stub_recorder(duplicate : Bool, broken : Bool) -> StubRecorder {
  StubRecorder::{
    duplicate,
    broken,
    saves: @ref.Ref(0),
    deletes: @ref.Ref(0),
    rows: @ref.Ref([]),
  }
}

///|
pub impl @recorder.Recorder for StubRecorder with fn save(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  if self.broken {
    raise Recorder("stub recorder is down")
  }
  self.saves.val = self.saves.val + 1
  if self.duplicate {
    false
  } else {
    self.rows.val.push(info)
    true
  }
}

///|
pub impl @recorder.Recorder for StubRecorder with fn update(
  self,
  info : @model.FileInfo,
) -> Unit raise @model.StorageError {
  let rows = self.rows.val
  let total = rows.length()
  for index in 0..<total {
    if rows[index].url == info.url {
      rows[index] = info
    }
  }
  ()
}

///|
pub impl @recorder.Recorder for StubRecorder with fn get_by_url(
  self,
  url : String,
) -> @model.FileInfo? raise @model.StorageError {
  let mut found : @model.FileInfo? = None
  for row in self.rows.val {
    if row.url == url && found is None {
      found = Some(row)
    }
  }
  found
}

///|
pub impl @recorder.Recorder for StubRecorder with fn delete(self, url : String) -> Bool raise @model.StorageError {
  self.deletes.val = self.deletes.val + 1
  let rows = self.rows.val
  let mut removed = 0
  let mut index = rows.length() - 1
  while index >= 0 {
    if rows[index].url == url {
      let _ = rows.remove(index)
      removed = removed + 1
    }
    index = index - 1
  }
  removed > 0
}

///|
pub impl @recorder.Recorder for StubRecorder with fn save_file_part(
  _self,
  _part : @model.FilePartInfo,
) -> Unit raise @model.StorageError {
  ()
}

///|
pub impl @recorder.Recorder for StubRecorder with fn delete_file_part_by_upload_id(
  _self,
  _upload_id : String,
) -> Unit raise @model.StorageError {
  ()
}

///|
pub extend StubRecorder with @recorder.Recorder::{
  save,
  update,
  get_by_url,
  delete,
  save_file_part,
  delete_file_part_by_upload_id,
}

///|
struct Sink {
  got : @ref.Ref[Array[Byte]]
}

///|
pub impl @io.Writer for Sink with fn write_once(
  self,
  data : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  for index in offset..<(offset + len) {
    let _ = self.got.val.push(data[index])
  }
  ()
  len
}

///|
pub extend Sink with @io.Writer::{write_once}

///|
fn error_name(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(_) => "InvalidInput"
    @model.StorageError::NotSupported(_) => "NotSupported"
    @model.StorageError::NotFound(_) => "NotFound"
    @model.StorageError::Platform(_) => "Platform"
    @model.StorageError::Recorder(_) => "Recorder"
  }
}

///|
async fn save_through(
  service : @storage.Service,
  platform : String,
) -> @model.FileInfo {
  let intent = @model.FileInfo::draft(platform, "uploads", "stub.txt", "txt")
  service.save(intent, @model.UploadSource::Bytes(@utf8.encode("stub-body"))) catch {
    error => fail("save raised " + error_name(error))
  }
}

///|
async test "service stamps platform, clock and record on save" {
  let platform = stub_platform("primary", false, true)
  let recorder = stub_recorder(false, false)
  let service = @storage.Service::new([platform], recorder)
  let saved = save_through(service, "primary")
  assert_eq(saved.platform, "primary")
  assert_eq(saved.url, "stub://primary/uploads/stub.txt")
  assert_eq(saved.size, Some(7L))
  assert_true(saved.create_time > 0L)
  assert_eq(platform.writes.val, 1)
  assert_eq(recorder.saves.val, 1)
  let row = recorder.get_by_url(saved.url) catch {
    error => fail("get_by_url raised " + error_name(error))
  }
  match row {
    Some(recorded) => assert_eq(recorded.create_time, saved.create_time)
    None => fail("the row the facade wrote is not readable back")
  }
}

///|
async test "an unknown platform is refused before anything is written" {
  let platform = stub_platform("primary", false, true)
  let recorder = stub_recorder(false, false)
  let service = @storage.Service::new([platform], recorder)
  let intent = @model.FileInfo::draft("ghost", "uploads", "stub.txt", "txt")
  let outcome = try {
    let _ = service.save(intent, @model.UploadSource::Bytes(@utf8.encode("x")))
    "no-error"
  } catch {
    error => error_name(error)
  }
  assert_eq(outcome, "InvalidInput")
  assert_eq(platform.writes.val, 0)
  assert_eq(recorder.saves.val, 0)
}

///|
async test "a recorder failure keeps the object and does not roll it back" {
  let platform = stub_platform("primary", false, true)
  let recorder = stub_recorder(false, true)
  let service = @storage.Service::new([platform], recorder)
  let intent = @model.FileInfo::draft("primary", "uploads", "stub.txt", "txt")
  let outcome = try {
    let _ = service.save(intent, @model.UploadSource::Bytes(@utf8.encode("x")))
    "no-error"
  } catch {
    error => error_name(error)
  }
  assert_eq(outcome, "Recorder")
  assert_eq(platform.writes.val, 1)
  // The point of this case: a bookkeeping failure must not become data loss.
  assert_eq(platform.deletes.val, 0)
}

///|
async test "a duplicate record keeps the object and the save still returns" {
  let platform = stub_platform("primary", false, true)
  let recorder = stub_recorder(true, false)
  let service = @storage.Service::new([platform], recorder)
  let saved = save_through(service, "primary")
  assert_eq(saved.url, "stub://primary/uploads/stub.txt")
  assert_eq(platform.deletes.val, 0)
  assert_eq(recorder.saves.val, 1)
}

///|
async test "a platform that declines the save records nothing" {
  let platform = stub_platform("primary", true, true)
  let recorder = stub_recorder(false, false)
  let service = @storage.Service::new([platform], recorder)
  let intent = @model.FileInfo::draft("primary", "uploads", "stub.txt", "txt")
  let outcome = try {
    let _ = service.save(intent, @model.UploadSource::Bytes(@utf8.encode("x")))
    "no-error"
  } catch {
    error => error_name(error)
  }
  assert_eq(outcome, "Platform")
  assert_eq(recorder.saves.val, 0)
}

///|
async test "an empty platform name selects the first registered platform" {
  let first = stub_platform("first", false, true)
  let second = stub_platform("second", false, true)
  let recorder = stub_recorder(false, false)
  let service = @storage.Service::new([first, second], recorder)
  let saved = save_through(service, "")
  assert_eq(service.platform_names().join(","), "first,second")
  assert_eq(saved.platform, "first")
  assert_eq(second.writes.val, 0)
}

///|
async test "delete removes the object then forgets the row" {
  let platform = stub_platform("primary", false, true)
  let recorder = stub_recorder(false, false)
  let service = @storage.Service::new([platform], recorder)
  let saved = save_through(service, "primary")
  let removed = service.delete(saved) catch {
    error => fail("delete raised " + error_name(error))
  }
  let row = recorder.get_by_url(saved.url) catch {
    error => fail("get_by_url raised " + error_name(error))
  }
  assert_true(removed)
  assert_eq(platform.deletes.val, 1)
  assert_eq(recorder.deletes.val, 1)
  assert_true(row is None)
}

///|
async test "get_file needs a record to route and never guesses" {
  let platform = stub_platform("primary", false, true)
  let recorder = stub_recorder(false, false)
  let service = @storage.Service::new([platform], recorder)
  let unrecorded = service.get_file("stub://primary/uploads/stub.txt") catch {
    error => fail("get_file raised " + error_name(error))
  }
  assert_true(unrecorded is None)
  assert_eq(platform.reads.val, 0)
  let saved = save_through(service, "primary")
  let found = service.get_file(saved.url) catch {
    error => fail("get_file raised " + error_name(error))
  }
  match found {
    Some(info) => assert_eq(info.path, "uploads/stub.txt")
    None => fail("the recorded object was not readable")
  }
  assert_eq(platform.reads.val, 1)
}

///|
async test "download streams through the routed platform" {
  let platform = stub_platform("primary", false, true)
  let recorder = stub_recorder(false, false)
  let service = @storage.Service::new([platform], recorder)
  let saved = save_through(service, "primary")
  let sink = Sink::{ got: @ref.Ref([]), }
  service.download(saved, sink) catch {
    error => fail("download raised " + error_name(error))
  }
  assert_true(sink.got.val == @utf8.encode("stub-body").to_array())
}

///|
async test "capabilities come from the routed platform" {
  let platform = stub_platform("primary", false, true)
  let recorder = stub_recorder(false, false)
  let service = @storage.Service::new([platform], recorder)
  let caps = service.capabilities("primary")
  assert_true(caps.multipart_upload)
  assert_true(!caps.acl)
  let unknown = try {
    let _ = service.capabilities("ghost")
    "no-error"
  } catch {
    error => error_name(error)
  }
  assert_eq(unknown, "InvalidInput")
}

///|
async test "user metadata is refused when the storage cannot keep it" {
  let platform = stub_platform("primary", false, false)
  let recorder = stub_recorder(false, false)
  let service = @storage.Service::new([platform], recorder)
  let intent = @model.FileInfo::draft("primary", "uploads", "stub.txt", "txt").stamped(@model.Stamp::{
      platform: None,
      path: None,
      url: None,
      size: None,
      create_time: None,
      upload_id: None,
      upload_status: None,
      user_metadata: None,
    },
  )
  intent.user_metadata["owner"] = "mldong"
  let outcome = try {
    let _ = service.save(intent, @model.UploadSource::Bytes(@utf8.encode("x")))
    "no-error"
  } catch {
    error => error_name(error)
  }
  assert_eq(outcome, "NotSupported")
  assert_eq(platform.writes.val, 0)
}

///|
async test "the same intent goes through when the storage reports metadata" {
  let platform = stub_platform("primary", false, true)
  let recorder = stub_recorder(false, false)
  let service = @storage.Service::new([platform], recorder)
  let intent = @model.FileInfo::draft("primary", "uploads", "stub.txt", "txt")
  intent.user_metadata["owner"] = "mldong"
  let saved = service.save(
    intent,
    @model.UploadSource::Bytes(@utf8.encode("x")),
  ) catch {
    error => fail("save raised " + error_name(error))
  }
  assert_eq(platform.writes.val, 1)
  assert_eq(saved.user_metadata.get("owner"), Some("mldong"))
}

///|
/// 分片初始化与对象上传在"记录没落下"这一档上**必须不同**：参考件
/// `UploadActuator` 忽略记录器返回值（对象已经在那儿了），而
/// `InitiateMultipartUploadActuator` 直接抛——会话号只活在那条记录里，账没落地
/// 这一路就再也接不上。摘掉门面里那句 raise，这条就先红。
async test "a multipart session with no record is refused" {
  let platform = stub_platform("primary", false, true)
  let recorder = stub_recorder(true, false)
  let service = @storage.Service::new([platform], recorder)
  let intent = @model.FileInfo::draft("primary", "uploads", "stub.txt", "txt")
  let outcome = try {
    let _ = service.init_multipart(intent)
    "no-error"
  } catch {
    error => error_name(error)
  }
  assert_eq(outcome, "Recorder")
  // 会话确实开了，也不许偷偷回去取消：抛的是"账没落地"，不是"什么都没发生"。
  assert_eq(platform.writes.val, 1)
  assert_eq(platform.deletes.val, 0)
}

///|
async test "init_multipart leaves an INITIATE row the later steps can find" {
  let platform = stub_platform("primary", false, true)
  let recorder = stub_recorder(false, false)
  let service = @storage.Service::new([platform], recorder)
  let intent = @model.FileInfo::draft("primary", "uploads", "stub.txt", "txt")
  let staged = service.init_multipart(intent) catch {
    error => fail("init_multipart raised " + error_name(error))
  }
  assert_eq(staged.upload_status, Some(@model.upload_status_initiate))
  assert_eq(staged.upload_id, Some("stub-upload"))
  assert_eq(recorder.saves.val, 1)
}
