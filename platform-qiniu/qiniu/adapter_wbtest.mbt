///|
/// 适配层的**同步**离线判据（碰到异步那一档的负判据在 `adapter_test.mbt`，
/// 那个文件走公开面）。这里钉的是翻译本身：错误分档、能力位与拒绝的成对关系、
/// key/url 两头对齐、元数据两侧的形状。协议正确性在 `sdk-kodo` 那侧另有向量。

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
fn service_error(status : Int32, message : String) -> @kodoerr.KodoError {
  let details = @kodoerr.service_error(status, message, Some("reqid-stub"))
  @kodoerr.KodoError::Service(details)
}

///|
test "适配 #0 错误分档：612 才是 NotFound，其余服务端码与本地档各归各" {
  let missing = error_text(
    map_error(service_error(612, "{\"error\":\"no such file\"}")),
  )
  assert_eq(missing.has_prefix("NotFound:kodo 612 no such file"), true)
  assert_eq(missing.contains("reqid=reqid-stub"), true)
  let other = error_text(map_error(service_error(599, "{\"error\":\"boom\"}")))
  assert_eq(other.has_prefix("Platform:kodo 599 boom"), true)
  assert_eq(
    error_text(map_error(@kodoerr.KodoError::BadParam("x"))),
    "InvalidInput:kodo param: x",
  )
  assert_eq(
    error_text(map_error(@kodoerr.KodoError::BadFile("x"))),
    "InvalidInput:kodo file: x",
  )
  assert_eq(
    error_text(map_error(@kodoerr.KodoError::Network("timeout"))),
    "Platform:kodo network: timeout",
  )
  assert_eq(
    error_text(map_error(@kodoerr.KodoError::Cancelled("x"))),
    "Platform:kodo cancelled: x",
  )
  assert_eq(
    error_text(map_error(@kodoerr.KodoError::BadResponse("x"))),
    "Platform:kodo response: x",
  )
  // "不存在"只认 612：把任何异常都当没有，会把服务端的拒绝读成一次成功的删除
  assert_eq(is_absent(service_error(612, "{}")), true)
  assert_eq(is_absent(service_error(599, "{}")), false)
  assert_eq(is_absent(@kodoerr.KodoError::Network("timeout")), false)
}

///|
test "适配 #1 key 与 url 两头对齐：域名外的一律不认，剥完前缀能拼回去" {
  assert_eq(
    key_of_url("https://blog.example.com", "https://blog.example.com/a/b/c.txt"),
    Some("a/b/c.txt"),
  )
  assert_eq(
    key_of_url("https://blog.example.com", "https://other.example.com/a.txt"),
    None,
  )
  assert_eq(
    key_of_url("https://blog.example.com/", "https://blog.example.com/a.txt"),
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
}

///|
test "适配 #2 空值拦在本地：key 与分片会话号都不许带着空串出门" {
  let blank_key = require_key("") catch { err => error_text(err) }
  assert_eq(blank_key, "InvalidInput:qiniu object needs a key")
  assert_eq(require_key("a/b.txt"), "a/b.txt")
  let no_id = @model.FileInfo::draft("qiniu", "a", "b.txt", "txt")
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
test "适配 #3 元数据两侧的形状：Map ↔ 平铺字段 ↔ 读侧嵌套对象" {
  let meta : Map[String, String] = Map([])
  meta["case"] = "qiniu"
  meta["kind"] = "adapter"
  let pairs = meta_pairs(meta)
  assert_eq(pairs.length(), 2)
  // 顺序按 Map 的迭代序，判据只认"两对都在"，不认先后
  assert_eq(pairs.contains(("case", "qiniu")), true)
  assert_eq(pairs.contains(("kind", "adapter")), true)
  let back = pairs_meta(pairs)
  assert_eq(back.get("case"), Some("qiniu"))
  assert_eq(back.get("kind"), Some("adapter"))
  assert_eq(back.get("absent"), None)
  assert_eq(pairs_meta([]).length(), 0)
  // 读侧的嵌套对象形状（2026-10-17 真桶现读的那一份）折成 Map
  let text = "{\"fsize\":24,\"x-qn-meta\":{\"case\":\"qiniu\",\"kind\":\"adapter\"}}"
  let read = pairs_meta(@sdk.stat_user_metadata(text))
  assert_eq(read.get("case"), Some("qiniu"))
  assert_eq(read.get("kind"), Some("adapter"))
  // 写侧是平铺字段：同一个键在两侧不该长成同一个样
  assert_eq(@sdk.meta_form_fields([("case", "qiniu")]), [
    ("x-qn-meta-case", "qiniu"),
  ])
}

///|
test "适配 #4 目的地缺文件名就拦在本地，路径与桶的拼法与门面同一把尺" {
  let named = @model.FileInfo::draft("qiniu", "a/b/", "c.txt", "txt")
  assert_eq(dest_key(named, "copy"), "a/b/c.txt")
  let blank = @model.FileInfo::draft("qiniu", "a/b", "", "txt")
  let blank_dest = dest_key(blank, "move") catch { err => error_text(err) }
  assert_eq(
    blank_dest, "InvalidInput:qiniu same_move needs a destination filename",
  )
}
