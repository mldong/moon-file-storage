///|
/// 适配层的异步负判据（走公开面）：所有"拦在出门之前"的档都靠一个从不发请求的桩传输
/// 自证——真发出去了就会拿到另一档读数（桩被调用即报错），两档文字不同才算证住。
/// 另一档桩只回 404 空正文，那是真桶 `HEAD /<key>` 的形状。一条请求都不上网，凭据是假的。

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
      @transport.Header::{ name: "x-oss-request-id", value: "reqid-stub", },
    ],
    body,
  }
}

///|
fn build_platform(
  transport : &@transport.Transport,
  domain~ : String? = None,
) -> @oss.OssPlatform raise {
  // 凭据是假的、只用于把签名算出来；域名用 invalid TLD，绝不会碰真端点
  let credentials = @auth.Credentials::new(
    "ak-stub-not-real", "sk-stub-not-real",
  )
  let config = @config.Config::new(
    "https://oss-cn-zhangjiakou.example.invalid", "cn-zhangjiakou", credentials,
  )
  @oss.OssPlatform::new(@oss.OssPlatformConfig::{
    platform: "oss",
    bucket: "blog",
    domain,
    client: @sdk.Client::new(config, transport),
  })
}

///|
fn stub_platform(domain~ : String? = None) -> @oss.OssPlatform raise {
  let transport : &@transport.Transport = StubTransport::{ }
  build_platform(transport, domain~)
}

///|
/// 处处都"没有这个对象"的一条腿。
fn absent_platform() -> @oss.OssPlatform raise {
  let transport : &@transport.Transport = AbsentTransport::{ }
  build_platform(transport, domain=Some("https://blog.example.invalid"))
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
  @model.FileInfo::draft("oss", "a/b", "c.txt", "txt")
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
  platform : @oss.OssPlatform,
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
  platform : @oss.OssPlatform,
  url : String,
) -> String raise @model.StorageError {
  match platform.get_file(url) {
    None => "<absent>"
    Some(one) => one.url
  }
}

///|
async fn exists_text(
  platform : @oss.OssPlatform,
  info : @model.FileInfo,
) -> String raise @model.StorageError {
  platform.exists(info).to_string()
}

///|
async fn delete_text(
  platform : @oss.OssPlatform,
  info : @model.FileInfo,
) -> String raise @model.StorageError {
  platform.delete(info).to_string()
}

///|
async fn list_text(
  platform : @oss.OssPlatform,
  path : String,
) -> String raise @model.StorageError {
  let page = platform.list_files(path, "", None)
  page.files.length().to_string()
}

///|
async fn part_text(
  platform : @oss.OssPlatform,
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
  platform : @oss.OssPlatform,
) -> String raise @model.StorageError {
  platform.set_file_acl(keyed_info("a/b.txt"), @model.CannedAcl::PublicRead)
  "accepted"
}

///|
fn presign_text(
  platform : @oss.OssPlatform,
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
    blocked.has_prefix("InvalidInput:oss platform oss needs a domain"),
    true,
  )
  // 同一条腿换成"有域名"：这一步真的去发请求了，桩把它拦下并报另一档
  let with_domain = stub_platform(domain=Some("https://blog.example.invalid"))
  let sent = save_text(with_domain, draft_info(), bytes) catch {
    err => text_of(err)
  }
  println("有域名 save 读数=" + sent)
  assert_eq(sent.has_prefix("Platform:oss network: "), true)
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
    from_path.has_prefix("NotSupported:oss platform uploads bytes or a reader"),
    true,
  )
}

///|
async test "适配 #6 空 key、缺会话号、越界分片号、别家域名的 URL 都拦在本地" {
  let platform = stub_platform(domain=Some("https://blog.example.invalid"))
  let blank = keyed_info("")
  let exists_blocked = exists_text(platform, blank) catch {
    err => text_of(err)
  }
  println("空 key exists 读数=" + exists_blocked)
  assert_eq(exists_blocked, "InvalidInput:oss object needs a key")
  let delete_blocked = delete_text(platform, blank) catch {
    err => text_of(err)
  }
  assert_eq(delete_blocked, "InvalidInput:oss object needs a key")
  // 有 key 但没有 init 回来的会话号：分片族四步都该这么拦
  let no_session = part_text(platform, keyed_info("a/b.txt"), 1) catch {
    err => text_of(err)
  }
  println("缺会话号读数=" + no_session)
  assert_eq(
    no_session, "InvalidInput:multipart needs the upload_id returned by init_multipart",
  )
  // 分片号越界：SDK 在拼出请求之前就拒，桩没被调用就是证据
  let bad_number = part_text(
    platform,
    keyed_info("a/b.txt", upload_id=Some("U1")),
    0,
  ) catch {
    err => text_of(err)
  }
  println("越界分片号读数=" + bad_number)
  assert_eq(
    bad_number.has_prefix("InvalidInput:oss param: part number must be within"),
    true,
  )
  let wrong_host = get_text(platform, "https://other.example.com/a.txt") catch {
    err => text_of(err)
  }
  assert_eq(
    wrong_host.has_prefix("InvalidInput:url is not under this platform domain"),
    true,
  )
}

///|
/// 能力位报 false 的那一族必须在**发出请求之前**拒绝：真发出去只会收到桶侧那条
/// 403 `AccessDenied`（2026-10-18 真桶：`public-read` 被拒、`private` 才收，而默认
/// 读回的 grant 是 `default`），把"这一族做不到"混成"这一次请求失败了"。
async test "适配 #7 能力位与实测逐条对齐，acl 报 false 且被调用就地拒绝" {
  let platform = stub_platform(domain=Some("https://blog.example.invalid"))
  let caps = platform.capabilities()
  // 真桶测过的五族（分片五步／ListObjects V2／预签名两档／x-oss-meta-* 回显／同桶复制）
  assert_eq(caps.multipart_upload, true)
  assert_eq(caps.list_files, true)
  assert_eq(caps.presigned_url, true)
  assert_eq(caps.metadata, true)
  assert_eq(caps.same_copy, true)
  assert_eq(caps.same_move, true)
  // 唯一兑不了现的那一族
  assert_eq(caps.acl, false)
  assert_eq(platform.name(), "oss")
  let refused = acl_text(platform) catch { err => text_of(err) }
  println("set_file_acl 读数=" + refused)
  assert_eq(refused, "NotSupported:oss platform oss has no canned ACL family")
  // 同一条腿换成真会出门的那一档：桩拦下它并报另一档文字。两档不同才证明上面那条没上网
  let sent = exists_text(platform, keyed_info("a/b.txt")) catch {
    err => text_of(err)
  }
  println("对照读数（会出门的那一档）=" + sent)
  assert_eq(sent.has_prefix("Platform:oss network: "), true)
  assert_eq(sent == refused, false)
}

///|
/// 预签名两档都是本地算出来的：那条"从不发请求"的桩一次都没被调用，签得出 URL；
/// 越界的有效期同样拦在本地（上限 604800 秒由签名那层把关）。
async test "适配 #8 预签名 GET 与 PUT 都签得出且互不相同，越界有效期不出门" {
  let platform = stub_platform(domain=Some("https://blog.example.invalid"))
  let download = presign_text(platform, @model.PresignMethod::Get, 60) catch {
    err => text_of(err)
  }
  println("预签名 GET 形状=" + download)
  assert_eq(
    download.has_prefix(
      "https://blog.oss-cn-zhangjiakou.example.invalid/a/b.txt?",
    ),
    true,
  )
  assert_eq(download.contains("x-oss-signature="), true)
  assert_eq(download.contains("x-oss-expires=60"), true)
  assert_eq(download.contains("ak-stub-not-real"), true)
  let upload = presign_text(platform, @model.PresignMethod::Put, 60) catch {
    err => text_of(err)
  }
  println("预签名 PUT 形状=" + upload)
  assert_eq(
    upload.has_prefix(
      "https://blog.oss-cn-zhangjiakou.example.invalid/a/b.txt?",
    ),
    true,
  )
  // 动词进签名串：两档绝不能是同一条 URL（契约里那条兜底判据）
  assert_eq(upload == download, false)
  // PUT 不锁 Content-Type：锁了直传方就得一字不差地发同一个值，否则签名不符
  assert_eq(upload.contains("content-type"), false)
  let too_long = presign_text(platform, @model.PresignMethod::Get, 604801) catch {
    err => text_of(err)
  }
  println("超上限读数=" + too_long)
  assert_eq(
    too_long.has_prefix(
      "InvalidInput:oss param: presign validity must be within",
    ),
    true,
  )
  let zero = presign_text(platform, @model.PresignMethod::Get, 0) catch {
    err => text_of(err)
  }
  assert_eq(zero.has_prefix("InvalidInput:oss param: "), true)
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
  let read = get_text(platform, "https://blog.example.invalid/a/b.txt") catch {
    err => text_of(err)
  }
  println("404 空正文下 get_file 读数=" + read)
  assert_eq(read, "<absent>")
  // 只有需要回"读数"而不是"答案"的那一族才把它升成一档错误
  let listed = list_text(platform, "a/b") catch { err => text_of(err) }
  println("404 空正文下 list_files 读数=" + listed)
  assert_eq(listed.has_prefix("NotFound:oss 404 "), true)
  assert_eq(listed.contains("reqid=reqid-stub"), true)
  // 空正文 ⇒ code 与 message 都是空串：文案里除了状态码什么都没有，正是"按 status 判"的证据
  assert_eq(listed.contains("NoSuchKey"), false)
}
