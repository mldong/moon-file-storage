///|
// 第八条契约腿：阿里云 OSS 原生协议（公网真桶）跑同一份契约正文。
//
// 环境不齐就跳过，而跳过必须响亮（"SKIP IS NOT A PASS"）。这条腿与 S3 兼容层那条互不背书——
// 阶段 G 判过兼容层写入侧在授权层就被拒，这里走的是原生 V4 签名 + 虚主机寻址。

///|
struct Rig {
  transport : &@transport.Transport
  client : @sdk.Client
  platform : @oss.OssPlatform
}

///|
/// 必备四项：两把键、桶、区域。`OSS_DOMAIN` 可省——省下的时候用桶的虚主机地址
/// （`https://<桶>.oss-<区域>.aliyuncs.com`），那是 SDK 自己拼预签名 URL 用的同一个前缀，
/// 两处一致才不会让"URL 以 domain 开头"那一档自己跟自己红。
fn live_env() -> (String, String, String, String)? {
  let ak = @env.get_env_var("OSS_AK").unwrap_or("")
  let sk = @env.get_env_var("OSS_SK").unwrap_or("")
  let bucket = @env.get_env_var("OSS_BUCKET").unwrap_or("")
  let region = @env.get_env_var("OSS_REGION").unwrap_or("")
  if ak.is_empty() || sk.is_empty() || bucket.is_empty() || region.is_empty() {
    None
  } else {
    Some((ak, sk, bucket, region))
  }
}

///|
fn report_skip() -> Unit {
  let missing : Array[String] = []
  for name in ["OSS_AK", "OSS_SK", "OSS_BUCKET", "OSS_REGION"] {
    if @env.get_env_var(name).unwrap_or("").is_empty() {
      missing.push(name)
    }
  }
  println("SKIP contract/oss, environment not supplied")
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
fn oss_text(error : @osserr.OssError) -> String {
  error.text()
}

///|
fn transport_text(error : @transport.TransportError) -> String {
  match error {
    @transport.TransportError::Network(msg) => "Network: " + msg
    @transport.TransportError::Timeout => "Timeout"
    @transport.TransportError::InvalidRequest(msg) => "InvalidRequest: " + msg
    @transport.TransportError::InvalidResponse(msg) => "InvalidResponse: " + msg
  }
}

///|
fn endpoint_of(region : String) -> String {
  "https://oss-" + region + ".aliyuncs.com"
}

///|
fn build(
  ak : String,
  sk : String,
  bucket : String,
  region : String,
) -> (Rig, String) raise @osserr.OssError {
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let credentials = @ossauth.Credentials::new(ak, sk)
  let config = @ossconfig.Config::new(endpoint_of(region), region, credentials)
  let client = @sdk.Client::new(config, transport)
  // 域名的这一格**不接受 OSS_DOMAIN**：契约断"预签名 URL 以 domain 开头"，而 V4 的签名
  // 是照着虚主机那一条资源路径算的，换一条 CNAME 前缀就等于换一条没签过的地址。
  // 本机现读两条：`https://<桶>.oss-<区域>.aliyuncs.com` 那条预签名 GET 回 200（moon-oss
  // 的 live 档）；owner 配的 CDN 域名那条 TLS 证书不被校验通过（curl 报证书不可信，
  // 绕过后拿到的是 OSS 原生 `AccessDenied / bucket acl`），也从没按 CNAME 量过签名。
  //  ⇒ 这一腿用 SDK 自己拼得出来的那一条；接 CDN 那条路要先补"CNAME 上怎么算资源路径"的
  //  实测再开，不在这儿猜。env 里给了就响亮记一笔，别让它静默失效。
  let given = @env.get_env_var("OSS_DOMAIN").unwrap_or("")
  let derived = "https://" + bucket + "." + endpoint_of(region)[8:].to_owned()
  if !given.is_empty() {
    println(
      "OSS_DOMAIN supplied (length " +
      given.length().to_string() +
      ") but not used: a V4 url is signed for the virtual hosted host",
    )
  }
  println("domain in use: " + derived)
  let domain = derived
  let platform = @oss.OssPlatform::new(@oss.OssPlatformConfig::{
    platform: "oss",
    bucket,
    domain: Some(domain),
    client,
  })
  (Rig::{ transport, client, platform, }, domain)
}

///|
/// 数一遍本轮前缀下还剩几个对象（V2 续页符读完，不带 delimiter——嵌套的也算）。
async fn count_residue(
  client : @sdk.Client,
  bucket : String,
  prefix : String,
) -> Int32 {
  let mut total = 0
  let mut marker : String? = None
  let mut done = false
  while !done {
    let page = client.list_objects(
      bucket,
      prefix~,
      max_keys=1000,
      continuation_token=marker,
    ) catch {
      err => fail("residue list: " + oss_text(err))
    }
    total = total + page.objects.length()
    let next = page.next_continuation_token
    if !page.is_truncated || next.unwrap_or("").is_empty() {
      done = true
    } else {
      marker = next
    }
  }
  total
}

///|
async fn read_bytes(body : &@transport.ResponseBody) -> Bytes {
  let merged : Array[Byte] = []
  let mut done = false
  while !done {
    let chunk = body.read(65536) catch {
      err => fail("read response body: " + transport_text(err))
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
/// 发一条不带任何凭据的 GET，把读数折成三档：`raised:<错误>`、`accepted:bytes_match`、
/// `accepted:bytes_differ`。"取回的是不是刚写进去那一份"才断得住；状态码本身在
/// 公开读与私有读两档载体上含义不同。
async fn fetch_reading(rig : Rig, url : String, want : Bytes) -> String {
  let response = rig.transport.send(@transport.Request::{
    http_method: @transport.Method::Get,
    url,
    headers: [],
    body: @transport.RequestBody::Empty,
  }) catch {
    err => return "raised:" + transport_text(err)
  }
  if response.status < 200 || response.status >= 300 {
    let body = response.body
    let _ = read_bytes(body)
    body.close()
    return "raised:status-" + response.status.to_string()
  }
  let got = read_bytes(response.body)
  if got.to_array() == want.to_array() {
    "accepted:bytes_match"
  } else {
    "accepted:bytes_differ"
  }
}

///|
/// 改**签名本体**的最后一个字符。OSS V4 的签名是 64 位小写十六进制且固定在查询串末尾
/// （它是唯一"算完再加"的参数），没有 base64 填充那类会被服务端吞掉的尾巴——
/// Kodo 那条腿就因为改到了填充位上假绿过一次，这里不重犯。
fn flip_signature(url : String) -> String {
  let chars = url.to_array()
  let pos = chars.length() - 1
  let after = if chars[pos] == 'a' { 'b' } else { 'a' }
  url[0:pos].to_owned() +
  after.to_string() +
  url[pos + 1:chars.length()].to_owned()
}

///|
/// 改 `x-oss-expires=` 的第一位数字：签的是含这一项的整串，动一位就该对不上。
fn flip_deadline(url : String) -> String? {
  let chars = url.to_array()
  match url.find("x-oss-expires=") {
    None => None
    Some(at) => {
      let pos = at + 14
      if pos >= chars.length() {
        None
      } else {
        let after = if chars[pos] == '9' { '8' } else { '9' }
        Some(
          url[0:pos].to_owned() +
          after.to_string() +
          url[pos + 1:chars.length()].to_owned(),
        )
      }
    }
  }
}

///|
/// 预签名 URL 的**真可用性**判据：契约正文只问"形状对不对"，"一个不带凭据的客户端拿这条
/// URL 能不能真把字节取回来"是服务端的事，所以在这里问一次。
async fn signed_get_proof(rig : Rig, bucket : String, prefix : String) -> Unit {
  let key = prefix + "/signed-get.txt"
  let body = @utf8.encode("presigned url, read back without any credentials")
  let _ = rig.client.put_object(bucket, key, body) catch {
    err => fail("signed-get seed upload: " + oss_text(err))
  }
  let info = @model.FileInfo::draft("oss", prefix, "signed-get.txt", "txt").stamped(@model.Stamp::{
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
  let ok = fetch_reading(rig, url, body)
  println("带签名那发=" + ok)
  assert_eq(ok, "accepted:bytes_match")

  let bare = match url.find("?") {
    None => url
    Some(at) => url[0:at].to_owned()
  }
  let unsigned = fetch_reading(rig, bare, body)
  let sig_tampered = fetch_reading(rig, flip_signature(url), body)
  let deadline_tampered = fetch_reading(
    rig,
    flip_deadline(url).unwrap_or(bare),
    body,
  )
  println("无令牌那发=" + unsigned)
  println("改签名末位=" + sig_tampered)
  println("改有效期=" + deadline_tampered)
  if unsigned.has_prefix("raised:") {
    // 私有桶：签名真在被校验，"篡改必拒"在这一支才是可证的判据
    assert_true(sig_tampered.has_prefix("raised:"))
    assert_true(deadline_tampered.has_prefix("raised:"))
  } else {
    // 公开读：签名是装饰。这一支只断"三档取回同一份字节"，并当场记下签名有效性
    // 不由这条腿证明——不许把它当成"预签名安全"的证据。
    println(
      "该桶公开读：签名不被校验，有效性不由这条腿证明",
    )
    assert_eq(unsigned, "accepted:bytes_match")
    assert_eq(sig_tampered, "accepted:bytes_match")
    assert_eq(deadline_tampered, "accepted:bytes_match")
  }

  let removed = rig.platform.delete(info) catch {
    err => fail("signed-get cleanup: " + storage_text(err))
  }
  assert_eq(removed, true)
}

///|
async fn run_oss(
  ak : String,
  sk : String,
  bucket : String,
  region : String,
) -> Unit {
  let stamp = @env.get_env_var("OSS_RUN_TAG").unwrap_or("0")
  let prefix = "moonfs-oss-contract-" + stamp
  let built = build(ak, sk, bucket, region) catch {
    err => fail("oss leg setup: " + oss_text(err))
  }
  let rig = built.0
  let domain = built.1
  let root = @fs.tmpdir(prefix="moonfs-contract-oss") catch {
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
    label: "oss",
    platform: "oss",
    base_path: prefix,
    domain,
    service,
    recorder,
    port: rig.platform,
    presigned_markers: ["x-oss-credential=", "x-oss-expires="],
  }
  @contract.run_contract(fixture)
  signed_get_proof(rig, bucket, prefix)
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
  // 契约把自己写的都删了，这里非 0 就是往真桶里漏了东西
  assert_eq(left, 0)
  // 主记录 + 分片子记录两份，且分片子记录要被门面清干净（完成与放弃各清一次）
  assert_eq(rows.length(), 2)
  assert_eq(parts.length(), 0)
}

///|
async test "oss platform walks the shared contract against the real bucket" {
  match live_env() {
    None => report_skip()
    Some(environment) =>
      run_oss(environment.0, environment.1, environment.2, environment.3)
  }
}
