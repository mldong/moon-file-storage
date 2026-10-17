///|
/// 适配层的异步负判据（走公开面）：所有"拦在出门之前"的档都靠一个从不发请求的桩传输
/// 自证——真发出去了就会拿到另一档读数（桩被调用即报错），两档文字不同才算证住。
/// 一条请求都不会上网，凭据也是假的。

///|
struct StubTransport {}

///|
impl @transport.Transport for StubTransport with fn send(self, request) {
  let detail = "stub transport must not be called: " + request.url
  let _ = self
  raise @transport.TransportError::InvalidRequest(detail)
}

///|
fn stub_platform(
  domain~ : String? = None,
  check_crc~ : Bool = false,
) -> @qiniu.QiniuPlatform raise {
  let transport : &@transport.Transport = StubTransport::{ }
  let auth = @auth.Auth::new("ak-stub-not-real", "sk-stub-not-real")
  let region = match @config.Region::with_region_id("z0") {
    None => raise @kodoerr.KodoError::BadParam("z0 must be constructible")
    Some(one) => one
  }
  let client = @sdk.Client::new(
    transport,
    auth,
    @config.Config::new(region, use_https=true),
    "blog",
  )
  @qiniu.QiniuPlatform::new(
    @qiniu.QiniuPlatformConfig::new(
      "qiniu",
      client,
      transport,
      domain~,
      check_crc~,
    ),
  )
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
async fn save_text(
  platform : @qiniu.QiniuPlatform,
  info : @model.FileInfo,
  source : @model.UploadSource,
) -> String raise @model.StorageError {
  let saved = platform.save(info, source)
  match saved {
    None => "<none>"
    Some(one) => one.url
  }
}

///|
async fn get_text(
  platform : @qiniu.QiniuPlatform,
  url : String,
) -> String raise @model.StorageError {
  match platform.get_file(url) {
    None => "<absent>"
    Some(one) => one.url
  }
}

///|
async fn exists_text(
  platform : @qiniu.QiniuPlatform,
  info : @model.FileInfo,
) -> String raise @model.StorageError {
  platform.exists(info).to_string()
}

///|
async fn part_text(
  platform : @qiniu.QiniuPlatform,
  info : @model.FileInfo,
) -> String raise @model.StorageError {
  let one = platform.upload_part(
    info,
    1,
    @model.UploadSource::Bytes(@utf8.encode("x")),
  )
  one.etag
}

///|
async fn acl_text(
  platform : @qiniu.QiniuPlatform,
) -> String raise @model.StorageError {
  platform.set_file_acl(keyed_info("a/b.txt"), @model.CannedAcl::Private)
  "accepted"
}

///|
fn presign_text(
  platform : @qiniu.QiniuPlatform,
  verb : @model.PresignMethod,
  seconds : Int32,
) -> String raise @model.StorageError {
  platform.presigned_url(keyed_info("a/b.txt"), verb, seconds)
}

///|
fn draft_info() -> @model.FileInfo {
  @model.FileInfo::draft("qiniu", "a/b", "c.txt", "txt")
}

///|
fn keyed_info(path : String) -> @model.FileInfo {
  draft_info().stamped(@model.Stamp::{
    platform: None,
    path: Some(path),
    url: None,
    size: None,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
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
    blocked.has_prefix("InvalidInput:qiniu platform qiniu needs a domain"),
    true,
  )
  // 同一条腿换成"有域名"：这一步真的去发请求了，桩把它拦下并报另一档
  // （SDK 把 InvalidRequest 归到参数档，所以文字前缀相同、后缀不同——正因不同才证明上面那条没出门）
  let with_domain = stub_platform(domain=Some("https://blog.example.com"))
  let sent = save_text(with_domain, draft_info(), bytes) catch {
    err => text_of(err)
  }
  println("有域名 save 读数=" + sent)
  assert_eq(
    sent.has_prefix(
      "InvalidInput:kodo param: stub transport must not be called",
    ),
    true,
  )
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
    from_path.has_prefix(
      "NotSupported:qiniu platform uploads bytes or a reader",
    ),
    true,
  )
}

///|
async test "适配 #6 空 key、缺会话号、别家域名的 URL 都拦在本地" {
  let platform = stub_platform(domain=Some("https://blog.example.com"))
  let blank = keyed_info("")
  let exists_blocked = exists_text(platform, blank) catch {
    err => text_of(err)
  }
  println("空 key exists 读数=" + exists_blocked)
  assert_eq(exists_blocked, "InvalidInput:qiniu object needs a key")
  let part_blocked = part_text(platform, blank) catch { err => text_of(err) }
  assert_eq(part_blocked, "InvalidInput:qiniu object needs a key")
  // 有 key 但没有 init 回来的会话号：分片族四步都该这么拦
  let no_session = part_text(platform, keyed_info("a/b.txt")) catch {
    err => text_of(err)
  }
  println("缺会话号读数=" + no_session)
  assert_eq(
    no_session, "InvalidInput:multipart needs the upload_id returned by init_multipart",
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
async test "适配 #7 能力位与拒绝成对：acl 报 false 且被调用就响亮" {
  let platform = stub_platform()
  let caps = platform.capabilities()
  assert_eq(caps.multipart_upload, true)
  assert_eq(caps.list_files, true)
  assert_eq(caps.presigned_url, true)
  assert_eq(caps.metadata, true)
  assert_eq(caps.same_copy, true)
  assert_eq(caps.same_move, true)
  assert_eq(caps.acl, false)
  assert_eq(platform.name(), "qiniu")
  let refused = acl_text(platform) catch { err => text_of(err) }
  println("set_file_acl 读数=" + refused)
  assert_eq(
    refused.has_prefix("NotSupported:qiniu platform qiniu has no canned ACL"),
    true,
  )
  // 预签名两档：只给 GET；Put 响亮拒绝（参照件原话就是"仅支持 GET"）
  let put = presign_text(platform, @model.PresignMethod::Put, 60) catch {
    err => text_of(err)
  }
  println("预签名 Put 读数=" + put)
  assert_eq(
    put.has_prefix("NotSupported:qiniu Kodo signs download URLs only"),
    true,
  )
  // 没给域名时连 GET 也签不出来：不能编一条打不开的地址
  let no_domain_get = presign_text(platform, @model.PresignMethod::Get, 60) catch {
    err => text_of(err)
  }
  assert_eq(no_domain_get.has_prefix("InvalidInput:"), true)
  let signed = stub_platform(domain=Some("https://blog.example.com"))
  let url = presign_text(signed, @model.PresignMethod::Get, 60) catch {
    err => text_of(err)
  }
  println("预签名 GET 形状=" + url)
  // 次序承重：先拼 `e=<deadline>`，对整串签，最后才拼 `token=`
  assert_eq(url.has_prefix("https://blog.example.com/a/b.txt?e="), true)
  assert_eq(url.contains("&token=ak-stub-not-real:"), true)
  let e_at = url.find("?e=").unwrap_or(-1)
  let token_at = url.find("&token=").unwrap_or(-1)
  assert_eq(e_at >= 0 && token_at > e_at, true)
}
