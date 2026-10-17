///|
/// 存储端口到 `mldong/moon-kodo`（七牛原生 Kodo 协议）的薄适配层。协议形状
/// （签名族、上传令牌、分块 V2、rs/rsf 路径）都留在 SDK 里，这个文件只做两件事：
/// 把 `FileInfo` + `UploadSource` 翻译成 SDK 请求，把 SDK 的读数与错误翻译回来。
///
/// `url` 由 `config.domain` 拼：七牛的回包里没有可公开打开的链接，编一条出来就是
/// 往记录里放一条打不开的地址，所以没给域名就响亮拒绝。

///|
pub struct QiniuPlatform {
  priv config : QiniuPlatformConfig
}

///|
pub fn QiniuPlatform::new(config : QiniuPlatformConfig) -> QiniuPlatform {
  { config, }
}

///|
pub fn QiniuPlatform::config(self : QiniuPlatform) -> QiniuPlatformConfig {
  self.config
}

///|
fn domain_of(platform : QiniuPlatform) -> String raise @model.StorageError {
  match platform.config.domain {
    Some(domain) => domain
    None => {
      let head = "qiniu platform " + platform.config.platform
      raise @model.StorageError::InvalidInput(
        head + " needs a domain to build urls",
      )
    }
  }
}

///|
fn client_of(platform : QiniuPlatform) -> @sdk.Client {
  platform.config.client
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
/// key 或公共前缀的最后一段（去掉尾部分隔符之后）。
fn last_segment(text : String) -> String {
  let body = trim_trailing_slash(text)
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
/// key 不能是空串：空 key 会打到桶前缀本身，那边"不存在"与"是个目录"分不清。
fn require_key(path : String) -> String raise @model.StorageError {
  if path.is_empty() {
    raise @model.StorageError::InvalidInput("qiniu object needs a key")
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
/// 错误分档：`NotFound` 只给"对象不存在"那一档（Kodo 用真 HTTP **612** 说这件事，
/// 参照件 `QiniuKodoFileStorage:478` 认的也是它）；伪码档（-1~-4）不是服务端的回答，
/// 归到本地失败那一族；其余服务端的码原样写进文案，不折叠成"平台错了"。
fn map_error(error : @kodoerr.KodoError) -> @model.StorageError {
  match error {
    @kodoerr.KodoError::BadParam(detail) =>
      @model.StorageError::InvalidInput("kodo param: " + detail)
    @kodoerr.KodoError::BadFile(detail) =>
      @model.StorageError::InvalidInput("kodo file: " + detail)
    @kodoerr.KodoError::Cancelled(detail) =>
      @model.StorageError::Platform("kodo cancelled: " + detail)
    @kodoerr.KodoError::Network(detail) =>
      @model.StorageError::Platform("kodo network: " + detail)
    @kodoerr.KodoError::BadResponse(detail) =>
      @model.StorageError::Platform("kodo response: " + detail)
    @kodoerr.KodoError::Service(details) =>
      if details.status == 612 {
        @model.StorageError::NotFound(
          "kodo 612 " +
          details.error +
          " reqid=" +
          details.req_id.unwrap_or("<none>"),
        )
      } else {
        let head = "kodo " + details.status.to_string() + " " + details.error
        @model.StorageError::Platform(
          head + " reqid=" + details.req_id.unwrap_or("<none>"),
        )
      }
  }
}

///|
/// "不存在"只认 612 这一个码。别的错误不许被顺手折叠成"没有"——那会把服务端的
/// 拒绝读成一次成功的删除。
fn is_absent(error : @kodoerr.KodoError) -> Bool {
  match error {
    @kodoerr.KodoError::Service(details) => details.status == 612
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
async fn read_source(
  source : @model.UploadSource,
) -> Bytes raise @model.StorageError {
  match source {
    @model.UploadSource::Bytes(data) => data
    @model.UploadSource::Stream(reader, _) => {
      let merged : Array[Byte] = []
      let mut done = false
      while !done {
        // `read_some` 而不是 `read(FixedArray)`：这层要的是攒出一整份字节，
        // 拿缓冲区的写法还得自己管偏移
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
        "qiniu platform uploads bytes or a reader; open the file and pass its reader",
      )
  }
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
          err =>
            raise @model.StorageError::Platform(
              "write destination: " + err.to_string(),
            )
        }
    }
  }
  body.close()
}

///|
/// `stat` 的三档读数折成一个：读到 / 不存在（`None`）/ 真失败（抛）。
/// 七牛的"不存在"是 612 这一档真 HTTP 码，不是 404，也不是任何异常都算没有。
async fn QiniuPlatform::stat_key(
  self : QiniuPlatform,
  key : String,
) -> @sdk.StatResult? raise @model.StorageError {
  let read = Some(client_of(self).stat(key)) catch {
    err => if is_absent(err) { None } else { raise map_error(err) }
  }
  read
}

///|
/// 会话号从 `FileInfo` 上取回来（端口只带 `upload_id`），令牌每次现签——
/// 与参照件一致：它每一步上传前签一枚，会话本身不存凭据。
fn QiniuPlatform::session_of(
  self : QiniuPlatform,
  info : @model.FileInfo,
) -> @sdk.UploadSession raise @model.StorageError {
  let key = require_key(info.path)
  let upload_id = require_upload_id(info)
  client_of(self).resume_multipart(key, upload_id) catch {
    err => raise map_error(err)
  }
}

///|
pub impl @platform.Platform for QiniuPlatform with fn name(self : QiniuPlatform) -> String {
  self.config.platform
}

///|
/// 七个能力位逐个有出处：`presigned_url` 与 `acl` 照参照件
/// （`QiniuKodoFileStorage:412` 报 true 且只接 GET；`FileStorage` 端口全仓没有一个
/// ACL 方法，Kodo 也没有 canned ACL 这一族），`metadata` 两侧都实测过——
/// 写用平铺字段 `x-qn-meta-<名>`，`stat` 回的是嵌套对象 `x-qn-meta`。
pub impl @platform.Platform for QiniuPlatform with fn capabilities(
  _self : QiniuPlatform,
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
pub impl @platform.Platform for QiniuPlatform with fn save(
  self,
  info : @model.FileInfo,
  source : @model.UploadSource,
) -> @model.FileInfo? raise @model.StorageError {
  if info.filename.is_empty() {
    raise @model.StorageError::InvalidInput("qiniu save needs a filename")
  }
  let domain = trim_trailing_slash(domain_of(self))
  let key = @model.object_key(info.base_path, info.filename)
  let data = read_source(source)
  let _ = client_of(self).put_bytes(
    key,
    data,
    mime=info.content_type,
    check_crc=self.config.check_crc,
    meta=meta_pairs(info.user_metadata),
  ) catch {
    err => raise map_error(err)
  }
  // 尺寸从 stat 取，不从请求侧的 length 取：装配出来的记录要说的是服务端存下的那份
  let stat = match self.stat_key(key) {
    Some(value) => value
    None =>
      raise @model.StorageError::Platform(
        "qiniu stored " + key + " but cannot stat it back",
      )
  }
  let meta = pairs_meta(stat.user_metadata)
  Some(
    info.stamped(@model.Stamp::{
      platform: None,
      path: Some(key),
      url: Some(domain + "/" + key),
      size: stat.fsize,
      create_time: None,
      upload_id: None,
      upload_status: None,
      user_metadata: Some(meta),
    }),
  )
}

///|
pub impl @platform.Platform for QiniuPlatform with fn get_file(
  self,
  url : String,
) -> @model.FileInfo? raise @model.StorageError {
  let domain = domain_of(self)
  let key = match key_of_url(domain, url) {
    Some(one) => one
    None =>
      raise @model.StorageError::InvalidInput(
        "url is not under this platform domain: " + url,
      )
  }
  match self.stat_key(key) {
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
          size: stat.fsize,
          create_time: None,
          upload_id: None,
          upload_status: None,
          user_metadata: Some(pairs_meta(stat.user_metadata)),
        }),
      )
  }
}

///|
pub impl @platform.Platform for QiniuPlatform with fn exists(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  self.stat_key(require_key(info.path)) is Some(_)
}

///|
/// Kodo 的删除对"本来就不存在"直接回 612，SDK 已把它折成 `false`（与参照件同档），
/// 所以这里不必先 stat 再删——那趟对照反而会把"删除失败"与"本来没有"混成一谈。
pub impl @platform.Platform for QiniuPlatform with fn delete(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  let key = require_key(info.path)
  client_of(self).delete(key) catch {
    err => raise map_error(err)
  }
}

///|
/// 取对象字节。Kodo 没有"下载"这个 API：参照件走的是 `privateDownloadUrl(域名/key)`
/// 再打开那条 URL，这里同形——先签名，再由注入的传输 GET 回来。
pub impl @platform.Platform for QiniuPlatform with fn download(
  self,
  info : @model.FileInfo,
  writer : &@io.Writer,
) -> Unit raise @model.StorageError {
  let key = require_key(info.path)
  let domain = trim_trailing_slash(domain_of(self))
  let signed = client_of(self).private_download_url(domain + "/" + key)
  // 交给 SDK 发这条无凭据 GET：重试档与 rs 系同一套（可重放 + 没拿到应答才重发一次），
  // 非 2xx 也由 SDK 统一解成 Service 读数，不在这里再判一遍状态码
  let response = client_of(self).open_url(signed) catch {
    err =>
      match err {
        // 走 CDN/iovip 时"没有这个对象"可能是 404 而不是 rs 系的 612，两档都算 NotFound；
        // 其余状态原样进 Platform，不折叠成"没有"
        @kodoerr.KodoError::Service(details) if details.status == 612 ||
          details.status == 404 =>
          // 文案带**不带查询串的**取回位置与状态码：签名 URL 的 query 里有
          // `AK:sign`，那是凭据，不能顺着错误串进日志；光给 key 又分不清是
          // 域名、路径还是签名的问题。
          raise @model.StorageError::NotFound(
            "qiniu download found nothing at " +
            domain +
            "/" +
            key +
            " (status " +
            details.status.to_string() +
            ")",
          )
        _ => raise map_error(err)
      }
  }
  pump_body(response.body, writer)
}

///|
pub impl @platform.Platform for QiniuPlatform with fn init_multipart(
  self,
  info : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  if info.filename.is_empty() {
    raise @model.StorageError::InvalidInput(
      "qiniu init_multipart needs a filename",
    )
  }
  let domain = trim_trailing_slash(domain_of(self))
  let key = @model.object_key(info.base_path, info.filename)
  let started = client_of(self).begin_multipart(key) catch {
    err => raise map_error(err)
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
pub impl @platform.Platform for QiniuPlatform with fn upload_part(
  self,
  info : @model.FileInfo,
  part_number : Int32,
  source : @model.UploadSource,
) -> @model.FilePartInfo raise @model.StorageError {
  let session = self.session_of(info)
  let upload_id = session.upload_id
  let data = read_source(source)
  let part = client_of(self).upload_part(
    session,
    part_number,
    data,
    check_crc=self.config.check_crc,
  ) catch {
    err => raise map_error(err)
  }
  @model.FilePartInfo::{
    platform: self.config.platform,
    upload_id,
    part_number,
    size: data.length().to_int64(),
    etag: part.etag,
  }
}

///|
pub impl @platform.Platform for QiniuPlatform with fn list_parts(
  self,
  info : @model.FileInfo,
  part_number_marker : Int32,
) -> @model.PartPage raise @model.StorageError {
  let session = self.session_of(info)
  let page = client_of(self).list_parts(
    session,
    part_number_marker=Some(part_number_marker),
  ) catch {
    err => raise map_error(err)
  }
  let parts : Array[@model.FilePartInfo] = []
  for part in page.parts {
    parts.push(@model.FilePartInfo::{
      platform: self.config.platform,
      upload_id: session.upload_id,
      part_number: part.part_number,
      size: part.size.unwrap_or(0L),
      etag: part.etag,
    })
  }
  @model.PartPage::{
    parts,
    is_truncated: page.truncated,
    next_part_number_marker: page.next_marker,
  }
}

///|
pub impl @platform.Platform for QiniuPlatform with fn complete_multipart(
  self,
  info : @model.FileInfo,
  parts : Array[@model.FilePartInfo],
) -> @model.FileInfo raise @model.StorageError {
  let session = self.session_of(info)
  let key = require_key(info.path)
  let mapped : Array[@sdk.PartInfo] = []
  for part in parts {
    mapped.push(@sdk.PartInfo::{
      part_number: part.part_number,
      etag: part.etag,
      size: Some(part.size),
      put_time: None,
    })
  }
  let _ = client_of(self).complete_multipart(
    session,
    mapped,
    mime_type=info.content_type,
  ) catch {
    err => raise map_error(err)
  }
  // 合并发生在服务端，尺寸只能读回来：这是这条记录上唯一有意义的数字
  let size = match self.stat_key(key) {
    Some(value) => value.fsize
    None =>
      raise @model.StorageError::Platform(
        "qiniu completed the upload but the object is not readable: " + key,
      )
  }
  info.stamped(@model.Stamp::{
    platform: None,
    path: None,
    url: None,
    size,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
}

///|
pub impl @platform.Platform for QiniuPlatform with fn abort_multipart(
  self,
  info : @model.FileInfo,
) -> Unit raise @model.StorageError {
  let session = self.session_of(info)
  client_of(self).abort_multipart(session) catch {
    err => raise map_error(err)
  }
}

///|
/// 预签名两档：**只给 GET**。参照件原话"七牛云 Kodo 仅支持 GET，如需支持更多功能，
/// 可以通过 AWS S3 的 SDK 来使用"（`QiniuKodoFileStorage:419-421`）。
/// 上传令牌不是"可以直接 PUT 的 URL"，拿令牌串冒充预签名 PUT 会让契约里
/// "免凭据直传"那一档假绿，所以这里响亮拒绝而不是返回一个能打开的串。
///
/// 回的是**一条 URL**，headers 不附——参照件那侧也是空表。
pub impl @platform.Platform for QiniuPlatform with fn presigned_url(
  self,
  info : @model.FileInfo,
  verb : @model.PresignMethod,
  expires_seconds : Int32,
) -> String raise @model.StorageError {
  let key = require_key(info.path)
  match verb {
    @model.PresignMethod::Get => {
      let domain = trim_trailing_slash(domain_of(self))
      client_of(self).private_download_url(
        domain + "/" + key,
        expires=expires_seconds.to_int64(),
      )
    }
    @model.PresignMethod::Put =>
      raise @model.StorageError::NotSupported(
        "qiniu Kodo signs download URLs only; use the S3 platform for direct PUT",
      )
  }
}

///|
fn dest_key(
  dest : @model.FileInfo,
  op : String,
) -> String raise @model.StorageError {
  if dest.filename.is_empty() {
    let head = "qiniu same_" + op + " needs a destination filename"
    raise @model.StorageError::InvalidInput(head)
  }
  @model.object_key(dest.base_path, dest.filename)
}

///|
/// `force=true`：与 S3 那条腿对齐——`CopyObject` 本来就是覆盖式的，七牛默认
/// `force=false` 会在目标位已有同名对象时回 614，两条腿对同一件事不该给出两种答案。
async fn QiniuPlatform::copy_between(
  self : QiniuPlatform,
  src : @model.FileInfo,
  dest : @model.FileInfo,
  op : String,
) -> @model.FileInfo raise @model.StorageError {
  let source_key = require_key(src.path)
  match self.stat_key(source_key) {
    None => {
      let head = "same_" + op + " source is not on this platform: " + source_key
      raise @model.StorageError::NotFound(head)
    }
    Some(_) => ()
  }
  let target_key = dest_key(dest, op)
  let client = client_of(self)
  if op == "copy" {
    client.copy(source_key, target_key, force=true) catch {
      err => raise map_error(err)
    }
  } else {
    client.move_object(source_key, target_key, force=true) catch {
      err => raise map_error(err)
    }
  }
  let size = match self.stat_key(target_key) {
    Some(value) => value.fsize
    None =>
      raise @model.StorageError::Platform(
        "qiniu ran " + op + " but cannot see the result: " + target_key,
      )
  }
  let domain = trim_trailing_slash(domain_of(self))
  dest.stamped(@model.Stamp::{
    platform: Some(self.config.platform),
    path: Some(target_key),
    url: Some(domain + "/" + target_key),
    size,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
}

///|
pub impl @platform.Platform for QiniuPlatform with fn same_copy(
  self,
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  self.copy_between(src, dest, "copy")
}

///|
/// 移动是服务端一步做完的（`/move/`），不是"复制完再删"：源消失这件事由那次调用保证，
/// 所以这里不再补一次删除。
pub impl @platform.Platform for QiniuPlatform with fn same_move(
  self,
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  self.copy_between(src, dest, "move")
}

///|
/// 单层列举：`commonPrefixes` 折成目录、`items` 折成文件；以 `/` 结尾的"目录标记对象"
/// 丢掉（前缀那一条已经代表它，两处都报会让同一个名字出现两次）。
/// 续页符直接用 rsf 的 `marker`，`is_eof` 缺键当"还有下一页"。
pub impl @platform.Platform for QiniuPlatform with fn list_files(
  self,
  path : String,
  filename_prefix : String,
  marker : String?,
) -> @model.FileListing raise @model.StorageError {
  let base = trim_leading_slash(path)
  let prefix = if base.is_empty() {
    filename_prefix
  } else {
    trim_trailing_slash(base) + "/" + filename_prefix
  }
  let listing = client_of(self).list_files(
    prefix=Some(prefix),
    marker~,
    delimiter=Some("/"),
    limit=Some(1000),
  ) catch {
    err => raise map_error(err)
  }
  let dirs : Array[@model.ListedDir] = []
  for common in listing.common_prefixes {
    dirs.push(@model.ListedDir::{ path: common, name: last_segment(common), })
  }
  let files : Array[@model.ListedFile] = []
  for item in listing.items {
    if item.key.has_suffix("/") {
      ()
    } else {
      files.push(@model.ListedFile::{
        path: item.key,
        name: last_segment(item.key),
        size: item.fsize.unwrap_or(0L),
        last_modified: item.put_time.map(x => x.to_string()),
        etag: item.hash,
      })
    }
  }
  @model.FileListing::{
    dirs,
    files,
    is_truncated: !listing.is_eof,
    next_continuation_token: listing.marker,
  }
}

///|
/// Kodo 没有 canned ACL 这一族（端口 `FileStorage` 全仓零个 ACL 方法，参照件也没做）：
/// 能力位报 false，被调用就地拒绝，不发请求也不假装成功。
pub impl @platform.Platform for QiniuPlatform with fn set_file_acl(
  self,
  _info : @model.FileInfo,
  _acl : @model.CannedAcl,
) -> Unit raise @model.StorageError {
  let head = "qiniu platform " + self.config.platform
  raise @model.StorageError::NotSupported(head + " has no canned ACL family")
}

///|
pub impl @platform.Platform for QiniuPlatform with fn close(
  _self : QiniuPlatform,
) -> Unit {
  // SDK 不持有跨请求的句柄：每条请求自己关响应体。
  ()
}

///|
pub extend QiniuPlatform with @platform.Platform::{
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
