///|
/// 黑盒侧的负判据：**声明没有的每一族，被调用时必须响亮拒绝**，而且拒绝要发生在
/// 拨号之前。地址一律用 `127.0.0.1:1`——本机没人听这个端口，所以一旦代码真去连，
/// 读数会是 `Platform: ftp transport: …` 而不是 `NotSupported`，两种失败分得开。
///
/// 每一档都写成 `try { let _ = 调用; "no-error" } catch { err => 档位 }`：把返回值丢掉，
/// 判据才只剩"哪一档"。`no-error` 出现在失败信息里就是红灯。

///|
fn text_of(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(d) => "InvalidInput: " + d
    @model.StorageError::NotSupported(d) => "NotSupported: " + d
    @model.StorageError::NotFound(d) => "NotFound: " + d
    @model.StorageError::Platform(d) => "Platform: " + d
    @model.StorageError::Recorder(d) => "Recorder: " + d
  }
}

///|
fn unreachable_config() -> @ftp.FtpPlatformConfig {
  @ftp.FtpPlatformConfig::new(
    "ftp-1",
    "127.0.0.1:1",
    "nobody",
    "never-dialed",
    timeout=2000,
  )
}

///|
fn draft(filename : String) -> @model.FileInfo {
  @model.FileInfo::draft("ftp-1", "", filename, "txt")
}

///|
fn bytes(text : String) -> @model.UploadSource {
  @model.UploadSource::Bytes(@utf8.encode(text))
}

///|
fn stamped_path(info : @model.FileInfo, path : String) -> @model.FileInfo {
  info.stamped(@model.Stamp::{
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
fn assert_refused(step : String, family : String) -> Unit raise {
  assert_true(step.has_prefix("NotSupported: ftp has no " + family))
  // 任何一步退化成连接失败，就说明"这一族没有"被"连不上"顶掉了
  assert_false(step.has_prefix("Platform: ftp transport"))
}

///|
test "ftp platform self-reports the four families it does not have" {
  let platform = @ftp.FtpPlatform::new(unreachable_config())
  assert_eq(platform.name(), "ftp-1")
  let caps = platform.capabilities()
  assert_false(caps.multipart_upload)
  assert_false(caps.presigned_url)
  assert_false(caps.acl)
  assert_false(caps.metadata)
  assert_false(caps.same_copy)
  assert_true(caps.list_files)
  assert_true(caps.same_move)
}

///|
async test "the absent families refuse before any connection is made" {
  let platform = @ftp.FtpPlatform::new(unreachable_config())
  let presigned = try {
    let _ = platform.presigned_url(draft("note"), @model.PresignMethod::Get, 60)
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_refused(presigned, "presigned url family")
  let initiated = try {
    let _ = platform.init_multipart(draft("note"))
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_refused(initiated, "multipart upload family")
  let parted = try {
    let _ = platform.upload_part(draft("note"), 1, bytes("x"))
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_refused(parted, "multipart upload family")
  let listed = try {
    let _ = platform.list_parts(draft("note"), 0)
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_refused(listed, "multipart upload family")
  let completed = try {
    let _ = platform.complete_multipart(draft("note"), [])
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_refused(completed, "multipart upload family")
  let aborted = try {
    let _ = platform.abort_multipart(draft("note"))
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_refused(aborted, "multipart upload family")
  let copied = try {
    let _ = platform.same_copy(draft("src"), draft("dst"))
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_refused(copied, "same-platform copy family")
  let acl = try {
    let _ = platform.set_file_acl(draft("note"), @model.CannedAcl::PublicRead)
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_refused(acl, "canned acl family")
}

///|
async test "a closed platform refuses instead of quietly redialing" {
  let platform = @ftp.FtpPlatform::new(unreachable_config())
  platform.close()
  let exists = try {
    let _ = platform.exists(stamped_path(draft("note"), "note.txt"))
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_eq(exists, "InvalidInput: ftp platform is closed")
  let saved = try {
    let _ = platform.save(stamped_path(draft("note"), "note.txt"), bytes("x"))
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_eq(saved, "InvalidInput: ftp platform is closed")
}

///|
async test "the request shape is checked before the endpoint is touched" {
  let platform = @ftp.FtpPlatform::new(unreachable_config())
  let no_name = try {
    let _ = platform.save(draft(""), bytes("x"))
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_eq(no_name, "InvalidInput: ftp save needs a filename")
  // 本地路径这一档在 FTP 上没有对应做法：不拨号、不读写，直接拒
  let from_path = try {
    let _ = platform.save(
      draft("note"),
      @model.UploadSource::Path("/tmp/note.txt"),
    )
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_true(from_path.has_prefix("NotSupported: ftp save from a local path"))
  let no_path = try {
    let _ = platform.delete(draft("note"))
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_eq(no_path, "InvalidInput: ftp object needs a path")
  let up = try {
    let _ = platform.exists(stamped_path(draft("note"), "a/../b/note.txt"))
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_true(up.has_prefix("InvalidInput: ftp key must not contain"))
  let crlf = try {
    let _ = platform.exists(
      stamped_path(draft("note"), "a/b" + "\r" + "note.txt"),
    )
    "no-error"
  } catch {
    err => text_of(err)
  }
  assert_true(
    crlf.has_prefix("InvalidInput: ftp key must not contain CR or LF"),
  )
}
