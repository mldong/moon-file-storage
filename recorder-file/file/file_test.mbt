///|
// The recorder is verified through a second instance over the same root: that is
// the only shape which proves rows left the process and landed on disk. Row
// counts are read from the JSON Lines files directly, because "the write
// happened" is exactly what a memory-only recorder would fake.

///|
fn draft(url : String, size : Int64, status : String) -> @model.FileInfo {
  @model.FileInfo::{
    id: Some("id-" + url),
    url,
    size: Some(size),
    filename: "a.txt",
    original_filename: "a.txt",
    base_path: "uploads",
    path: "uploads/a.txt",
    ext: "txt",
    content_type: Some("text/plain"),
    platform: "local-1",
    th_url: None,
    th_filename: None,
    th_size: None,
    th_content_type: None,
    object_id: Some("obj"),
    object_type: Some("type"),
    metadata: Map([("k", "v")]),
    user_metadata: Map([("uk", "uv")]),
    th_metadata: Map([]),
    th_user_metadata: Map([]),
    attr: Map([("n", @json.to_json(1))]),
    file_acl: None,
    th_file_acl: None,
    hash_info: Some(@model.HashInfo::{
      md5: Some("md5"),
      sha1: None,
      sha256: None,
    }),
    upload_id: None,
    upload_status: Some(status),
    create_time: 1792000000000L,
  }
}

///|
fn part(
  upload_id : String,
  number : Int32,
  etag : String,
) -> @model.FilePartInfo {
  @model.FilePartInfo::{
    platform: "local-1",
    upload_id,
    part_number: number,
    size: 100L,
    etag,
  }
}

///|
async fn fresh_root(case : String) -> String {
  let base = @fs.tmpdir(prefix="moonfs-recorder-" + case) catch {
    error => fail("tmpdir: " + error.to_string())
  }
  @fs.mkdir(base, recursive=true, allow_exist=true) catch {
    error => fail("mkdir: " + error.to_string())
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
async fn line_count(path : String) -> Int32 {
  let exists = @fs.exists(path) catch {
    error => fail("stat: " + error.to_string())
  }
  if !exists {
    0
  } else {
    let data = @fs.read_file(path) catch {
      error => fail("read: " + error.to_string())
    }
    let text = @utf8.decode_lossy(data.binary())
    let mut rows = 0
    for line in text.split("\n") {
      if !line.is_empty() {
        rows = rows + 1
      }
    }
    rows
  }
}

///|
fn recorder_for(root : String) -> @file.FileRecorder {
  @file.FileRecorder::new(@file.FileRecorderConfig::{ root_dir: root, })
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
async test "records survive a reopened recorder" {
  let root = fresh_root("reopen")
  let url = "https://files.invalid/uploads/a.txt"
  let saved = recorder_for(root).save(draft(url, 10L, "uploading")) catch {
    error => fail("save raised " + error_name(error))
  }
  let reopened = recorder_for(root).get_by_url(url) catch {
    error => fail("get_by_url raised " + error_name(error))
  }
  let rows = line_count(root + "/files.jsonl")
  remove_root(root)
  assert_true(saved)
  assert_eq(rows, 1)
  match reopened {
    Some(read_back) => assert_true(read_back == draft(url, 10L, "uploading"))
    None => fail("the reopened recorder found no record")
  }
}

///|
async test "saving the same url twice reports false and keeps one row" {
  let root = fresh_root("twice")
  let url = "https://files.invalid/uploads/dup.txt"
  let recorder = recorder_for(root)
  let first = recorder.save(draft(url, 1L, "uploading")) catch {
    error => fail("first save raised " + error_name(error))
  }
  let second = recorder.save(draft(url, 999L, "re-uploaded")) catch {
    error => fail("second save raised " + error_name(error))
  }
  let kept = recorder.get_by_url(url) catch {
    error => fail("get_by_url raised " + error_name(error))
  }
  let rows = line_count(root + "/files.jsonl")
  remove_root(root)
  assert_true(first)
  assert_true(!second)
  assert_eq(rows, 1)
  match kept {
    Some(info) => assert_eq(info.size, Some(1L))
    None => fail("the first record disappeared")
  }
}

///|
async test "update rewrites a row and never creates one" {
  let root = fresh_root("update")
  let url = "https://files.invalid/uploads/up.txt"
  let other = "https://files.invalid/uploads/never-recorded.txt"
  let recorder = recorder_for(root)
  let _ = recorder.save(draft(url, 2L, "uploading")) catch {
    error => fail("save raised " + error_name(error))
  }
  let _ = recorder.update(draft(url, 2L, "SUCCESS")) catch {
    error => fail("update raised " + error_name(error))
  }
  let _ = recorder.update(draft(other, 7L, "uploading")) catch {
    error => fail("update of an unknown url raised " + error_name(error))
  }
  let status = recorder.get_by_url(url) catch {
    error => fail("get_by_url raised " + error_name(error))
  }
  let ghost = recorder.get_by_url(other) catch {
    error => fail("get_by_url on the unknown url raised " + error_name(error))
  }
  let rows = line_count(root + "/files.jsonl")
  remove_root(root)
  match status {
    Some(info) => assert_eq(info.upload_status, Some("SUCCESS"))
    None => fail("update lost the record")
  }
  assert_true(ghost is None)
  assert_eq(rows, 1)
}

///|
async test "delete answers whether the row was there" {
  let root = fresh_root("delete")
  let url = "https://files.invalid/uploads/del.txt"
  let recorder = recorder_for(root)
  let _ = recorder.save(draft(url, 3L, "SUCCESS")) catch {
    error => fail("save raised " + error_name(error))
  }
  let removed = recorder.delete(url) catch {
    error => fail("delete raised " + error_name(error))
  }
  let again = recorder.delete(url) catch {
    error => fail("second delete raised " + error_name(error))
  }
  let found = recorder.get_by_url(url) catch {
    error => fail("get_by_url raised " + error_name(error))
  }
  let rows = line_count(root + "/files.jsonl")
  remove_root(root)
  assert_true(removed)
  assert_true(!again)
  assert_true(found is None)
  assert_eq(rows, 0)
}

///|
async test "parts are keyed by upload id and part number" {
  let root = fresh_root("parts")
  let recorder = recorder_for(root)
  let _ = recorder.save_file_part(part("up-1", 1, "etag-a")) catch {
    error => fail("save part raised " + error_name(error))
  }
  let _ = recorder.save_file_part(part("up-1", 1, "etag-retry")) catch {
    error => fail("retry part raised " + error_name(error))
  }
  let _ = recorder.save_file_part(part("up-1", 2, "etag-b")) catch {
    error => fail("second part raised " + error_name(error))
  }
  let _ = recorder.save_file_part(part("up-2", 1, "other-upload")) catch {
    error => fail("other upload part raised " + error_name(error))
  }
  let before = recorder.part_rows() catch {
    error => fail("part_rows raised " + error_name(error))
  }
  let _ = recorder.delete_file_part_by_upload_id("up-1") catch {
    error => fail("delete parts raised " + error_name(error))
  }
  let after = recorder.part_rows() catch {
    error => fail("part_rows raised " + error_name(error))
  }
  let rows = line_count(root + "/file_parts.jsonl")
  remove_root(root)
  assert_eq(before.length(), 3)
  assert_eq(before.map(p => p.etag).filter(e => e == "etag-retry").length(), 1)
  assert_eq(after.length(), 1)
  assert_eq(after[0].upload_id, "up-2")
  assert_eq(rows, 1)
}

///|
async test "a corrupt record raises instead of looking absent" {
  let root = fresh_root("corrupt")
  let recorder = recorder_for(root)
  let _ = recorder.save(
    draft("https://files.invalid/uploads/ok.txt", 4L, "SUCCESS"),
  ) catch {
    error => fail("save raised " + error_name(error))
  }
  @fs.write_file(root + "/files.jsonl", @utf8.encode("not json at all\n")) catch {
    error => fail("corrupt the file: " + error.to_string())
  }
  let outcome = try {
    let _ = recorder.get_by_url("https://files.invalid/uploads/ok.txt")
    "no-error"
  } catch {
    error => error_name(error)
  }
  remove_root(root)
  assert_eq(outcome, "Recorder")
}
