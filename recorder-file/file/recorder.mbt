///|
/// File-backed recorder: one JSON Lines file per record kind under `root_dir`.
///
/// Each operation reads the whole record file, applies the change and writes it
/// back. That is deliberate at this size: the recorder is a small index, and the
/// alternative (append plus compaction) needs a lock this filesystem port does
/// not expose. The trade-off is stated rather than hidden — two writers racing on
/// one root can lose rows, so this recorder serves single-writer deployments
/// until a real store replaces it.
///
/// Records are keyed by `FileInfo.url`, the same key the reference framework's
/// `FileRecorder` uses (`getFileInfo(url)` / `delete(url)`).

///|
pub struct FileRecorder {
  priv config : FileRecorderConfig
}

///|
pub fn FileRecorder::new(config : FileRecorderConfig) -> FileRecorder {
  { config, }
}

///|
pub fn FileRecorder::config(self : FileRecorder) -> FileRecorderConfig {
  self.config
}

///|
let records_name : String = "files.jsonl"

///|
let parts_name : String = "file_parts.jsonl"

///|
fn recorder_error(detail : String) -> @model.StorageError {
  @model.StorageError::Recorder(detail)
}

///|
fn os_detail(op : String, path : String, error : Error) -> @model.StorageError {
  recorder_error("recorder " + op + " " + path + ": " + error.to_string())
}

///|
fn trim_trailing_slash(text : String) -> String {
  let mut end = text.length()
  while end > 0 && text[end - 1] == '/' {
    end = end - 1
  }
  text[0:end].to_owned()
}

///|
fn record_file(root_dir : String, name : String) -> String {
  trim_trailing_slash(root_dir) + "/" + name
}

///|
fn parent_of(path : String) -> String {
  let mut found : Int32? = None
  let mut index = path.length() - 1
  while index >= 0 && found is None {
    if path[index] == '/' {
      found = Some(index)
    }
    index = index - 1
  }
  match found {
    Some(index) => path[0:index].to_owned()
    None => "."
  }
}

///|
async fn read_text(path : String) -> String raise @model.StorageError {
  let exists = @fs.exists(path) catch {
    error => raise os_detail("stat", path, error)
  }
  if !exists {
    ""
  } else {
    let data = @fs.read_file(path) catch {
      error => raise os_detail("read", path, error)
    }
    @utf8.decode_lossy(data.binary())
  }
}

///|
async fn write_text(
  path : String,
  text : String,
) -> Unit raise @model.StorageError {
  let parent = parent_of(path)
  @fs.mkdir(parent, recursive=true, allow_exist=true) catch {
    error => raise os_detail("mkdir", parent, error)
  }
  @fs.write_file(path, @utf8.encode(text)) catch {
    error => raise os_detail("write", path, error)
  }
}

///|
fn split_lines(text : String) -> Array[String] {
  let lines : Array[String] = []
  for line in text.split("\n") {
    if !line.is_empty() {
      lines.push(line.to_owned())
    }
  }
  lines
}

///|
fn encode_record(info : @model.FileInfo) -> String {
  @json.to_json(info).stringify()
}

///|
fn encode_part(part : @model.FilePartInfo) -> String {
  @json.to_json(part).stringify()
}

///|
fn[T] join_lines(rows : Array[T], encode : (T) -> String) -> String {
  let buf = StringBuilder()
  for row in rows {
    buf.write_string(encode(row))
    buf.write_string("\n")
  }
  buf.to_string()
}

///|
fn decode_record(
  line : String,
  path : String,
) -> @model.FileInfo raise @model.StorageError {
  let json = @json.parse(line) catch {
    error =>
      raise recorder_error(
        "record in " + path + " is not json: " + error.to_string(),
      )
  }
  let record : @model.FileInfo = @json.from_json(json) catch {
    error =>
      raise recorder_error(
        "record in " + path + " does not decode: " + error.to_string(),
      )
  }
  record
}

///|
fn decode_part(
  line : String,
  path : String,
) -> @model.FilePartInfo raise @model.StorageError {
  let json = @json.parse(line) catch {
    error =>
      raise recorder_error(
        "part record in " + path + " is not json: " + error.to_string(),
      )
  }
  let part : @model.FilePartInfo = @json.from_json(json) catch {
    error =>
      raise recorder_error(
        "part record in " + path + " does not decode: " + error.to_string(),
      )
  }
  part
}

///|
async fn read_records(
  root_dir : String,
) -> Array[@model.FileInfo] raise @model.StorageError {
  let path = record_file(root_dir, records_name)
  let text = read_text(path)
  let rows : Array[@model.FileInfo] = []
  for line in split_lines(text) {
    rows.push(decode_record(line, path))
  }
  rows
}

///|
async fn write_records(
  root_dir : String,
  rows : Array[@model.FileInfo],
) -> Unit raise @model.StorageError {
  let path = record_file(root_dir, records_name)
  write_text(path, join_lines(rows, encode_record))
}

///|
async fn read_parts(
  root_dir : String,
) -> Array[@model.FilePartInfo] raise @model.StorageError {
  let path = record_file(root_dir, parts_name)
  let text = read_text(path)
  let rows : Array[@model.FilePartInfo] = []
  for line in split_lines(text) {
    rows.push(decode_part(line, path))
  }
  rows
}

///|
async fn write_parts(
  root_dir : String,
  rows : Array[@model.FilePartInfo],
) -> Unit raise @model.StorageError {
  let path = record_file(root_dir, parts_name)
  write_text(path, join_lines(rows, encode_part))
}

///|
/// A record is already saved when its url is present; the reference framework
/// reports that from the mapper as `false` and leaves the store untouched, and
/// the upload that triggered it is **not** rolled back — the caller decides what
/// an unrecorded object means.
pub impl @recorder.Recorder for FileRecorder with fn save(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  let records = read_records(self.config.root_dir)
  let mut duplicate = false
  for record in records {
    if record.url == info.url {
      duplicate = true
    }
  }
  if duplicate {
    false
  } else {
    let saved = records
    saved.push(info)
    write_records(self.config.root_dir, saved)
    true
  }
}

///|
/// Rewrite the row for the same url. A url that is not recorded stays unrecorded:
/// `update` never creates a row and never fails, matching the reference mapper's
/// update on zero affected rows.
pub impl @recorder.Recorder for FileRecorder with fn update(
  self,
  info : @model.FileInfo,
) -> Unit raise @model.StorageError {
  let records = read_records(self.config.root_dir)
  let updated : Array[@model.FileInfo] = []
  for record in records {
    if record.url == info.url {
      updated.push(info)
    } else {
      updated.push(record)
    }
  }
  write_records(self.config.root_dir, updated)
}

///|
pub impl @recorder.Recorder for FileRecorder with fn get_by_url(
  self,
  url : String,
) -> @model.FileInfo? raise @model.StorageError {
  let records = read_records(self.config.root_dir)
  let mut found : @model.FileInfo? = None
  for record in records {
    if record.url == url && found is None {
      found = Some(record)
    }
  }
  found
}

///|
pub impl @recorder.Recorder for FileRecorder with fn delete(self, url : String) -> Bool raise @model.StorageError {
  let records = read_records(self.config.root_dir)
  let kept : Array[@model.FileInfo] = []
  for record in records {
    if record.url != url {
      kept.push(record)
    }
  }
  let removed = kept.length() != records.length()
  if removed {
    write_records(self.config.root_dir, kept)
  }
  removed
}

///|
/// Parts are keyed by `(upload_id, part_number)`: re-sending the same part
/// replaces its row instead of duplicating it, which is what a retry loop needs.
pub impl @recorder.Recorder for FileRecorder with fn save_file_part(
  self,
  part : @model.FilePartInfo,
) -> Unit raise @model.StorageError {
  let rows = read_parts(self.config.root_dir)
  let next : Array[@model.FilePartInfo] = []
  for row in rows {
    if row.upload_id != part.upload_id || row.part_number != part.part_number {
      next.push(row)
    }
  }
  next.push(part)
  write_parts(self.config.root_dir, next)
}

///|
pub impl @recorder.Recorder for FileRecorder with fn delete_file_part_by_upload_id(
  self,
  upload_id : String,
) -> Unit raise @model.StorageError {
  let rows = read_parts(self.config.root_dir)
  let kept : Array[@model.FilePartInfo] = []
  for row in rows {
    if row.upload_id != upload_id {
      kept.push(row)
    }
  }
  write_parts(self.config.root_dir, kept)
}

///|
pub extend FileRecorder with @recorder.Recorder::{
  save,
  update,
  get_by_url,
  delete,
  save_file_part,
  delete_file_part_by_upload_id,
}

///|
/// Row counts are not part of the recorder contract, but a file recorder has to be
/// observable from disk or nothing here proves it persisted anything.
pub async fn FileRecorder::record_rows(
  self : FileRecorder,
) -> Array[@model.FileInfo] raise @model.StorageError {
  read_records(self.config.root_dir)
}

///|
pub async fn FileRecorder::part_rows(
  self : FileRecorder,
) -> Array[@model.FilePartInfo] raise @model.StorageError {
  read_parts(self.config.root_dir)
}
