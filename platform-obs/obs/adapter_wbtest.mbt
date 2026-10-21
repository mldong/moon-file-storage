///|
/// 适配层的**同步**离线判据（碰到异步那一档的负判据在 `adapter_test.mbt`，那个文件走公开面）。
/// 这里钉的是翻译本身：错误分档、canned ACL 词表映射、key/url 两头对齐、元数据两侧的形状、
/// 分片顺序、续页标记。协议正确性在 `moon-obs` 那侧另有向量。

///|
/// 错误分档的读数：看的是"哪一档"，不是某一串具体文字。
fn wb_error_text(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(m) => "InvalidInput:" + m
    @model.StorageError::NotSupported(m) => "NotSupported:" + m
    @model.StorageError::NotFound(m) => "NotFound:" + m
    @model.StorageError::Platform(m) => "Platform:" + m
    @model.StorageError::Recorder(m) => "Recorder:" + m
  }
}

///|
/// OBS 的 `ServiceError` 比 COS 少一格 `trace_id`、`request_id` 是可空的——
/// 桩就按它的真形状造。
fn wb_service(
  status : Int32,
  code : String,
  message : String,
) -> @obserr.ObsError {
  @obserr.ObsError::Service(@obserr.ServiceError::{
    status,
    code,
    message,
    request_id: Some("reqid-stub"),
  })
}

///|
/// 没有请求号的那一档：SDK 两个头名都找不到时给 `None`，文案必须落 `<none>` 而不是空串——
/// 报障时要一眼看出"这发没带上号"。
test "适配 #0 错误分档：404 只看状态码，空正文与缺请求号都要认得出来" {
  // 真桶的 `HEAD /<key>` 打不存在的键**只有 404、没有 XML 正文**，此时 code 与 message
  // 都是空串。照 code 判档会把每一次"没有"都读成未知错误。
  let head_missing = wb_service(404, "", "")
  assert_eq(is_absent(head_missing), true)
  let reading = wb_error_text(map_error(head_missing))
  assert_eq(reading.has_prefix("NotFound:obs 404 "), true)
  assert_eq(reading.contains("reqid=reqid-stub"), true)
  // GET 的 404 带正文，读数是 NoSuchKey；放弃之后再查分片是 NoSuchUpload（2026-10-19
  // 真桶读数）——同一档，都按 status 落 NotFound
  assert_eq(
    wb_error_text(
      map_error(
        wb_service(404, "NoSuchKey", "The specified key does not exist."),
      ),
    ).has_prefix("NotFound:obs 404 NoSuchKey"),
    true,
  )
  assert_eq(is_absent(wb_service(404, "NoSuchUpload", "")), true)
  // 403 不是"没有"：签名不符、桶私有裸读（原生面的 `AccessDenied`）都得原样报失败
  assert_eq(is_absent(wb_service(403, "AccessDenied", "denied")), false)
  let denied = wb_error_text(
    map_error(wb_service(403, "AccessDenied", "denied")),
  )
  assert_eq(denied.has_prefix("Platform:obs 403 AccessDenied denied"), true)
  assert_eq(is_absent(wb_service(403, "SignatureDoesNotMatch", "")), false)
  // 400 两档：坏 ACL 取值的 InvalidArgument 与分片越界的 EntityTooSmall（下限 100KiB
  // 真桶实测）都是"这一次请求被拒"——不是"没有"，也不是"这一族做不到"，原样进 Platform。
  // 特别是 EntityTooSmall 不许折叠成 NotSupported：那会把"片给小了"读成"这家不会分片"。
  assert_eq(is_absent(wb_service(400, "InvalidArgument", "")), false)
  let refused = wb_error_text(
    map_error(wb_service(400, "InvalidArgument", "x")),
  )
  assert_eq(refused.has_prefix("Platform:obs 400 InvalidArgument"), true)
  let too_small = wb_error_text(
    map_error(wb_service(400, "EntityTooSmall", "x")),
  )
  assert_eq(too_small.has_prefix("Platform:obs 400 EntityTooSmall"), true)
  assert_eq(too_small.has_prefix("NotSupported"), false)
  // path 风格那一族根本走不到这里（SDK 出门前就 BadParam），下面本地三臂各归各
  assert_eq(is_absent(wb_service(500, "", "")), false)
  // 把"没连上"与"服务端答了但拒绝"混成一个整数，重试策略会被带偏
  assert_eq(
    wb_error_text(map_error(@obserr.ObsError::BadParam("x"))),
    "InvalidInput:obs param: x",
  )
  assert_eq(
    wb_error_text(map_error(@obserr.ObsError::Network("timeout"))),
    "Platform:obs network: timeout",
  )
  assert_eq(
    wb_error_text(map_error(@obserr.ObsError::BadResponse("not utf8"))),
    "Platform:obs response: not utf8",
  )
  // 请求号缺失的那一档落在 `<none>`
  let anonymous = @obserr.ObsError::Service(@obserr.ServiceError::{
    status: 403,
    code: "AccessDenied",
    message: "",
    request_id: None,
  })
  assert_eq(wb_error_text(map_error(anonymous)).contains("reqid=<none>"), true)
}

///|
/// canned ACL 词表映射：OBS 的 SDK 收**裸串**（没有自家枚举），所以这一腿直接用端口的
/// `header_value`——三档线值恰好都在这家真桶收的取值面里（2026-10-19 实测
/// `private`／`public-read`／`public-read-write` 全收）。`platform-cos` 那边是映射到
/// SDK 枚举再 `.text()`，这里没有中间词表，形状不同处就登记在此。
test "适配 #A 契约三档映到 OBS 线值：private / public-read / public-read-write" {
  assert_eq(sdk_acl(@model.CannedAcl::Private), "private")
  assert_eq(sdk_acl(@model.CannedAcl::PublicRead), "public-read")
  assert_eq(sdk_acl(@model.CannedAcl::PublicReadWrite), "public-read-write")
  // OBS 特有的更高档位（`bucket-owner-read` 一类）端口没有对应项，不凭空造：
  // 端口枚举只有这三档，翻译是全集上的满射，不存在第四种输入
  let only_three : Array[@model.CannedAcl] = [
    @model.CannedAcl::Private,
    @model.CannedAcl::PublicRead,
    @model.CannedAcl::PublicReadWrite,
  ]
  assert_eq(only_three.map(acl => sdk_acl(acl)), [
    "private", "public-read", "public-read-write",
  ])
}

///|
test "适配 #1 key 与 url 两头对齐：域名外的一律不认，剥完前缀能拼回去" {
  let host = "https://sample-bucket.obs.cn-south-1.invalid"
  assert_eq(key_of_url(host, host + "/a/b/c.txt"), Some("a/b/c.txt"))
  assert_eq(key_of_url(host, "https://other.example.invalid/a.txt"), None)
  assert_eq(key_of_url(host + "/", host + "/a.txt"), Some("a.txt"))
  assert_eq(parent_of_key("a/b/c.txt"), "a/b")
  assert_eq(file_name_of_key("a/b/c.txt"), "c.txt")
  assert_eq(ext_of_key("a/b/c.tar.gz"), "gz")
  assert_eq(ext_of_key("a/b/noext"), "")
  assert_eq(parent_of_key("c.txt"), "")
  assert_eq(file_name_of_key("c.txt"), "c.txt")
  assert_eq(last_segment("a/b/inner/"), "inner")
  assert_eq(last_segment("c.txt"), "c.txt")
  assert_eq(trim_leading_slash("/a/b"), "a/b")
  assert_eq(trim_trailing_slash("a/b//"), "a/b")
  assert_eq(strip_trailing_slash("a/b/"), "a/b")
}

///|
test "适配 #2 空值拦在本地：key 与分片会话号都不许带着空串出门" {
  let blank_key = require_key("") catch { err => wb_error_text(err) }
  assert_eq(blank_key, "InvalidInput:obs object needs a key")
  assert_eq(require_key("a/b.txt"), "a/b.txt")
  let no_id = @model.FileInfo::draft("obs", "a", "b.txt", "txt")
  let no_id_reading = require_upload_id(no_id) catch {
    err => wb_error_text(err)
  }
  assert_eq(
    no_id_reading, "InvalidInput:multipart needs the upload_id returned by init_multipart",
  )
  let empty_id = no_id.stamped(@model.Stamp::{
    platform: None,
    path: None,
    url: None,
    size: None,
    create_time: None,
    upload_id: Some(""),
    upload_status: None,
    user_metadata: None,
  })
  let empty_reading = require_upload_id(empty_id) catch {
    err => wb_error_text(err)
  }
  assert_eq(
    empty_reading, "InvalidInput:multipart needs the upload_id returned by init_multipart",
  )
  let with_id = no_id.stamped(@model.Stamp::{
    platform: None,
    path: None,
    url: None,
    size: None,
    create_time: None,
    upload_id: Some("U1"),
    upload_status: None,
    user_metadata: None,
  })
  assert_eq(require_upload_id(with_id), "U1")
}

///|
test "适配 #3 元数据两侧的形状：Map ↔ `<prefix>meta-*` 平铺头（键名不带前缀）" {
  let meta : Map[String, String] = Map([])
  meta["case"] = "obs"
  meta["kind"] = "adapter"
  let pairs = meta_pairs(meta)
  assert_eq(pairs.length(), 2)
  // 顺序按 Map 的迭代序，判据只认"两对都在"，不认先后
  assert_eq(pairs.contains(("case", "obs")), true)
  assert_eq(pairs.contains(("kind", "adapter")), true)
  let back = pairs_meta(pairs)
  assert_eq(back.get("case"), Some("obs"))
  assert_eq(back.get("kind"), Some("adapter"))
  assert_eq(back.get("absent"), None)
  assert_eq(pairs_meta([]).length(), 0)
  assert_eq(meta_pairs(Map([])).length(), 0)
}

///|
/// 完成分片要把分片按号升序交出去：SDK 那一层刻意不重排（重排会藏掉"调用方给的顺序
/// 不对"这个真错），所以排序是这条腿的活。ETag 带引号原样进数组——不剥。
test "适配 #4 分片升序与续页标记：乱序进去、升序出来，读不出的标记不硬造 0" {
  let ordered : Array[(Int32, String)] = []
  push_part_ascending(ordered, 3, "\"c\"")
  push_part_ascending(ordered, 1, "\"a\"")
  push_part_ascending(ordered, 2, "\"b\"")
  assert_eq(ordered.map(p => p.0), [1, 2, 3])
  assert_eq(ordered.map(p => p.1), ["\"a\"", "\"b\"", "\"c\""])
  let single : Array[(Int32, String)] = []
  push_part_ascending(single, 7, "\"z\"")
  assert_eq(single, [(7, "\"z\"")])
  // ListParts 的续页标记在协议里是字符串；端点不给就是到底了。
  // OBS 与 COS 不同的一格：SDK 的 list_parts 真接 `part-number-marker`（Int32），
  // 0 不发查询、负数不发查询，"从头列"与"标记得不合法"不混。
  assert_eq(marker_to_int32("12"), Some(12))
  assert_eq(marker_to_int32("0"), Some(0))
  assert_eq(marker_to_int32(""), None)
  assert_eq(marker_to_int32("abc"), None)
}

///|
test "适配 #5 目的地缺文件名就拦在本地，路径的拼法与门面同一把尺" {
  let named = @model.FileInfo::draft("obs", "a/b/", "c.txt", "txt")
  assert_eq(dest_key(named, "copy"), "a/b/c.txt")
  let blank = @model.FileInfo::draft("obs", "a/b", "", "txt")
  let blank_dest = dest_key(blank, "move") catch { err => wb_error_text(err) }
  assert_eq(
    blank_dest, "InvalidInput:obs same_move needs a destination filename",
  )
}

///|
/// OBS 只有虚主机这一档寻址（path 风格一律 403 `VirtualHostDomainRequired`，真桶实测）。
/// 端口没有"寻址风格"这一法，适配层也不提供 path 选项。这里钉分档：path 风格那一族的
/// 响亮拒绝在 SDK 出门前落 `BadParam`（本体在 `Config::path_style_url`，真调用与派生形状
/// 的钉子挪到 `adapter_test.mbt`——白盒档看不见 `for test` 引的凭据件与配置件），
/// 适配层把它读成 `InvalidInput`：出门前的本地拒与线上的 403 不混档。
test "适配 #6 path 风格那一族的本地拒落 InvalidInput，不混进网络/服务端档" {
  let refused = wb_error_text(
    map_error(
      @obserr.ObsError::BadParam(
        "obs has no path-style addressing for bucket sample-bucket/a/b.txt: a path-style request is answered 403 VirtualHostDomainRequired, use virtual-hosted style",
      ),
    ),
  )
  assert_eq(refused.has_prefix("InvalidInput:obs param: "), true)
  assert_eq(refused.contains("VirtualHostDomainRequired"), true)
  assert_eq(refused.has_prefix("Platform"), false)
  // 本地拒不是"没有"：不许把寻址用错折叠成 NotFound（那会把配置错读成对象不存在）
  assert_eq(is_absent(@obserr.ObsError::BadParam("path style")), false)
}
