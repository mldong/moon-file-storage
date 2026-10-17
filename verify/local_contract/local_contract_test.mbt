///|
// The local platform through the shared contract, then a check from the
// filesystem side: the suite deletes everything it wrote, so an empty object
// directory afterwards is the reading that says the platform kept its promises.

///|
async fn tmp_root() -> String {
  let root = @fs.tmpdir(prefix="moonfs-contract-local") catch {
    error => fail("tmpdir: " + error.to_string())
  }
  let _ = @fs.mkdir(root, recursive=true, allow_exist=true) catch {
    error => fail("mkdir: " + error.to_string())
  }
  root
}

///|
async fn entries(path : String) -> Array[String] {
  @fs.readdir(path) catch {
    error => fail("readdir " + path + ": " + error.to_string())
  }
}

///|
async test "local platform walks the shared contract" {
  let root = tmp_root()
  let domain = "https://local.contract.invalid"
  let platform = @local.LocalPlatform::new(@local.LocalConfig::{
    platform: "local-1",
    root_dir: root,
    domain,
    base_path: "uploads",
  })
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root + "/records",
  })
  let service = @storage.Service::new([platform], recorder)
  let fixture = @contract.Fixture::{
    label: "local",
    platform: "local-1",
    base_path: "uploads",
    domain,
    service,
    recorder,
    port: platform,
    presigned_markers: [],
  }
  @contract.run_contract(fixture)
  let left = files_under(root + "/uploads")
  let rows = entries(root + "/records")
  // 门面的分片编排把每片都写进了 `file_parts.jsonl`，而完成与放弃那两步各自要把它
  // 清掉——"账本文件还在"和"分片行没留"是两件事，都要判。
  let parts = recorder.part_rows() catch {
    error => fail("part_rows raised " + error_name(error))
  }
  let removed = @fs.rmdir(root, recursive=true) catch {
    error => fail("cleanup: " + error.to_string())
  }
  let _ = removed
  // The contract deletes every object it wrote, so no file may remain under the
  // storage root. Directories are a different matter: local storage has real
  // directories and the listing case creates them — deleting them would be the
  // platform removing what the caller never asked it to remove, so the check
  // counts files, not entries. The recorder file must still be there: that is the
  // difference between "nothing was written" and "everything was cleaned up".
  assert_eq(left, 0)
  // 主记录一份 + 分片子记录一份，缺一个就是那一族没真写。
  assert_eq(rows.length(), 2)
  assert_eq(parts.length(), 0)
}

///|
fn error_name(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(detail) => "InvalidInput: " + detail
    @model.StorageError::NotSupported(detail) => "NotSupported: " + detail
    @model.StorageError::NotFound(detail) => "NotFound: " + detail
    @model.StorageError::Platform(detail) => "Platform: " + detail
    @model.StorageError::Recorder(detail) => "Recorder: " + detail
  }
}

///|
/// Every file below `dir`, recursively — the residue the contract must not leave.
async fn files_under(dir : String) -> Int32 {
  let names = @fs.readdir(dir) catch {
    error => fail("readdir " + dir + ": " + error.to_string())
  }
  let mut total = 0
  for name in names {
    let path = dir + "/" + name
    let kind = @fs.kind(path) catch {
      error => fail("stat " + path + ": " + error.to_string())
    }
    if kind == @fs.FileKind::Directory {
      total = total + files_under(path)
    } else {
      total = total + 1
    }
  }
  total
}

///|

///|
/// B3 的那句验收线要真磁盘证据：记录器坏掉时，对象必须留在盘上（不回滚），
/// 错误照传到调用方。桩件只能证明"没调用 delete"，这里证明"文件真的还在"。
async test "a broken recorder leaves the object on disk, not rolled back" {
  let root = tmp_root()
  let domain = "https://local.contract.invalid"
  let platform = @local.LocalPlatform::new(@local.LocalConfig::{
    platform: "local-1",
    root_dir: root,
    domain,
    base_path: "uploads",
  })
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root + "/records",
  })
  let service = @storage.Service::new([platform], recorder)
  // 先把记录文件写成一行非法 json：下一次 `save` 读记录时就会 raise。
  let _ = @fs.mkdir(root + "/records", recursive=true, allow_exist=true) catch {
    error => fail("mkdir records: " + error.to_string())
  }
  let _ = @fs.write_file(
    root + "/records/files.jsonl",
    @utf8.encode("this line is not json"),
  ) catch {
    error => fail("corrupt the recorder: " + error.to_string())
  }
  let intent = @model.FileInfo::draft("local-1", "uploads", "orphan.txt", "txt")
  let outcome = try {
    let _ = service.save(
      intent,
      @model.UploadSource::Bytes(@utf8.encode("orphan")),
    )
    "no-error"
  } catch {
    @model.StorageError::Recorder(_) => "Recorder"
    @model.StorageError::InvalidInput(_) => "InvalidInput"
    @model.StorageError::NotSupported(_) => "NotSupported"
    @model.StorageError::NotFound(_) => "NotFound"
    @model.StorageError::Platform(_) => "Platform"
  }
  let landed = @fs.exists(root + "/uploads/orphan.txt") catch {
    error => fail("stat: " + error.to_string())
  }
  let _ = @fs.rmdir(root, recursive=true) catch {
    error => println("cleanup " + root + " raised " + error.to_string())
  }
  assert_eq(outcome, "Recorder")
  assert_true(landed)
}
