///|
/// FTP 后端适配层：把 `PaiGack/ftp` 这个客户端接到存储端口上。
///
/// 两条与另外三条腿不同的前提，都写在这里而不是散在方法里：
///
/// 1. **连接是自己拨的**。S3/Kodo 那条腿收的是已经建好的客户端，这里收的是凭据：
///    FTP 的会话是长连接，端口没有"首次使用时再连"的位置，所以第一次真正要发命令时
///    才连，之后复用同一条。
/// 2. **数据通道只认服务端报的地址**。客户端库把 `Tcp::addr()`（本机地址）当成了对端
///    地址存进控制连接，于是 EPSV 的数据连接会拨回自己机器上（实测：控制 host 读到
///    客户机自己的局域网地址，STOR 一律 `远程计算机拒绝网络连接`）。这里用
///    `disable_epsv=true` + `trust_pasv_ip=true` 这一对开关绕过去，代价是 SSRF 守卫
///    退化成"信 PASV 回包"。
pub struct FtpPlatform {
  config : FtpPlatformConfig
  mut session : @ftplib.FTPClient?
  mut shut : Bool
}

///|
pub fn FtpPlatform::new(config : FtpPlatformConfig) -> FtpPlatform {
  { config, session: None, shut: false, }
}

///|
pub fn FtpPlatform::config(self : FtpPlatform) -> FtpPlatformConfig {
  self.config
}

///|
/// 拨号 + 登录，并把会话存回平台。凭据不进错误文案：失败只说"登录这一步"。
async fn FtpPlatform::connect(
  self : FtpPlatform,
) -> @ftplib.FTPClient raise @model.StorageError {
  let client = @ftplib.dial(
    self.config.addr,
    timeout_ms=self.config.timeout_ms,
    disable_epsv=true,
    trust_pasv_ip=true,
  ) catch {
    err => raise map_error(err)
  }
  @ftplib.login(client, self.config.user, self.config.password) catch {
    err =>
      raise @model.StorageError::Platform(
        "ftp login failed for user '" +
        self.config.user +
        "': " +
        describe_login(err),
      )
  }
  self.session = Some(client)
  client
}

///|
/// 登录失败时把库的读数取出来，但绝不带出口令：`PASS` 那一行的原文在 OSError 的
/// 文案里不出现，库也不会打，这里只做一次归一。
fn describe_login(error : Error) -> String {
  match error {
    @ftplib.FtpError::ServerError(code=c, msg=m) =>
      "server said " + c.to_string() + ": " + m
    _ => "transport failed"
  }
}

///|
/// 端口方法共用的取会话入口：没连过就连，`QUIT` 过或库标成已关就重拨一条。
async fn FtpPlatform::attached(
  self : FtpPlatform,
) -> @ftplib.FTPClient raise @model.StorageError {
  if self.shut {
    raise @model.StorageError::InvalidInput("ftp platform is closed")
  }
  match self.session {
    Some(client) =>
      if client.is_closed() {
        self.session = None
        self.connect()
      } else {
        client
      }
    None => self.connect()
  }
}

///|

///|
/// 端口的坐标系就是 `info.path`。这一条法把"必须有 path"与"`..`/CR/LF 不合法"都排在
/// 拨号之前：坏请求不该被"连不上"顶掉，也不该在服务端留下任何痕迹。
fn object_key_of(info : @model.FileInfo) -> String raise @model.StorageError {
  normalize_key(require_key(info.path))
}

///|
fn require_key(path : String) -> String raise @model.StorageError {
  if path.is_empty() {
    raise @model.StorageError::InvalidInput("ftp object needs a path")
  }
  path
}

///|
/// 父目录逐段建。库的 `make_dir` 不递归，而 FTP 的 `MKD` 对"已存在"与"没权限"回的是
/// 同一族 5xx，所以判据不靠文案：先 `CWD` 进去过一遍，进不去才 `MKD`，`MKD` 之后
/// 还要再进一次才算数。
async fn ensure_dir(
  client : @ftplib.FTPClient,
  dir_key : String,
) -> Unit raise @model.StorageError {
  if dir_key.is_empty() {
    ()
  } else {
    let built : Array[String] = []
    for segment in dir_key.split("/") {
      if segment.is_empty() || segment == "." {
        continue
      }
      built.push(segment.to_owned())
      let path = "/" + built.join("/")
      let entered = dir_exists(client, path)
      if !entered {
        @ftplib.make_dir(client, path) catch {
          err => raise map_error(err)
        }
        // MKD 回 257 之后还要再进一次才算数：FTP 的 5xx 分不出"已存在"与"没权限"
        if !dir_exists(client, path) {
          raise @model.StorageError::Platform(
            "ftp MKD returned ok but " + path + " cannot be entered",
          )
        }
      }
    }
    // 上面这些 CWD 会把工作目录挪到最深一层；后续命令用的都是绝对路径，
    // 但把 cwd 复位可以让"这条腿在服务端看起来做了什么"一眼可读。
    @ftplib.change_dir(client, "/") catch {
      err => raise map_error(err)
    }
  }
}

///|
/// 目录在不在，只看 `CWD` 进不进得去：这是 FTP 上唯一不依赖文案的存在性判据。
async fn dir_exists(
  client : @ftplib.FTPClient,
  path : String,
) -> Bool raise @model.StorageError {
  // 不吞错：进不去分两档——服务端说"没有这个目录"才算缺，别的答案（超时、连接断了）
  // 原样抛出去。把它们折成 false 会让下一步的 MKD 报出一个看不懂的 550。
  let ok = try {
    @ftplib.change_dir(client, path)
    true
  } catch {
    err => if is_absent(err) { false } else { raise map_error(err) }
  }
  ok
}

///|
/// 一个 key 的读数：列父目录的一层再按名字取。
///
/// 不用 `MLST`/`MLSD` 是因为这轮的服务端不实现它（`FEAT` 里就没有这两行），
/// 而 `SIZE` 只给尺寸、`MDTM` 只给时间，端口要的 `Entry` 两样都要。
async fn lookup(
  client : @ftplib.FTPClient,
  key : String,
) -> @ftplib.Entry? raise @model.StorageError {
  let name = name_of_key(key)
  if name.is_empty() {
    None
  } else {
    let dir = dir_of_key(key)
    let remote = if dir.is_empty() { "/" } else { "/" + dir }
    let listing : Array[@ftplib.Entry]? = Some(@ftplib.list(client, remote)) catch {
      err => if is_absent(err) { None } else { raise map_error(err) }
    }
    match listing {
      None => None
      Some(items) => {
        let mut found : @ftplib.Entry? = None
        for item in items {
          if item.name == name && found is None {
            found = Some(item)
          }
        }
        found
      }
    }
  }
}

///|
/// 从 `Entry` 装配记录：尺寸与时间是服务端给的读数，不是请求侧的。
fn record_for(
  config : FtpPlatformConfig,
  url : String,
  key : String,
  entry : @ftplib.Entry,
  create_time~ : Bool,
) -> @model.FileInfo raise @model.StorageError {
  @model.FileInfo::draft(
    config.platform,
    dir_of_key(key),
    name_of_key(key),
    ext_of_key(key),
  ).stamped(@model.Stamp::{
    platform: None,
    path: Some(key),
    url: Some(url),
    size: Some(entry.size.reinterpret_as_int64()),
    create_time: if create_time {
      Some(entry.time.to_unix_second())
    } else {
      None
    },
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
}

///|
/// 把一条数据连接搬到调用方的 Writer 上。
///
/// `DataResponse` 只提供 `read(FixedArray[Byte]) -> Int32`：库的文档注释说它
/// `impl @io.Reader`，实测没有那条 impl（编译报 "no `impl` is defined"），
/// 所以这一层自己搬。
async fn pump(response : @ftplib.DataResponse, writer : &@io.Writer) -> Unit {
  let chunk = FixedArray::make(8192, (0 : Byte))
  let mut more = true
  while more {
    let got = response.read(chunk, offset=0, max_len=chunk.length())
    if got > 0 {
      writer.write(Bytes::from_array(chunk[0:got].to_owned()))
    } else {
      more = false
    }
  }
}

///|
/// 把一份正文写到远端路径上。
///
/// `MemoryReader` 会 spawn 一个产出任务，`STOR` 失败时它还在等没人读的管道——
/// wasm 运行时把"所有任务都停着"判成 deadlock 并中止进程，报出来的名字还是隔壁文件
/// （实测）。所以无论成败都要关掉它。
async fn put_source(
  client : @ftplib.FTPClient,
  remote : String,
  source : @model.UploadSource,
) -> Unit raise @model.StorageError {
  match source {
    @model.UploadSource::Path(from) =>
      raise @model.StorageError::NotSupported(
        "ftp save from a local path is not wired: " + from,
      )
    @model.UploadSource::Bytes(data) => {
      let reader = @io.MemoryReader::MemoryReader(writer => writer.write(data))
      let failure : Error? = try {
        @ftplib.stor(client, remote, reader)
        None
      } catch {
        err => Some(err)
      }
      reader.close()
      match failure {
        Some(err) => raise map_error(err)
        None => ()
      }
    }
    @model.UploadSource::Stream(stream, _) =>
      @ftplib.stor(client, remote, stream) catch {
        err => raise map_error(err)
      }
  }
}

///|
pub impl @platform.Platform for FtpPlatform with fn name(self : FtpPlatform) -> String {
  self.config.platform
}

///|
/// 七个能力位的出处：FTP 协议里**没有**分片上传、预签名 URL、对象级 ACL 这三族，
/// 参照件的 FTP 适配也同样没有同平台复制——四档报 false，被调用时必须响亮拒绝。
/// `metadata` 也是 false：LIST 能给的是名字、尺寸和时间，没有挂自定义键值的地方。
/// 剩下两档是真做过读回的：`list_files` 看一层目录，`same_move` 用 `RNFR`/`RNTO`。
pub impl @platform.Platform for FtpPlatform with fn capabilities(
  _self : FtpPlatform,
) -> @model.Capabilities {
  @model.Capabilities::{
    multipart_upload: false,
    list_files: true,
    presigned_url: false,
    acl: false,
    metadata: false,
    same_copy: false,
    same_move: true,
  }
}

///|
pub impl @platform.Platform for FtpPlatform with fn save(
  self,
  info : @model.FileInfo,
  source : @model.UploadSource,
) -> @model.FileInfo? raise @model.StorageError {
  if info.filename.is_empty() {
    raise @model.StorageError::InvalidInput("ftp save needs a filename")
  }
  // 源的形状先验：本地路径这一档 FTP 侧没有对应做法（没有服务端读本地文件的通道），
  // 要在拨号之前拒掉，免得"连不上"盖住"这一档不支持"
  match source {
    @model.UploadSource::Path(from) =>
      raise @model.StorageError::NotSupported(
        "ftp save from a local path is not wired: " + from,
      )
    _ => ()
  }
  let key = normalize_key(@model.object_key(info.base_path, info.filename))
  let remote = remote_of(key)
  let client = self.attached()
  ensure_dir(client, dir_of_key(key))
  put_source(client, remote, source)
  // 写完不信任"没报错"：把读数从服务端取回来，取不回来就是失败
  match lookup(client, key) {
    None =>
      raise @model.StorageError::Platform(
        "ftp STOR did not raise but " + key + " is not readable back",
      )
    // 只盖存储侧的读数（path/url/尺寸），身份字段沿用请求那一份：参照件的 save 就是
    // "把写进去的记录原样回给你"，从 key 反推会把 original_filename 换成文件名
    Some(entry) =>
      Some(
        info.stamped(@model.Stamp::{
          platform: None,
          path: Some(key),
          url: Some(url_of(self.config, key)),
          size: Some(entry.size.reinterpret_as_int64()),
          create_time: None,
          upload_id: None,
          upload_status: None,
          user_metadata: None,
        }),
      )
  }
}

///|
pub impl @platform.Platform for FtpPlatform with fn get_file(self, url : String) -> @model.FileInfo? raise @model.StorageError {
  let key = match relative_of_url(self.config, url) {
    Some(one) => one
    None =>
      raise @model.StorageError::InvalidInput(
        "url is not under this platform domain: " + url,
      )
  }
  let key = normalize_key(key)
  let client = self.attached()
  match lookup(client, key) {
    Some(entry) if entry.type_ == @ftplib.EntryType::File =>
      Some(record_for(self.config, url, key, entry, create_time=true))
    _ => None
  }
}

///|
pub impl @platform.Platform for FtpPlatform with fn exists(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  let key = object_key_of(info)
  let client = self.attached()
  match lookup(client, key) {
    Some(entry) => entry.type_ == @ftplib.EntryType::File
    None => false
  }
}

///|
pub impl @platform.Platform for FtpPlatform with fn delete(
  self,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  let key = object_key_of(info)
  let client = self.attached()
  match lookup(client, key) {
    // 目录不是对象：与"本来就没有"同一档，不把 `DELE` 打在服务端必然回 550 的路径上
    None => false
    Some(entry) if entry.type_ != @ftplib.EntryType::File => false
    Some(_) => {
      @ftplib.delete(client, remote_of(key)) catch {
        err => raise map_error(err)
      }
      true
    }
  }
}

///|
pub impl @platform.Platform for FtpPlatform with fn download(
  self,
  info : @model.FileInfo,
  writer : &@io.Writer,
) -> Unit raise @model.StorageError {
  let remote = remote_of(object_key_of(info))
  let client = self.attached()
  let response = @ftplib.retr(client, remote) catch {
    err => raise map_error(err)
  }
  let failures : Array[Error] = []
  let _ = pump(response, writer) catch { err => failures.push(err) }
  // 传输的收尾 `226` 必须读掉：不 close 就等于把上一条命令的尾巴留给下一条。
  // 正文搬完了但收尾失败也算失败——那说明这条会话已经错位了。
  let _ = response.close() catch { err => failures.push(err) }
  match failures {
    [] => ()
    _ => raise map_error(failures[0])
  }
}

///|
/// 三族在 FTP 上不存在。端口要的是"声明没有就必须响亮拒绝"，不是静默接受——
/// 而且拒绝发生在拨号之前，坏凭据不会把"这一族没有"盖成"连不上"。
fn not_supported(family : String) -> @model.StorageError {
  @model.StorageError::NotSupported("ftp has no " + family + " family")
}

///|
pub impl @platform.Platform for FtpPlatform with fn init_multipart(
  _self : FtpPlatform,
  _info : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  raise not_supported("multipart upload")
}

///|
pub impl @platform.Platform for FtpPlatform with fn upload_part(
  _self : FtpPlatform,
  _info : @model.FileInfo,
  _part_number : Int32,
  _source : @model.UploadSource,
) -> @model.FilePartInfo raise @model.StorageError {
  raise not_supported("multipart upload")
}

///|
pub impl @platform.Platform for FtpPlatform with fn list_parts(
  _self : FtpPlatform,
  _info : @model.FileInfo,
  _marker : Int32,
) -> @model.PartPage raise @model.StorageError {
  raise not_supported("multipart upload")
}

///|
pub impl @platform.Platform for FtpPlatform with fn complete_multipart(
  _self : FtpPlatform,
  _info : @model.FileInfo,
  _parts : Array[@model.FilePartInfo],
) -> @model.FileInfo raise @model.StorageError {
  raise not_supported("multipart upload")
}

///|
pub impl @platform.Platform for FtpPlatform with fn abort_multipart(
  _self : FtpPlatform,
  _info : @model.FileInfo,
) -> Unit raise @model.StorageError {
  raise not_supported("multipart upload")
}

///|
/// 预签名是"免凭据也能打开"的 URL：FTP 的认证只有会话级用户名口令，
/// 没有可以放进 URL 的临时凭据形状，参照件的 FTP 适配同样不支持。
pub impl @platform.Platform for FtpPlatform with fn presigned_url(
  _self : FtpPlatform,
  _info : @model.FileInfo,
  _method : @model.PresignMethod,
  _expires : Int32,
) -> String raise @model.StorageError {
  raise not_supported("presigned url")
}

///|
/// 参照件的 FTP 适配没有同平台复制这一族（它只给 `sameMove`），Kodo/S3 那种服务端
/// 复制在 FTP 上也没有对应命令。硬要做就是"整份取回内存再写回去"——那既不原子，
/// 又把内存用量绑到对象尺寸上，不是端口这条法承诺的事。
pub impl @platform.Platform for FtpPlatform with fn same_copy(
  _self : FtpPlatform,
  _source : @model.FileInfo,
  _dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  raise not_supported("same-platform copy")
}

///|
/// 同平台移动：FTP 有对应用语（`RNFR`/`RNTO`），两个绝对路径在同一条会话里改名。
/// 源必须是本平台的既有对象，缺失报 `NotFound`——这一档与 Kodo/S3 两条腿同判据。
pub impl @platform.Platform for FtpPlatform with fn same_move(
  self,
  source : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  if dest.filename.is_empty() {
    raise @model.StorageError::InvalidInput(
      "ftp same_move needs a destination filename",
    )
  }
  let from_key = object_key_of(source)
  let key = normalize_key(@model.object_key(dest.base_path, dest.filename))
  let client = self.attached()
  match lookup(client, from_key) {
    Some(entry) if entry.type_ == @ftplib.EntryType::File => ()
    _ =>
      raise @model.StorageError::NotFound(
        "same_move source is not on this platform: " + from_key,
      )
  }
  ensure_dir(client, dir_of_key(key))
  @ftplib.rename(client, remote_of(from_key), remote_of(key)) catch {
    err => raise map_error(err)
  }
  match lookup(client, key) {
    None =>
      raise @model.StorageError::Platform(
        "ftp RNTO returned ok but " + key + " is not readable back",
      )
    Some(entry) =>
      dest.stamped(@model.Stamp::{
        platform: Some(self.config.platform),
        path: Some(key),
        url: Some(url_of(self.config, key)),
        size: Some(entry.size.reinterpret_as_int64()),
        create_time: Some(entry.time.to_unix_second()),
        upload_id: None,
        upload_status: None,
        user_metadata: None,
      })
  }
}

///|
/// 单层列举：FTP 的目录就是这一层，没有 common prefixes 这一说——`dirs` 由
/// 条目类型给，`files` 由文件条目给。`marker` 没有对应物（协议不分页），整页返回。
pub impl @platform.Platform for FtpPlatform with fn list_files(
  self,
  path : String,
  filename_prefix : String,
  _marker : String?,
) -> @model.FileListing raise @model.StorageError {
  let dir = normalize_key(path)
  let remote = if dir.is_empty() { "/" } else { "/" + dir }
  let client = self.attached()
  let entries = @ftplib.list(client, remote) catch {
    err => raise map_error(err)
  }
  let dirs : Array[@model.ListedDir] = []
  let files : Array[@model.ListedFile] = []
  for entry in entries {
    if !filename_prefix.is_empty() && !entry.name.has_prefix(filename_prefix) {
      continue
    }
    let key = if dir.is_empty() { entry.name } else { dir + "/" + entry.name }
    if entry.type_ == @ftplib.EntryType::Folder {
      dirs.push(@model.ListedDir::{ path: key + "/", name: entry.name, })
    } else {
      files.push(@model.ListedFile::{
        path: key,
        name: entry.name,
        size: entry.size.reinterpret_as_int64(),
        last_modified: Some(entry.time.to_unix_second().to_string()),
        etag: None,
      })
    }
  }
  @model.FileListing::{
    dirs,
    files,
    is_truncated: false,
    next_continuation_token: None,
  }
}

///|
pub impl @platform.Platform for FtpPlatform with fn set_file_acl(
  _self : FtpPlatform,
  _info : @model.FileInfo,
  _acl : @model.CannedAcl,
) -> Unit raise @model.StorageError {
  raise not_supported("canned acl")
}

///|
/// 端口的 `close` 是同步的，而 `QUIT` 要等服务端回 `221`——这里只能把平台标成
/// "不再接受调用"。库的 `quit` 也只发命令、不关 socket（它没有 `Control::close`），
/// 所以连接真正的收口发生在进程退出时；长驻调用方要自己管这条会话的生命周期。
pub impl @platform.Platform for FtpPlatform with fn close(self : FtpPlatform) -> Unit {
  self.shut = true
  self.session = None
}

///|
pub extend FtpPlatform with @platform.Platform::{
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
