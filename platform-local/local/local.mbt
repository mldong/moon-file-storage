///|
/// Local filesystem platform: an object is a file under `config.root_dir`, and
/// `FileInfo.path` is its key relative to that root.
///
/// Every `@fs` failure is mapped into `StorageError::Platform` with the path that
/// was attempted attached — a permission problem and a missing file must not
/// reach the caller as the same shape. "No such object" is *not* an error: it is
/// `None` from `get_file`, matching the reference framework's `getFileInfo(url)`,
/// which returns null rather than throwing.

///|
pub struct LocalPlatform {
  priv config : LocalConfig
}

///|
pub fn LocalPlatform::new(config : LocalConfig) -> LocalPlatform {
  { config, }
}

///|
pub fn LocalPlatform::config(self : LocalPlatform) -> LocalConfig {
  self.config
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
fn trim_leading_slash(text : String) -> String {
  let mut start = 0
  while start < text.length() && text[start] == '/' {
    start = start + 1
  }
  text[start:].to_owned()
}

///|
fn join_path(root : String, relative : String) -> String {
  let base = trim_trailing_slash(root)
  let key = trim_leading_slash(relative)
  base + "/" + key
}

///|
/// An object is addressed by its key, and "no key" is not the root directory.
/// The contract suite found this: a draft whose `path` was never stamped turned
/// an `exists`/`delete` call into an attempt to unlink the storage root itself.
fn object_path(
  root : String,
  relative : String,
) -> String raise @model.StorageError {
  let key = trim_leading_slash(relative)
  if key.is_empty() {
    raise @model.StorageError::InvalidInput("local object needs a path")
  }
  join_path(root, key)
}

///|
fn last_slash(text : String) -> Int32? {
  let mut found : Int32? = None
  let mut index = text.length() - 1
  while index >= 0 && found is None {
    if text[index] == '/' {
      found = Some(index)
    }
    index = index - 1
  }
  found
}

///|
fn parent_of(path : String) -> String {
  match last_slash(path) {
    Some(index) => path[0:index].to_owned()
    None => "."
  }
}

///|
fn platform_error(detail : String) -> @model.StorageError {
  @model.StorageError::Platform(detail)
}

///|
fn os_detail(op : String, path : String, error : Error) -> @model.StorageError {
  platform_error("local " + op + " " + path + ": " + error.to_string())
}

///|
fn stored(
  info : @model.FileInfo,
  path : String,
  url : String,
  size : Int64,
) -> @model.FileInfo {
  info.stamped(@model.Stamp::{
    platform: None,
    path: Some(path),
    url: Some(url),
    size: Some(size),
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
}

///|
pub impl @platform.Platform for LocalPlatform with fn name(self) -> String {
  self.config.platform
}

///|
/// Self-reported capability: local storage has no presigned URL and no ACL, and
/// it cannot carry object metadata that the filesystem has no place for.
/// Multipart, same-platform copy and move are real here (see the multipart and
/// copy sections below); `list_files` describes the filesystem, but the port has
/// no listing method yet, so that flag is not a callable promise. Reporting any
/// of the absent ones as `true` would let the contract suite pass on a branch
/// that does nothing.
pub impl @platform.Platform for LocalPlatform with fn capabilities(_self) -> @model.Capabilities {
  @model.Capabilities::{
    multipart_upload: true,
    list_files: true,
    presigned_url: false,
    acl: false,
    metadata: false,
    same_copy: true,
    same_move: true,
  }
}

///|
async fn write_source(
  path : String,
  source : @model.UploadSource,
) -> Int64 raise @model.StorageError {
  let parent = parent_of(path)
  @fs.mkdir(parent, recursive=true, allow_exist=true) catch {
    error => raise os_detail("mkdir", parent, error)
  }
  match source {
    @model.UploadSource::Bytes(data) => {
      @fs.write_file(path, data) catch {
        error => raise os_detail("write", path, error)
      }
      data.length().to_int64()
    }
    @model.UploadSource::Path(from) => {
      let data = @fs.read_file(from) catch {
        error => raise os_detail("read source", from, error)
      }
      @fs.write_file(path, data) catch {
        error => raise os_detail("write", path, error)
      }
      @fs.file_size(path) catch {
        error => raise os_detail("stat", path, error)
      }
    }
    @model.UploadSource::Stream(reader, _length) => {
      let file = @fs.create(path, allow_existing=true) catch {
        error => raise os_detail("create", path, error)
      }
      file.write_reader(reader) catch {
        error => {
          file.close()
          raise os_detail("write stream", path, error)
        }
      }
      file.close()
      @fs.file_size(path) catch {
        error => raise os_detail("stat", path, error)
      }
    }
  }
}

///|
pub impl @platform.Platform for LocalPlatform with fn save(
  self,
  info : @model.FileInfo,
  source : @model.UploadSource,
) -> @model.FileInfo? raise @model.StorageError {
  if info.filename.is_empty() {
    raise @model.StorageError::InvalidInput("local save needs a filename")
  }
  let key = @model.object_key(info.base_path, info.filename)
  let target = join_path(self.config.root_dir, key)
  let size = write_source(target, source)
  Some(stored(info, key, url_of(self.config.domain, key), size))
}

///|
fn url_of(domain : String, path : String) -> String {
  join_path(domain, path)
}

///|
fn relative_of_url(domain : String, url : String) -> String? {
  let prefix = trim_trailing_slash(domain) + "/"
  if url.has_prefix(prefix) {
    Some(url[prefix.length():].to_owned())
  } else {
    None
  }
}

///|
pub impl @platform.Platform for LocalPlatform with fn get_file(
  self,
  url : String,
) -> @model.FileInfo? raise @model.StorageError {
  let key = match relative_of_url(self.config.domain, url) {
    Some(key) => key
    None =>
      raise @model.StorageError::InvalidInput(
        "url is not under this platform domain: " + url,
      )
  }
  let target = join_path(self.config.root_dir, key)
  let exists = @fs.exists(target) catch {
    error => raise os_detail("stat", target, error)
  }
  if !exists {
    None
  } else {
    let size = @fs.file_size(target) catch {
      error => raise os_detail("stat", target, error)
    }
    Some(@model.FileInfo::{
      id: None,
      url,
      size: Some(size),
      filename: file_name_of(key),
      original_filename: file_name_of(key),
      base_path: parent_of(key),
      path: key,
      ext: ext_of(key),
      content_type: None,
      platform: self.config.platform,
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
    })
  }
}

///|
fn file_name_of(key : String) -> String {
  match last_slash(key) {
    Some(index) => key[index + 1:].to_owned()
    None => key
  }
}

///|
fn ext_of(key : String) -> String {
  let name = file_name_of(key)
  let mut found : Int32? = None
  let mut index = name.length() - 1
  while index >= 0 && found is None {
    if name[index] == '.' {
      found = Some(index)
    }
    index = index - 1
  }
  match found {
    Some(index) => name[index + 1:].to_owned()
    None => ""
  }
}

///|
pub impl @platform.Platform for LocalPlatform with fn exists(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  let target = join_path(self.config.root_dir, info.path)
  @fs.exists(target) catch {
    error => raise os_detail("stat", target, error)
  }
}

///|
pub impl @platform.Platform for LocalPlatform with fn delete(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  let target = object_path(self.config.root_dir, info.path)
  let existed = @fs.exists(target) catch {
    error => raise os_detail("stat", target, error)
  }
  if !existed {
    false
  } else {
    @fs.remove(target) catch {
      error => raise os_detail("remove", target, error)
    }
    true
  }
}

///|
pub impl @platform.Platform for LocalPlatform with fn download(
  self,
  info : @model.FileInfo,
  writer : &@io.Writer,
) -> Unit raise @model.StorageError {
  let target = object_path(self.config.root_dir, info.path)
  let data = @fs.read_file(target) catch {
    error => raise os_detail("read", target, error)
  }
  writer.write(data) catch {
    error => raise os_detail("write destination", info.path, error)
  }
}

///|
/// Local multipart sessions keep the reference framework's shape: the parts live
/// in a directory named after the `upload_id` next to where the final object will
/// be, and `complete_multipart` concatenates them in part-number order. There is
/// no separate index file — a part's size and MD5 come from the file itself, so
/// the listing cannot drift from what is on disk.
let max_local_parts : Int32 = 10000

///|
fn require_upload_id(
  info : @model.FileInfo,
) -> String raise @model.StorageError {
  match info.upload_id {
    Some(id) if !id.is_empty() => id
    _ =>
      raise @model.StorageError::InvalidInput(
        "multipart needs the upload_id returned by init_multipart",
      )
  }
}

///|
fn new_upload_id() -> String raise @model.StorageError {
  // `IdError` carries no message worth relaying: the only ways it can refuse are
  // a clock that moved backwards or a counter overflow, and neither is the
  // caller's fault.
  @id.uuid_v4_random() catch {
    _ =>
      raise @model.StorageError::Platform(
        "local upload id: the id generator refused",
      )
  }
}

///|
/// Out-of-range part numbers are refused before any byte is written, the same
/// way the S3 leg refuses them before sending a request.
fn check_part_number(part_number : Int32) -> Unit raise @model.StorageError {
  if part_number < 1 || part_number > max_local_parts {
    let bound = "local part_number must be within 1..10000, got "
    raise @model.StorageError::InvalidInput(bound + part_number.to_string())
  }
}

///|
fn session_dir(target : String, upload_id : String) -> String {
  join_path(parent_of(target), upload_id)
}

///|
fn part_path(dir : String, part_number : Int32) -> String {
  join_path(dir, part_number.to_string())
}

///|
/// A part file is named by its number, so a name that is not decimal ASCII is
/// not a part — read as absent rather than guessed at.
fn parse_part_number(name : String) -> Int32? {
  let value = Some(@string.parse_int64(name, base=10)) catch { _ => None }
  match value {
    Some(number) if number >= 1L && number <= 10000L => Some(number.to_int())
    _ => None
  }
}

///|
async fn read_part(path : String) -> &@io.Data raise @model.StorageError {
  @fs.read_file(path) catch {
    error => raise os_detail("read part", path, error)
  }
}

///|
async fn part_etag(path : String) -> String raise @model.StorageError {
  let data = read_part(path)
  @hex.encode(@digest.md5_of_bytes(data.binary()))
}

///|
/// Keep the parts ordered by part number as they are collected. Merging in
/// arrival order would silently produce a different object than the client asked
/// for, and the contract compares bytes after the merge.
fn push_sorted(
  parts : Array[@model.FilePartInfo],
  part : @model.FilePartInfo,
) -> Unit {
  parts.push(part)
  let mut index = parts.length() - 1
  while index > 0 && parts[index - 1].part_number > parts[index].part_number {
    let earlier = parts[index - 1]
    parts[index - 1] = parts[index]
    parts[index] = earlier
    index = index - 1
  }
}

///|
pub impl @platform.Platform for LocalPlatform with fn init_multipart(
  self,
  info : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  if info.filename.is_empty() {
    raise @model.StorageError::InvalidInput(
      "local init_multipart needs a filename",
    )
  }
  let key = @model.object_key(info.base_path, info.filename)
  let target = object_path(self.config.root_dir, key)
  let upload_id = new_upload_id()
  let dir = session_dir(target, upload_id)
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    error => raise os_detail("mkdir", dir, error)
  }
  stamp_target(self.config, info, key, upload_id, None)
}

///|
pub impl @platform.Platform for LocalPlatform with fn upload_part(
  self,
  info : @model.FileInfo,
  part_number : Int32,
  source : @model.UploadSource,
) -> @model.FilePartInfo raise @model.StorageError {
  check_part_number(part_number)
  let upload_id = require_upload_id(info)
  let target = object_path(self.config.root_dir, info.path)
  let path = part_path(session_dir(target, upload_id), part_number)
  let size = write_source(path, source)
  @model.FilePartInfo::{
    platform: self.config.platform,
    upload_id,
    part_number,
    size,
    etag: part_etag(path),
  }
}

///|
pub impl @platform.Platform for LocalPlatform with fn list_parts(
  self,
  info : @model.FileInfo,
  part_number_marker : Int32,
) -> @model.PartPage raise @model.StorageError {
  let upload_id = require_upload_id(info)
  let target = object_path(self.config.root_dir, info.path)
  let dir = session_dir(target, upload_id)
  let names = @fs.readdir(dir) catch {
    error => raise os_detail("readdir", dir, error)
  }
  let parts : Array[@model.FilePartInfo] = []
  for name in names {
    match parse_part_number(name) {
      Some(part_number) if part_number > part_number_marker => {
        let path = join_path(dir, name)
        let size = @fs.file_size(path) catch {
          error => raise os_detail("stat", path, error)
        }
        push_sorted(parts, @model.FilePartInfo::{
          platform: self.config.platform,
          upload_id,
          part_number,
          size,
          etag: part_etag(path),
        })
      }
      _ => ()
    }
  }
  // Local parts are all in one directory, so there is never a next page.
  @model.PartPage::{
    parts,
    is_truncated: false,
    next_part_number_marker: None,
  }
}

///|
pub impl @platform.Platform for LocalPlatform with fn complete_multipart(
  self,
  info : @model.FileInfo,
  parts : Array[@model.FilePartInfo],
) -> @model.FileInfo raise @model.StorageError {
  let upload_id = require_upload_id(info)
  let target = object_path(self.config.root_dir, info.path)
  let dir = session_dir(target, upload_id)
  // The caller's list is not necessarily in part order, and merging in arrival
  // order would build a different object than the one asked for.
  let ordered : Array[@model.FilePartInfo] = []
  for part in parts {
    push_sorted(ordered, part)
  }
  // One handle, explicit offsets. `write_file(append=true)` still carries
  // `CreateOrTruncate` by default, and the contract caught the destination being
  // truncated between parts — a positioned write cannot be surprised by that.
  let file = @fs.create(target, allow_existing=true) catch {
    error => raise os_detail("create", target, error)
  }
  let mut offset = 0L
  let mut index = 0
  while index < ordered.length() {
    let path = part_path(dir, ordered[index].part_number)
    let data = read_part(path)
    file.write_at(data.binary(), position=offset) catch {
      error => {
        file.close()
        raise os_detail("merge part", path, error)
      }
    }
    offset = offset + data.binary().length().to_int64()
    index = index + 1
  }
  file.close()
  @fs.rmdir(dir, recursive=true) catch {
    error => raise os_detail("remove parts", dir, error)
  }
  // The size comes back from the file the merge produced, not from a sum kept in
  // here: the caller is about to hand that number to a record.
  let size = @fs.file_size(target) catch {
    error => raise os_detail("stat", target, error)
  }
  stamp_target(self.config, info, info.path, upload_id, Some(size))
}

///|
/// Aborting a session that is already gone is not an error — the caller asked for
/// "no parts left", and that is the state it gets.
pub impl @platform.Platform for LocalPlatform with fn abort_multipart(
  self,
  info : @model.FileInfo,
) -> Unit raise @model.StorageError {
  let upload_id = require_upload_id(info)
  let target = object_path(self.config.root_dir, info.path)
  let dir = session_dir(target, upload_id)
  let exists = @fs.exists(dir) catch {
    error => raise os_detail("stat", dir, error)
  }
  if exists {
    @fs.rmdir(dir, recursive=true) catch {
      error => raise os_detail("remove parts", dir, error)
    }
  }
}

///|
/// A local root is served as it is: there is no credential-bearing URL to hand
/// out, so claiming `presigned_url` would be a promise this storage cannot keep.
pub impl @platform.Platform for LocalPlatform with fn presigned_url(
  self,
  _info : @model.FileInfo,
  _method : @model.PresignMethod,
  _expires_seconds : Int32,
) -> String raise @model.StorageError {
  raise @model.StorageError::NotSupported(
    self.config.platform + " cannot sign a URL — the root is served as it is",
  )
}

///|
pub impl @platform.Platform for LocalPlatform with fn same_copy(
  self,
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  let (source, target, key) = same_operation(self.config, src, dest, "copy")
  let size = write_source(target, @model.UploadSource::Path(source))
  stamp_dest(self.config, dest, key, size)
}

///|
/// The move is a rename, so it stays on the same storage and never copies bytes
/// through the caller — the reason the reference framework keeps it as a platform
/// optimization instead of copy-then-delete.
pub impl @platform.Platform for LocalPlatform with fn same_move(
  self,
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  let (source, target, key) = same_operation(self.config, src, dest, "move")
  @fs.mkdir(parent_of(target), recursive=true, allow_exist=true) catch {
    error => raise os_detail("mkdir", parent_of(target), error)
  }
  @fs.rename(source, target, replace=true) catch {
    error => raise os_detail("rename", source, error)
  }
  let size = @fs.file_size(target) catch {
    error => raise os_detail("stat", target, error)
  }
  stamp_dest(self.config, dest, key, size)
}

///|
/// Shared front half of copy and move: resolve both keys and require the source
/// to exist. A missing source is `NotFound`, not a silent empty result — the
/// caller asked for an object that is not on this storage.
async fn same_operation(
  config : LocalConfig,
  src : @model.FileInfo,
  dest : @model.FileInfo,
  op : String,
) -> (String, String, String) raise @model.StorageError {
  if dest.filename.is_empty() {
    raise @model.StorageError::InvalidInput(
      "local same_" + op + " needs a destination filename",
    )
  }
  let source = object_path(config.root_dir, src.path)
  let exists = @fs.exists(source) catch {
    error => raise os_detail("stat", source, error)
  }
  if !exists {
    raise @model.StorageError::NotFound(
      "same_" + op + " source is not on this platform: " + src.path,
    )
  }
  let key = @model.object_key(dest.base_path, dest.filename)
  (source, join_path(config.root_dir, key), key)
}

///|
fn stamp_dest(
  config : LocalConfig,
  dest : @model.FileInfo,
  key : String,
  size : Int64,
) -> @model.FileInfo {
  dest.stamped(@model.Stamp::{
    platform: Some(config.platform),
    path: Some(key),
    url: Some(url_of(config.domain, key)),
    size: Some(size),
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
}

///|
fn stamp_target(
  config : LocalConfig,
  info : @model.FileInfo,
  key : String,
  upload_id : String,
  size : Int64?,
) -> @model.FileInfo {
  info.stamped(@model.Stamp::{
    platform: Some(config.platform),
    path: Some(key),
    url: Some(url_of(config.domain, key)),
    size,
    create_time: None,
    upload_id: Some(upload_id),
    upload_status: None,
    user_metadata: None,
  })
}

///|
/// One level of the tree, in the shape the reference framework's local storage
/// returns: directories come back as key prefixes ending in `/`, files as keys
/// relative to the root — the same coordinate space `exists` and `delete` use.
/// A directory that is not there lists nothing instead of failing, because
/// "empty" and "absent" answer the same question the caller is asking.
pub impl @platform.Platform for LocalPlatform with fn list_files(
  self,
  path : String,
  filename_prefix : String,
  _marker : String?,
) -> @model.FileListing raise @model.StorageError {
  let relative = trim_leading_slash(path)
  let dir = join_path(self.config.root_dir, relative)
  let dirs : Array[@model.ListedDir] = []
  let files : Array[@model.ListedFile] = []
  let kind = @fs.kind(dir) catch {
    error => raise os_detail("stat", dir, error)
  }
  if kind != @fs.FileKind::Directory {
    @model.FileListing::{
      dirs,
      files,
      is_truncated: false,
      next_continuation_token: None,
    }
  } else {
    let names = @fs.readdir(dir) catch {
      error => raise os_detail("readdir", dir, error)
    }
    for name in names {
      if !filename_prefix.is_empty() && !name.has_prefix(filename_prefix) {
        ()
      } else {
        let entry = join_path(dir, name)
        let key = if relative.is_empty() { name } else { relative + "/" + name }
        let entry_kind = @fs.kind(entry) catch {
          error => raise os_detail("stat", entry, error)
        }
        if entry_kind == @fs.FileKind::Directory {
          dirs.push(@model.ListedDir::{ path: key + "/", name, })
        } else {
          let size = @fs.file_size(entry) catch {
            error => raise os_detail("stat", entry, error)
          }
          let seconds = @fs.mtime(entry) catch {
            error => raise os_detail("mtime", entry, error)
          }
          let stamp = seconds.0.to_string()
          files.push(@model.ListedFile::{
            path: key,
            name,
            size,
            last_modified: Some(stamp),
            etag: None,
          })
        }
      }
    }
    @model.FileListing::{
      dirs,
      files,
      is_truncated: false,
      next_continuation_token: None,
    }
  }
}

///|
/// A filesystem has no object ACL to set: reporting `acl: false` and then
/// accepting the call would be the decorative claim the contract exists to catch.
pub impl @platform.Platform for LocalPlatform with fn set_file_acl(
  self,
  _info : @model.FileInfo,
  _acl : @model.CannedAcl,
) -> Unit raise @model.StorageError {
  raise @model.StorageError::NotSupported(
    self.config.platform + " has no object ACL to set",
  )
}

///|
pub extend LocalPlatform with @platform.Platform::{
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
pub impl @platform.Platform for LocalPlatform with fn close(_self) -> Unit {
  // A local platform holds no handles between calls; each operation opens and
  // closes what it needs, so there is nothing to release here.
  ()
}
