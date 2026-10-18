///|
// 第九条契约腿：腾讯云 COS 原生协议（公网真桶）跑同一份契约正文。
//
// 环境不齐就跳过，而跳过必须响亮（"SKIP IS NOT A PASS"）。这条腿与 S3 兼容层那条互不背书——
// 走的是 `q-sign-*` 原生签名 + 虚主机寻址：签名件与协议件在 `mldong/moon-cos`，端口接入在
// `platform-cos`，两处的读数在这一条腿里一起过真端点。

///|
struct Rig {
  transport : &@transport.Transport
  config : @cosconfig.Config
  client : @sdk.Client
  platform : @cos.CosPlatform
}

///|
/// 必备四项：两把键、长命名桶（appid 就在桶名里）、区域。`COS_DOMAIN` 可省，但省与不省都
/// 不生效——原因写在 `build` 里那一条响亮忽略；`COS_RUN_TAG` 只决定本轮前缀。
fn live_env() -> (String, String, String, String)? {
  let ak = @env.get_env_var("COS_AK").unwrap_or("")
  let sk = @env.get_env_var("COS_SK").unwrap_or("")
  let bucket = @env.get_env_var("COS_BUCKET").unwrap_or("")
  let region = @env.get_env_var("COS_REGION").unwrap_or("")
  if ak.is_empty() || sk.is_empty() || bucket.is_empty() || region.is_empty() {
    None
  } else {
    Some((ak, sk, bucket, region))
  }
}

///|
fn report_skip() -> Unit {
  let missing : Array[String] = []
  for name in ["COS_AK", "COS_SK", "COS_BUCKET", "COS_REGION"] {
    if @env.get_env_var(name).unwrap_or("").is_empty() {
      missing.push(name)
    }
  }
  println("SKIP contract/cos, environment not supplied")
  println("missing: " + missing.join(", "))
  println("SKIP IS NOT A PASS: this platform leg was not verified by this run.")
}

///|
fn storage_text(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(detail) => "InvalidInput: " + detail
    @model.StorageError::NotSupported(detail) => "NotSupported: " + detail
    @model.StorageError::NotFound(detail) => "NotFound: " + detail
    @model.StorageError::Platform(detail) => "Platform: " + detail
    @model.StorageError::Recorder(detail) => "Recorder: " + detail
  }
}

///|
fn cos_text(error : @coserr.CosError) -> String {
  error.text()
}

///|
/// 传输层的错误**只报种类、不报文案**：官方 http 的错误串可能带上整条 URL，而预签名 URL 的
/// 查询串里有 `q-ak`（SecretId 原样在其中）。这一腿的输出一律不含凭据值，所以在这里就把
/// 文案截掉，不留"某条分支不小心把 URL 打出来"的余地。
fn transport_kind(error : @transport.TransportError) -> String {
  match error {
    @transport.TransportError::Network(_) => "Network"
    @transport.TransportError::Timeout => "Timeout"
    @transport.TransportError::InvalidRequest(_) => "InvalidRequest"
    @transport.TransportError::InvalidResponse(_) => "InvalidResponse"
  }
}

///|
/// 造这一条腿的全部件：凭据 → 配置（区域即主机，COS 没有独立 endpoint 这一位）→ SDK 客户端
/// → 端口。域名**不接受 `COS_DOMAIN`**，理由在 2026-10-18 当晚改过一次，这里记终局那版：
/// owner 把自定义域名在桶侧备案之后，80 端口确实路由进桶了（签 `Host: <自定义域>` 的 GET
/// 回 200 并取回正文，匿名私有回 403——读数在阶段 H 卡 §2.4 的 M4），**但 443 还不行**：
/// 证书是 `CN=*.cos.<region>.myqcloud.com`，SAN 盖不住那个名，握手直接报 `SEC_E_WRONG_PRINCIPAL`
/// （0x80090322）；而本 SDK 只拼 `https://`，所以切过去的第一发就红在 TLS 上。
/// 第二道坎是签名本身：原生默认把 `Host` 算进签名的头块（`moon-cos/auth/sign.mbt` 白名单
/// 第一项就是 host），实测签虚主机的那条预签名换到自定义域上取直接 403，只有 `sign_host=false`
/// 现签的串能跨域名用（M5）——而这一档还没端上 `cos` 包的公开面。
///  ⇒ 这一腿用 SDK 自己拼得出的虚主机那一条（与签名同源，"预签名 URL 以 domain 开头"那一档
///  才不会自己跟自己红）。env 里给了就响亮记一笔长度，别让它静默失效。
fn build(
  ak : String,
  sk : String,
  bucket : String,
  region : String,
) -> (Rig, String) raise @coserr.CosError {
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let credentials = @cosauth.Credentials::new(ak, sk)
  let config = @cosconfig.Config::new(region, credentials)
  let client = @sdk.Client::new(config, transport)
  let host = config.host(bucket)
  let derived = "https://" + host
  let given = @env.get_env_var("COS_DOMAIN").unwrap_or("")
  if !given.is_empty() {
    println(
      "COS_DOMAIN supplied (length " +
      given.length().to_string() +
      ") but not used: 443 still serves CN=*.cos.<region>.myqcloud.com which does not cover this name (TLS SEC_E_WRONG_PRINCIPAL), and this SDK only builds https urls; presigned strings are host-bound unless signed with sign_host=false",
    )
  }
  println("domain in use: " + derived)
  let domain = derived
  let platform = @cos.CosPlatform::new(@cos.CosPlatformConfig::{
    platform: "cos",
    bucket,
    domain: Some(domain),
    client,
  })
  (Rig::{ transport, config, client, platform, }, domain)
}

///|
/// 数一遍本轮前缀下还剩几个对象。**分页读**：COS 原生只有 V1 形态（`marker`／`NextMarker`，
/// 没有 `list-type=2`），所以续页符就叫 `next_marker`。不带 delimiter——嵌套目录里的也算，
/// 漏一层就是往真桶里漏东西。SDK 请求时一律带 `encoding-type=url` 并把键解回解码态，
/// 与写入侧同一坐标系，所以这里的比较与 `prefix` 直接对得上。
async fn count_residue(
  client : @sdk.Client,
  bucket : String,
  prefix : String,
) -> Int32 {
  let mut total = 0
  let mut marker = ""
  let mut done = false
  while !done {
    let page = client.list_objects(bucket, prefix~, marker~, max_keys=1000) catch {
      err => fail("residue list: " + cos_text(err))
    }
    total = total + page.objects.length()
    let next = page.next_marker.unwrap_or("")
    if !page.is_truncated || next.is_empty() {
      done = true
    } else {
      marker = next
    }
  }
  total
}

///|
async fn cos_read_bytes(body : &@transport.ResponseBody) -> Bytes {
  let merged : Array[Byte] = []
  let mut done = false
  while !done {
    let chunk = body.read(65536) catch {
      err => fail("read response body: " + transport_kind(err))
    }
    match chunk {
      None => done = true
      Some(data) => merged.append(data.to_array())
    }
  }
  body.close()
  Bytes::from_array(merged)
}

///|
/// 免凭据发一条 GET：这一发不带任何 Authorization，能取回才叫"预签名"，被拒才叫"签名/窗口
/// 真在被校验"。返回第一段是 `status-<码>`（应答真回来了）或 `raised:<种类>`（没连上），
/// 第二段是正文。正文一律读尽并 close——晾着一条没读尽的线会把后面那条请求整等 30 秒。
async fn cos_fetch(rig : Rig, url : String) -> (String, Bytes) {
  let response = rig.transport.send(@transport.Request::{
    http_method: @transport.Method::Get,
    url,
    headers: [],
    body: @transport.RequestBody::Empty,
  }) catch {
    err =>
      return ("raised:transport-" + transport_kind(err), Bytes::from_array([]))
  }
  let state = "status-" + response.status.to_string()
  let got = cos_read_bytes(response.body)
  (state, got)
}

///|
/// 把一次免凭据读数折成这条腿断得住的三档：`raised:<状态码/错误>`、`accepted:bytes_match`、
/// `accepted:bytes_differ`。"取回的是不是刚写进去那一份"才断得住；状态码本身在公开读与私有读
/// 两档载体上含义不同（同一折法见 oss／qiniu 两条腿）。
fn cos_fold(state : String, got : Bytes, want : Bytes) -> String {
  if state == "status-200" {
    if got.to_array() == want.to_array() {
      "accepted:bytes_match"
    } else {
      "accepted:bytes_differ"
    }
  } else {
    "raised:" + state
  }
}

///|
async fn cos_reading(rig : Rig, url : String, want : Bytes) -> String {
  let (state, got) = cos_fetch(rig, url)
  cos_fold(state, got, want)
}

///|
/// 改**签名本体**的一个字符。COS 的签名是 `q-signature=` 之后那 40 位小写十六进制，它排在
/// 查询串末尾。先跳过尾部的 `0`：那是七牛那条腿假绿过一次的教训（改到 base64 填充位上，
/// 服务端解码时把它吞了，签名照样过 ⇒ 实测 200），这里要改到最后一个真摘要字符上。
fn cos_flip_signature(url : String) -> String raise {
  let chars = url.to_array()
  let mark = "q-signature="
  let at = match url.find(mark) {
    None => fail("presigned url carries no " + mark)
    Some(at) => at + mark.length()
  }
  let mut pos = chars.length() - 1
  while pos > at && chars[pos] == '0' {
    pos = pos - 1
  }
  if pos <= at {
    fail(mark + " has nothing to flip")
  }
  let after = if chars[pos] == 'a' { 'b' } else { 'a' }
  url[0:pos].to_owned() +
  after.to_string() +
  url[pos + 1:chars.length()].to_owned()
}

///|
/// **过期那一档必须重签，不能改 URL**：改一个字符就同时把签名改坏了，那一发证的其实是
/// "篡改即拒"，同一轮里就把两件事证成了一件。这里照 `moon-cos/auth` 的能力钉一个早已过去的
/// 窗口现签一条（`1000000000000` 毫秒 = 2001-09-09，`window_at` 还照参照实现往前回拨 60 秒），
/// 签名本身完全成立、只有窗口失效。读数与 `moon-cos` 的 live 档同形。
fn cos_expired_url(
  rig : Rig,
  bucket : String,
  key : String,
) -> String raise @coserr.CosError {
  let host = rig.config.host(bucket)
  let base = rig.config.url_of(bucket, key)
  let stale = @cosauth.window_at(1000000000000L, 60L)
  let tail = @cosauth.presign_query(
    rig.config.credentials(),
    @cosauth.RequestToSign::{
      verb: "GET",
      path: @cosconfig.path_of(key),
      query: [],
      headers: [("host", host)],
    },
    stale,
  )
  base + "?" + tail
}

///|
/// 预签名 URL 的**真可用性**判据（契约正文只问形状，这一档问服务端）：四笔读数全部在
/// 2026-10-18 真桶上量过，所以每一条断言都有出处——
/// ① 免凭据那发回 200 且逐字节相等；② 改签名的一个字符回 403；③ 早过期的窗口回 403
/// （COS 把过期报成 403 `AccessDenied` + `Request has expired`，**没有**独立错误码，
/// 所以这一档只断状态码，绝不断文案里的码串）；④ 写完自己删干净。
/// "公开读／私有读"两档由**无令牌那一发**当场裁决：本桶的虚主机是私有的，所以可证的是拒绝
/// 那一支；结构照七牛那条腿，断的是端点实际走了哪一支。
async fn signed_get_proof(rig : Rig, bucket : String, prefix : String) -> Unit {
  let key = prefix + "/signed-get.txt"
  let body = @utf8.encode("presigned url, read back without any credentials")
  let _ = rig.client.put_object(bucket, key, body) catch {
    err => fail("signed-get seed upload: " + cos_text(err))
  }
  let info = @model.FileInfo::draft("cos", prefix, "signed-get.txt", "txt").stamped(@model.Stamp::{
      platform: None,
      path: Some(key),
      url: None,
      size: None,
      create_time: None,
      upload_id: None,
      upload_status: None,
      user_metadata: None,
    },
  )
  let url = rig.platform.presigned_url(info, @model.PresignMethod::Get, 120) catch {
    err => fail("presigned_url(Get) raised " + storage_text(err))
  }
  let (signed_state, signed_body) = cos_fetch(rig, url)
  println(
    "带签名那发=" +
    signed_state +
    " 字节=" +
    signed_body.length().to_string(),
  )
  assert_eq(signed_state, "status-200")
  assert_eq(signed_body.to_array(), body.to_array())

  let bare = match url.find("?") {
    None => url
    Some(at) => url[0:at].to_owned()
  }
  let unsigned = cos_reading(rig, bare, body)
  let tampered_url = cos_flip_signature(url) catch {
    err => fail("flip signature: " + err.to_string())
  }
  let sig_tampered = cos_reading(rig, tampered_url, body)
  let expired_url = cos_expired_url(rig, bucket, key) catch {
    err => fail("stale window re-sign: " + cos_text(err))
  }
  let (expired_state, expired_body) = cos_fetch(rig, expired_url)
  let expired_reading = cos_fold(expired_state, expired_body, body)
  // 只报"正文里有没有 expired 这个词"这个布尔读数，正文本身不打：COS 的错误 XML 可能回显
  // 请求资源串，而这一腿的输出必须不含任何凭据形态的东西。
  let expired_text = @utf8.decode_lossy(expired_body.exact_view())
  let says_expired = expired_text.find("expired") is Some(_)
  println("无令牌那发=" + unsigned)
  println("改签名一位=" + sig_tampered)
  println(
    "过期窗口重签=" +
    expired_reading +
    " 正文含 expired=" +
    says_expired.to_string(),
  )
  if unsigned.has_prefix("raised:") {
    // 私有读：签名与窗口真在被校验，"篡改必拒、过期必拒"在这一支才是可证的判据
    println("该域名私有读：签名与窗口在校验之内")
    assert_eq(sig_tampered, "raised:status-403")
    assert_eq(expired_reading, "raised:status-403")
  } else {
    // 公开读：签名是装饰。这一支只断"三档取回同一份字节"，并当场记下签名有效性
    // 不由这条腿证明——不许把它当成"预签名安全"的证据。
    println(
      "该域名公开读：签名不被校验，有效性不由这条腿证明",
    )
    assert_eq(unsigned, "accepted:bytes_match")
    assert_eq(sig_tampered, "accepted:bytes_match")
    assert_eq(expired_reading, "accepted:bytes_match")
  }
  let removed = rig.platform.delete(info) catch {
    err => fail("signed-get cleanup: " + storage_text(err))
  }
  assert_eq(removed, true)
}

///|
/// ACL 那一族在 COS 上**兑得了现**（`capabilities().acl == true`，与 OSS 那条腿在接入层就
/// `NotSupported` 不同）：`platform-cos` 真去调 `PUT /<key>?acl` + `x-cos-acl`。契约正文只断
/// "声称能做就不许拒"，所以这里把两件事各自问一遍，读数进台账：
/// ① 写 `public-read` 之后匿名 GET 真回 200（2026-10-18 现读）；
/// ② 对象级 `public-read-write` 那一档端点收不收——现读是 400 `InvalidArgument`，
///    落在"收下"或"拒下"两档之内就只记读数，落到两档之外才算红（同一纪律见 `moon-cos`
///    live 档的 M10；能力位报的是"这一族做得到"，具体某一档收不收由服务端定）。
async fn acl_proof(rig : Rig, bucket : String, prefix : String) -> Unit {
  let key = prefix + "/acl-proof.txt"
  let body = @utf8.encode("acl 这一族在 cos 上兑得了现")
  let _ = rig.client.put_object(bucket, key, body) catch {
    err => fail("acl seed upload: " + cos_text(err))
  }
  let info = @model.FileInfo::draft("cos", prefix, "acl-proof.txt", "txt").stamped(@model.Stamp::{
      platform: None,
      path: Some(key),
      url: None,
      size: None,
      create_time: None,
      upload_id: None,
      upload_status: None,
      user_metadata: None,
    },
  )
  let url = rig.config.url_of(bucket, key) catch {
    err => fail("acl url: " + cos_text(err))
  }
  let initial = rig.client.get_object_acl(bucket, key) catch {
    err => fail("initial acl: " + cos_text(err))
  }
  println(
    "对象初始 ACL：permissions=" +
    initial.permissions.join(",") +
    " public_read=" +
    initial.public_read.to_string(),
  )
  assert_true(!initial.public_read)

  let set_public = try {
    rig.platform.set_file_acl(info, @model.CannedAcl::PublicRead)
    "no-error"
  } catch {
    err => storage_text(err)
  }
  println("端口写 public-read 读数=" + set_public)
  assert_eq(set_public, "no-error")

  let read_back = rig.client.get_object_acl(bucket, key) catch {
    err => fail("acl read back: " + cos_text(err))
  }
  println(
    "写 public-read 之后：permissions=" +
    read_back.permissions.join(",") +
    " public_read=" +
    read_back.public_read.to_string(),
  )
  assert_true(read_back.public_read)
  let (anon_state, anon_body) = cos_fetch(rig, url)
  println(
    "public-read 之后匿名那发=" +
    anon_state +
    " 字节=" +
    anon_body.length().to_string(),
  )
  assert_eq(anon_state, "status-200")
  assert_eq(anon_body.to_array(), body.to_array())

  let back_private = try {
    rig.platform.set_file_acl(info, @model.CannedAcl::Private)
    "no-error"
  } catch {
    err => storage_text(err)
  }
  let (private_state, _) = cos_fetch(rig, url)
  println(
    "改回 private 读数=" + back_private + " 匿名那发=" + private_state,
  )
  assert_eq(back_private, "no-error")
  assert_eq(private_state, "status-403")

  let wide = try {
    rig.platform.set_file_acl(info, @model.CannedAcl::PublicReadWrite)
    "accepted"
  } catch {
    err => "refused:" + storage_text(err)
  }
  println("对象级 public-read-write 读数=" + wide)
  if wide == "accepted" {
    let grants = rig.client.get_object_acl(bucket, key) catch {
      err => fail("widened acl: " + cos_text(err))
    }
    println("收下之后 permissions=" + grants.permissions.join(","))
    assert_true(grants.permissions.length() >= 2)
  } else if !wide.has_prefix("refused:") {
    fail("public-read-write 的读数落在两档之外：" + wide)
  }

  rig.client.delete_object(bucket, key) catch {
    err => fail("acl cleanup: " + cos_text(err))
  }
}

///|
async fn run_cos(
  ak : String,
  sk : String,
  bucket : String,
  region : String,
) -> Unit {
  let stamp = @env.get_env_var("COS_RUN_TAG").unwrap_or("0")
  let prefix = "moonfs-cos-contract-" + stamp
  let built = build(ak, sk, bucket, region) catch {
    err => fail("cos leg setup: " + cos_text(err))
  }
  let rig = built.0
  let domain = built.1
  println("本轮前缀=" + prefix + " run tag=" + stamp)
  let root = @fs.tmpdir(prefix="moonfs-contract-cos") catch {
    err => fail("tmpdir: " + err.to_string())
  }
  let _ = @fs.mkdir(root, recursive=true, allow_exist=true) catch {
    err => fail("mkdir: " + err.to_string())
  }
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root,
  })
  let service = @storage.Service::new([rig.platform], recorder)
  let fixture = @contract.Fixture::{
    label: "cos",
    platform: "cos",
    base_path: prefix,
    domain,
    service,
    recorder,
    port: rig.platform,
    // 真字段名，不是照抄别家：COS 的预签名＝Authorization 七个字段整体搬进 query，
    // 算法名与时间窗分别是 `q-sign-algorithm=` 与 `q-sign-time=`（窗口 `start;end` 里的
    // `;` 百分号编成 `%3B`）。没有 `X-Amz-Expires` 那样的独立有效期参数。
    presigned_markers: ["q-sign-algorithm=", "q-sign-time="],
  }
  @contract.run_contract(fixture)
  signed_get_proof(rig, bucket, prefix)
  acl_proof(rig, bucket, prefix)
  let left = count_residue(rig.client, bucket, prefix)
  let parts = recorder.part_rows() catch {
    err => fail("part_rows: " + storage_text(err))
  }
  let rows = @fs.readdir(root) catch {
    err => fail("readdir: " + err.to_string())
  }
  let _ = @fs.rmdir(root, recursive=true) catch {
    err => println("cleanup " + root + " raised " + err.to_string())
  }
  println(
    "本轮前缀重列剩余=" +
    left.to_string() +
    " 本地记录行数=" +
    rows.length().to_string() +
    " 分片子记录行数=" +
    parts.length().to_string(),
  )
  // 契约把自己写的都删了，这里非 0 就是往真桶里漏了东西
  assert_eq(left, 0)
  // 主记录 + 分片子记录两份，且分片子记录要被门面清干净（完成与放弃各清一次）
  assert_eq(rows.length(), 2)
  assert_eq(parts.length(), 0)
}

///|
async test "cos platform walks the shared contract against the real bucket" {
  match live_env() {
    None => report_skip()
    Some(environment) =>
      run_cos(environment.0, environment.1, environment.2, environment.3)
  }
}
