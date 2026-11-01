///|
// 契约腿：FTPS（显式 AUTH TLS）。
//
// 与明文 FTP 那条腿跑**同一份契约正文**，差别只在配置：`tls=true` 让控制连接在
// 明文拨入后发 `AUTH TLS` 升级（RFC 4217），数据通道由库按 `PROT P` 加密。
// 服务端能力位与明文档相同（协议射程不变），所以正文里那几族走的还是
// "必须响亮拒绝"那一臂，`presigned_markers` 给空数组。
//
// 这一腿需要一个开了 TLS 的 FTP 服务端；环境不齐就响亮跳过，与 qiniu/MinIO 两腿同规。

///|
fn env_or(name : String) -> String {
  @env.get_env_var(name).unwrap_or("")
}

///|
/// 四项齐了才跑：主机、用户、口令，外加一个"这轮是谁"的号（避免和上一轮的残留混谈）。
/// 私有 CA 可选：`FTPS_TRUST_PEM` 给 PEM 文件路径，不给就用系统信任根。
fn live_env() -> (String, String, String, String, String)? {
  let host = env_or("FTPS_HOST")
  let user = env_or("FTPS_USER")
  let pass = env_or("FTPS_PASS")
  let stamp = env_or("FTPS_RUN_TAG")
  let trust_pem = env_or("FTPS_TRUST_PEM")
  if host.is_empty() || user.is_empty() || pass.is_empty() {
    None
  } else {
    Some((host, user, pass, stamp, trust_pem))
  }
}

///|
fn report_skip() -> Unit {
  let missing : Array[String] = []
  for name in ["FTPS_HOST", "FTPS_USER", "FTPS_PASS"] {
    if env_or(name).is_empty() {
      missing.push(name)
    }
  }
  println("SKIP contract/ftps, environment not supplied")
  println("missing: " + missing.join(", "))
  println("SKIP IS NOT A PASS: this platform leg was not verified by this run.")
  println(
    "给它四个 env 就能跑：FTPS_HOST / FTPS_PORT / FTPS_USER / FTPS_PASS（外加本轮自命名的 FTPS_RUN_TAG；私有 CA 另给 FTPS_TRUST_PEM）",
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
fn build(
  host : String,
  user : String,
  pass : String,
  trust_pem : String,
) -> @ftp.FtpPlatform {
  let port = env_or("FTPS_PORT")
  let addr = if port.is_empty() { host } else { host + ":" + port }
  let given = env_or("FTPS_DOMAIN")
  let domain = if given.is_empty() {
    None
  } else {
    println("domain from env: " + given)
    Some(given)
  }
  @ftp.FtpPlatform::new(
    @ftp.FtpPlatformConfig::new(
      "ftps",
      addr,
      user,
      pass,
      domain~,
      tls=true,
      trust_pem_file=trust_pem,
    ),
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
/// 契约正文之外多问一句：**嵌套 key 的列举形状**（与明文 FTP 腿同一份判据）。
async fn nested_listing_proof(
  platform : @ftp.FtpPlatform,
  prefix : String,
) -> Unit {
  let flat_text = "flat subject for the ftps leg"
  let deep_text = "deep subject for the ftps leg"
  let flat = @model.FileInfo::draft(
    "ftps", prefix, "moonfs-ftps-flat.txt", "txt",
  )
  let deep = @model.FileInfo::draft(
    "ftps",
    prefix + "/moonfs-ftps-sub",
    "moonfs-ftps-deep.txt",
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
  let page = platform.list_files(prefix, "moonfs-ftps-", None) catch {
    err => fail("nested proof: list raised " + storage_text(err))
  }
  assert_eq(page.files.length(), 1)
  assert_eq(page.files[0].name, "moonfs-ftps-flat.txt")
  assert_eq(page.dirs.length(), 1)
  assert_eq(page.dirs[0].path, prefix + "/moonfs-ftps-sub/")
  assert_false(page.is_truncated)
  // 深那一层要能在自己的目录里被看见，否则"dirs 有、内容没有"是假绿
  let inner = platform.list_files(prefix + "/moonfs-ftps-sub", "", None) catch {
    err => fail("nested proof: inner list raised " + storage_text(err))
  }
  assert_eq(inner.files.length(), 1)
  assert_eq(inner.files[0].name, "moonfs-ftps-deep.txt")
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
async fn run_ftps(
  host : String,
  user : String,
  pass : String,
  stamp : String,
  trust_pem : String,
) -> Unit {
  let prefix = "moonfs-ftps-contract-" + stamp
  let platform = build(host, user, pass, trust_pem)
  let domain = env_or("FTPS_DOMAIN")
  let base = if domain.is_empty() {
    let port = env_or("FTPS_PORT")
    "ftps://" + host + (if port.is_empty() { ":21" } else { ":" + port })
  } else if domain[domain.length() - 1:domain.length()] == "/" {
    domain[0:domain.length() - 1].to_owned()
  } else {
    domain
  }
  let root = @fs.tmpdir(prefix="moonfs-contract-ftps") catch {
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
    label: "ftps",
    platform: "ftps",
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
  // 跨实现那一条腿不在这里跑：正文清完，xcheck 那份单独留给 python 取
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
  // 记录器这一腿只剩**一份**主记录。FTP 那五步全在拨号之前被拒，分片子记录
  // 一次也没落过——这个数就是那件事的读数（FTPS 的能力位与明文档相同）。
  println("recorder 残留: " + rows.join(", "))
  assert_eq(rows.length(), 1)
  assert_eq(parts.length(), 0)
}

///|
async test "ftps platform walks the shared contract over explicit AUTH TLS" {
  match live_env() {
    None => report_skip()
    Some(environment) =>
      run_ftps(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
      )
  }
}

///|
/// 跨实现验证那一份的落点：契约正文删干净之后，这里另外写一条自命名对象，
/// 让 **python `ftplib`（FTP_TLS）** 用另一个实现把它取回来比对字节。
/// 传完由这条测试之外的清理步骤删掉，最后把整个卷清干净。
async test "the bytes this adapter writes are readable by another ftps implementation" {
  match live_env() {
    None => report_skip()
    Some(environment) => {
      let platform = build(
        environment.0,
        environment.1,
        environment.2,
        environment.4,
      )
      let stamp = environment.3
      let text = "cross-implementation proof for the ftps leg " + stamp
      let info = @model.FileInfo::draft(
        "ftps",
        "moonfs-ftps-xcheck-" + stamp,
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
          println("xcheck written: moonfs-ftps-xcheck-" + stamp + "/proof.txt")
        }
      }
    }
  }
}
