///|
/// 适配层的异步负判据（走公开面）：所有"拦在出门之前"的档都靠一个从不发请求的桩传输
/// 自证——真发出去了就会拿到另一档读数（桩被调用即报错），两档文字不同才算证住。
/// 另一档桩只回 404 空正文，那是真桶 `HEAD /<key>` 的形状（只有状态码、没有 XML 正文、
/// 没有 `<Code>`）。一条请求都不上网，凭据是假的。

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
/// 每次调用都回 **404 + 空正文**：不带 `<Code>`，正是真桶那一发 `HEAD` 打不存在的键
/// 收到的形状（只有状态码，没有 XML）。判"不存在"必须只看状态码，这一档就是它的判据。
/// 请求号头给 `x-amz-request-id`——OBS 的 V4 那一族真桶回的就是这个头名（SDK 的
/// `signed_prefix` 在原生面取 `Amz`），两个名字都找一遍的活归 SDK。
struct AbsentTransport {}

///|
impl @transport.Transport for AbsentTransport with fn send(self, request) {
  let _ = self
  let _ = request
  let body : &@transport.ResponseBody = QuietBody::{ }
  @transport.Response::{
    status: 404,
    headers: [
      @transport.Header::{ name: "x-amz-request-id", value: "reqid-stub", },
    ],
    body,
  }
}

///|
/// 假凭据、假区域，虚主机域名一律 `.invalid`，绝不会碰真端点；桶名是示例占位。
/// OBS 只有虚主机一档寻址，所以连"要不要 path 风格"的配置位都没有（见 wbtest #6）。
fn build_platform(
  transport : &@transport.Transport,
  domain~ : String? = None,
) -> @obs.ObsPlatform raise {
  let credentials = @auth.Credentials::new("akExampleKeyId", "skExampleSecret")
  let config = @config.Config::new(
    "obs.cn-south-1.invalid", "cn-south-1", credentials,
  )
  @obs.ObsPlatform::new(@obs.ObsPlatformConfig::{
    platform: "obs",
    bucket: "sample-bucket",
    domain,
    client: @sdk.Client::new(config, transport),
  })
}

///|
/// 桶的虚主机前缀，预签名 URL 就落在这个域上；domain 用它才能过契约里"预签名 URL
/// 以 domain 开头"那一档（V4 签名把 `Host` 算进签名头，`X-Amz-SignedHeaders=host`）。
fn vhost() -> String {
  "https://sample-bucket.obs.cn-south-1.invalid"
}

///|
fn stub_platform(domain~ : String? = None) -> @obs.ObsPlatform raise {
  let transport : &@transport.Transport = StubTransport::{ }
  build_platform(transport, domain~)
}

///|
/// 处处都"没有这个对象"的一条腿。
fn absent_platform() -> @obs.ObsPlatform raise {
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
  @model.FileInfo::draft("obs", "a/b", "c.txt", "txt")
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
  platform : @obs.ObsPlatform,
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
  platform : @obs.ObsPlatform,
  url : String,
) -> String raise @model.StorageError {
  match platform.get_file(url) {
    None => "<absent>"
    Some(one) => one.url
  }
}

///|
async fn exists_text(
  platform : @obs.ObsPlatform,
  info : @model.FileInfo,
) -> String raise @model.StorageError {
  platform.exists(info).to_string()
}

///|
async fn delete_text(
  platform : @obs.ObsPlatform,
  info : @model.FileInfo,
) -> String raise @model.StorageError {
  platform.delete(info).to_string()
}

///|
async fn list_text(
  platform : @obs.ObsPlatform,
  path : String,
) -> String raise @model.StorageError {
  let page = platform.list_files(path, "", None)
  page.files.length().to_string()
}

///|
async fn part_text(
  platform : @obs.ObsPlatform,
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
  platform : @obs.ObsPlatform,
) -> String raise @model.StorageError {
  platform.set_file_acl(keyed_info("a/b.txt"), @model.CannedAcl::PublicRead)
  "accepted"
}

///|
fn presign_text(
  platform : @obs.ObsPlatform,
  verb : @model.PresignMethod,
  seconds : Int32,
) -> String raise @model.StorageError {
  platform.presigned_url(keyed_info("a/b.txt"), verb, seconds)
}

///|
async fn list_parts_text(
  platform : @obs.ObsPlatform,
  info : @model.FileInfo,
) -> String raise @model.StorageError {
  let page = platform.list_parts(info, 0)
  page.parts.length().to_string()
}

///|
async fn complete_text(
  platform : @obs.ObsPlatform,
  info : @model.FileInfo,
) -> String raise @model.StorageError {
  let one = platform.complete_multipart(info, [])
  one.url
}

///|
async fn abort_text(
  platform : @obs.ObsPlatform,
  info : @model.FileInfo,
) -> String raise @model.StorageError {
  platform.abort_multipart(info)
  "aborted"
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
    blocked.has_prefix("InvalidInput:obs platform obs needs a domain"),
    true,
  )
  // 同一条腿换成"有域名"：这一步真的去发请求了，桩把它拦下并报另一档
  let with_domain = stub_platform(domain=Some(vhost()))
  let sent = save_text(with_domain, draft_info(), bytes) catch {
    err => text_of(err)
  }
  println("有域名 save 读数=" + sent)
  assert_eq(sent.has_prefix("Platform:obs network: "), true)
  assert_eq(sent.contains("stub transport must not be called"), true)
  assert_eq(sent == blocked, false)
  // 本地文件那一档：本端口不读盘，交给调用方自己开句柄
  let from_path = save_text(
    with_domain,
    draft_info(),
    @model.UploadSource::Path("nowhere-placeholder.bin"),
  ) catch {
    err => text_of(err)
  }
  println("Path 档读数=" + from_path)
  assert_eq(
    from_path.has_prefix("NotSupported:obs platform uploads bytes or a reader"),
    true,
  )
}

///|
async test "适配 #6 空 key、缺会话号、别家域名的 URL 都拦在本地；越界分片号在出门前就拒" {
  let platform = stub_platform(domain=Some(vhost()))
  let blank = keyed_info("")
  let exists_blocked = exists_text(platform, blank) catch {
    err => text_of(err)
  }
  println("空 key exists 读数=" + exists_blocked)
  assert_eq(exists_blocked, "InvalidInput:obs object needs a key")
  let delete_blocked = delete_text(platform, blank) catch {
    err => text_of(err)
  }
  assert_eq(delete_blocked, "InvalidInput:obs object needs a key")
  // 有 key 但没有 init 回来的会话号：分片族四步都该这么拦
  let no_session = part_text(platform, keyed_info("a/b.txt"), 1) catch {
    err => text_of(err)
  }
  println("缺会话号读数=" + no_session)
  assert_eq(
    no_session, "InvalidInput:multipart needs the upload_id returned by init_multipart",
  )
  // 与 `platform-cos` 相反的一档：OBS 的 SDK 在**发出请求之前**校验分片号 1..10000，
  // 端口要的就是这一档。所以分片号 0 报 InvalidInput 而不是走到传输；桩一次都没被调用
  // （文字里不含 "network"）就是"拦在出门前"的证据。
  let zero_part = part_text(
    platform,
    keyed_info("a/b.txt", upload_id=Some("U1")),
    0,
  ) catch {
    err => text_of(err)
  }
  println("分片号 0 读数=" + zero_part)
  assert_eq(
    zero_part.has_prefix(
      "InvalidInput:obs param: part number must be within 1..10000",
    ),
    true,
  )
  assert_eq(zero_part.contains("network"), false)
  let wrong_host = get_text(platform, "https://other.example.invalid/a.txt") catch {
    err => text_of(err)
  }
  assert_eq(
    wrong_host.has_prefix("InvalidInput:url is not under this platform domain"),
    true,
  )
}

///|
/// 能力位报 true 的那一族必须**真的会出门**：`acl` 在 OBS 是真值（`public-read` 生效后
/// 匿名 GET 200、改回 `private` 又 403，2026-10-19 真桶实测——与 `platform-oss` 那一格
/// 正相反，与 COS 同号但两家各自实测），`set_file_acl` 就真去调 `put_object_acl`，桩把它
/// 拦下报传输那一档——证住它没有就地 `NotSupported`。
async test "适配 #7 能力位逐条对齐，acl 报 true 且 set_file_acl 真会出门" {
  let platform = stub_platform(domain=Some(vhost()))
  let caps = platform.capabilities()
  assert_eq(caps.multipart_upload, true)
  assert_eq(caps.list_files, true)
  assert_eq(caps.presigned_url, true)
  assert_eq(caps.metadata, true)
  assert_eq(caps.same_copy, true)
  assert_eq(caps.same_move, true)
  // 七位全 true 是 OBS 自己的实测结论（出处见 capabilities 注释），不是照抄 COS 那份
  assert_eq(caps.acl, true)
  assert_eq(platform.name(), "obs")
  let outcome = acl_text(platform) catch { err => text_of(err) }
  println("set_file_acl 读数=" + outcome)
  // 不是就地拒绝，而是真发了请求被桩拦下
  assert_eq(outcome.has_prefix("NotSupported"), false)
  assert_eq(outcome.has_prefix("Platform:obs network: "), true)
  assert_eq(outcome.contains("stub transport must not be called"), true)
  // 对照：exists 也会出门（同一档桩），两族都真的走网络
  let sent = exists_text(platform, keyed_info("a/b.txt")) catch {
    err => text_of(err)
  }
  assert_eq(sent.has_prefix("Platform:obs network: "), true)
}

///|
/// 预签名两档都是本地算出来的：那条"从不发请求"的桩一次都没被调用，签得出 URL。
/// 与 `platform-cos` 不同的两处：① 有效期有**文档数字**（1..604800 秒，永久密钥七天），
/// 上界与"窗口不成立"两档都在 SDK 本地拒 → `InvalidInput`；② 参数名是 `X-Amz-*` 那一套
/// （原生面也一样），`Host` 必入签。
async test "适配 #8 预签名 GET 与 PUT 都签得出且互不相同，有效期上界在本地把关" {
  let platform = stub_platform(domain=Some(vhost()))
  let download = presign_text(platform, @model.PresignMethod::Get, 600) catch {
    err => text_of(err)
  }
  println("预签名 GET 形状=" + download)
  assert_eq(download.has_prefix(vhost() + "/a/b.txt?"), true)
  assert_eq(download.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"), true)
  // access key 原样进 X-Amz-Credential（预签名里本就是明文，不是秘密）
  assert_eq(download.contains("akExampleKeyId"), true)
  assert_eq(download.contains("X-Amz-SignedHeaders=host"), true)
  let upload = presign_text(platform, @model.PresignMethod::Put, 600) catch {
    err => text_of(err)
  }
  println("预签名 PUT 形状=" + upload)
  assert_eq(upload.has_prefix(vhost() + "/a/b.txt?"), true)
  // 动词进签名串：两档绝不能是同一条 URL（契约里那条兜底判据）
  assert_true(upload != download)
  // PUT 不锁 Content-Type：锁了直传方就得一字不差地发同一个值，否则签名不符
  assert_eq(upload.contains("content-type"), false)
  // 上界在本地把关：604801 秒（七天 + 1）就地拒，不发给服务端猜——与 COS"没有文档
  // 数字、照样签得出"相反的一档
  let over_cap = presign_text(platform, @model.PresignMethod::Get, 604801) catch {
    err => text_of(err)
  }
  println("超上界读数=" + over_cap)
  assert_eq(
    over_cap.has_prefix(
      "InvalidInput:obs param: presign validity must be within 1..604800",
    ),
    true,
  )
  // 下界同理：负得把窗口推没的有效期本地就拒，不出门
  let bad_window = presign_text(platform, @model.PresignMethod::Get, -120) catch {
    err => text_of(err)
  }
  println("窗口不成立读数=" + bad_window)
  assert_eq(
    bad_window.has_prefix(
      "InvalidInput:obs param: presign validity must be within 1..604800",
    ),
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
  assert_eq(listed.has_prefix("NotFound:obs 404 "), true)
  assert_eq(listed.contains("reqid=reqid-stub"), true)
  // 空正文 ⇒ code 与 message 都是空串：文案里除了状态码什么都没有，正是"按 status 判"的证据
  assert_eq(listed.contains("NoSuchKey"), false)
}

///|
/// "厂商做不到"的响亮失败收口成一档：OBS 这一腿的**七个能力族全部兑现有据**（实测出处
/// 见 `capabilities`），端口面上没有"这家做不到的一族"；做不到的是来源档位里的本地文件
/// 一档（`UploadSource::Path`——本端口族在 OBS 与其余各腿同口径不读盘），必须报
/// `NotSupported` 且不发请求。abort 之后 `list_parts` 那一发（真桶回 404 `NoSuchUpload`）
/// 归到 `NotFound` 的判据在 wbtest #0，这里钉"桩一次都没被调用"这一条。
async test "适配 #10 Path 档响亮失败不发请求；缺会话号的分片四步全拦在本地" {
  let platform = stub_platform(domain=Some(vhost()))
  let from_path = save_text(
    platform,
    draft_info(),
    @model.UploadSource::Path("nowhere-placeholder.bin"),
  ) catch {
    err => text_of(err)
  }
  assert_eq(
    from_path.has_prefix("NotSupported:obs platform uploads bytes or a reader"),
    true,
  )
  assert_eq(from_path.contains("stub transport"), false)
  let no_id = keyed_info("a/b.txt")
  let readings : Array[String] = []
  readings.push(part_text(platform, no_id, 1) catch { err => text_of(err) })
  readings.push(list_parts_text(platform, no_id) catch { err => text_of(err) })
  readings.push(complete_text(platform, no_id) catch { err => text_of(err) })
  readings.push(abort_text(platform, no_id) catch { err => text_of(err) })
  for reading in readings {
    println("缺会话号读数=" + reading)
    assert_eq(
      reading, "InvalidInput:multipart needs the upload_id returned by init_multipart",
    )
  }
}

///|
/// OBS 只有虚主机一档寻址的**真件**钉子（分档的白盒钉在 wbtest #6）：响亮拒绝的本体是
/// SDK 的 `Config::path_style_url`——永远 raise，不给"也许能用"的串。端口没有寻址风格
/// 这一法，适配层也不提供 path 选项；这里同时钉派生只有一条路：`host_of`/`url_of` 都走
/// 虚主机，没有第二个答案。真桶读数：path 风格一律 403 `VirtualHostDomainRequired`（带正文）。
async test "适配 #11 path 风格永远响亮拒；host 与 URL 的派生只有虚主机一条路" {
  let credentials = @auth.Credentials::new("akExampleKeyId", "skExampleSecret")
  let config = @config.Config::new(
    "obs.cn-south-1.invalid", "cn-south-1", credentials,
  )
  let refused = config.path_style_url("sample-bucket", key="a/b.txt") catch {
    e => e.text()
  }
  println("path 风格读数=" + refused)
  assert_eq(refused.has_prefix("obs bad-param: "), true)
  assert_eq(refused.contains("VirtualHostDomainRequired"), true)
  assert_eq(
    config.host_of("sample-bucket"),
    "sample-bucket.obs.cn-south-1.invalid",
  )
  assert_eq(
    config.url_of("sample-bucket", key="a/b.txt"),
    "https://sample-bucket.obs.cn-south-1.invalid/a/b.txt",
  )
  // 空桶名走的是服务级主机（`GET /` 列桶那一族），与桶级同一处派生、不是第三种形状
  assert_eq(config.host_of(""), "obs.cn-south-1.invalid")
}
