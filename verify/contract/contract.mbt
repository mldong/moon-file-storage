///|
// One contract, two callers. These cases are the same body the reference
// framework runs for every storage (`FileStorageServiceBaseTest`); each platform
// entry test feeds this suite its own `Service`, then checks the storage from its
// own side (a directory listing here, a bucket listing there).
//
// A case never skips a capability: it reads what the platform *claims* and then
// asserts the consequence, so an unsupported feature shows up as a red assertion
// or an explicit refusal — never as a silently passing branch.

///|
pub(all) struct Fixture {
  label : String
  platform : String
  base_path : String
  domain : String
  service : @storage.Service
  recorder : &@recorder.Recorder
  /// 三族走端口本体：门面只编排对象族与记录，分片／预签名／复制移动没有服务编排，
  /// 所以契约直接调端口，免得把"门面没做的事"读成"端口没有"。
  port : &@platform.Platform
  /// 预签名 URL 的形状判据由**这条腿自己报**：各家签名 URL 的查询串写法不同
  /// （S3 是 X-Amz-Signature= / X-Amz-Expires=，原生 Kodo 是 ?e= / &token=），
  /// 把某一家的写法写进共享正文，就等于让别的腿迁就一个协议细节。
  presigned_markers : Array[String]
}

///|
struct Sink {
  got : @ref.Ref[Array[Byte]]
}

///|
pub impl @io.Writer for Sink with fn write_once(
  self,
  data : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  for index in offset..<(offset + len) {
    let _ = self.got.val.push(data[index])
  }
  len
}

///|
pub extend Sink with @io.Writer::{write, write_once, write_reader}

///|
fn payload(text : String) -> Bytes {
  // Never `.to_bytes()` on a String: that is UTF-16 code units here, so a
  // byte-equality assertion built from it would compare the wrong length.
  @utf8.encode(text)
}

///|
fn object_name(case : String) -> String {
  "contract-" + case + ".txt"
}

///|
fn describe(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(detail) => "InvalidInput: " + detail
    @model.StorageError::NotSupported(detail) => "NotSupported: " + detail
    @model.StorageError::NotFound(detail) => "NotFound: " + detail
    @model.StorageError::Platform(detail) => "Platform: " + detail
    @model.StorageError::Recorder(detail) => "Recorder: " + detail
  }
}

///|
fn url_of(fixture : Fixture, name : String) -> String {
  let key = @model.object_key(fixture.base_path, name)
  fixture.domain + "/" + key
}

///|
async fn save_source(
  fixture : Fixture,
  case : String,
  source : @model.UploadSource,
) -> @model.FileInfo {
  let intent = @model.FileInfo::draft(
    fixture.platform,
    fixture.base_path,
    object_name(case),
    "txt",
  )
  fixture.service.save(intent, source) catch {
    error => fail(fixture.label + " save raised " + describe(error))
  }
}

///|
async fn save_bytes(
  fixture : Fixture,
  case : String,
  text : String,
) -> @model.FileInfo {
  save_source(fixture, case, @model.UploadSource::Bytes(payload(text)))
}

///|
async fn read_back(fixture : Fixture, info : @model.FileInfo) -> Array[Byte] {
  let sink = Sink::{ got: @ref.Ref([]), }
  fixture.service.download(info, sink) catch {
    error => fail(fixture.label + " download raised " + describe(error))
  }
  sink.got.val
}

///|
async fn is_present(fixture : Fixture, info : @model.FileInfo) -> Bool {
  fixture.service.exists(info) catch {
    error => fail(fixture.label + " exists raised " + describe(error))
  }
}

///|
async fn remove(fixture : Fixture, info : @model.FileInfo) -> Bool {
  fixture.service.delete(info) catch {
    error => fail(fixture.label + " delete raised " + describe(error))
  }
}

///|
async fn lookup(fixture : Fixture, url : String) -> @model.FileInfo? {
  fixture.service.get_file(url) catch {
    error => fail(fixture.label + " get_file raised " + describe(error))
  }
}

///|
/// 读**记录器里那一行**，不是 `service.get_file`：后者还要让平台确认对象实存，
/// 而分片会话进行到一半时对象根本还不存在。参考件那条 `getFileInfoByUrl` 同样是
/// 直接读记录器，判"账落没落"必须走这条口。
async fn row_of(fixture : Fixture, url : String) -> @model.FileInfo? {
  fixture.recorder.get_by_url(url) catch {
    error => fail(fixture.label + " recorder read raised " + describe(error))
  }
}

///|
/// Upload → exists → record readable → download byte for byte → delete →
/// record gone. This is the chain the facade owns, so every platform walks it
/// end to end.
pub async fn case_round_trip(fixture : Fixture) -> Unit {
  let text = "moon-file-storage contract body for " + fixture.label
  let size = payload(text).length().to_int64()
  let info = save_bytes(fixture, "round-trip", text)
  let present = is_present(fixture, info)
  let row = fixture.recorder.get_by_url(info.url) catch {
    error => fail(fixture.label + " get_by_url raised " + describe(error))
  }
  let read = read_back(fixture, info)
  let storage_view = lookup(fixture, info.url)
  let removed = remove(fixture, info)
  let after = is_present(fixture, info)
  let gone = fixture.recorder.get_by_url(info.url) catch {
    error => fail(fixture.label + " get_by_url raised " + describe(error))
  }
  assert_true(present)
  assert_true(row is Some(_))
  assert_eq(info.size, Some(size))
  assert_true(read == payload(text).to_array())
  match storage_view {
    Some(view) => assert_eq(view.size, Some(size))
    None => fail(fixture.label + " reported the object absent after writing it")
  }
  assert_true(removed)
  assert_true(!after)
  assert_true(gone is None)
}

///|
/// A streamed source must land byte-identical too — this is the branch where an
/// adapter that buffers wrongly shows it.
pub async fn case_stream_upload(fixture : Fixture) -> Unit {
  let text = "streamed body for " + fixture.label
  let data = payload(text)
  let reader = @io.MemoryReader::MemoryReader(writer => writer.write(data))
  let info = save_source(
    fixture,
    "stream",
    @model.UploadSource::Stream(reader, Some(data.length().to_int64())),
  )
  reader.close()
  let read = read_back(fixture, info)
  let removed = remove(fixture, info)
  assert_eq(info.size, Some(data.length().to_int64()))
  assert_true(read == data.to_array())
  assert_true(removed)
}

///|
/// Absent is a fact, not an error: reading, checking or deleting a key that was
/// never written must answer "no" rather than throw or invent a record.
pub async fn case_absent(fixture : Fixture) -> Unit {
  let name = object_name("absent")
  let intent = @model.FileInfo::draft(
    fixture.platform,
    fixture.base_path,
    name,
    "txt",
  ).stamped(@model.Stamp::{
    platform: None,
    path: Some(@model.object_key(fixture.base_path, name)),
    url: Some(url_of(fixture, name)),
    size: None,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
  let ghost = lookup(fixture, url_of(fixture, object_name("absent")))
  let present = is_present(fixture, intent)
  let removed = remove(fixture, intent)
  assert_true(ghost is None)
  assert_true(!present)
  assert_true(!removed)
}

///|
/// The capability claim has to bite: a storage that says it cannot keep user
/// metadata must refuse the upload instead of accepting it and dropping the data;
/// one that says it can must hand the same value back on the next read.
pub async fn case_metadata_claim(fixture : Fixture) -> Unit {
  let caps = fixture.service.capabilities(fixture.platform)
  let text = "metadata claim"
  let intent = @model.FileInfo::draft(
    fixture.platform,
    fixture.base_path,
    object_name("metadata"),
    "txt",
  )
  intent.user_metadata["case"] = fixture.label
  let outcome = Ok(
    fixture.service.save(intent, @model.UploadSource::Bytes(payload(text))),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(info) => {
      if !caps.metadata {
        let claim = fixture.label + " stored user metadata it claims it cannot"
        fail(claim)
      }
      let read = read_back(fixture, info)
      let view = lookup(fixture, info.url)
      let removed = remove(fixture, info)
      assert_true(read == payload(text).to_array())
      assert_true(removed)
      match view {
        Some(stored) =>
          assert_eq(stored.user_metadata.get("case"), Some(fixture.label))
        None => fail(fixture.label + " lost the object it just stored")
      }
    }
    Err(error) => {
      if caps.metadata {
        let head = fixture.label + " refused a save it claims to support: "
        fail(head + describe(error))
      }
      let reason = describe(error)
      if !reason.has_prefix("NotSupported") {
        let head = fixture.label + " failed with "
        fail(head + reason)
      }
      assert_true(!caps.metadata)
    }
  }
}

///|
/// A key stamped onto a draft that was never written: the shape used to assert
/// "the source is not here" rather than an empty success.
fn ghost(fixture : Fixture, case : String) -> @model.FileInfo {
  let name = object_name(case)
  @model.FileInfo::draft(fixture.platform, fixture.base_path, name, "txt").stamped(@model.Stamp::{
      platform: None,
      path: Some(@model.object_key(fixture.base_path, name)),
      url: Some(url_of(fixture, name)),
      size: None,
      create_time: None,
      upload_id: None,
      upload_status: None,
      user_metadata: None,
    },
  )
}

///|
/// `String.find` is the substring test in this toolchain (there is no
/// `has_substring`), so the presigned url checks go through here.
fn holds(text : String, needle : String) -> Bool {
  text.find(needle) is Some(_)
}

///|
async fn download_port(
  fixture : Fixture,
  info : @model.FileInfo,
) -> Array[Byte] {
  let sink = Sink::{ got: @ref.Ref([]), }
  fixture.port.download(info, sink) catch {
    error => fail(fixture.label + " port download raised " + describe(error))
  }
  sink.got.val
}

///|
async fn present_port(fixture : Fixture, info : @model.FileInfo) -> Bool {
  fixture.port.exists(info) catch {
    error => fail(fixture.label + " port exists raised " + describe(error))
  }
}

///|
/// A platform that claims a family absent must refuse when it is called anyway.
/// "no-error" here is the red case: it means the claim was decorative.
fn expect_refusal(
  fixture : Fixture,
  family : String,
  outcome : String,
) -> Unit raise {
  if outcome == "no-error" {
    let head = fixture.label +
      " carried out " +
      family +
      " while claiming it cannot"
    fail(head)
  }
  if !outcome.has_prefix("NotSupported") {
    let head = fixture.label + " refused " + family + " with "
    fail(head + outcome)
  }
}

///|
/// The five steps each get their own refusal check: refusing only the first one
/// and accepting the rest would still let a caller write half an object.
async fn case_multipart_refusals(fixture : Fixture) -> Unit {
  let draft = @model.FileInfo::draft(
    fixture.platform,
    fixture.base_path,
    object_name("multipart"),
    "txt",
  )
  let piece = @model.UploadSource::Bytes(payload("x"))
  let started = try {
    let _ = fixture.port.init_multipart(draft)
    "no-error"
  } catch {
    error => describe(error)
  }
  expect_refusal(fixture, "init_multipart", started)
  let part = try {
    let _ = fixture.port.upload_part(draft, 1, piece)
    "no-error"
  } catch {
    error => describe(error)
  }
  expect_refusal(fixture, "upload_part", part)
  let listed = try {
    let _ = fixture.port.list_parts(draft, 0)
    "no-error"
  } catch {
    error => describe(error)
  }
  expect_refusal(fixture, "list_parts", listed)
  let completed = try {
    let _ = fixture.port.complete_multipart(draft, [])
    "no-error"
  } catch {
    error => describe(error)
  }
  expect_refusal(fixture, "complete_multipart", completed)
  let aborted = try {
    fixture.port.abort_multipart(draft)
    "no-error"
  } catch {
    error => describe(error)
  }
  expect_refusal(fixture, "abort_multipart", aborted)
}

///|
/// S3 rejects a completed multipart upload whose non-final part is under 5 MiB,
/// so the contract's first piece is that size — a suite built from toy-sized
/// pieces would pass on local and fail on every real object store.
let min_part_bytes : Int32 = 5242880

///|
fn piece(line : String, repeats : Int32) -> String {
  let buf = StringBuilder()
  for _ in 0..<repeats {
    buf.write_string(line)
  }
  buf.to_string()
}

///|
struct SpotSink {
  seen : @ref.Ref[Int64]
  want : Array[Int64]
  spots : @ref.Ref[Map[Int64, Byte]]
}

///|
pub impl @io.Writer for SpotSink with fn write_once(
  self,
  data : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  let start = self.seen.val
  let end = start + len.to_int64()
  for position in self.want {
    if position >= start && position < end {
      self.spots.val[position] = data[offset + (position - start).to_int()]
    }
  }
  self.seen.val = end
  len
}

///|
pub extend SpotSink with @io.Writer::{write, write_once, write_reader}

///|
/// Manual multipart end to end: two parts listed in order, merged in the order
/// the **service** decides (the caller's list is passed shuffled), and the object
/// that comes back is the concatenation — checked at the boundaries, which is
/// where a merge that followed arrival order or truncated the destination shows
/// up. Byte-for-byte comparison of the whole body would cost 5 MB of test heap
/// per leg and say no more.
async fn case_multipart_round_trip(fixture : Fixture) -> Unit {
  let line = "multipart-part-one-padding-0123456789-01"
  let two = "part-two-tail-completes-the-object"
  let line_bytes = payload(line)
  let two_bytes = payload(two)
  if min_part_bytes % line_bytes.length() != 0 {
    fail("contract fixture: the 5 MiB piece is not a whole number of lines")
  }
  let one = piece(line, min_part_bytes / line_bytes.length())
  let one_bytes = payload(one)
  let boundary = one_bytes.length().to_int64()
  let total = boundary + two_bytes.length().to_int64()
  let draft = @model.FileInfo::draft(
    fixture.platform,
    fixture.base_path,
    object_name("multipart"),
    "txt",
  )
  let started = fixture.port.init_multipart(draft) catch {
    error => fail(fixture.label + " init_multipart raised " + describe(error))
  }
  assert_true(started.upload_id is Some(_))
  let first = fixture.port.upload_part(
    started,
    1,
    @model.UploadSource::Bytes(one_bytes),
  ) catch {
    error => fail(fixture.label + " upload_part(1) raised " + describe(error))
  }
  let second = fixture.port.upload_part(
    started,
    2,
    @model.UploadSource::Bytes(two_bytes),
  ) catch {
    error => fail(fixture.label + " upload_part(2) raised " + describe(error))
  }
  assert_eq(first.size, one_bytes.length().to_int64())
  assert_eq(second.size, two_bytes.length().to_int64())
  // A part numbered outside 1..10000 is refused; which refusal is the platform's
  // business, that it is refused before anything lands is not negotiable.
  let out_of_range = try {
    let _ = fixture.port.upload_part(
      started,
      0,
      @model.UploadSource::Bytes(payload("x")),
    )
    "no-error"
  } catch {
    error => describe(error)
  }
  if out_of_range == "no-error" {
    fail(fixture.label + " accepted part number 0")
  }
  let page = fixture.port.list_parts(started, 0) catch {
    error => fail(fixture.label + " list_parts raised " + describe(error))
  }
  assert_eq(page.parts.length(), 2)
  assert_eq(page.parts[0].part_number, 1)
  assert_eq(page.parts[1].part_number, 2)
  let merged = fixture.port.complete_multipart(started, [second, first]) catch {
    error =>
      fail(fixture.label + " complete_multipart raised " + describe(error))
  }
  let sink = SpotSink::{
    seen: @ref.Ref(0L),
    want: [0L, boundary - 1L, boundary, total - 1L],
    spots: @ref.Ref(Map([])),
  }
  fixture.port.download(merged, sink) catch {
    error => fail(fixture.label + " download raised " + describe(error))
  }
  let read = sink.spots.val
  assert_eq(merged.size, Some(total))
  assert_eq(sink.seen.val, total)
  assert_eq(read.get(0L), Some(line_bytes[0]))
  assert_eq(read.get(boundary - 1L), Some(line_bytes[line_bytes.length() - 1]))
  assert_eq(read.get(boundary), Some(two_bytes[0]))
  assert_eq(read.get(total - 1L), Some(two_bytes[two_bytes.length() - 1]))
  let _ = fixture.port.delete(merged) catch {
    error => fail(fixture.label + " cleanup delete raised " + describe(error))
  }

  // An aborted session leaves no object and no parts behind.
  let abandoned = fixture.port.init_multipart(
    @model.FileInfo::draft(
      fixture.platform,
      fixture.base_path,
      object_name("multipart-abort"),
      "txt",
    ),
  ) catch {
    error =>
      fail(fixture.label + " init_multipart(abort) raised " + describe(error))
  }
  let _ = fixture.port.upload_part(
    abandoned,
    1,
    @model.UploadSource::Bytes(payload("abandoned")),
  ) catch {
    error =>
      fail(fixture.label + " upload_part(abort) raised " + describe(error))
  }
  fixture.port.abort_multipart(abandoned) catch {
    error => fail(fixture.label + " abort_multipart raised " + describe(error))
  }
  let left = try {
    let listed = fixture.port.list_parts(abandoned, 0)
    listed.parts.length().to_string()
  } catch {
    // A storage that drops the session entirely answers "no such upload"; either
    // answer is fine as long as no part survives.
    _ => "gone"
  }
  if left != "gone" && left != "0" {
    fail(fixture.label + " kept " + left + " parts after abort")
  }
  let survived = present_port(fixture, abandoned)
  assert_true(!survived)
}

///|
pub async fn case_multipart(fixture : Fixture) -> Unit {
  let caps = fixture.service.capabilities(fixture.platform)
  if caps.multipart_upload {
    case_multipart_round_trip(fixture)
  } else {
    case_multipart_refusals(fixture)
  }
}

///|
/// The presigned family at port level: both verbs produce a URL that carries the
/// signature in the query and points at this object, and the two verbs are not
/// the same signature. Actually fetching or PUTting through the URL without
/// credentials is proven by the leg that can reach the network — see the s3 leg.
pub async fn case_presigned_url(fixture : Fixture) -> Unit {
  let caps = fixture.service.capabilities(fixture.platform)
  let ghost_info = ghost(fixture, "presigned")
  if !caps.presigned_url {
    let get = try {
      let _ = fixture.port.presigned_url(
        ghost_info,
        @model.PresignMethod::Get,
        60,
      )
      "no-error"
    } catch {
      error => describe(error)
    }
    expect_refusal(fixture, "presigned_url(Get)", get)
    let put = try {
      let _ = fixture.port.presigned_url(
        ghost_info,
        @model.PresignMethod::Put,
        60,
      )
      "no-error"
    } catch {
      error => describe(error)
    }
    expect_refusal(fixture, "presigned_url(Put)", put)
  } else {
    let text = "presigned subject for " + fixture.label
    let info = save_bytes(fixture, "presigned", text)
    let download_url = fixture.port.presigned_url(
      info,
      @model.PresignMethod::Get,
      60,
    ) catch {
      error =>
        fail(fixture.label + " presigned_url(Get) raised " + describe(error))
    }
    let key = @model.object_key(fixture.base_path, object_name("presigned"))
    assert_true(download_url.has_prefix("http"))
    assert_true(download_url.has_prefix(fixture.domain))
    assert_true(holds(download_url, key))
    // 形状判据由这条腿自报：marker 逐个要在。签不出任何 marker 的腿
    // 不该把 presigned_url 报成 true——那一档由下面 PUT 与 GET 必须不同兜住
    for marker in fixture.presigned_markers {
      assert_true(holds(download_url, marker))
    }
    let put = try {
      let url = fixture.port.presigned_url(info, @model.PresignMethod::Put, 60)
      "url:" + url
    } catch {
      error => describe(error)
    }
    if put.has_prefix("url:") {
      let upload_url = put[4:put.length()].to_owned()
      for marker in fixture.presigned_markers {
        assert_true(holds(upload_url, marker))
      }
      if download_url == upload_url {
        fail(fixture.label + " signed the same url for GET and PUT")
      }
    } else if put.has_prefix("NotSupported") {
      // 响亮拒绝是一档合法结局（参照件那条 Kodo 腿原话就是「仅支持 GET」）；
      // 但必须是 NotSupported 本身：别的失败文案进不来这一档，最后那条 else 会红
      println(fixture.label + " presigned_url(Put) refused: " + put)
    } else {
      fail(fixture.label + " presigned_url(Put) failed with " + put)
    }
    let removed = remove(fixture, info)
    assert_true(removed)
  }
}

///|
/// Same-platform copy and move. The copy must leave the source alone; the move
/// must take it away. A missing source is `NotFound` on both legs, and a platform
/// that claims the family absent is refused before anything is written.
pub async fn case_same_copy_move(fixture : Fixture) -> Unit {
  let caps = fixture.service.capabilities(fixture.platform)
  let src_ghost = ghost(fixture, "copy-source-ghost")
  let dest = @model.FileInfo::draft(
    fixture.platform,
    fixture.base_path,
    object_name("copy-dst"),
    "txt",
  )
  // 两族各按自己的声明走。旧写法把两族捆在一个 `!same_copy || !same_move` 里，
  // 于是"声明一族、没有另一族"的平台（FTP 就是这样：`RNFR`/`RNTO` 有，复制没有）
  // 根本没有可走的臂——它对自己那族给出的 `NotFound` 会被读成"拒绝姿势不对"。
  if !caps.same_copy {
    let copied = try {
      let _ = fixture.port.same_copy(src_ghost, dest)
      "no-error"
    } catch {
      error => describe(error)
    }
    expect_refusal(fixture, "same_copy", copied)
  }
  if !caps.same_move {
    let moved = try {
      let _ = fixture.port.same_move(src_ghost, dest)
      "no-error"
    } catch {
      error => describe(error)
    }
    expect_refusal(fixture, "same_move", moved)
  }
  if caps.same_copy && caps.same_move {
    let text = "same-platform subject for " + fixture.label
    let src = save_bytes(fixture, "copy-src", text)
    let missing = try {
      let _ = fixture.port.same_copy(src_ghost, dest)
      "no-error"
    } catch {
      error => describe(error)
    }
    if !missing.has_prefix("NotFound") {
      let head = fixture.label + " answered a missing copy source with "
      fail(head + missing)
    }
    let copied = fixture.port.same_copy(src, dest) catch {
      error => fail(fixture.label + " same_copy raised " + describe(error))
    }
    let copied_read = download_port(fixture, copied)
    let source_remains = present_port(fixture, src)
    assert_true(copied_read == payload(text).to_array())
    assert_true(source_remains)
    // 移动接在复制的产物上：这条链证明"复制回的那份记录可以直接当移动的源"
    let moved = fixture.port.same_move(
      copied,
      @model.FileInfo::draft(
        fixture.platform,
        fixture.base_path,
        object_name("move-dst"),
        "txt",
      ),
    ) catch {
      error => fail(fixture.label + " same_move raised " + describe(error))
    }
    let moved_read = download_port(fixture, moved)
    let old_gone = present_port(fixture, copied)
    assert_true(moved_read == payload(text).to_array())
    assert_true(!old_gone)
    let _ = fixture.port.delete(moved) catch {
      error => fail(fixture.label + " cleanup delete raised " + describe(error))
    }
    let removed = remove(fixture, src)
    assert_true(removed)
  } else if caps.same_copy {
    let text = "same-platform subject for " + fixture.label
    let src = save_bytes(fixture, "copy-src", text)
    let missing = try {
      let _ = fixture.port.same_copy(src_ghost, dest)
      "no-error"
    } catch {
      error => describe(error)
    }
    if !missing.has_prefix("NotFound") {
      let head = fixture.label + " answered a missing copy source with "
      fail(head + missing)
    }
    let copied = fixture.port.same_copy(src, dest) catch {
      error => fail(fixture.label + " same_copy raised " + describe(error))
    }
    let copied_read = download_port(fixture, copied)
    let source_remains = present_port(fixture, src)
    assert_true(copied_read == payload(text).to_array())
    assert_true(source_remains)
    let _ = fixture.port.delete(copied) catch {
      error => fail(fixture.label + " cleanup delete raised " + describe(error))
    }
    let removed = remove(fixture, src)
    assert_true(removed)
  } else if caps.same_move {
    // 只有移动这一族的载体：源搬走之后不该再在原地，正文读回的必须还是那份字节
    let text = "same-platform subject for " + fixture.label
    let src = save_bytes(fixture, "copy-src", text)
    let missing = try {
      let _ = fixture.port.same_move(src_ghost, dest)
      "no-error"
    } catch {
      error => describe(error)
    }
    if !missing.has_prefix("NotFound") {
      let head = fixture.label + " answered a missing move source with "
      fail(head + missing)
    }
    let moved = fixture.port.same_move(
      src,
      @model.FileInfo::draft(
        fixture.platform,
        fixture.base_path,
        object_name("move-dst"),
        "txt",
      ),
    ) catch {
      error => fail(fixture.label + " same_move raised " + describe(error))
    }
    let moved_read = download_port(fixture, moved)
    let old_gone = present_port(fixture, src)
    assert_true(moved_read == payload(text).to_array())
    assert_true(!old_gone)
    let _ = fixture.port.delete(moved) catch {
      error => fail(fixture.label + " cleanup delete raised " + describe(error))
    }
  }
}

///|
fn has_name(names : Array[String], wanted : String) -> Bool {
  let mut found = false
  for name in names {
    if name == wanted {
      found = true
    }
  }
  found
}

///|
async fn save_named(
  fixture : Fixture,
  name : String,
  text : String,
) -> @model.FileInfo {
  let intent = @model.FileInfo::draft(
    fixture.platform,
    fixture.base_path,
    name,
    "txt",
  )
  fixture.service.save(intent, @model.UploadSource::Bytes(payload(text))) catch {
    error =>
      fail(fixture.label + " save " + name + " raised " + describe(error))
  }
}

///|
/// One level, dirs and files split apart, and the prefix filter actually
/// filtering. A platform that lists the whole store instead of one level passes
/// the "contains" assertions by accident, so the negative half matters: the
/// nested object must NOT show up among the files.
async fn case_list_files_round(fixture : Fixture) -> Unit {
  let dir = "contract-listing"
  let a = save_named(fixture, dir + "/a.txt", "aa")
  let b = save_named(fixture, dir + "/b.txt", "bb")
  let deep = save_named(fixture, dir + "/nested/c.txt", "cc")
  let path = fixture.base_path + "/" + dir
  let page = fixture.port.list_files(path, "", None) catch {
    error => fail(fixture.label + " list_files raised " + describe(error))
  }
  let file_names : Array[String] = []
  for file in page.files {
    file_names.push(file.name)
    assert_true(!has_name([file.name], "c.txt"))
  }
  let dir_names : Array[String] = []
  for listed in page.dirs {
    dir_names.push(listed.name)
  }
  assert_true(has_name(file_names, "a.txt"))
  assert_true(has_name(file_names, "b.txt"))
  assert_true(has_name(dir_names, "nested"))
  let filtered = fixture.port.list_files(path, "a", None) catch {
    error =>
      fail(fixture.label + " list_files(prefix) raised " + describe(error))
  }
  assert_eq(filtered.files.length(), 1)
  assert_eq(filtered.files[0].name, "a.txt")
  let _ = remove(fixture, a)
  let _ = remove(fixture, b)
  let after = remove(fixture, deep)
  assert_true(after)
  let left = fixture.port.list_files(path, "", None) catch {
    error =>
      fail(
        fixture.label + " list_files after cleanup raised " + describe(error),
      )
  }
  assert_eq(left.files.length(), 0)
}

///|
pub async fn case_list_files(fixture : Fixture) -> Unit {
  let caps = fixture.service.capabilities(fixture.platform)
  if !caps.list_files {
    let refused = try {
      let _ = fixture.port.list_files(fixture.base_path, "", None)
      "no-error"
    } catch {
      error => describe(error)
    }
    expect_refusal(fixture, "list_files", refused)
  } else {
    case_list_files_round(fixture)
  }
}

///|
/// The ACL claim has to bite on both sides: a storage that says it cannot set an
/// ACL must refuse the call, and one that says it can must take it. Whether the
/// grant really landed is a question for the endpoint, answered by the s3 leg
/// reading the policy document back (`get_object_acl`) rather than by this body.
pub async fn case_acl_claim(fixture : Fixture) -> Unit {
  let caps = fixture.service.capabilities(fixture.platform)
  let info = save_named(fixture, "acl-subject.txt", "acl subject")
  let outcome = try {
    fixture.port.set_file_acl(info, @model.CannedAcl::PublicRead)
    "no-error"
  } catch {
    error => describe(error)
  }
  if caps.acl {
    if outcome != "no-error" {
      let head = fixture.label + " refused an ACL it claims to support: "
      fail(head + outcome)
    }
  } else {
    expect_refusal(fixture, "set_file_acl", outcome)
  }
  let removed = remove(fixture, info)
  assert_true(removed)
}

///|
/// 分片四步在门面上的记录时机，逐条照四个执行器：初始化落一条 INITIATE、完成把
/// 同一行改成 COMPLETE、放弃把整行删掉。参考件的 `FileRecorder` 也没有读分片的入口，
/// 所以"分片子记录写没写"这一档归记录器自己的用例（`part_rows`），这里判的是
/// 门面必须留下的那行主记录。
pub async fn case_multipart_records(fixture : Fixture) -> Unit {
  let caps = fixture.service.capabilities(fixture.platform)
  let draft = @model.FileInfo::draft(
    fixture.platform,
    fixture.base_path,
    object_name("facade-multipart"),
    "txt",
  )
  if !caps.multipart_upload {
    let outcome = try {
      let _ = fixture.service.init_multipart(draft)
      "no-error"
    } catch {
      error => describe(error)
    }
    expect_refusal(fixture, "init_multipart", outcome)
    return
  }
  let staged = fixture.service.init_multipart(draft) catch {
    error => fail(fixture.label + " init_multipart raised " + describe(error))
  }
  assert_eq(staged.upload_status, Some(@model.upload_status_initiate))
  let upload_id = match staged.upload_id {
    Some(id) => id
    None => fail(fixture.label + " init_multipart answered no upload id")
  }
  let opened = row_of(fixture, staged.url)
  match opened {
    None => fail(fixture.label + " kept no record after init_multipart")
    Some(row) =>
      assert_eq(row.upload_status, Some(@model.upload_status_initiate))
  }

  let line = "facade-multipart-padding-012345678901234"
  let line_bytes = payload(line)
  if min_part_bytes % line_bytes.length() != 0 {
    fail("contract fixture: the 5 MiB piece is not a whole number of lines")
  }
  let _ = fixture.service.upload_part(
    staged,
    1,
    @model.UploadSource::Bytes(
      payload(piece(line, min_part_bytes / line_bytes.length())),
    ),
  ) catch {
    error => fail(fixture.label + " upload_part raised " + describe(error))
  }
  let enumerated = fixture.service.list_parts(staged, 0) catch {
    error => fail(fixture.label + " list_parts raised " + describe(error))
  }
  let first_etag = if enumerated.parts.length() > 0 {
    enumerated.parts[0].etag
  } else {
    "(none)"
  }
  let seen = "facade multipart " +
    upload_id +
    " enumerated parts=" +
    enumerated.parts.length().to_string() +
    " first_etag=" +
    first_etag
  println(seen)
  assert_true(enumerated.parts.length() > 0)
  let done = fixture.service.complete_multipart(staged, None) catch {
    error =>
      fail(fixture.label + " complete_multipart raised " + describe(error))
  }
  assert_eq(done.upload_status, Some(@model.upload_status_complete))
  let closed = row_of(fixture, done.url)
  match closed {
    None => fail(fixture.label + " lost its row across complete_multipart")
    Some(row) => {
      assert_eq(row.upload_status, Some(@model.upload_status_complete))
      // 会话号要留在改过的那一行上：完成之后清分片子记录用的就是它。
      match row.upload_id {
        Some(id) => assert_eq(id, upload_id)
        None => fail(fixture.label + " dropped the upload id on update")
      }
    }
  }
  // 放弃那一档另开一个会话：参考件的 abort 是 `deleteFilePartByUploadId` 加
  // `delete(url)`，两个会话共用同一 url 会把刚完成那条的账一起删掉——那是参考件
  // 自己的行为，不是本用例要判的事。
  let doomed_draft = @model.FileInfo::draft(
    fixture.platform,
    fixture.base_path,
    object_name("facade-abort"),
    "txt",
  )
  let doomed = fixture.service.init_multipart(doomed_draft) catch {
    error =>
      fail(fixture.label + " second init_multipart raised " + describe(error))
  }
  let _ = fixture.service.abort_multipart(doomed) catch {
    error => fail(fixture.label + " abort_multipart raised " + describe(error))
  }
  let gone = row_of(fixture, doomed.url)
  match gone {
    None => ()
    Some(row) => {
      let head = "abort left a record for " + row.url
      fail(fixture.label + " " + head)
    }
  }
  let removed = remove(fixture, done)
  assert_true(removed)
}

///|
/// 复制：目标记录描述的是同一份字节，源不许动，同一路径要拦。
/// 走平台自己那一路还是走通用那一路由能力位决定，两条都要给出同样的结果——
/// 这正是"同平台复制只是优化"这句话的判据形状（参考件 `isSameCopy` 也只这么用）。
pub async fn case_copy(fixture : Fixture) -> Unit {
  let text = "copied payload for " + fixture.label
  let src = save_bytes(fixture, "copy-src", text)
  let dest_name = object_name("copy-dest")
  let draft = @model.FileInfo::draft(
    fixture.platform,
    fixture.base_path,
    dest_name,
    "txt",
  )
  let copied = fixture.service.copy(src, draft) catch {
    error => fail(fixture.label + " copy raised " + describe(error))
  }
  assert_eq(copied.url, url_of(fixture, dest_name))
  assert_eq(copied.original_filename, src.original_filename)
  let size = copied.size.unwrap_or(-1L)
  assert_eq(size, payload(text).length().to_int64())
  let read = read_back(fixture, copied)
  assert_true(read == payload(text).to_array())
  // 复制不动源：这一条挂了就说明"复制"被实现成了"移动"。
  assert_true(is_present(fixture, src))
  let from_copy = lookup(fixture, copied.url)
  assert_true(from_copy is Some(_))

  let collide = @model.FileInfo::draft(
    fixture.platform,
    fixture.base_path,
    src.filename,
    "txt",
  )
  let refused = try {
    let _ = fixture.service.copy(src, collide)
    "no-error"
  } catch {
    error => describe(error)
  }
  if !refused.has_prefix("InvalidInput") {
    let head = fixture.label + " copied an object onto itself with "
    fail(head + refused)
  }
  let removed = remove(fixture, copied)
  assert_true(removed)
  let last = remove(fixture, src)
  assert_true(last)
}

///|
/// 移动：目标就位、源消失、两条记录各归各位。
/// 强制 SAME 档而存储没有这一族时必须响亮地拒——参考件 `isSameCopy` 里
/// `MoveMode.SAME` 那一支就是抛。
pub async fn case_move(fixture : Fixture) -> Unit {
  let text = "moved payload for " + fixture.label
  let src = save_bytes(fixture, "move-src", text)
  let dest_name = object_name("move-dest")
  let draft = @model.FileInfo::draft(
    fixture.platform,
    fixture.base_path,
    dest_name,
    "txt",
  )
  let caps = fixture.service.capabilities(fixture.platform)
  let moved = fixture.service.move_file(src, draft) catch {
    error => fail(fixture.label + " move_file raised " + describe(error))
  }
  assert_eq(moved.url, url_of(fixture, dest_name))
  let read = read_back(fixture, moved)
  assert_true(read == payload(text).to_array())
  // 移动之后源既不在这儿也没记录：与复制那一档的区别就靠这两条钉住。
  assert_true(!is_present(fixture, src))
  let old_row = lookup(fixture, src.url)
  assert_true(old_row is None)
  let last = remove(fixture, moved)
  assert_true(last)

  if !caps.same_move {
    let forced = @model.FileInfo::draft(
      fixture.platform,
      fixture.base_path,
      object_name("move-forced"),
      "txt",
    )
    let source = save_bytes(fixture, "move-forced-src", text)
    let refused = try {
      let _ = fixture.service.move_file(
        source,
        forced,
        mode=@model.MoveMode::Same,
      )
      "no-error"
    } catch {
      error => describe(error)
    }
    if !refused.has_prefix("NotSupported") {
      let head = fixture.label + " took a forced same-platform move it claims"
      fail(head + " it has not: " + refused)
    }
    let cleaned = remove(fixture, source)
    assert_true(cleaned)
  }
}

///|
/// 门面在"这个存储不做这一族"时给的是**空值**（`None` / `false`），不是抛——
/// 照参考件：`listFiles` 回 notSupport、`generatePresignedUrl` 回 null、
/// `setFileAcl` 回 false。声称做却给不出值，才算红。
pub async fn case_facade_declines_or_delivers(fixture : Fixture) -> Unit {
  let caps = fixture.service.capabilities(fixture.platform)
  // 三档都用同一个**真对象**判：draft 的 path 是空串，S3 那一侧会当成"没给 key"
  // 拒掉，拿那种输入判"门面给不给得出 URL"判的是输入形状而不是能力位。
  let subject = save_bytes(fixture, "facade-declines", "facade decline payload")
  let presigned = fixture.service.presigned_url(
    subject,
    @model.PresignMethod::Get,
    60,
  ) catch {
    error => fail(fixture.label + " presigned_url raised " + describe(error))
  }
  match (caps.presigned_url, presigned) {
    (true, None) => fail(fixture.label + " claims presigned urls and gave none")
    (false, Some(text)) => {
      let head = "issued a presigned url from a storage that claims none: "
      fail(fixture.label + " " + head + text)
    }
    _ => ()
  }
  // 声称能列的那一档要真看得见刚写下的对象——只判"回没回东西"会被一张空页蒙过去。
  let page = fixture.service.list_files(
    fixture.platform,
    fixture.base_path,
    object_name("facade-declines"),
    None,
  ) catch {
    error => fail(fixture.label + " list_files raised " + describe(error))
  }
  match (caps.list_files, page) {
    (true, None) => fail(fixture.label + " claims listing and gave none")
    (true, Some(rows)) => {
      let names : Array[String] = []
      for file in rows.files {
        names.push(file.name)
      }
      if !has_name(names, object_name("facade-declines")) {
        let head = "listing claimed by " +
          fixture.label +
          " missed the object: "
        fail(head + names.join(", "))
      }
    }
    (false, Some(rows)) => {
      let head = "listed from a storage that claims no listing: "
      let n = rows.files.length().to_string()
      fail(fixture.label + " " + head + n + " file(s)")
    }
    (false, None) => ()
  }
  let accepted = fixture.service.set_file_acl(
    subject,
    @model.CannedAcl::PublicRead,
  ) catch {
    error => fail(fixture.label + " set_file_acl raised " + describe(error))
  }
  if accepted != caps.acl {
    let head = "set_file_acl answered " + accepted.to_string() + " while acl="
    fail(fixture.label + " " + head + caps.acl.to_string())
  }
  let removed = remove(fixture, subject)
  assert_true(removed)
}

///|
/// The whole contract, one call per platform.
pub async fn run_contract(fixture : Fixture) -> Unit {
  case_round_trip(fixture)
  case_stream_upload(fixture)
  case_absent(fixture)
  case_metadata_claim(fixture)
  case_multipart(fixture)
  case_presigned_url(fixture)
  case_same_copy_move(fixture)
  case_list_files(fixture)
  case_acl_claim(fixture)
  case_multipart_records(fixture)
  case_copy(fixture)
  case_move(fixture)
  case_facade_declines_or_delivers(fixture)
}
