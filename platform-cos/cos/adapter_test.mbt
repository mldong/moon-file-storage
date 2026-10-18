///|
/// 适配层的异步负判据（走公开面）：所有"拦在出门之前"的档都靠一个从不发请求的桩传输
/// 自证——真发出去了就会拿到另一档读数（桩被调用即报错），两档文字不同才算证住。
/// 另一档桩只回 404 空正文，那是真桶 `HEAD /<key>` 的形状（2026-10-18 现读：只有状态码、
/// 没有 XML 正文、没有 `<Code>`）。一条请求都不上网，凭据是假的。

///|
struct StubTransport {}

///|
impl @transport.Transport for StubTransport with fn send(self, request) {
  let detail = "stub transport must not be called: " + request.url
  let _ = self
  raise @transport.TransportError::InvalidRequest(detail)
}

///|
/// 空正文的一档：`read` 直接 EOF，`close` 什么都不做。
struct QuietBody {}

///|
impl @transport.ResponseBody for QuietBody with fn read(self, max_bytes) {
  let _ = max_bytes
  let _ = self
  None
}

///|
impl @transport.ResponseBody for QuietBody with fn close(self) {
  let _ = self
}

///|
/// 每次调用都回 **404 + 空正文**：不带 `<Code>`，正是 2026-10-18 真桶那一发 `HEAD`
/// 打不存在的键收到的形状（只有状态码，没有 XML）。判"不存在"必须只看状态码，
/// 这一档就是它的判据。
struct AbsentTransport {}

///|
impl @transport.Transport for AbsentTransport with fn send(self, request) {
  let _ = self
  let _ = request
  let body : &@transport.ResponseBody = QuietBody::{ }
  @transport.Response::{
    status: 404,
    headers: [
      @transport.Header::{ name: "x-cos-request-id", value: "reqid-stub", },
    ],
    body,
  }
}

///|
/// 假凭据、假区域、虚主机域名一律 `.invalid`，绝不会碰真端点；桶用 COS 长命名
/// `<Name>-<APPID>`（SDK 的 `Config::host()` 会响亮拒绝非长命名，这里不重复那道校验）。
fn build_platform(
  transport : &@transport.Transport,
  domain~ : String? = None,
) -> @cos.CosPlatform raise {
  let credentials = @auth.Credentials::new("AKIDtestid", "testSecretKey")
  let config = @config.Config::new("ap-guangzhou", credentials)
  @cos.CosPlatform::new(@cos.CosPlatformConfig::{
    platform: "cos",
    bucket: "blog-1250000000",
    domain,
    client: @sdk.Client::new(config, transport),
  })
}

///|
/// 桶的虚主机前缀，预签名 URL 就落在这个域上；domain 用它才能过契约里"预签名 URL
/// 以 domain 开头"那一档（原生签名默认把 `Host` 算进去）。
fn vhost() -> String {
  "https://blog-1250000000.cos.ap-guangzhou.myqcloud.com"
}

///|
fn stub_platform(domain~ : String? = None) -> @cos.CosPlatform raise {
  let transport : &@transport.Transport = StubTransport::{ }
  build_platform(transport, domain~)
}

///|
/// 处处都"没有这个对象"的一条腿。
fn absent_platform() -> @cos.CosPlatform raise {
  let transport : &@transport.Transport = AbsentTransport::{ }
  build_platform(transport, domain=Some(vhost()))
}

///|
fn text_of(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(m) => "InvalidInput:" + m
    @model.StorageError::NotSupported(m) => "NotSupported:" + m
    @model.StorageError::NotFound(m) => "NotFound:" + m
    @model.StorageError::Platform(m) => "Platform:" + m
    @model.StorageError::Recorder(m) => "Recorder:" + m
  }
}

///|
fn draft_info() -> @model.FileInfo {
  @model.FileInfo::draft("cos", "a/b", "c.txt", "txt")
}

///|
/// 带 key 的记录；`upload_id~` 给的就是分片族那四步要认的会话号。
fn keyed_info(path : String, upload_id~ : String? = None) -> @model.FileInfo {
  draft_info().stamped(@model.Stamp::{
    platform: None,
    path: Some(path),
    url: None,
    size: None,
    create_time: None,
    upload_id,
    upload_status: None,
    user_metadata: None,
  })
}

///|
async fn save_text(
  platform : @cos.CosPlatform,
  info : @model.FileInfo,
  source : @model.UploadSource,
) -> String raise @model.StorageError {
  match platform.save(info, source) {
    None => "<none>"
    Some(one) => one.url
  }
}

///|
async fn get_text(
  platform : @cos.CosPlatform,
  url : String,
) -> String raise @model.StorageError {
  match platform.get_file(url) {
    None => "<absent>"
    Some(one) => one.url
  }
}

///|
async fn exists_text(
  platform : @cos.CosPlatform,
  info : @model.FileInfo,
) -> String raise @model.StorageError {
  platform.exists(info).to_string()
}

///|
async fn delete_text(
  platform : @cos.CosPlatform,
  info : @model.FileInfo,
) -> String raise @model.StorageError {
  platform.delete(info).to_string()
}

///|
async fn list_text(
  platform : @cos.CosPlatform,
  path : String,
) -> String raise @model.StorageError {
  let page = platform.list_files(path, "", None)
  page.files.length().to_string()
}

///|
async fn part_text(
  platform : @cos.CosPlatform,
  info : @model.FileInfo,
  part_number : Int32,
) -> String raise @model.StorageError {
  let one = platform.upload_part(
    info,
    part_number,
    @model.UploadSource::Bytes(@utf8.encode("x")),
  )
  one.etag
}

///|
async fn acl_text(
  platform : @cos.CosPlatform,
) -> String raise @model.StorageError {
  platform.set_file_acl(keyed_info("a/b.txt"), @model.CannedAcl::PublicRead)
  "accepted"
}

///|
fn presign_text(
  platform : @cos.CosPlatform,
  verb : @model.PresignMethod,
  seconds : Int32,
) -> String raise @model.StorageError {
  platform.presigned_url(keyed_info("a/b.txt"), verb, seconds)
}

///|
async test "适配 #5 没给域名拦在本地；给了域名才会走到传输——两档读数不同" {
  let bytes = @model.UploadSource::Bytes(@utf8.encode("x"))
  let no_domain = stub_platform()
  let blocked = save_text(no_domain, draft_info(), bytes) catch {
    err => text_of(err)
  }
  println("无域名 save 读数=" + blocked)
  assert_eq(
    blocked.has_prefix("InvalidInput:cos platform cos needs a domain"),
    true,
  )
  // 同一条腿换成"有域名"：这一步真的去发请求了，桩把它拦下并报另一档
  let with_domain = stub_platform(domain=Some(vhost()))
  let sent = save_text(with_domain, draft_info(), bytes) catch {
    err => text_of(err)
  }
  println("有域名 save 读数=" + sent)
  assert_eq(sent.has_prefix("Platform:cos network: "), true)
  assert_eq(sent.contains("stub transport must not be called"), true)
  assert_eq(sent == blocked, false)
  // 本地文件那一档：本端口不读盘，交给调用方自己开句柄
  let from_path = save_text(
    with_domain,
    draft_info(),
    @model.UploadSource::Path("G:/nowhere.bin"),
  ) catch {
    err => text_of(err)
  }
  println("Path 档读数=" + from_path)
  assert_eq(
    from_path.has_prefix("NotSupported:cos platform uploads bytes or a reader"),
    true,
  )
}

///|
async test "适配 #6 空 key、缺会话号、别家域名的 URL 都拦在本地；越界分片号不做本地判据" {
  let platform = stub_platform(domain=Some(vhost()))
  let blank = keyed_info("")
  let exists_blocked = exists_text(platform, blank) catch {
    err => text_of(err)
  }
  println("空 key exists 读数=" + exists_blocked)
  assert_eq(exists_blocked, "InvalidInput:cos object needs a key")
  let delete_blocked = delete_text(platform, blank) catch {
    err => text_of(err)
  }
  assert_eq(delete_blocked, "InvalidInput:cos object needs a key")
  // 有 key 但没有 init 回来的会话号：分片族四步都该这么拦
  let no_session = part_text(platform, keyed_info("a/b.txt"), 1) catch {
    err => text_of(err)
  }
  println("缺会话号读数=" + no_session)
  assert_eq(
    no_session, "InvalidInput:multipart needs the upload_id returned by init_multipart",
  )
  // 与 `platform-oss` 相反的一档：COS 的 `upload_part` **不在出门前**校验分片号，
  // 越界照样发出去（服务端回 400）。所以分片号 0 走到桩、报的是传输那一档而不是 InvalidInput。
  let zero_part = part_text(
    platform,
    keyed_info("a/b.txt", upload_id=Some("U1")),
    0,
  ) catch {
    err => text_of(err)
  }
  println("分片号 0 读数=" + zero_part)
  assert_eq(zero_part.has_prefix("Platform:cos network: "), true)
  let wrong_host = get_text(platform, "https://other.example.com/a.txt") catch {
    err => text_of(err)
  }
  assert_eq(
    wrong_host.has_prefix("InvalidInput:url is not under this platform domain"),
    true,
  )
}

///|
/// 能力位报 true 的那一族必须**真的会出门**：`acl: true` 之下 `set_file_acl` 会去调
/// `put_object_acl`，桩把它拦下报传输那一档——这就证住了它没有像 `platform-oss` 那样
/// 就地 `NotSupported`（COS 真桶收 `x-cos-acl: public-read` 且匿名 GET 回 200，2026-10-18 现读）。
async test "适配 #7 能力位逐条对齐，acl 报 true 且 set_file_acl 真会出门" {
  let platform = stub_platform(domain=Some(vhost()))
  let caps = platform.capabilities()
  assert_eq(caps.multipart_upload, true)
  assert_eq(caps.list_files, true)
  assert_eq(caps.presigned_url, true)
  assert_eq(caps.metadata, true)
  assert_eq(caps.same_copy, true)
  assert_eq(caps.same_move, true)
  // 与 OSS 唯一的不同位：COS 这一族在契约语义下兑得了现
  assert_eq(caps.acl, true)
  assert_eq(platform.name(), "cos")
  let outcome = acl_text(platform) catch { err => text_of(err) }
  println("set_file_acl 读数=" + outcome)
  // 不是就地拒绝，而是真发了请求被桩拦下
  assert_eq(outcome.has_prefix("NotSupported"), false)
  assert_eq(outcome.has_prefix("Platform:cos network: "), true)
  assert_eq(outcome.contains("stub transport must not be called"), true)
  // 对照：exists 也会出门（同一档桩），两族都真的走网络
  let sent = exists_text(platform, keyed_info("a/b.txt")) catch {
    err => text_of(err)
  }
  assert_eq(sent.has_prefix("Platform:cos network: "), true)
}

///|
/// 预签名两档都是本地算出来的：那条"从不发请求"的桩一次都没被调用，签得出 URL。
/// 与 OSS 不同的两处：① 有效期没有独立参数，窗口写在 `q-sign-time` 里，本端口不判上界
/// （COS 没有文档数字），所以 604801 秒照样签得出；② 只拒"窗口不成立"（结束不晚于起始），
/// 负得够多的有效期就地 `BadParam`。
async test "适配 #8 预签名 GET 与 PUT 都签得出且互不相同，PUT 不锁 Content-Type" {
  let platform = stub_platform(domain=Some(vhost()))
  let download = presign_text(platform, @model.PresignMethod::Get, 600) catch {
    err => text_of(err)
  }
  println("预签名 GET 形状=" + download)
  assert_eq(download.has_prefix(vhost() + "/a/b.txt?"), true)
  assert_eq(download.contains("q-sign-algorithm=sha1"), true)
  // secret_id 原样进 q-ak（预签名里本就是明文，不是秘密）
  assert_eq(download.contains("AKIDtestid"), true)
  let upload = presign_text(platform, @model.PresignMethod::Put, 600) catch {
    err => text_of(err)
  }
  println("预签名 PUT 形状=" + upload)
  assert_eq(upload.has_prefix(vhost() + "/a/b.txt?"), true)
  // 动词进签名串：两档绝不能是同一条 URL（契约里那条兜底判据）
  assert_eq(upload == download, false)
  // PUT 不锁 Content-Type：锁了直传方就得一字不差地发同一个值，否则签名不符
  assert_eq(upload.contains("content-type"), false)
  // 上界不在这里判：一条很长的有效期照样签得出（与 OSS 拒 >604800 相反）
  let long = presign_text(platform, @model.PresignMethod::Get, 604801) catch {
    err => text_of(err)
  }
  println("超长有效期读数=" + long)
  assert_eq(long.has_prefix(vhost() + "/a/b.txt?"), true)
  // 窗口不成立才拒：负得把结束推到起始之前，本地 BadParam，不出门
  let bad_window = presign_text(platform, @model.PresignMethod::Get, -120) catch {
    err => text_of(err)
  }
  println("窗口不成立读数=" + bad_window)
  assert_eq(
    bad_window.has_prefix("InvalidInput:cos param: presigned window"),
    true,
  )
}

///|
/// 404 只看状态码：这一档桩回的是**空正文**（真桶 `HEAD /<key>` 就是这样，`code` 是
/// 空串），三条读数分别是"没有"的回答与"没有"的错误——都不许退化成"平台错了"。
async test "适配 #9 空正文的 404：exists/delete 答没有，get_file 回 None，列举报 NotFound" {
  let platform = absent_platform()
  let info = keyed_info("a/b.txt")
  let present = exists_text(platform, info) catch { err => text_of(err) }
  println("404 空正文下 exists 读数=" + present)
  assert_eq(present, "false")
  let removed = delete_text(platform, info) catch { err => text_of(err) }
  println("404 空正文下 delete 读数=" + removed)
  assert_eq(removed, "false")
  let read = get_text(platform, vhost() + "/a/b.txt") catch {
    err => text_of(err)
  }
  println("404 空正文下 get_file 读数=" + read)
  assert_eq(read, "<absent>")
  // 只有需要回"读数"而不是"答案"的那一族才把它升成一档错误
  let listed = list_text(platform, "a/b") catch { err => text_of(err) }
  println("404 空正文下 list_files 读数=" + listed)
  assert_eq(listed.has_prefix("NotFound:cos 404 "), true)
  assert_eq(listed.contains("reqid=reqid-stub"), true)
  // 空正文 ⇒ code 与 message 都是空串：文案里除了状态码什么都没有，正是"按 status 判"的证据
  assert_eq(listed.contains("NoSuchKey"), false)
}
