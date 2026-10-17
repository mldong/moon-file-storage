///|
// 第五条契约腿：原生 Kodo（公网真桶）跑同一份契约正文。
//
// 环境不齐就跳过，而跳过必须响亮（"SKIP IS NOT A PASS"）。这一条腿与 S3 兼容端点那条
// 互不背书——阶段 C 判死的是七牛的 S3 兼容形状，这里跑的是原生协议（上传令牌 + rs/rsf/iovip）。

///|
struct Rig {
  transport : @transport.AsyncHttpTransport
  client : @kodo.Client
  platform : @qiniu.QiniuPlatform
}

///|

///|
/// 必备三项是凭据与桶；`KODO_DOMAIN` 可省——省下的时候用**探测回来的交付主机**
/// （卡 §3-2：不把某台主机名写死，但也得有一条能真打开的域名才拼得出 URL）。
fn live_env() -> (String, String, String)? {
  let ak = @env.get_env_var("KODO_AK").unwrap_or("")
  let sk = @env.get_env_var("KODO_SK").unwrap_or("")
  let bucket = @env.get_env_var("KODO_BUCKET").unwrap_or("")
  if ak.is_empty() || sk.is_empty() || bucket.is_empty() {
    None
  } else {
    Some((ak, sk, bucket))
  }
}

///|
fn report_skip() -> Unit {
  let missing : Array[String] = []
  for name in ["KODO_AK", "KODO_SK", "KODO_BUCKET"] {
    if @env.get_env_var(name).unwrap_or("").is_empty() {
      missing.push(name)
    }
  }
  println("SKIP contract/qiniu, environment not supplied")
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
fn kodo_text(error : @kodoerr.KodoError) -> String {
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
/// 区域一律现探（卡 §3-2）：不把某台主机名写死，探回哪台就用哪台。
async fn build(
  ak : String,
  sk : String,
  bucket : String,
) -> (Rig, String) raise @kodoerr.KodoError {
  let transport = @transport.AsyncHttpTransport::new()
  let auth = @kodoauth.Auth::new(ak, sk)
  let probe = @kodo.query_region(transport, ak, bucket)
  let line = "region=" + probe.region.region_id + " via uc=" + probe.uc_host
  println(line)
  let given = @env.get_env_var("KODO_DOMAIN").unwrap_or("")
  let domain = if given.is_empty() {
    let derived = "https://" + probe.region.iovip_host
    println("domain from env: <none>, using probed io host " + derived)
    derived
  } else {
    println("domain from env: " + given)
    given
  }
  let cfg = @kodoconfig.Config::new(probe.region, use_https=true)
  let client = @kodo.Client::new(transport, auth, cfg, bucket)
  // `check_crc` 这一腿全程开着：契约写下的每一次上传都顺带过一遍块级/整份校验
  let platform = @qiniu.QiniuPlatform::new(
    @qiniu.QiniuPlatformConfig::new(
      "qiniu",
      client,
      transport,
      domain=Some(domain),
      check_crc=true,
    ),
  )
  (Rig::{ transport, client, platform, }, domain)
}

///|
/// 数一遍本轮前缀下还剩几个对象（分页读完，不带 delimiter——嵌套的也算）。
async fn count_residue(client : @kodo.Client, prefix : String) -> Int32 {
  let mut total = 0
  let mut marker : String? = None
  let mut done = false
  while !done {
    let page = client.list_files(prefix=Some(prefix), marker~, limit=Some(200)) catch {
      err => fail("residue list: " + kodo_text(err))
    }
    total = total + page.items.length()
    let next = page.marker
    if page.is_eof || next.unwrap_or("").is_empty() {
      done = true
    } else {
      marker = next
    }
  }
  total
}

///|
/// 私有下载 URL 的**真可用性**判据（KD1b 的 `Get` 那一档）：
/// 契约正文只能问"形状对不对"，"一个不带任何凭据的客户端拿这条 URL 能不能真把字节取回来"
/// 是服务端的事，所以在这里问一次——取回必须逐字节相等，把签名改一个字符必须被拒。
async fn signed_get_proof(rig : Rig, prefix : String) -> Unit {
  let key = prefix + "/signed-get.txt"
  let body = @utf8.encode(
    "private download url, read back without any credentials",
  )
  let _ = rig.client.put_bytes(key, body) catch {
    err => fail("signed-get seed upload: " + kodo_text(err))
  }
  let info = @model.FileInfo::draft("qiniu", prefix, "signed-get.txt", "txt").stamped(@model.Stamp::{
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
  // 免凭据：这条请求不带任何 Authorization 头，能取回才叫"预签名"
  let response = rig.transport.send(@transport.Request::{
    http_method: @transport.Method::Get,
    url,
    headers: [],
    body: @transport.RequestBody::Empty,
  }) catch {
    err => fail("signed GET raised " + transport_text(err))
  }
  let status = response.status
  let got = read_bytes(response.body)
  println(
    "signed GET status=" +
    status.to_string() +
    " bytes=" +
    got.length().to_string(),
  )
  assert_eq(status, 200)
  assert_eq(got.to_array(), body.to_array())

  // 签好的 URL 去掉 `?…` 就是无令牌那条：先问"这台载体看不看令牌"，再决定能断什么
  let bare = match url.find("?") {
    None => url
    Some(at) => url[0:at].to_owned()
  }
  let unsigned = fetch_reading(rig, bare, body)
  let sig_tampered = fetch_reading(rig, flip_signature(url), body)
  let deadline_url = flip_deadline(url).unwrap_or(bare)
  let deadline_tampered = fetch_reading(rig, deadline_url, body)
  println("无令牌那发=" + unsigned)
  println("改签名摘要位=" + sig_tampered)
  println("改过期时刻=" + deadline_tampered)
  if unsigned.has_prefix("raised:") {
    // 私有空间：令牌真在被校验，"篡改必拒"只有在这一支才是可证的判据
    assert_true(sig_tampered.has_prefix("raised:"))
    assert_true(deadline_tampered.has_prefix("raised:"))
  } else {
    // 公开读：令牌是装饰。这一支只断"三档取回的都是同一份字节"，
    // 并当场记下签名有效性不由这条腿证明（S3 那条腿才有"篡改即 403"的实测）
    println(
      "该域名公开读：私有下载签名不被校验，签名有效性不由这条腿证明",
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
async fn run_qiniu(ak : String, sk : String, bucket : String) -> Unit {
  let stamp = @env.get_env_var("KODO_RUN_TAG").unwrap_or("0")
  let prefix = "moonfs-kodo-contract-" + stamp
  let built = build(ak, sk, bucket) catch {
    err => fail("qiniu leg setup: " + kodo_text(err))
  }
  let rig = built.0
  let domain = built.1
  let root = @fs.tmpdir(prefix="moonfs-contract-qiniu") catch {
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
    label: "qiniu",
    platform: "qiniu",
    base_path: prefix,
    domain,
    service,
    recorder,
    port: rig.platform,
    presigned_markers: ["?e=", "&token="],
  }
  @contract.run_contract(fixture)
  signed_get_proof(rig, prefix)
  let left = count_residue(rig.client, prefix)
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
async test "qiniu platform walks the shared contract against the real bucket" {
  match live_env() {
    None => report_skip()
    Some(environment) => run_qiniu(environment.0, environment.1, environment.2)
  }
}

///|
/// 改**签名本体**的一个字符。上一版改的是 URL 最末尾——那是 base64 的填充 `=`，
/// 服务端解 base64 时把它吞了，签名照样过 ⇒ 那条负判据当时是假绿（实测 200）。
/// 所以这里先跳过填充位，改到最后一个真摘要字符上。
fn flip_signature(url : String) -> String {
  let chars = url.to_array()
  let mut pos = chars.length() - 1
  while pos > 0 && chars[pos] == '=' {
    pos = pos - 1
  }
  let after = if chars[pos] == 'a' { "b" } else { "a" }
  url[0:pos].to_owned() + after + url[pos + 1:chars.length()].to_owned()
}

///|
/// 改 `?e=<过期时刻>` 的第一位数字：签的是加完 `e=` 之后的整串，动一位就该对不上。
fn flip_deadline(url : String) -> String? {
  let chars = url.to_array()
  match url.find("?e=") {
    None => None
    Some(at) => {
      let pos = at + 3
      if pos >= chars.length() {
        None
      } else {
        let after = if chars[pos] == '9' { "8" } else { "9" }
        Some(
          url[0:pos].to_owned() + after + url[pos + 1:chars.length()].to_owned(),
        )
      }
    }
  }
}

///|
/// 发一条 GET，把读数折成两档：`raised:<错误>`，或 `accepted:bytes_match` / `bytes_differ`。
/// "取回的是不是刚写进去那一份"才是这条腿断得住的东西；状态码本身在两档载体上含义不同。
async fn fetch_reading(rig : Rig, url : String, want : Bytes) -> String {
  let ok = rig.client.open_url(url) catch {
    err => return "raised:" + kodo_text(err)
  }
  let got = read_bytes(ok.body)
  if got.to_array() == want.to_array() {
    "accepted:bytes_match"
  } else {
    "accepted:bytes_differ"
  }
}
