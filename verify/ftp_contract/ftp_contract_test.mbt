///|
// 第七条契约腿：FTP（一次性自建的 vsftpd 容器）跑同一份契约正文。
//
// 与前六条不同的两点，都在这里说清而不是藏在适配层：
//   - 这一腿需要一个真 FTP 服务端（本仓不给起服务端的脚本，任一 vsftpd 实例都行），环境不齐就响亮跳过；
//   - 它的能力位是四档关（分片／预签名／ACL／同平台复制）＋`metadata` 关，所以正文里
//     那几族走的是"必须响亮拒绝"那一臂，`presigned_markers` 给空数组。

///|
fn env_or(name : String) -> String {
  @env.get_env_var(name).unwrap_or("")
}

///|
/// 四项齐了才跑：主机、用户、口令，外加一个"这轮是谁"的号（避免和上一轮的残留混谈）。
fn live_env() -> (String, String, String, String)? {
  let host = env_or("FTP_HOST")
  let user = env_or("FTP_USER")
  let pass = env_or("FTP_PASS")
  let stamp = env_or("FTP_RUN_TAG")
  if host.is_empty() || user.is_empty() || pass.is_empty() {
    None
  } else {
    Some((host, user, pass, stamp))
  }
}

///|
fn report_skip() -> Unit {
  let missing : Array[String] = []
  for name in ["FTP_HOST", "FTP_USER", "FTP_PASS"] {
    if env_or(name).is_empty() {
      missing.push(name)
    }
  }
  println("SKIP contract/ftp, environment not supplied")
  println("missing: " + missing.join(", "))
  println("SKIP IS NOT A PASS: this platform leg was not verified by this run.")
  println(
    "给它四个 env 就能跑：FTP_HOST / FTP_PORT / FTP_USER / FTP_PASS（外加本轮自命名的 FTP_RUN_TAG）",
  )
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
fn build(host : String, user : String, pass : String) -> @ftp.FtpPlatform {
  let port = env_or("FTP_PORT")
  let addr = if port.is_empty() { host } else { host + ":" + port }
  let given = env_or("FTP_DOMAIN")
  let domain = if given.is_empty() {
    None
  } else {
    println("domain from env: " + given)
    Some(given)
  }
  @ftp.FtpPlatform::new(
    @ftp.FtpPlatformConfig::new("ftp", addr, user, pass, domain~),
  )
}

///|
/// 数一遍这个前缀下还剩几个**文件**（一层，目录不算残留——本轮没往服务端写目录语义）。
async fn count_files(platform : @ftp.FtpPlatform, prefix : String) -> Int32 {
  let page = platform.list_files(prefix, "", None) catch {
    err => fail("residue list: " + storage_text(err))
  }
  page.files.length()
}

///|
/// 契约正文之外多问一句：**嵌套 key 的列举形状**。
///
/// 正文的 `case_list_files` 只在一层里问；FTP 的目录是真的下一级，`dirs` 该由条目类型
/// 给出来。这里建一层 `moonfs-ftp-sub/`，各写一个文件，要求本层 `files` 只含本层那一个、
/// `dirs` 只含那一层子目录，而嵌套那个文件只出现在它自己的目录里——这是 delimiter 语义
/// 在 FTP 上的等价物。子目录的名字**带前缀**是必须的：`filename_prefix` 按参照件那两腿
/// 同形，对目录条目一样生效（不匹配就不该出现），换个名字就变成在测过滤器。
/// 走的都是端口本体（门面那一段正文已经覆盖过）。
async fn nested_listing_proof(
  platform : @ftp.FtpPlatform,
  prefix : String,
) -> Unit {
  let flat_text = "flat subject for the ftp leg"
  let deep_text = "deep subject for the ftp leg"
  let flat = @model.FileInfo::draft("ftp", prefix, "moonfs-ftp-flat.txt", "txt")
  let deep = @model.FileInfo::draft(
    "ftp",
    prefix + "/moonfs-ftp-sub",
    "moonfs-ftp-deep.txt",
    "txt",
  )
  let flat_written = platform.save(
    flat,
    @model.UploadSource::Bytes(@utf8.encode(flat_text)),
  ) catch {
    err => fail("nested proof: flat save raised " + storage_text(err))
  }
  let deep_written = platform.save(
    deep,
    @model.UploadSource::Bytes(@utf8.encode(deep_text)),
  ) catch {
    err => fail("nested proof: deep save raised " + storage_text(err))
  }
  let flat_record = match flat_written {
    Some(one) => one
    None => fail("nested proof: flat save returned no record")
  }
  let deep_record = match deep_written {
    Some(one) => one
    None => fail("nested proof: deep save returned no record")
  }
  // 尺寸是服务端读回来的，不是请求侧的 length
  assert_eq(flat_record.size, Some(flat_text.length().to_int64()))
  let page = platform.list_files(prefix, "moonfs-ftp-", None) catch {
    err => fail("nested proof: list raised " + storage_text(err))
  }
  assert_eq(page.files.length(), 1)
  assert_eq(page.files[0].name, "moonfs-ftp-flat.txt")
  assert_eq(page.dirs.length(), 1)
  assert_eq(page.dirs[0].path, prefix + "/moonfs-ftp-sub/")
  assert_false(page.is_truncated)
  // 深那一层要能在自己的目录里被看见，否则"dirs 有、内容没有"是假绿
  let inner = platform.list_files(prefix + "/moonfs-ftp-sub", "", None) catch {
    err => fail("nested proof: inner list raised " + storage_text(err))
  }
  assert_eq(inner.files.length(), 1)
  assert_eq(inner.files[0].name, "moonfs-ftp-deep.txt")
  // 收口：正文不管的事这里自己删干净，残留复算才只剩"漏了的东西"
  let removed_flat = platform.delete(flat_record) catch {
    err => fail("nested proof: delete flat raised " + storage_text(err))
  }
  let removed_deep = platform.delete(deep_record) catch {
    err => fail("nested proof: delete deep raised " + storage_text(err))
  }
  assert_true(removed_flat)
  assert_true(removed_deep)
}

///|
async fn run_ftp(
  host : String,
  user : String,
  pass : String,
  stamp : String,
) -> Unit {
  let prefix = "moonfs-ftp-contract-" + stamp
  let platform = build(host, user, pass)
  let domain = env_or("FTP_DOMAIN")
  let base = if domain.is_empty() {
    let port = env_or("FTP_PORT")
    "ftp://" + host + (if port.is_empty() { ":21" } else { ":" + port })
  } else if domain[domain.length() - 1:domain.length()] == "/" {
    domain[0:domain.length() - 1].to_owned()
  } else {
    domain
  }
  let root = @fs.tmpdir(prefix="moonfs-contract-ftp") catch {
    err => fail("tmpdir: " + err.to_string())
  }
  let _ = @fs.mkdir(root, recursive=true, allow_exist=true) catch {
    err => fail("mkdir: " + err.to_string())
  }
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root,
  })
  let service = @storage.Service::new([platform], recorder)
  let fixture = @contract.Fixture::{
    label: "ftp",
    platform: "ftp",
    base_path: prefix,
    domain: base,
    service,
    recorder,
    port: platform,
    presigned_markers: [],
  }
  @contract.run_contract(fixture)
  nested_listing_proof(platform, prefix)
  let left = count_files(platform, prefix)
  // 跨实现那一条腿不在这里跑：正文清完，xcheck 那份单独留给 python 取（见 §E 台账）
  let parts = recorder.part_rows() catch {
    err => fail("part_rows: " + storage_text(err))
  }
  let rows = @fs.readdir(root) catch {
    err => fail("readdir: " + err.to_string())
  }
  let _ = @fs.rmdir(root, recursive=true) catch {
    err => println("cleanup " + root + " raised " + err.to_string())
  }
  // 契约把自己写的都删了；这里非 0 就是往服务端漏了正文
  assert_eq(left, 0)
  // 记录器这一腿只剩**一份**主记录（qiniu 那条是两份：主记录 + 分片子记录文件）。
  // FTP 那五步全在拨号之前被拒，分片子记录一次也没落过——这个数就是那件事的读数。
  println("recorder 残留: " + rows.join(", "))
  assert_eq(rows.length(), 1)
  assert_eq(parts.length(), 0)
}

///|
async test "ftp platform walks the shared contract against the one-shot vsftpd container" {
  match live_env() {
    None => report_skip()
    Some(environment) =>
      run_ftp(environment.0, environment.1, environment.2, environment.3)
  }
}

///|
/// 跨实现验证那一份的落点：契约正文删干净之后，这里另外写一条自命名对象，
/// 让 **python `ftplib`** 用另一个实现把它取回来比对字节（正文与适配层同源自证不了这件事）。
/// 传完由这条测试之外的清理步骤删掉，最后把整个卷清干净。
async test "the bytes this adapter writes are readable by another ftp implementation" {
  match live_env() {
    None => report_skip()
    Some(environment) => {
      let platform = build(environment.0, environment.1, environment.2)
      let stamp = environment.3
      let text = "cross-implementation proof for the ftp leg " + stamp
      let info = @model.FileInfo::draft(
        "ftp",
        "moonfs-ftp-xcheck-" + stamp,
        "proof.txt",
        "txt",
      )
      let written = platform.save(
        info,
        @model.UploadSource::Bytes(@utf8.encode(text)),
      ) catch {
        err => fail("xcheck save: " + storage_text(err))
      }
      match written {
        None => fail("xcheck save returned no record")
        Some(one) => {
          assert_eq(one.size, Some(text.length().to_int64()))
          println("xcheck written: moonfs-ftp-xcheck-" + stamp + "/proof.txt")
        }
      }
    }
  }
}
