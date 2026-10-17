///|
/// Thin adapter from the storage port onto `mldong/moon-s3`. Everything protocol
/// shaped (signing, multipart, XML) stays in the SDK; this file only translates
/// `FileInfo` + `UploadSource` into SDK requests and SDK responses back.
///
/// `url` is built from `config.domain`, which this adapter **requires**: an S3
/// endpoint answer is not a public url, and inventing one would put a link in the
/// record that nobody can open.
pub struct S3Platform {
  priv config : S3PlatformConfig
}

///|
pub fn S3Platform::new(config : S3PlatformConfig) -> S3Platform {
  { config, }
}

///|
pub fn S3Platform::config(self : S3Platform) -> S3PlatformConfig {
  self.config
}

///|
fn platform_domain(platform : S3Platform) -> String raise @model.StorageError {
  match platform.config.domain {
    Some(domain) => domain
    None => {
      let name = "s3 platform " + platform.config.platform
      raise InvalidInput(name + " needs a domain to build urls")
    }
  }
}

///|
fn strip_trailing_slash(text : String) -> String {
  trim_trailing_slash(text)
}

///|
/// The last `/`-delimited segment of a key or common prefix.
fn last_segment(text : String) -> String {
  let body = strip_trailing_slash(text)
  let mut found : Int32? = None
  let mut index = body.length() - 1
  while index >= 0 && found is None {
    if body[index] == '/' {
      found = Some(index)
    }
    index = index - 1
  }
  match found {
    Some(at) => body[at + 1:].to_owned()
    None => body
  }
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
fn trim_trailing_slash(text : String) -> String {
  let mut end = text.length()
  while end > 0 && text[end - 1] == '/' {
    end = end - 1
  }
  text[0:end].to_owned()
}

///|
fn map_error(error : @sdk.S3Error) -> @model.StorageError {
  match error {
    @sdk.S3Error::Service(details) => {
      let head = "s3 " + details.status_code.to_string()
      let code = head + " " + details.code
      @model.StorageError::Platform(code + ": " + details.message)
    }
    @sdk.S3Error::InvalidConfig(detail) =>
      @model.StorageError::Platform("s3 config: " + detail)
    @sdk.S3Error::InvalidRequest(detail) =>
      @model.StorageError::Platform("s3 request: " + detail)
    @sdk.S3Error::Signing(_) =>
      @model.StorageError::Platform("s3 signing failed")
    @sdk.S3Error::Transport(_) =>
      @model.StorageError::Platform("s3 transport failed")
  }
}

///|
/// "No such key" arrives as 404 (GET) or as a 404 with an empty body (HEAD, which
/// the SDK already turns into `NoSuchKey`); anything else is a real failure and
/// must not be swallowed into "absent".
fn is_absent(error : @sdk.S3Error) -> Bool {
  match error {
    @sdk.S3Error::Service(details) =>
      details.status_code == 404 || details.code == "NoSuchKey"
    _ => false
  }
}

///|
pub impl @platform.Platform for S3Platform with fn name(self : S3Platform) -> String {
  self.config.platform
}

///|
/// These flags describe what this storage family can do, which is what the
/// reference framework's `isSupportXxx` means. Every flag here now has a port
/// method behind it: `list_files` maps to ListObjects with a `/` delimiter, `acl`
/// maps to `PUT /key?acl` with a canned value. Whether the grant really lands is
/// answered by the endpoint, which the s3 leg reads back with `get_object_acl`.
pub impl @platform.Platform for S3Platform with fn capabilities(
  _self : S3Platform,
) -> @model.Capabilities {
  @model.Capabilities::{
    multipart_upload: true,
    list_files: true,
    presigned_url: true,
    acl: _self.config.supports_acl,
    metadata: true,
    same_copy: true,
    same_move: true,
  }
}

///|
async fn S3Platform::put(
  self : S3Platform,
  key : String,
  body : @transport.RequestBody,
  content_type : String?,
  metadata : Map[String, String],
) -> Int64 raise @model.StorageError {
  let request : @sdk.PutObjectRequest = {
    bucket: self.config.bucket,
    key,
    body,
    content_type,
    metadata,
  }
  let _ = self.config.client.put_object(request) catch {
    error => raise map_error(error)
  }
  // The size comes back from a stat rather than from the request: a streamed
  // body carries no length the caller can be trusted with.
  let stat = self.config.client.stat_object({ bucket: self.config.bucket, key, }) catch {
    error => raise map_error(error)
  }
  stat.content_length
}

///|
pub impl @platform.Platform for S3Platform with fn save(
  self,
  info : @model.FileInfo,
  source : @model.UploadSource,
) -> @model.FileInfo? raise @model.StorageError {
  if info.filename.is_empty() {
    raise InvalidInput("s3 save needs a filename")
  }
  let domain = trim_trailing_slash(platform_domain(self))
  let key = @model.object_key(info.base_path, info.filename)
  let body = match source {
    @model.UploadSource::Bytes(data) => @transport.RequestBody::Bytes(data)
    @model.UploadSource::Stream(reader, length) =>
      @transport.RequestBody::Stream(reader, length)
    @model.UploadSource::Path(_) =>
      raise NotSupported(
        "s3 platform uploads bytes or a reader; open the file and pass its reader",
      )
  }
  let size = self.put(key, body, info.content_type, info.user_metadata)
  Some(
    info.stamped(@model.Stamp::{
      platform: None,
      path: Some(key),
      url: Some(domain + "/" + key),
      size: Some(size),
      create_time: None,
      upload_id: None,
      upload_status: None,
      user_metadata: None,
    }),
  )
}

///|
fn key_of_url(domain : String, url : String) -> String? {
  let prefix = trim_trailing_slash(domain) + "/"
  if url.has_prefix(prefix) {
    Some(url[prefix.length():].to_owned())
  } else {
    None
  }
}

///|
async fn S3Platform::stat(
  self : S3Platform,
  key : String,
) -> @sdk.StatObjectResponse? raise @model.StorageError {
  let stat = Some(
    self.config.client.stat_object({ bucket: self.config.bucket, key, }),
  ) catch {
    error => if is_absent(error) { None } else { raise map_error(error) }
  }
  stat
}

///|
pub impl @platform.Platform for S3Platform with fn get_file(self, url : String) -> @model.FileInfo? raise @model.StorageError {
  let domain = platform_domain(self)
  let key = match key_of_url(domain, url) {
    Some(key) => key
    None => raise InvalidInput("url is not under this platform domain: " + url)
  }
  match self.stat(key) {
    None => None
    Some(stat) =>
      Some(
        @model.FileInfo::draft(
          self.config.platform,
          parent_of_key(key),
          file_name_of_key(key),
          ext_of_key(key),
        ).stamped(@model.Stamp::{
          platform: None,
          path: Some(key),
          url: Some(trim_trailing_slash(domain) + "/" + key),
          size: Some(stat.content_length),
          create_time: None,
          upload_id: None,
          upload_status: None,
          user_metadata: Some(stat.metadata),
        }),
      )
  }
}

///|
fn parent_of_key(key : String) -> String {
  let mut found : Int32? = None
  let mut index = key.length() - 1
  while index >= 0 && found is None {
    if key[index] == '/' {
      found = Some(index)
    }
    index = index - 1
  }
  match found {
    Some(index) => key[0:index].to_owned()
    None => ""
  }
}

///|
fn file_name_of_key(key : String) -> String {
  match parent_of_key(key) {
    "" => key
    parent => key[parent.length() + 1:].to_owned()
  }
}

///|
fn ext_of_key(key : String) -> String {
  let name = file_name_of_key(key)
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
fn require_key(path : String) -> String raise @model.StorageError {
  if path.is_empty() {
    // The suite found this shape too: an unstamped draft would otherwise address
    // the bucket prefix itself, where HEAD/GET answer with a directory listing.
    raise @model.StorageError::InvalidInput("s3 object needs a key")
  }
  path
}

///|
pub impl @platform.Platform for S3Platform with fn exists(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  self.stat(require_key(info.path)) is Some(_)
}

///|
/// S3 `DELETE` is idempotent and answers 204 for a key that is not there, so the
/// port's `Bool` can only come from checking first.
pub impl @platform.Platform for S3Platform with fn delete(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  let key = require_key(info.path)
  let existed = self.stat(key) is Some(_)
  if existed {
    let _ = self.config.client.delete_object({
      bucket: self.config.bucket,
      key,
    }) catch {
      error => raise map_error(error)
    }
  }
  existed
}

///|
async fn pump_body(
  body : &@transport.ResponseBody,
  writer : &@io.Writer,
) -> Unit raise @model.StorageError {
  let mut done = false
  while !done {
    let chunk = body.read(65536) catch {
      @transport.TransportError::Network(msg) =>
        raise Platform("read response body: " + msg)
      @transport.TransportError::Timeout =>
        raise Platform("read response body: timeout")
      @transport.TransportError::InvalidRequest(msg) =>
        raise Platform("read response body: " + msg)
      @transport.TransportError::InvalidResponse(msg) =>
        raise Platform("read response body: " + msg)
    }
    match chunk {
      None => done = true
      Some(data) =>
        writer.write(data) catch {
          error => raise Platform("write destination: " + error.to_string())
        }
    }
  }
  body.close()
}

///|
pub impl @platform.Platform for S3Platform with fn download(
  self,
  info : @model.FileInfo,
  writer : &@io.Writer,
) -> Unit raise @model.StorageError {
  let key = require_key(info.path)
  let response = self.config.client.get_object({
    bucket: self.config.bucket,
    key,
    range: None,
  }) catch {
    error => raise map_error(error)
  }
  pump_body(response.body, writer)
}

///|
pub impl @platform.Platform for S3Platform with fn close(_self : S3Platform) -> Unit {
  // The SDK holds no per-platform handles; each request opens and closes its own
  // response body.
  ()
}

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
/// A part must carry its length: `UploadPart` signs a request whose
/// `Content-Length` is part of what the service checks, so a stream without a
/// known length cannot be sent rather than sent wrong.
fn part_body(
  source : @model.UploadSource,
) -> (@transport.RequestBody, Int64) raise @model.StorageError {
  match source {
    @model.UploadSource::Bytes(data) =>
      (@transport.RequestBody::Bytes(data), data.length().to_int64())
    @model.UploadSource::Stream(reader, Some(length)) =>
      (@transport.RequestBody::Stream(reader, Some(length)), length)
    @model.UploadSource::Stream(_, None) =>
      raise InvalidInput("s3 upload_part needs a part of known length")
    @model.UploadSource::Path(_) =>
      raise NotSupported(
        "s3 platform uploads bytes or a reader; open the file and pass its reader",
      )
  }
}

///|
fn push_part_ascending(
  parts : Array[@sdk.CompletedPart],
  part : @sdk.CompletedPart,
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
pub impl @platform.Platform for S3Platform with fn init_multipart(
  self,
  info : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  if info.filename.is_empty() {
    raise InvalidInput("s3 init_multipart needs a filename")
  }
  let domain = trim_trailing_slash(platform_domain(self))
  let key = @model.object_key(info.base_path, info.filename)
  let started = self.config.client.create_multipart_upload({
    bucket: self.config.bucket,
    key,
    content_type: info.content_type,
    metadata: info.user_metadata,
  }) catch {
    error => raise map_error(error)
  }
  info.stamped(@model.Stamp::{
    platform: None,
    path: Some(key),
    url: Some(domain + "/" + key),
    size: None,
    create_time: None,
    upload_id: Some(started.upload_id),
    upload_status: None,
    user_metadata: None,
  })
}

///|
pub impl @platform.Platform for S3Platform with fn upload_part(
  self,
  info : @model.FileInfo,
  part_number : Int32,
  source : @model.UploadSource,
) -> @model.FilePartInfo raise @model.StorageError {
  let upload_id = require_upload_id(info)
  let key = require_key(info.path)
  let (body, size) = part_body(source)
  let part = self.config.client.upload_part({
    bucket: self.config.bucket,
    key,
    upload_id,
    part_number,
    body,
  }) catch {
    error => raise map_error(error)
  }
  @model.FilePartInfo::{
    platform: self.config.platform,
    upload_id,
    part_number,
    size,
    etag: part.etag,
  }
}

///|
pub impl @platform.Platform for S3Platform with fn list_parts(
  self,
  info : @model.FileInfo,
  part_number_marker : Int32,
) -> @model.PartPage raise @model.StorageError {
  let upload_id = require_upload_id(info)
  let key = require_key(info.path)
  let page = self.config.client.list_parts({
    bucket: self.config.bucket,
    key,
    upload_id,
    part_number_marker: Some(part_number_marker),
    max_parts: None,
  }) catch {
    error => raise map_error(error)
  }
  let parts : Array[@model.FilePartInfo] = []
  for part in page.parts {
    parts.push(@model.FilePartInfo::{
      platform: self.config.platform,
      upload_id,
      part_number: part.part_number,
      size: part.size,
      etag: part.etag,
    })
  }
  @model.PartPage::{
    parts,
    is_truncated: page.is_truncated,
    next_part_number_marker: page.next_part_number_marker,
  }
}

///|
pub impl @platform.Platform for S3Platform with fn complete_multipart(
  self,
  info : @model.FileInfo,
  parts : Array[@model.FilePartInfo],
) -> @model.FileInfo raise @model.StorageError {
  let upload_id = require_upload_id(info)
  let key = require_key(info.path)
  let ordered : Array[@sdk.CompletedPart] = []
  for part in parts {
    push_part_ascending(ordered, @sdk.CompletedPart::{
      part_number: part.part_number,
      etag: part.etag,
    })
  }
  let _ = self.config.client.complete_multipart_upload({
    bucket: self.config.bucket,
    key,
    upload_id,
    parts: ordered,
  }) catch {
    error => raise map_error(error)
  }
  // The size is read back from the object the service just assembled; the merge
  // happened on its side, so this is the only number that means anything.
  let size = match self.stat(key) {
    Some(value) => value.content_length
    None =>
      raise Platform(
        "s3 completed the upload but the object is not readable: " + key,
      )
  }
  info.stamped(@model.Stamp::{
    platform: None,
    path: None,
    url: None,
    size: Some(size),
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
}

///|
pub impl @platform.Platform for S3Platform with fn abort_multipart(
  self,
  info : @model.FileInfo,
) -> Unit raise @model.StorageError {
  let upload_id = require_upload_id(info)
  let key = require_key(info.path)
  let _ = self.config.client.abort_multipart_upload({
    bucket: self.config.bucket,
    key,
    upload_id,
  }) catch {
    error => raise map_error(error)
  }
}

///|
pub impl @platform.Platform for S3Platform with fn presigned_url(
  self,
  info : @model.FileInfo,
  verb : @model.PresignMethod,
  expires_seconds : Int32,
) -> String raise @model.StorageError {
  let key = require_key(info.path)
  let http_verb = match verb {
    @model.PresignMethod::Get => @transport.Method::Get
    @model.PresignMethod::Put => @transport.Method::Put
  }
  self.config.client.presigned_url(
    self.config.bucket,
    key,
    http_verb,
    expires_seconds,
  ) catch {
    error => raise map_error(error)
  }
}

///|
/// The destination of a same-platform copy or move: the draft carries the base
/// path and the new name, the key is derived the same way `save` derives it.
fn S3Platform::dest_key(
  _self : S3Platform,
  dest : @model.FileInfo,
  op : String,
) -> String raise @model.StorageError {
  if dest.filename.is_empty() {
    raise InvalidInput("s3 same_" + op + " needs a destination filename")
  }
  @model.object_key(dest.base_path, dest.filename)
}

///|
fn S3Platform::stamped_dest(
  self : S3Platform,
  dest : @model.FileInfo,
  key : String,
  size : Int64,
) -> @model.FileInfo raise @model.StorageError {
  let domain = trim_trailing_slash(platform_domain(self))
  dest.stamped(@model.Stamp::{
    platform: Some(self.config.platform),
    path: Some(key),
    url: Some(domain + "/" + key),
    size: Some(size),
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
}

///|
/// A copy whose source is missing is `NotFound`, not an empty answer: the caller
/// named an object this storage does not have. (Objects over the single-request
/// copy limit are out of scope here — that needs an upload-part-copy loop.)
async fn S3Platform::copy_between(
  self : S3Platform,
  src : @model.FileInfo,
  dest : @model.FileInfo,
  op : String,
) -> @model.FileInfo raise @model.StorageError {
  let source_key = require_key(src.path)
  match self.stat(source_key) {
    None =>
      raise @model.StorageError::NotFound(
        "same_" + op + " source is not on this platform: " + source_key,
      )
    Some(_) => ()
  }
  let target_key = self.dest_key(dest, op)
  let _ = self.config.client.copy_object({
    bucket: self.config.bucket,
    key: target_key,
    source_bucket: self.config.bucket,
    source_key,
  }) catch {
    error => raise map_error(error)
  }
  let size = match self.stat(target_key) {
    Some(value) => value.content_length
    None =>
      raise Platform("s3 copied " + source_key + " but cannot see the result")
  }
  self.stamped_dest(dest, target_key, size)
}

///|
pub impl @platform.Platform for S3Platform with fn same_copy(
  self,
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  self.copy_between(src, dest, "copy")
}

///|
/// S3 has no move verb, so the move is a copy followed by deleting the source —
/// still inside one storage, which is what makes it a platform optimization.
pub impl @platform.Platform for S3Platform with fn same_move(
  self,
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  let moved = self.copy_between(src, dest, "move")
  // Hoisted out of the request literal: leaving it there would mix a
  // `StorageError` from the key check into a `catch` that only sees `S3Error`.
  let source_key = require_key(src.path)
  let _ = self.config.client.delete_object({
    bucket: self.config.bucket,
    key: source_key,
  }) catch {
    error => raise map_error(error)
  }
  moved
}

///|
/// One level: the store's common prefixes become directories, its object
/// summaries become files. The directory marker object (a key ending in `/`)
/// is dropped — the prefix entry already represents it, and reporting both
/// would make the same name appear twice with different meanings.
pub impl @platform.Platform for S3Platform with fn list_files(
  self,
  path : String,
  filename_prefix : String,
  marker : String?,
) -> @model.FileListing raise @model.StorageError {
  let base = trim_leading_slash(path)
  // The directory scope needs its separator: "listing" + "a" would otherwise
  // address a sibling named "listinga" and the filtered page would come back empty.
  let prefix = if base.is_empty() {
    filename_prefix
  } else {
    strip_trailing_slash(base) + "/" + filename_prefix
  }
  let listing = self.config.client.list_objects({
    bucket: self.config.bucket,
    prefix: Some(prefix),
    delimiter: Some("/"),
    continuation_token: marker,
    max_keys: Some(1000),
  }) catch {
    error => raise map_error(error)
  }
  let dirs : Array[@model.ListedDir] = []
  for common in listing.common_prefixes {
    let name = last_segment(strip_trailing_slash(common))
    dirs.push(@model.ListedDir::{ path: common, name, })
  }
  let files : Array[@model.ListedFile] = []
  for object in listing.objects {
    if object.key.has_suffix("/") {
      ()
    } else {
      files.push(@model.ListedFile::{
        path: object.key,
        name: last_segment(object.key),
        size: object.size,
        last_modified: object.last_modified,
        etag: object.etag,
      })
    }
  }
  @model.FileListing::{
    dirs,
    files,
    is_truncated: listing.is_truncated,
    next_continuation_token: listing.next_continuation_token,
  }
}

///|
pub impl @platform.Platform for S3Platform with fn set_file_acl(
  self,
  info : @model.FileInfo,
  acl : @model.CannedAcl,
) -> Unit raise @model.StorageError {
  // Refuse before sending when the deployment was declared without ACL writes:
  // the reference framework gates on `isSupportAcl` for the same reason, and a
  // call that reaches the endpoint only to collect a 501 is not a refusal.
  if !self.config.supports_acl {
    raise @model.StorageError::NotSupported(
      self.config.platform + " endpoint does not support setting ACL",
    )
  }
  let key = require_key(info.path)
  let _ = self.config.client.put_object_acl({
    bucket: self.config.bucket,
    key,
    acl: acl.header_value(),
  }) catch {
    error => raise map_error(error)
  }
}

///|
pub extend S3Platform with @platform.Platform::{
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
