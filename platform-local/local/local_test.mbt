///|
// The local platform is verified against the real disk: every case writes under
// `@fs.tmpdir`, asserts what landed on the filesystem, and removes the whole root
// at the end. Asserting only the returned struct would let a platform that never
// touches disk pass.

///|
fn payload() -> Bytes {
  // UTF-8 on purpose: `.to_bytes()` yields UTF-16 code units for a String, so a
  // byte-equality assertion built on it would be measuring the wrong thing.
  @utf8.encode("moon-file-storage local leg 0123456789")
}

///|
async fn fresh_root(case : String) -> String {
  let base = @fs.tmpdir(prefix="moonfs-local-" + case) catch {
    error => fail("tmpdir: " + error.to_string())
  }
  @fs.mkdir(base, recursive=true, allow_exist=true) catch {
    error => fail("mkdir " + base + ": " + error.to_string())
  }
  base
}

///|
async fn remove_root(root : String) -> Unit {
  @fs.rmdir(root, recursive=true) catch {
    error => println("cleanup " + root + " raised " + error.to_string())
  }
}

///|
async fn disk_stat(path : String) -> Bool {
  @fs.exists(path) catch {
    error => fail("stat " + path + ": " + error.to_string())
  }
}

///|
async fn disk_size(path : String) -> Int64 {
  @fs.file_size(path) catch {
    error => fail("size " + path + ": " + error.to_string())
  }
}

///|
async fn disk_bytes(path : String) -> Bytes {
  let data = @fs.read_file(path) catch {
    error => fail("read " + path + ": " + error.to_string())
  }
  data.binary()
}

///|
fn platform_for(root : String) -> @local.LocalPlatform {
  @local.LocalPlatform::new(@local.LocalConfig::{
    platform: "local-1",
    root_dir: root,
    domain: "https://files.invalid",
    base_path: "uploads",
  })
}

///|
fn draft(
  base_path : String,
  filename : String,
  ext : String,
) -> @model.FileInfo {
  @model.FileInfo::{
    id: None,
    url: "",
    size: None,
    filename,
    original_filename: filename,
    base_path,
    path: "",
    ext,
    content_type: None,
    platform: "local-1",
    th_url: None,
    th_filename: None,
    th_size: None,
    th_content_type: None,
    object_id: None,
    object_type: None,
    metadata: Map([]),
    user_metadata: Map([]),
    th_metadata: Map([]),
    th_user_metadata: Map([]),
    attr: Map([]),
    file_acl: None,
    th_file_acl: None,
    hash_info: None,
    upload_id: None,
    upload_status: None,
    create_time: 0L,
  }
}

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
async fn save_bytes(
  platform : @local.LocalPlatform,
  base_path : String,
  filename : String,
) -> @model.FileInfo {
  let saved = platform.save(
    draft(base_path, filename, "txt"),
    @model.UploadSource::Bytes(payload()),
  ) catch {
    error => fail("save raised " + error_name(error))
  }
  match saved {
    Some(info) => info
    None => fail("local save returned None")
  }
}

///|
async test "local save lands the object on disk" {
  let root = fresh_root("save")
  let platform = platform_for(root)
  let size = payload().length().to_int64()
  assert_eq(size, 38L)
  let info = save_bytes(platform, "uploads", "hello.txt")
  let on_disk = disk_stat(root + "/uploads/hello.txt")
  let written = disk_size(root + "/uploads/hello.txt")
  platform.close()
  remove_root(root)
  assert_true(on_disk)
  assert_eq(info.url, "https://files.invalid/uploads/hello.txt")
  assert_eq(info.path, "uploads/hello.txt")
  assert_eq(info.size, Some(size))
  assert_eq(written, size)
}

///|
async test "local get_file reads back what save wrote" {
  let root = fresh_root("read")
  let platform = platform_for(root)
  let size = payload().length().to_int64()
  let info = save_bytes(platform, "uploads", "roundtrip.txt")
  let found = platform.get_file(info.url) catch {
    error => fail("get_file raised " + error_name(error))
  }
  let missing = platform.get_file("https://files.invalid/uploads/absent.txt") catch {
    error => fail("get_file on absent raised " + error_name(error))
  }
  let present = platform.exists(info) catch {
    error => fail("exists raised " + error_name(error))
  }
  platform.close()
  remove_root(root)
  match found {
    Some(read_back) => {
      assert_eq(read_back.path, "uploads/roundtrip.txt")
      assert_eq(read_back.size, Some(size))
      assert_eq(read_back.filename, "roundtrip.txt")
      assert_eq(read_back.ext, "txt")
      assert_eq(read_back.platform, "local-1")
    }
    None => fail("get_file did not find the object save just wrote")
  }
  assert_true(missing is None)
  assert_true(present)
}

///|
async test "local download writes the same bytes to the sink" {
  let root = fresh_root("download")
  let platform = platform_for(root)
  let info = save_bytes(platform, "d", "bin.dat")
  let sink_path = root + "/sink-copy"
  let sink = @fs.create(sink_path, allow_existing=true) catch {
    error => fail("create sink: " + error.to_string())
  }
  platform.download(info, sink) catch {
    error => fail("download raised " + error_name(error))
  }
  sink.close()
  let through_sink = disk_bytes(sink_path)
  let on_disk = disk_bytes(root + "/d/bin.dat")
  platform.close()
  remove_root(root)
  assert_true(through_sink == payload())
  assert_true(through_sink == on_disk)
}

///|
async test "local delete removes the object and reports what it saw" {
  let root = fresh_root("delete")
  let platform = platform_for(root)
  let info = save_bytes(platform, "del", "gone.txt")
  let removed = platform.delete(info) catch {
    error => fail("delete raised " + error_name(error))
  }
  let after = platform.exists(info) catch {
    error => fail("exists raised " + error_name(error))
  }
  let on_disk = disk_stat(root + "/del/gone.txt")
  let again = platform.delete(info) catch {
    error => fail("second delete raised " + error_name(error))
  }
  platform.close()
  remove_root(root)
  assert_true(removed)
  assert_true(!after)
  assert_true(!on_disk)
  assert_true(!again)
}

///|
async test "local stream source reaches disk byte for byte" {
  let root = fresh_root("stream")
  let platform = platform_for(root)
  let size = payload().length().to_int64()
  let data = payload()
  let reader = @io.MemoryReader::MemoryReader(writer => writer.write(data))
  let saved = platform.save(
    draft("s", "stream.txt", "txt"),
    @model.UploadSource::Stream(reader, Some(size)),
  ) catch {
    error => fail("save stream raised " + error_name(error))
  }
  reader.close()
  let info = match saved {
    Some(info) => info
    None => fail("save stream returned None")
  }
  let on_disk = disk_bytes(root + "/s/stream.txt")
  platform.close()
  remove_root(root)
  assert_eq(info.size, Some(size))
  assert_true(on_disk == data)
}

///|
async test "local path source copies an existing file" {
  let root = fresh_root("path")
  let platform = platform_for(root)
  let size = payload().length().to_int64()
  let source_path = root + "/source.txt"
  @fs.write_file(source_path, payload()) catch {
    error => fail("seed source: " + error.to_string())
  }
  let saved = platform.save(
    draft("p", "copied.txt", "txt"),
    @model.UploadSource::Path(source_path),
  ) catch {
    error => fail("save path raised " + error_name(error))
  }
  let info = match saved {
    Some(info) => info
    None => fail("save path returned None")
  }
  let on_disk = disk_bytes(root + "/p/copied.txt")
  platform.close()
  remove_root(root)
  assert_eq(info.size, Some(size))
  assert_true(on_disk == payload())
}

///|
async test "local refuses bad input before writing an object" {
  let root = fresh_root("refuse")
  let platform = platform_for(root)
  let empty_name = try {
    let _ = platform.save(
      draft("uploads", "", "txt"),
      @model.UploadSource::Bytes(payload()),
    )
    "no-error"
  } catch {
    error => error_name(error)
  }
  let foreign = try {
    let _ = platform.get_file("https://other.invalid/uploads/hello.txt")
    "no-error"
  } catch {
    error => error_name(error)
  }
  let nothing = try {
    let _ = platform.save(
      draft("", "nowhere.txt", "txt"),
      @model.UploadSource::Path(root + "/not-there.txt"),
    )
    "no-error"
  } catch {
    error => error_name(error)
  }
  let landed = disk_stat(root + "/nowhere.txt")
  platform.close()
  remove_root(root)
  assert_eq(empty_name, "InvalidInput")
  assert_eq(foreign, "InvalidInput")
  assert_eq(nothing, "Platform")
  assert_true(!landed)
}

///|

///|
// The claim has to match what this platform now really does: multipart and
// same-platform copy/move are implemented on the filesystem (the reference
// framework's local storage implements them too), while a signed URL is not a
// thing a local root can offer.
test "local capabilities report what it cannot do" {
  let platform = platform_for("/unused-root")
  let caps = platform.capabilities()
  assert_true(caps.multipart_upload)
  assert_true(!caps.presigned_url)
  assert_true(!caps.acl)
  assert_true(!caps.metadata)
  assert_true(caps.list_files)
  assert_true(caps.same_copy)
  assert_true(caps.same_move)
}
