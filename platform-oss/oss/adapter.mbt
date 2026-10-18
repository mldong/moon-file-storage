///|
/// 存储端口到 `mldong/moon-oss`（阿里云 OSS 原生协议）的薄适配层。协议形状（V4 签名、
/// 虚主机寻址、分片、XML）全部留在 SDK 里，这个文件只做两件事：把 `FileInfo` +
/// `UploadSource` 翻译成 SDK 请求，把 SDK 的读数与错误翻译回来。
///
/// `url` 由 `config.domain` 拼（与 `platform-s3`／`platform-qiniu` 同一口径）：OSS 的
/// 回包里没有可公开打开的链接，自己编一条就是往记录里放一条打不开的地址。

///|
pub struct OssPlatform {
  priv config : OssPlatformConfig
}

///|
pub fn OssPlatform::new(config : OssPlatformConfig) -> OssPlatform {
  { config, }
}

///|
pub fn OssPlatform::config(self : OssPlatform) -> OssPlatformConfig {
  self.config
}

///|
fn platform_domain(platform : OssPlatform) -> String raise @model.StorageError {
  match platform.config.domain {
    Some(domain) => domain
    None => {
      let name = "oss platform " + platform.config.platform
      raise @model.StorageError::InvalidInput(
        name + " needs a domain to build urls",
      )
    }
  }
}

///|
fn strip_trailing_slash(text : String) -> String {
  trim_trailing_slash(text)
}

///|
/// key 或公共前缀的最后一段（去掉尾部分隔符之后）。
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
/// key 不能是空串：空 key 打到桶前缀本身，那边"不存在"与"是个目录"分不清。
fn require_key(path : String) -> String raise @model.StorageError {
  if path.is_empty() {
    raise @model.StorageError::InvalidInput("oss object needs a key")
  }
  path
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
/// 域名下的 key：`get_file` 只认本平台域名前缀的 URL，别的域名一律不猜。
fn key_of_url(domain : String, url : String) -> String? {
  let prefix = trim_trailing_slash(domain) + "/"
  if url.has_prefix(prefix) {
    Some(url[prefix.length():].to_owned())
  } else {
    None
  }
}

///|
fn request_id_of(details : @osserr.ServiceError) -> String {
  details.request_id.unwrap_or("<none>")
}

///|
/// 服务端那一档的一行读数：状态码、`<Code>`、`<Message>` 与 `x-oss-request-id`。
/// 状态码必须单独带上——`HEAD /<key>` 的 404 **没有 XML 正文**（2026-10-18 真桶现读），
/// 那一档的 `code` 与 `message` 都是空串，只抄 `code` 的文案会什么都不说。
fn service_text(details : @osserr.ServiceError) -> String {
  let head = "oss " + details.status.to_string() + " " + details.code
  head + " " + details.message + " reqid=" + request_id_of(details)
}

///|
/// 错误分档：`Service` 里只有 404 折成 `NotFound`（`NoSuchKey`/`NoSuchBucket` 都在这
/// 一档），其余状态码原样进 `Platform` 的文案；本地拒掉的三臂各归各——把"没连上"与
/// "服务端答了但拒绝"混成一谈，重试策略就会被带偏（同 moon-kodo 的理由）。
fn map_error(error : @osserr.OssError) -> @model.StorageError {
  match error {
    @osserr.OssError::BadParam(detail) =>
      @model.StorageError::InvalidInput("oss param: " + detail)
    @osserr.OssError::Network(detail) =>
      @model.StorageError::Platform("oss network: " + detail)
    @osserr.OssError::BadResponse(detail) =>
      @model.StorageError::Platform("oss response: " + detail)
    @osserr.OssError::Service(details) =>
      if details.status == 404 {
        @model.StorageError::NotFound(service_text(details))
      } else {
        @model.StorageError::Platform(service_text(details))
      }
  }
}

///|
/// "不存在"**只看 `status`**：真桶的 `HEAD /<key>` 404 回包没有正文，`code` 是空串，
/// 照 `code` 判会把每一次"没有"都读成未知错误。其余错误不许顺手折叠成"没有"——
/// 那会把服务端的拒绝读成一次成功的删除。
fn is_absent(error : @osserr.OssError) -> Bool {
  match error {
    @osserr.OssError::Service(details) => details.status == 404
    _ => false
  }
}

///|
fn meta_pairs(metadata : Map[String, String]) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for pair in metadata.iter() {
    out.push(pair)
  }
  out
}

///|
fn pairs_meta(pairs : Array[(String, String)]) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  for pair in pairs {
    out[pair.0] = pair.1
  }
  out
}

///|
/// ListParts 的续页标记在协议里是字符串，端点不给就是"到底了"。读不出数字就当没有
/// 下一页标记，不硬造一个 `0`——那会让调用方把"到底"读成"从第一片重来"。
fn marker_to_int32(text : String) -> Int32? {
  let parsed = Some(@string.parse_int(text.view(), base=10)) catch { _ => None }
  parsed
}

///|
/// SDK 的写侧只收 `Bytes`，所以流档在这里整段攒出来。本地文件那一档本端口不读盘
/// （与 `platform-s3`／`platform-qiniu` 同口径：调用方自己开句柄再传 reader）。
async fn read_source(
  source : @model.UploadSource,
) -> Bytes raise @model.StorageError {
  match source {
    @model.UploadSource::Bytes(data) => data
    @model.UploadSource::Stream(reader, _) => {
      let merged : Array[Byte] = []
      let mut done = false
      while !done {
        // `read_some` 而不是定长缓冲：这层要的是攒出整份字节，不是逐块转发
        let chunk = reader.read_some(max_len=65536) catch {
          err =>
            raise @model.StorageError::Platform(
              "read upload source: " + err.to_string(),
            )
        }
        match chunk {
          None => done = true
          Some(data) => merged.append(data.to_array())
        }
      }
      Bytes::from_array(merged)
    }
    @model.UploadSource::Path(_) =>
      raise @model.StorageError::NotSupported(
        "oss platform uploads bytes or a reader; open the file and pass its reader",
      )
  }
}

///|
pub impl @platform.Platform for OssPlatform with fn name(self : OssPlatform) -> String {
  self.config.platform
}

///|
/// 七个能力位逐个有出处，全是 2026-10-18 真桶读数：分片五步、ListObjects V2 单层
/// 列举、预签名 GET 与 PUT、`x-oss-meta-*` 写了能读回、同桶 `copy_object` 都验过。
/// `acl` 报 **false**：写 `x-oss-object-acl: public-read` 被桶侧拒 403 `AccessDenied`
/// （"Put public object acl is not allowed"），`private` 才收，而读回来的 grant 是
/// `default` 不是 `private`——契约那三档 canned 名与 OSS 的取值面本就不同名，这一族
/// 在契约语义下兑不了现。所以它不是 `platform-s3` 那种"端点不做、可以由接入方关掉"
/// 的开关，这里直接写死。
pub impl @platform.Platform for OssPlatform with fn capabilities(
  _self : OssPlatform,
) -> @model.Capabilities {
  @model.Capabilities::{
    multipart_upload: true,
    list_files: true,
    presigned_url: true,
    acl: false,
    metadata: true,
    same_copy: true,
    same_move: true,
  }
}

///|
async fn OssPlatform::stat(
  self : OssPlatform,
  key : String,
) -> @sdk.ObjectStat? raise @model.StorageError {
  let read = Some(self.config.client.stat_object(self.config.bucket, key)) catch {
    error => if is_absent(error) { None } else { raise map_error(error) }
  }
  read
}

///|
/// 写一个对象并把它读回来。尺寸与元数据都取自 `stat` 的读数：要说的是服务端存下的
/// 那一份，不是请求里的那一份（`put_object` 的回包只给 etag）。
async fn OssPlatform::put(
  self : OssPlatform,
  key : String,
  data : Bytes,
  content_type : String?,
  metadata : Map[String, String],
) -> @sdk.ObjectStat raise @model.StorageError {
  let _ = self.config.client.put_object(
    self.config.bucket,
    key,
    data,
    content_type=content_type.unwrap_or(""),
    metadata=meta_pairs(metadata),
  ) catch {
    error => raise map_error(error)
  }
  match self.stat(key) {
    None =>
      raise @model.StorageError::Platform(
        "oss stored " + key + " but it is not readable back",
      )
    Some(stat) => stat
  }
}

///|
pub impl @platform.Platform for OssPlatform with fn save(
  self,
  info : @model.FileInfo,
  source : @model.UploadSource,
) -> @model.FileInfo? raise @model.StorageError {
  if info.filename.is_empty() {
    raise @model.StorageError::InvalidInput("oss save needs a filename")
  }
  let domain = trim_trailing_slash(platform_domain(self))
  let key = @model.object_key(info.base_path, info.filename)
  let data = read_source(source)
  let stat = self.put(key, data, info.content_type, info.user_metadata)
  Some(
    info.stamped(@model.Stamp::{
      platform: None,
      path: Some(key),
      url: Some(domain + "/" + key),
      size: Some(stat.size),
      create_time: None,
      upload_id: None,
      upload_status: None,
      user_metadata: Some(pairs_meta(stat.metadata)),
    }),
  )
}

///|
pub impl @platform.Platform for OssPlatform with fn get_file(self, url : String) -> @model.FileInfo? raise @model.StorageError {
  let domain = platform_domain(self)
  let key = match key_of_url(domain, url) {
    Some(key) => key
    None =>
      raise @model.StorageError::InvalidInput(
        "url is not under this platform domain: " + url,
      )
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
          size: Some(stat.size),
          create_time: None,
          upload_id: None,
          upload_status: None,
          user_metadata: Some(pairs_meta(stat.metadata)),
        }),
      )
  }
}

///|
pub impl @platform.Platform for OssPlatform with fn exists(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  self.stat(require_key(info.path)) is Some(_)
}

///|
/// OSS 的 `DELETE` 对"本来就不存在"一样回 204，端口那个 `Bool` 只能先查再删来得。
pub impl @platform.Platform for OssPlatform with fn delete(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  let key = require_key(info.path)
  let existed = self.stat(key) is Some(_)
  if existed {
    self.config.client.delete_object(self.config.bucket, key) catch {
      error => raise map_error(error)
    }
  }
  existed
}

///|
/// `get_object` 已经把整段正文读回（SDK 那一层没有留流式档），这里只管搬过去。
pub impl @platform.Platform for OssPlatform with fn download(
  self,
  info : @model.FileInfo,
  writer : &@io.Writer,
) -> Unit raise @model.StorageError {
  let key = require_key(info.path)
  let data = self.config.client.get_object(self.config.bucket, key) catch {
    error => raise map_error(error)
  }
  writer.write(data.body) catch {
    error =>
      raise @model.StorageError::Platform(
        "write destination: " + error.to_string(),
      )
  }
}

///|
pub impl @platform.Platform for OssPlatform with fn init_multipart(
  self,
  info : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  if info.filename.is_empty() {
    raise @model.StorageError::InvalidInput(
      "oss init_multipart needs a filename",
    )
  }
  let domain = trim_trailing_slash(platform_domain(self))
  let key = @model.object_key(info.base_path, info.filename)
  let started = self.config.client.create_multipart_upload(
    self.config.bucket,
    key,
    content_type=info.content_type.unwrap_or(""),
    metadata=meta_pairs(info.user_metadata),
  ) catch {
    error => raise map_error(error)
  }
  info.stamped(@model.Stamp::{
    platform: None,
    path: Some(key),
    url: Some(domain + "/" + key),
    size: None,
    create_time: None,
    upload_id: Some(started),
    upload_status: None,
    user_metadata: None,
  })
}

///|
pub impl @platform.Platform for OssPlatform with fn upload_part(
  self,
  info : @model.FileInfo,
  part_number : Int32,
  source : @model.UploadSource,
) -> @model.FilePartInfo raise @model.StorageError {
  let upload_id = require_upload_id(info)
  let key = require_key(info.path)
  let data = read_source(source)
  // 分片号越界由 SDK 在发出任何请求之前拒（`BadParam`），这里不重做一遍判据
  let etag = self.config.client.upload_part(
    self.config.bucket,
    key,
    upload_id,
    part_number,
    data,
  ) catch {
    error => raise map_error(error)
  }
  @model.FilePartInfo::{
    platform: self.config.platform,
    upload_id,
    part_number,
    size: data.length().to_int64(),
    etag,
  }
}

///|
pub impl @platform.Platform for OssPlatform with fn list_parts(
  self,
  info : @model.FileInfo,
  part_number_marker : Int32,
) -> @model.PartPage raise @model.StorageError {
  let upload_id = require_upload_id(info)
  let key = require_key(info.path)
  let page = self.config.client.list_parts(
    self.config.bucket,
    key,
    upload_id,
    part_number_marker~,
  ) catch {
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
    next_part_number_marker: match page.next_part_number_marker {
      Some(marker) => marker_to_int32(marker)
      None => None
    },
  }
}

///|
/// 分片必须按号升序交给 `CompleteMultipartUpload`：SDK 那一层刻意不重排（重排会把
/// "调用方给的顺序不对"这个真错藏起来），所以排序是这条腿的活。
fn push_part_ascending(
  parts : Array[(Int32, String)],
  part_number : Int32,
  etag : String,
) -> Unit {
  parts.push((part_number, etag))
  let mut index = parts.length() - 1
  while index > 0 && parts[index - 1].0 > parts[index].0 {
    let earlier = parts[index - 1]
    parts[index - 1] = parts[index]
    parts[index] = earlier
    index = index - 1
  }
}

///|
pub impl @platform.Platform for OssPlatform with fn complete_multipart(
  self,
  info : @model.FileInfo,
  parts : Array[@model.FilePartInfo],
) -> @model.FileInfo raise @model.StorageError {
  let upload_id = require_upload_id(info)
  let key = require_key(info.path)
  let ordered : Array[(Int32, String)] = []
  for part in parts {
    push_part_ascending(ordered, part.part_number, part.etag)
  }
  let _ = self.config.client.complete_multipart_upload(
    self.config.bucket,
    key,
    upload_id,
    ordered,
  ) catch {
    error => raise map_error(error)
  }
  // 合并发生在服务端，尺寸只能读回来：这是这条记录上唯一有意义的数字。
  // 完成件的 ETag 带 `-N` 后缀（两片就是 `…-2`），本端口不存 ETag，不必为它特判。
  let size = match self.stat(key) {
    Some(stat) => stat.size
    None =>
      raise @model.StorageError::Platform(
        "oss completed the upload but the object is not readable: " + key,
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
pub impl @platform.Platform for OssPlatform with fn abort_multipart(
  self,
  info : @model.FileInfo,
) -> Unit raise @model.StorageError {
  let upload_id = require_upload_id(info)
  let key = require_key(info.path)
  self.config.client.abort_multipart_upload(self.config.bucket, key, upload_id) catch {
    error => raise map_error(error)
  }
}

///|
/// 两档都签得出（2026-10-18 真桶：免凭据 GET 回 200、按 PUT 直传回 200）。
/// PUT 那一档**不锁 Content-Type**：`content_type~` 一旦给定就参与签名，直传方换个值
/// 发出去就是 `SignatureDoesNotMatch`，而契约那档只验"这条 URL 能免凭据 PUT 上去"。
/// 有效期的界（1..604800 秒）由签名那层把关，越界在本地 `BadParam`，不发请求。
pub impl @platform.Platform for OssPlatform with fn presigned_url(
  self,
  info : @model.FileInfo,
  verb : @model.PresignMethod,
  expires_seconds : Int32,
) -> String raise @model.StorageError {
  let key = require_key(info.path)
  let expires = expires_seconds.to_int64()
  let client = self.config.client
  match verb {
    @model.PresignMethod::Get =>
      client.presigned_get_url(self.config.bucket, key, expires_sec=expires) catch {
        error => raise map_error(error)
      }
    @model.PresignMethod::Put =>
      client.presigned_put_url(self.config.bucket, key, expires_sec=expires) catch {
        error => raise map_error(error)
      }
  }
}

///|
/// 复制／移动的目标位：草稿带基路径与新名字，key 的拼法与 `save` 同一把尺。
fn dest_key(
  dest : @model.FileInfo,
  op : String,
) -> String raise @model.StorageError {
  if dest.filename.is_empty() {
    let head = "oss same_" + op + " needs a destination filename"
    raise @model.StorageError::InvalidInput(head)
  }
  @model.object_key(dest.base_path, dest.filename)
}

///|
/// 源缺失是 `NotFound` 而不是空回答：调用方点的是这个存储上没有的对象。
/// （超过单次复制上限的大对象要走 upload-part-copy，这一层不做，与 `platform-s3` 同。）
async fn OssPlatform::copy_between(
  self : OssPlatform,
  src : @model.FileInfo,
  dest : @model.FileInfo,
  op : String,
) -> @model.FileInfo raise @model.StorageError {
  let source_key = require_key(src.path)
  match self.stat(source_key) {
    None => {
      let head = "same_" + op + " source is not on this platform: " + source_key
      raise @model.StorageError::NotFound(head)
    }
    Some(_) => ()
  }
  let target_key = dest_key(dest, op)
  let _ = self.config.client.copy_object(
    self.config.bucket,
    source_key,
    self.config.bucket,
    target_key,
  ) catch {
    error => raise map_error(error)
  }
  let size = match self.stat(target_key) {
    Some(stat) => stat.size
    None =>
      raise @model.StorageError::Platform(
        "oss ran " + op + " but cannot see the result: " + target_key,
      )
  }
  let domain = trim_trailing_slash(platform_domain(self))
  dest.stamped(@model.Stamp::{
    platform: Some(self.config.platform),
    path: Some(target_key),
    url: Some(domain + "/" + target_key),
    size: Some(size),
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
}

///|
pub impl @platform.Platform for OssPlatform with fn same_copy(
  self,
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  self.copy_between(src, dest, "copy")
}

///|
/// OSS 没有 move 这个动词，所以移动是"复制完再删源"——仍在同一个存储里做完，
/// 这就是它算平台优化的理由（与 `platform-s3` 同形）。
pub impl @platform.Platform for OssPlatform with fn same_move(
  self,
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  let moved = self.copy_between(src, dest, "move")
  // 提到外面再发请求：留在参数列表里会把 `require_key` 的 `StorageError`
  // 混进只看得见 `OssError` 的那个 `catch`。
  let source_key = require_key(src.path)
  self.config.client.delete_object(self.config.bucket, source_key) catch {
    error => raise map_error(error)
  }
  moved
}

///|
/// 单层列举：`commonPrefixes` 折成目录、`Contents` 折成文件。以 `/` 结尾的"目录标记
/// 对象"丢掉——前缀那一条已经代表它，两处都报会让同一个名字出现两次。
/// V2 的续页符是服务端自己发的 `NextContinuationToken`，直接当 `marker` 用。
pub impl @platform.Platform for OssPlatform with fn list_files(
  self,
  path : String,
  filename_prefix : String,
  marker : String?,
) -> @model.FileListing raise @model.StorageError {
  let base = trim_leading_slash(path)
  // 目录范围要带上分隔符："listing" + "a" 否则打到的是同名兄弟 "listinga"
  let prefix = if base.is_empty() {
    filename_prefix
  } else {
    strip_trailing_slash(base) + "/" + filename_prefix
  }
  let listing = self.config.client.list_objects(
    self.config.bucket,
    prefix~,
    delimiter="/",
    max_keys=1000,
    continuation_token=marker,
  ) catch {
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
/// canned ACL 这一族在契约语义下兑不了现（实测出处见 `capabilities`）：能力位报
/// false，被调用就地拒绝，**一个请求都不发**。真发出去只会收到桶侧那条 403
/// `AccessDenied`，把"这一族做不到"混成"这一次请求失败了"。
pub impl @platform.Platform for OssPlatform with fn set_file_acl(
  self,
  _info : @model.FileInfo,
  _acl : @model.CannedAcl,
) -> Unit raise @model.StorageError {
  let head = "oss platform " + self.config.platform
  raise @model.StorageError::NotSupported(head + " has no canned ACL family")
}

///|
pub impl @platform.Platform for OssPlatform with fn close(_self : OssPlatform) -> Unit {
  // SDK 不持有跨请求的句柄：每条请求自己把响应体读尽再关（晾着连接会让下一条整等
  // 30 秒，这条纪律在 moon-oss 那侧执行，不在这里）。
  ()
}

///|
pub extend OssPlatform with @platform.Platform::{
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
