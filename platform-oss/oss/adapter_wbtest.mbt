///|
/// 适配层的**同步**离线判据（碰到异步那一档的负判据在 `adapter_test.mbt`，那个文件走公开面）。
/// 这里钉的是翻译本身：错误分档、key/url 两头对齐、元数据两侧的形状、分片顺序、续页标记。
/// 协议正确性在 `moon-oss` 那侧另有向量。

///|
/// 错误分档的读数：看的是"哪一档"，不是某一串具体文字。
fn error_text(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(m) => "InvalidInput:" + m
    @model.StorageError::NotSupported(m) => "NotSupported:" + m
    @model.StorageError::NotFound(m) => "NotFound:" + m
    @model.StorageError::Platform(m) => "Platform:" + m
    @model.StorageError::Recorder(m) => "Recorder:" + m
  }
}

///|
fn service(status : Int32, code : String, message : String) -> @osserr.OssError {
  @osserr.OssError::Service(@osserr.ServiceError::{
    status,
    code,
    message,
    request_id: Some("reqid-stub"),
  })
}

///|
test "适配 #0 错误分档：404 只看状态码，空正文那一档也要认成 NotFound" {
  // 真桶的 `HEAD /<key>` 打不存在的键**只有 404、没有 XML 正文**（2026-10-18 现读），
  // 此时 code 与 message 都是空串。照 code 判档会把每一次"没有"都读成未知错误。
  let head_missing = service(404, "", "")
  assert_eq(is_absent(head_missing), true)
  let reading = error_text(map_error(head_missing))
  assert_eq(reading.has_prefix("NotFound:oss 404 "), true)
  assert_eq(reading.contains("reqid=reqid-stub"), true)
  // GET 的 404 带正文，读数是 NoSuchKey；放弃之后再查分片是 NoSuchUpload——同一档
  assert_eq(
    error_text(
      map_error(service(404, "NoSuchKey", "The specified key does not exist.")),
    ).has_prefix("NotFound:oss 404 NoSuchKey"),
    true,
  )
  assert_eq(is_absent(service(404, "NoSuchUpload", "")), true)
  // 403 不是"没有"：写公开读 ACL 被桶侧拒、换错密钥签名不符，都得原样报失败
  assert_eq(
    is_absent(
      service(403, "AccessDenied", "Put public object acl is not allowed"),
    ),
    false,
  )
  let denied = error_text(map_error(service(403, "AccessDenied", "denied")))
  assert_eq(denied.has_prefix("Platform:oss 403 AccessDenied denied"), true)
  assert_eq(is_absent(service(403, "SignatureDoesNotMatch", "")), false)
  // 500 那一档也不许折叠成"没有"
  assert_eq(is_absent(service(500, "", "")), false)
  // 本地三臂各归各：把"没连上"与"服务端答了但拒绝"混成一个整数，重试策略会被带偏
  assert_eq(
    error_text(map_error(@osserr.OssError::BadParam("x"))),
    "InvalidInput:oss param: x",
  )
  assert_eq(
    error_text(map_error(@osserr.OssError::Network("timeout"))),
    "Platform:oss network: timeout",
  )
  assert_eq(
    error_text(map_error(@osserr.OssError::BadResponse("not utf8"))),
    "Platform:oss response: not utf8",
  )
}

///|
test "适配 #1 key 与 url 两头对齐：域名外的一律不认，剥完前缀能拼回去" {
  assert_eq(
    key_of_url(
      "https://blog.example.invalid", "https://blog.example.invalid/a/b/c.txt",
    ),
    Some("a/b/c.txt"),
  )
  assert_eq(
    key_of_url(
      "https://blog.example.invalid", "https://other.example.invalid/a.txt",
    ),
    None,
  )
  assert_eq(
    key_of_url(
      "https://blog.example.invalid/", "https://blog.example.invalid/a.txt",
    ),
    Some("a.txt"),
  )
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
  let blank_key = require_key("") catch { err => error_text(err) }
  assert_eq(blank_key, "InvalidInput:oss object needs a key")
  assert_eq(require_key("a/b.txt"), "a/b.txt")
  let no_id = @model.FileInfo::draft("oss", "a", "b.txt", "txt")
  let no_id_reading = require_upload_id(no_id) catch { err => error_text(err) }
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
    err => error_text(err)
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
test "适配 #3 元数据两侧的形状：Map ↔ `x-oss-meta-*` 平铺头（键名不带前缀）" {
  let meta : Map[String, String] = Map([])
  meta["case"] = "oss"
  meta["kind"] = "adapter"
  let pairs = meta_pairs(meta)
  assert_eq(pairs.length(), 2)
  // 顺序按 Map 的迭代序，判据只认"两对都在"，不认先后
  assert_eq(pairs.contains(("case", "oss")), true)
  assert_eq(pairs.contains(("kind", "adapter")), true)
  let back = pairs_meta(pairs)
  assert_eq(back.get("case"), Some("oss"))
  assert_eq(back.get("kind"), Some("adapter"))
  assert_eq(back.get("absent"), None)
  assert_eq(pairs_meta([]).length(), 0)
  assert_eq(meta_pairs(Map([])).length(), 0)
}

///|
/// 完成分片要把分片按号升序交出去：SDK 那一层刻意不重排（重排会藏掉"调用方给的顺序
/// 不对"这个真错），所以排序是这条腿的活。
test "适配 #4 分片升序与续页标记：乱序进去、升序出来，读不出的标记不硬造 0" {
  let ordered : Array[(Int32, String)] = []
  push_part_ascending(ordered, 3, "c")
  push_part_ascending(ordered, 1, "a")
  push_part_ascending(ordered, 2, "b")
  assert_eq(ordered.map(p => p.0), [1, 2, 3])
  assert_eq(ordered.map(p => p.1), ["a", "b", "c"])
  let single : Array[(Int32, String)] = []
  push_part_ascending(single, 7, "z")
  assert_eq(single, [(7, "z")])
  // ListParts 的续页标记在协议里是字符串；端点不给就是到底了
  assert_eq(marker_to_int32("12"), Some(12))
  assert_eq(marker_to_int32("0"), Some(0))
  assert_eq(marker_to_int32(""), None)
  assert_eq(marker_to_int32("abc"), None)
}

///|
test "适配 #5 目的地缺文件名就拦在本地，路径的拼法与门面同一把尺" {
  let named = @model.FileInfo::draft("oss", "a/b/", "c.txt", "txt")
  assert_eq(dest_key(named, "copy"), "a/b/c.txt")
  let blank = @model.FileInfo::draft("oss", "a/b", "", "txt")
  let blank_dest = dest_key(blank, "move") catch { err => error_text(err) }
  assert_eq(
    blank_dest, "InvalidInput:oss same_move needs a destination filename",
  )
}
