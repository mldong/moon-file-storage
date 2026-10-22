///|
// 第十条契约腿：华为云 OBS 原生协议（公网真桶）跑同一份契约正文。
//
// 环境不齐就跳过，而跳过必须响亮（"SKIP IS NOT A PASS"），并且要当场点名本轮没证到什么。
// 这条腿与 `moon-s3` 仓里那条 OBS 兼容面腿互不背书：这里走的是原生 V4 签名（`AWS4-HMAC-SHA256`
// 的构造、`X-Amz-*` 的预签名参数）+ 虚主机寻址。签名件与协议件在 `mldong/moon-obs`，端口接入在
// `platform-obs`，两处的读数在这一条腿里一起过真端点。
//
// 清扫纪律（2026-10-19 任务 #73 起，与 `moon-obs/obs/live_test.mbt` 同一口径）：
// ① 开头无条件扫一次本轮前缀（`moonfs-obs-contract-<OBS_RUN_TAG>`，本轮独占），
//    把上一轮这一腿中途红掉留下的残留删掉；② 阳性对照证明这一扫真会删东西；
// ③ 五个证明段整段包在 try/catch 里折成读数，**结尾清扫排在断言之前**，中途红也把桶扫干净
//    再把红原样交出去；④ 只重发"传输层没拿到应答"那一臂，协议层读数一次都不重试。
//    为什么不用 `defer`：阶段 B 卡 §7-5 记着"`defer` 能不能放 async 调用仍未验"。
//
// ⑤ **重试层数**（10-21 收口，别把它读成"两层保险"）：走 SDK 公开面的每一发只有 **SDK 那一层**
//    （`moon-obs/obs/request.mbt`：响应头未到达 ⇒ 幂等档重发一次；POST 与流式体不重发；
//    拿到任何状态码都不重发）。腿层原先叠在 SDK 之上的两处壳（`obs_delete_retry` 与
//    `obs_clean` 的三趟循环）**已撤**；只剩 `obs_fetch` 一层，而它只包**裸 `transport.send`
//    的免凭据 GET**（预签名／匿名那几发压根没过 SDK 请求层，SDK 够不着），并已降到一次。
//    ⇒ 整条链每一发恰好一层，那一层至多重发一次；数不出第二层才算收了口。

///|
struct Rig {
  transport : &@transport.Transport
  config : @obsconfig.Config
  client : @sdk.Client
  platform : @obs.ObsPlatform
}

///|
/// 必备四项：两把键、桶、区域。`OBS_DOMAIN` 可省，但省与不省都不生效——原因写在 `build` 里
/// 那一条响亮忽略；`OBS_RUN_TAG` 只决定本轮前缀（hub 的门禁脚本导出的是这六个变量名）。
fn live_env() -> (String, String, String, String)? {
  let ak = @env.get_env_var("OBS_AK").unwrap_or("")
  let sk = @env.get_env_var("OBS_SK").unwrap_or("")
  let bucket = @env.get_env_var("OBS_BUCKET").unwrap_or("")
  let region = @env.get_env_var("OBS_REGION").unwrap_or("")
  if ak.is_empty() || sk.is_empty() || bucket.is_empty() || region.is_empty() {
    None
  } else {
    Some((ak, sk, bucket, region))
  }
}

///|
/// 跳过要说出"本轮没证到哪几格"，不然读的人只能看到一条空 SKIP，把"没跑"读成"跑了没问题"。
/// 这一档点名的是 OBS 自己那几格（其余各家共用的正文那一档由 `run_contract` 兜）。
fn report_skip() -> Unit {
  let missing : Array[String] = []
  for name in ["OBS_AK", "OBS_SK", "OBS_BUCKET", "OBS_REGION"] {
    if @env.get_env_var(name).unwrap_or("").is_empty() {
      missing.push(name)
    }
  }
  println("SKIP contract/obs, environment not supplied")
  println("missing: " + missing.join(", "))
  println("本轮没有对 OBS 原生面证到的格子：")
  println(
    "  1) 同一份契约正文的 13 个用例族（对象族／手动分片五步／预签名形状／复制移动／列举／ACL 声称／元数据／分片记账／门面行为）",
  )
  println(
    "  2) 预签名 URL 免凭据真取回，以及改签名、过期窗口两发必拒",
  )
  println(
    "  3) canned ACL 生效且可逆：public-read 之后匿名 GET 200、改回 private 又 403",
  )
  println(
    "  4) 分片下限 100KiB 这一格：100KiB 非末片过、99KiB 非末片回 400 EntityTooSmall",
  )
  println(
    "  5) 只有虚主机寻址：path 风格那一格要在发出请求之前就拒",
  )
  println(
    "给它四项 env 就能跑：OBS_AK / OBS_SK / OBS_BUCKET / OBS_REGION（本轮前缀用 OBS_RUN_TAG）",
  )
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
fn obs_text(error : @obserr.ObsError) -> String {
  error.text()
}

///|
/// 传输层的错误**只报种类、不报文案**：OBS 的预签名 URL 查询串里 `X-Amz-Credential` 的头一段
/// 就是 Access Key Id 原值，而 http 那层的错误串可能把整条 URL 带出来。这一腿的输出一律不含
/// 凭据值，所以在这里就把文案截掉，不留"某条分支不小心把 URL 打出来"的余地。
fn transport_kind(error : @transport.TransportError) -> String {
  match error {
    @transport.TransportError::Network(_) => "Network"
    @transport.TransportError::Timeout => "Timeout"
    @transport.TransportError::InvalidRequest(_) => "InvalidRequest"
    @transport.TransportError::InvalidResponse(_) => "InvalidResponse"
  }
}

///|
/// 造这一条腿的全部件：凭据 → 配置 → SDK 客户端 → 端口。域名有**两档**，各由一条 test 量：
///
/// - 默认档（`custom_domain=false`）：`Config::from_region` 派生原生端点基址，域名取
///   `<scheme>://<桶名>.<基址>` 那条虚主机，与签名里被算进头块的 `Host` 同源。契约正文走这一档
///   （"预签名 URL 以 domain 开头"那一档才不会自己跟自己红）。
/// - 寻址档（`custom_domain=true`）：用 `OBS_DOMAIN` 那个**已在桶侧绑定本桶**的自定义域名，
///   经 `Config::with_domain` 造配置，host 逐字用域名、scheme 是 **http**。为什么不是 https：
///   域名解析到华为云 IP 但证书名盖不住它，握手直接失败（同一域名在区域端点侧量到过
///   `目标主要名称不正确`）——那是桶侧没绑证书，不是签名问题。为什么不能再拼桶名：
///   `<桶名>.<域名>` 连 DNS 都不解析（真桶实测）。`OBS_DOMAIN` 没给时这一档响亮 SKIP。
fn build(
  ak : String,
  sk : String,
  bucket : String,
  region : String,
  custom_domain~ : Bool = false,
) -> (Rig, String) raise @obserr.ObsError {
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let credentials = @obsauth.Credentials::new(ak, sk)
  let given = @env.get_env_var("OBS_DOMAIN").unwrap_or("")
  let config = if custom_domain {
    if given.is_empty() {
      raise @obserr.ObsError::BadParam(
        "OBS_DOMAIN is absent: the addressing arm has no domain to bind",
      )
    }
    @obsconfig.Config::with_domain("http://" + given, region, credentials)
  } else {
    @obsconfig.Config::from_region(region, credentials)
  }
  let client = @sdk.Client::new(config, transport)
  let derived = config.scheme_of() + "://" + config.host_of(bucket)
  if !custom_domain && !given.is_empty() {
    println(
      "OBS_DOMAIN supplied (length " +
      given.length().to_string() +
      ") but not used by this arm: 默认档要与签名的 Host 同源，虚主机那条才是契约正文的地基；自定义域名那一档由寻址档那条 test 专门量（http 通、https 等桶侧证书）",
    )
  }
  println("domain in use: " + derived)
  let domain = derived
  let platform = @obs.ObsPlatform::new(@obs.ObsPlatformConfig::{
    platform: "obs",
    bucket,
    domain: Some(domain),
    client,
  })
  (Rig::{ transport, config, client, platform, }, domain)
}

///|
/// 读数截断（回体与键表只用来认形状，不整份进日志）。
fn obs_trim(text : String, limit : Int32) -> String {
  if text.length() <= limit {
    text
  } else {
    text[0:limit].to_owned() + "…"
  }
}

///|
/// **只有传输层死亡**（没拿到应答、30 秒界、连接半路断）才算这一臂。
/// 协议层的红——状态码或服务端码不对——一律落在它之外：本线纪律是"传输层死亡可以重发，
/// 协议层读数一次都不重试"，判据不许因为链路抖过就放宽。
fn obs_transport_death(err : @obserr.ObsError) -> Bool {
  match err {
    @obserr.ObsError::Network(_) => true
    _ => false
  }
}

///|
/// 复列一个前缀下的**全部**键。OBS 原生这条腿的承诺面是 V1
/// （`marker`／`NextMarker`，SDK 没有把 `list-type=2` 端上承诺面），所以续页符叫 `next_marker`。
/// 不带 delimiter——嵌套目录里的也算，漏一层就是往真桶里漏东西。
/// V1 不带 delimiter 时**不回 `<NextMarker>`**（10-19 实测形状），所以续页符退回"本页最后一个键"：
/// 只认 NextMarker 的话，第 1001 个之后的残留会静悄悄地扫不到，守卫就成了空转。
async fn obs_keys_under(
  client : @sdk.Client,
  bucket : String,
  prefix : String,
) -> Array[String] raise @obserr.ObsError {
  let keys : Array[String] = []
  let mut marker = ""
  let mut page = 0
  let mut done = false
  while !done && page < 20 {
    page = page + 1
    let listing = client.list_objects(bucket, prefix~, marker~, max_keys=1000)
    let mut last = ""
    for item in listing.objects {
      keys.push(item.key)
      last = item.key
    }
    let next = listing.next_marker.unwrap_or("")
    let cursor = if !next.is_empty() { next } else { last }
    done = !listing.is_truncated || cursor.is_empty()
    marker = cursor
  }
  keys
}

///|
/// 只读复列的读数串：`count=<n> keys=<前 200 字符>`。扫不扫得动先看得见。
async fn obs_listing_note(
  client : @sdk.Client,
  bucket : String,
  prefix : String,
) -> String {
  let keys = obs_keys_under(client, bucket, prefix) catch {
    err => return "error:" + obs_text(err)
  }
  "count=" +
  keys.length().to_string() +
  " keys=" +
  obs_trim(keys.join(","), 200)
}

///|
/// `stat` 的读数串：成功报 `ok:<字节数>`，失败报服务端码与文案（404 那一臂判前缀用）。
async fn obs_stat_note(
  client : @sdk.Client,
  bucket : String,
  key : String,
) -> String {
  let stat = client.stat_object(bucket, key) catch {
    err => return obs_text(err)
  }
  "ok:" + stat.size.to_string()
}

///|
/// 删一个键的读数（把错误折成串而不是抛出去——清扫那一串是 typed raise，抛不出来）。
/// **这一档不在腿层重发**：`delete_object` 走的是 SDK 请求层，而"响应头未到达⇒幂等档重发一次"
/// 已收进 `moon-obs/obs/request.mbt`。上一版这里的三趟 `while` 壳与 SDK 叠成两层重试，10-21 撤掉。
async fn obs_delete_note(
  client : @sdk.Client,
  bucket : String,
  key : String,
) -> String noraise {
  client.delete_object(bucket, key) catch {
    err => return obs_text(err)
  }
  "ok"
}

///|
/// 一趟清扫：列尽前缀下的键 → 逐个删 → 复列剩余。
/// `raise` 只在"列不出来"时发生（协议层的拒由调用侧分档，不在这儿吞掉）。
async fn obs_clean_once(
  client : @sdk.Client,
  bucket : String,
  prefix : String,
) -> Int64 raise @obserr.ObsError {
  let keys = obs_keys_under(client, bucket, prefix)
  println(
    "清扫 " +
    obs_trim(prefix, 120) +
    " 找到 " +
    keys.length().to_string() +
    " 个: " +
    obs_trim(keys.join(","), 200),
  )
  for key in keys {
    println(
      "  删 " +
      obs_trim(key, 120) +
      " -> " +
      obs_delete_note(client, bucket, key),
    )
  }
  obs_keys_under(client, bucket, prefix).length().to_int64()
}

///|
/// 清扫一个前缀并返回剩余个数：`>=0` 是复列到的实数，`-1` 是**这一趟**在传输层没拿到应答
/// （SDK 那一层已经重发过一次，还是没拿到就是真没拿到），`-2` 是被服务端拒了
/// （协议层红，按纪律**不重试**）。两个负数都不许被读成"扫干净了"。
/// 10-21 起这一条**只跑一趟**：上一版的三趟循环与 SDK 那层叠成两层重试，层数数不清。
async fn obs_clean(
  client : @sdk.Client,
  bucket : String,
  prefix : String,
) -> Int64 {
  obs_clean_once(client, bucket, prefix) catch {
    err =>
      if obs_transport_death(err) {
        println(
          "清扫这一趟在传输层没拿到应答（SDK 层已按幂等档重发过一次）: " +
          obs_text(err),
        )
        -1L
      } else {
        println(
          "清扫被服务端拒了，按本线纪律**不重试**: " +
          obs_text(err),
        )
        -2L
      }
  }
}

///|
/// 开头清扫：无条件先把本轮独占前缀扫一遍（上一轮这一腿中途红掉留下的残留就在这一趟被删掉），
/// 并把"剩余必须为 0"当成这一腿的入场条件——扫不干净就别往下写。
async fn obs_open_clean(
  client : @sdk.Client,
  bucket : String,
  prefix : String,
  label : String,
) -> Unit {
  let opening = obs_clean(client, bucket, prefix)
  println(
    label +
    " 清扫 " +
    obs_trim(prefix, 120) +
    " -> 剩余" +
    opening.to_string() +
    " 个",
  )
  if opening < 0 {
    fail(
      label +
      " 清扫没跑成（读数 " +
      opening.to_string() +
      "）：残留到底在不在没人证明过",
    )
  }
  assert_eq(opening, 0L)
}

///|
/// 阳性对照：证明"开头清扫"不是一行空转。先放一个对象**故意不删**（那正是"上一轮中途红掉
/// 留下的残留"的形状），再让每一轮开头跑的那一条 `obs_open_clean` 跑它，然后两路断它确实没了：
/// 复列查不到 + `HEAD` 给 404。没有这一条，开头清扫本身就是一档可能永远绿着的假守卫。
async fn obs_orphan_proof(
  client : @sdk.Client,
  bucket : String,
  prefix : String,
) -> Unit {
  let orphan = prefix + "/orphan-left-behind.txt"
  let _ = client.put_object(
    bucket,
    orphan,
    @utf8.encode("故意留下的残留"),
  ) catch {
    err => fail("放残留: " + obs_text(err))
  }
  let planted = obs_listing_note(client, bucket, prefix)
  println("阳性对照 故意留下残留之后复列: " + planted)
  assert_true(planted.has_prefix("count=1"))
  let seen = obs_stat_note(client, bucket, orphan)
  println("阳性对照 残留还在时 stat=" + seen)
  assert_true(seen.has_prefix("ok:"))
  // 下一趟开头清扫跑它：调的就是每一轮开头那一条，不另开一条路径
  obs_open_clean(client, bucket, prefix, "阳性对照·下一趟")
  let after = obs_listing_note(client, bucket, prefix)
  println("阳性对照 开头清扫之后复列: " + after)
  assert_true(after.has_prefix("count=0"))
  let gone = obs_stat_note(client, bucket, orphan)
  println("阳性对照 开头清扫之后再查 stat=" + gone)
  assert_true(gone.has_prefix("404"))
}

///|
async fn obs_read_bytes(body : &@transport.ResponseBody) -> Bytes {
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
/// 免凭据发一条 GET 的**一趟**：这一发不带任何 Authorization，能取回才叫"预签名"，被拒才叫
/// "签名/窗口真在被校验"。返回第一段是 `status-<码>`（应答真回来了）或 `raised:<种类>`（没连上），
/// 第二段是正文。正文一律读尽并 close——晾着一条没读尽的线会把后面那条请求整等 30 秒。
async fn obs_fetch_once(rig : Rig, url : String) -> (String, Bytes) {
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
  let got = obs_read_bytes(response.body)
  (state, got)
}

///|
/// 免凭据那一发的重发策略（**这一腿唯一合法的一层**，理由见 `obs_fetch_once` 上方那段）：
/// **至多重发一次**，且只重发"响应头未到达"（`raised:transport-*`，即根本没拿到应答）。
/// 政策与 SDK 那一层同形，只是它管不到这几发——这几发是裸 `transport.send`、不带签名，
/// 压根没走 `moon-obs` 的请求层。状态码与文案一律原样交出去，一次都不重试：
/// 公网抖一下不该把 403 读成 timeout，而反复拿不到应答时这一档仍然红（判据一个字没动）。
/// 上一版这里是"最多三趟"，10-21 降到一次，与 SDK 那档对齐，免得读数被多层兜住。
async fn obs_fetch(rig : Rig, url : String) -> (String, Bytes) {
  let outcome = obs_fetch_once(rig, url)
  if !outcome.0.has_prefix("raised:transport-") {
    outcome
  } else {
    println(
      "免凭据那发在传输层没拿到应答，重发一次（腿层唯一一层，SDK 够不着这一发）: " +
      outcome.0,
    )
    @async.sleep(2000)
    obs_fetch_once(rig, url)
  }
}

///|
/// 把一次免凭据读数折成这条腿断得住的三档：`raised:<状态码/错误>`、`accepted:bytes_match`、
/// `accepted:bytes_differ`。"取回的是不是刚写进去那一份"才断得住；状态码本身在公开读与私有读
/// 两档载体上含义不同（同一折法见 oss／cos 两条腿）。
fn obs_fold(state : String, got : Bytes, want : Bytes) -> String {
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
async fn obs_reading(rig : Rig, url : String, want : Bytes) -> String {
  let (state, got) = obs_fetch(rig, url)
  obs_fold(state, got, want)
}

///|
/// 改**签名本体**的一个字符。OBS 的 V4 签名是 `X-Amz-Signature=` 之后那 64 位小写十六进制，
/// 它排在查询串末尾（`presign_v4` 是"算完再加"的那一个）。先跳过尾部的 `0`：那是七牛那条腿
/// 假绿过一次的教训（改到 base64 填充位上，服务端解码时把它吞了，签名照样过 ⇒ 实测 200），
/// 这里要改到最后一个真摘要字符上。
fn obs_flip_signature(url : String) -> String raise {
  let chars = url.to_array()
  let mark = "X-Amz-Signature="
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
/// "篡改即拒"，同一轮里就把两件事证成了一件。这里照 `moon-obs/auth` 的能力钉一个早已过去的
/// 时刻现签一条（`1000000000000` 毫秒 = 2001-09-09），签名本身完全成立、只有窗口失效。
fn obs_expired_url(
  rig : Rig,
  bucket : String,
  key : String,
) -> String raise @obserr.ObsError {
  let host = rig.config.host_of(bucket)
  let base = rig.config.url_of(bucket, key~)
  let stale = @obsauth.iso8601_basic(1000000000000L)
  let signed = rig.config
    .credentials()
    .presign_at(rig.config.region_of(), stale, 60L, @obsauth.RequestToSign::{
      verb: "GET",
      canonical_uri: rig.config.canonical_uri_of(bucket, key~),
      query: [],
      headers: [("host", host)],
      payload_hash: @obsauth.unsigned_payload,
    })
  base + "?" + signed.query
}

///|
/// 预签名 URL 的**真可用性**判据（契约正文只问形状，这一档问服务端）。三条读数都有出处
/// （`moon-obs` 的 live 档在真桶量过：免凭据 GET 200、改签名 403 `SignatureDoesNotMatch`、
/// 裸读 403 `AccessDenied`）。过期窗口那一格 `moon-obs` 没量过，由本条腿现量并写死：
/// **回 403**，但回体里**没有** `expired` 那个词（COS 那家回的是 `AccessDenied` +
/// `Request has expired`，两家同一档不同文案）——所以这一档只断状态码，不断文案。
/// ① 免凭据那发回 200 且逐字节相等；② 改签名一个字符回 403；③ 早过期的窗口回 403；
/// ④ 写完自己删干净。
/// "公开读／私有读"两档由**无令牌那一发**当场裁决：本桶的虚主机是私有的（原生面**允许**匿名
/// 请求，那一发 403 是 ACL 的答案而非兼容面那种 `400 NotSupportAnonymous`），所以可证的是拒绝
/// 那一支；断的是端点实际走了哪一支。
async fn signed_get_proof(rig : Rig, bucket : String, prefix : String) -> Unit {
  let key = prefix + "/signed-get.txt"
  let body = @utf8.encode("presigned url, read back without any credentials")
  let _ = rig.client.put_object(bucket, key, body) catch {
    err => fail("signed-get seed upload: " + obs_text(err))
  }
  let info = @model.FileInfo::draft("obs", prefix, "signed-get.txt", "txt").stamped(@model.Stamp::{
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
  let (signed_state, signed_body) = obs_fetch(rig, url)
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
  let unsigned = obs_reading(rig, bare, body)
  let tampered_url = obs_flip_signature(url) catch {
    err => fail("flip signature: " + err.to_string())
  }
  let sig_tampered = obs_reading(rig, tampered_url, body)
  let expired_url = obs_expired_url(rig, bucket, key) catch {
    err => fail("stale window re-sign: " + obs_text(err))
  }
  let (expired_state, expired_body) = obs_fetch(rig, expired_url)
  let expired_reading = obs_fold(expired_state, expired_body, body)
  // 只报"正文里有没有 expired 这个词"这个布尔读数，正文本身不打：OBS 的错误 XML 会回显请求
  // 资源串，而这一腿的输出必须不含任何凭据形态的东西。
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
/// OBS 回体里那条"所有人可读"的授权：`Grantee` 靠 `xsi:type` 分档，组授权给 `URI`，
/// 全局读那一组的 URI 线值真桶读回的是 `http://acs.amazonaws.com/groups/global/AllUsers`
/// （命名空间是 OBS 自己的 `obs.myhwclouds.com`，grant 里组的 URI 却是 acs 那一条）。
fn all_users_group() -> String {
  "http://acs.amazonaws.com/groups/global/AllUsers"
}

///|
fn obs_all_users_read(acl : @sdk.ObjectAcl) -> Bool {
  let mut found = false
  for grant in acl.grants {
    let uri = grant.grantee_uri.unwrap_or("")
    if uri == all_users_group() && grant.permission == "READ" {
      found = true
    }
  }
  found
}

///|
fn obs_permission_list(acl : @sdk.ObjectAcl) -> String {
  let names : Array[String] = []
  for grant in acl.grants {
    let _ = names.push(grant.permission)
  }
  names.join(",")
}

///|
/// ACL 那一族在 OBS 上**兑得了现**（`capabilities().acl == true`，与 `platform-oss` 那条腿在
/// 接入层就 `NotSupported` 不同；与 `platform-cos` 同号是两家各自实测的结果，不是照抄）：
/// `platform-obs` 真去调 `PUT /<key>?acl` + `x-amz-acl`（原生端点的 V4 头前缀就是 `x-amz-`，
/// 这一格的选择在 SDK 一处）。契约正文只断"声称能做就不许拒"，所以这里把四件事各自问一遍，
/// 读数打进输出（出处：2026-10-19 真桶）：
/// ① 写 `public-read` 之后匿名 GET 真回 200 且逐字节相等（原生面允许匿名请求，所以这一发在
///    OBS 上是真能打开的公开 URL）；② 改回 `private` 之后同一发回 403——**可逆**；
/// ③ 授权列表里那一组 AllUsers/READ 随两档出现与消失；
/// ④ 对象级 `public-read-write` 这一档 OBS **收**（与 COS 的 400 `InvalidArgument` 相反），
///    读到两档之外才算红。
async fn acl_proof(rig : Rig, bucket : String, prefix : String) -> Unit {
  let key = prefix + "/acl-proof.txt"
  let body = @utf8.encode("acl 这一族在 obs 上兑得了现")
  let _ = rig.client.put_object(bucket, key, body) catch {
    err => fail("acl seed upload: " + obs_text(err))
  }
  let info = @model.FileInfo::draft("obs", prefix, "acl-proof.txt", "txt").stamped(@model.Stamp::{
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
  let url = rig.config.url_of(bucket, key~)
  let initial = rig.client.get_object_acl(bucket, key) catch {
    err => fail("initial acl: " + obs_text(err))
  }
  println(
    "对象初始 ACL：条数=" +
    initial.grants.length().to_string() +
    " 权限=" +
    obs_permission_list(initial) +
    " 命名空间长度=" +
    initial.default_ns.unwrap_or("").length().to_string(),
  )
  assert_true(!obs_all_users_read(initial))

  let set_public = try {
    rig.platform.set_file_acl(info, @model.CannedAcl::PublicRead)
    "no-error"
  } catch {
    err => storage_text(err)
  }
  println("端口写 public-read 读数=" + set_public)
  assert_eq(set_public, "no-error")

  let read_back = rig.client.get_object_acl(bucket, key) catch {
    err => fail("acl read back: " + obs_text(err))
  }
  println(
    "写 public-read 之后：条数=" +
    read_back.grants.length().to_string() +
    " 权限=" +
    obs_permission_list(read_back) +
    " AllUsers/READ=" +
    obs_all_users_read(read_back).to_string(),
  )
  assert_true(obs_all_users_read(read_back))
  let (anon_state, anon_body) = obs_fetch(rig, url)
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
  let after_private = rig.client.get_object_acl(bucket, key) catch {
    err => fail("acl back to private: " + obs_text(err))
  }
  let (private_state, _) = obs_fetch(rig, url)
  println(
    "改回 private 读数=" +
    back_private +
    " AllUsers/READ=" +
    obs_all_users_read(after_private).to_string() +
    " 匿名那发=" +
    private_state,
  )
  assert_eq(back_private, "no-error")
  assert_true(!obs_all_users_read(after_private))
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
      err => fail("widened acl: " + obs_text(err))
    }
    println("收下之后条数=" + grants.grants.length().to_string())
    // 实测三档 canned 名 OBS 都收，所以这一格断"收下"而不是"拒下"；读回里全局读那一组
    // 必须还在（public-read-write ⊇ public-read），条数至少两条（owner + 组授权）。
    assert_true(obs_all_users_read(grants))
    assert_true(grants.grants.length() >= 2)
  } else if !wide.has_prefix("refused:") {
    fail("public-read-write 的读数落在两档之外：" + wide)
  }

  rig.client.delete_object(bucket, key) catch {
    err => fail("acl cleanup: " + obs_text(err))
  }
}

///|
/// 凑一段纯 ASCII 的正文（分片下限那一档要的 99KiB／100KiB 两份）。挑纯 ASCII 是为了让
/// "尺寸"这一格不掺进编码宽度这另一件事。
fn obs_fill(size : Int32) -> Bytes {
  @utf8.encode("a").repeat(size)
}

///|
/// 分片下限这一格在 OBS 上是**实测出来的数字**：非末片 100KiB 过、99KiB 回 400
/// `EntityTooSmall`（2026-10-19 真桶，原生面与兼容面同值）。契约正文自己那份用的是 5MiB
/// 安全档，量不到这一格的边界，所以在这里各问一发：
/// 拒的那一发走端口（`complete_multipart` 的错误分档要真把服务端的 400 透出成 `Platform`，
/// 不许折叠成"成功"或"不存在"），收的那一发也要真合得出对象并读回尺寸。
/// 两档都用 `~` 前缀自己的键，收尾各删各的；会话一律 abort（正档完成后会话已不存在，
/// abort 那一发的读数只打不发判据）。
async fn part_floor_proof(rig : Rig, prefix : String) -> Unit {
  let refused_name = "floor-99kib.txt"
  let draft = @model.FileInfo::draft("obs", prefix, refused_name, "txt")
  let started = rig.platform.init_multipart(draft) catch {
    err => fail("floor init_multipart: " + storage_text(err))
  }
  let first = rig.platform.upload_part(
    started,
    1,
    @model.UploadSource::Bytes(obs_fill(99 * 1024)),
  ) catch {
    err => fail("floor upload_part(1): " + storage_text(err))
  }
  let second = rig.platform.upload_part(
    started,
    2,
    @model.UploadSource::Bytes(@utf8.encode("tail")),
  ) catch {
    err => fail("floor upload_part(2): " + storage_text(err))
  }
  let parts : Array[@model.FilePartInfo] = [first, second]
  let refused = try {
    let _ = rig.platform.complete_multipart(started, parts)
    "no-error"
  } catch {
    err => storage_text(err)
  }
  println("99KiB 非末片的完成读数=" + refused)
  assert_true(refused.has_prefix("Platform: obs 400 EntityTooSmall"))
  let aborted = try {
    rig.platform.abort_multipart(started)
    "no-error"
  } catch {
    err => storage_text(err)
  }
  println("拒下之后 abort 读数=" + aborted)
  assert_eq(aborted, "no-error")

  let ok_name = "floor-100kib.txt"
  let ok_draft = @model.FileInfo::draft("obs", prefix, ok_name, "txt")
  let ok_started = rig.platform.init_multipart(ok_draft) catch {
    err => fail("floor ok init_multipart: " + storage_text(err))
  }
  let ok_first = rig.platform.upload_part(
    ok_started,
    1,
    @model.UploadSource::Bytes(obs_fill(100 * 1024)),
  ) catch {
    err => fail("floor ok upload_part(1): " + storage_text(err))
  }
  let tail = @utf8.encode("tail")
  let ok_second = rig.platform.upload_part(
    ok_started,
    2,
    @model.UploadSource::Bytes(tail),
  ) catch {
    err => fail("floor ok upload_part(2): " + storage_text(err))
  }
  let ok_parts : Array[@model.FilePartInfo] = [ok_first, ok_second]
  let merged = rig.platform.complete_multipart(ok_started, ok_parts) catch {
    err => fail("floor 100KiB complete_multipart raised " + storage_text(err))
  }
  println(
    "100KiB 非末片完成之后尺寸=" +
    merged.size.unwrap_or(-1L).to_string(),
  )
  // 合并发生在服务端读回来的那一份：100KiB + "tail" 四个字节
  assert_eq(merged.size, Some((100 * 1024 + 4).to_int64()))
  let removed = rig.platform.delete(merged) catch {
    err => fail("floor cleanup: " + storage_text(err))
  }
  assert_eq(removed, true)
}

///|
/// 一条寻址事实要在端口上钉住：**OBS 只有 virtual-hosted**。path 风格那条地址
/// （`https://obs.<区域>.myhuaweicloud.com/<桶>/<键>`）在真端点一律 403
/// `VirtualHostDomainRequired`（带正文，832 字节，2026-10-19 实测），所以端口不给这一档：
/// `get_file` 只认本平台域名前缀的 URL，别的一律在**发出任何请求之前** `InvalidInput`。
/// 这一档不联网，量的是"端口不替服务端猜一条发不出去的地址"。
async fn vhost_only_refusal(
  rig : Rig,
  bucket : String,
  region : String,
) -> Unit {
  let path_style = "https://" +
    @obsconfig.native_endpoint_host(region) +
    "/" +
    bucket +
    "/vhost-only.txt"
  let refused = try {
    let _ = rig.platform.get_file(path_style)
    "no-error"
  } catch {
    err => storage_text(err)
  }
  println("path 风格那一格=" + refused)
  assert_true(refused.has_prefix("InvalidInput:"))
}

///|
async fn run_obs(
  ak : String,
  sk : String,
  bucket : String,
  region : String,
) -> Unit {
  let stamp = @env.get_env_var("OBS_RUN_TAG").unwrap_or("0")
  let prefix = "moonfs-obs-contract-" + stamp
  let built = build(ak, sk, bucket, region) catch {
    err => fail("obs leg setup: " + obs_text(err))
  }
  let rig = built.0
  let domain = built.1
  println("本轮前缀=" + prefix + " run tag=" + stamp)
  // ① 开头清扫：本轮独占前缀，把上一轮这一腿中途红掉留下的残留先删掉（契约正文那一段
  //    自己会删它写的东西，但"红一次"时那一段根本跑不到收尾，所以这一趟是必须的）。
  obs_open_clean(rig.client, bucket, prefix, "开头")
  // ② 阳性对照：证明上面那一趟真会删东西，不是一行空转。
  obs_orphan_proof(rig.client, bucket, prefix)
  let root = @fs.tmpdir(prefix="moonfs-contract-obs") catch {
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
    label: "obs",
    platform: "obs",
    base_path: prefix,
    domain,
    service,
    recorder,
    port: rig.platform,
    // 真字段名，不是照抄别家：OBS 原生面的预签名参数就是 `X-Amz-*` 那一套（**没有**
    // `x-obs-` 版本，签名件 `presign_v4` 的字面量如此），凭证串与有效期分别是
    // `X-Amz-Credential=` 与 `X-Amz-Expires=`（算法名 `AWS4-HMAC-SHA256`，服务段仍是 `s3`）。
    presigned_markers: ["X-Amz-Credential=", "X-Amz-Expires="],
  }
  // ③ 五个证明段整段包起来：里面的红（`fail`／`assert_*`）折成读数，先让结尾清扫跑完
  //    再原样交出去——判据一条不放宽，但"红一次"不再等于"往真桶里漏东西"。
  let outcome = try {
    @contract.run_contract(fixture)
    signed_get_proof(rig, bucket, prefix)
    acl_proof(rig, bucket, prefix)
    part_floor_proof(rig, prefix)
    vhost_only_refusal(rig, bucket, region)
    "no-error"
  } catch {
    err => "测量阶段红: " + err.to_string()
  }
  // ④ 结尾清扫与本地记账读数都排在断言之前（桶侧扫干净、`%TEMP%` 那一份也删干净）
  let left = obs_clean(rig.client, bucket, prefix)
  println(
    "结尾清扫 " +
    obs_trim(prefix, 120) +
    " -> 剩余" +
    left.to_string() +
    " 个",
  )
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
  // ⑤ 判据：先说桶（守卫本身），再交测量阶段的红（免得被"行数对不上"这种连带红盖住），
  //    最后才是记录行数的连带判据。一条不放宽。
  if outcome != "no-error" && left != 0 {
    fail(
      outcome +
      " ｜且结尾清扫没归零，剩余 " +
      left.to_string() +
      " 个",
    )
  }
  if outcome != "no-error" {
    fail(outcome)
  }
  if left < 0 {
    fail(
      "结尾清扫没跑成（读数 " +
      left.to_string() +
      "）：这一腿到底漏没漏没人证明过",
    )
  }
  // 契约把自己写的都删了，这里非 0 就是往真桶里漏了东西
  assert_eq(left, 0L)
  // 主记录 + 分片子记录两份，且分片子记录要被门面清干净（完成与放弃各清一次）
  assert_eq(rows.length(), 2)
  assert_eq(parts.length(), 0)
}

///|

///|
/// 寻址档专用的一条：同一个桶绑定的自定义域名走 **http**，把预签名那一整套真取回再核一遍。
/// 它**不冒充**"契约正文换了个载体"——正文量平台能力，这一档只量寻址与 scheme。
async fn run_obs_domain(
  ak : String,
  sk : String,
  bucket : String,
  region : String,
) -> Unit {
  let stamp = @env.get_env_var("OBS_RUN_TAG").unwrap_or("0")
  let prefix = "moonfs-obs-domain-" + stamp
  let built = build(ak, sk, bucket, region, custom_domain=true) catch {
    err => fail("obs addressing arm setup: " + obs_text(err))
  }
  let rig = built.0
  let domain = built.1
  println("寻址档前缀=" + prefix + " 使用的域名=" + domain)
  // 预签名串必须挂在这个域名下（域名档里 host 逐字用，不拼桶名）
  let key = prefix + "/shape.txt"
  let info = @model.FileInfo::draft("obs", prefix, "shape.txt", "txt").stamped(@model.Stamp::{
    platform: None,
    path: Some(key),
    url: None,
    size: None,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
  let url = rig.platform.presigned_url(info, @model.PresignMethod::Get, 120) catch {
    err =>
      fail("presigned_url on the custom domain raised: " + storage_text(err))
  }
  assert_true(url.has_prefix(domain + "/"))
  signed_get_proof(rig, bucket, prefix)
  let left = obs_clean(rig.client, bucket, prefix)
  println("寻址档本轮前缀清扫后剩余=" + left.to_string())
  assert_eq(left, 0)
}

///|
async test "obs addressing arm: a bound custom domain served over http" {
  let given = @env.get_env_var("OBS_DOMAIN").unwrap_or("")
  match live_env() {
    None => report_skip()
    Some(environment) =>
      if given.is_empty() {
        println("SKIP contract/obs addressing arm, OBS_DOMAIN not supplied")
        println(
          "SKIP IS NOT A PASS: this platform leg was not verified by this run.",
        )
      } else {
        run_obs_domain(
          environment.0,
          environment.1,
          environment.2,
          environment.3,
        )
      }
  }
}

///|
async test "obs platform walks the shared contract against the real bucket" {
  match live_env() {
    None => report_skip()
    Some(environment) =>
      run_obs(environment.0, environment.1, environment.2, environment.3)
  }
}
