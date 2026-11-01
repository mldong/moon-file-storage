///|
/// 离线判据：只打纯函数那一层——坐标折算、错误分档、URL 往返。这些不需要网络，
/// 也不需要假凭据拨一条注定连不上的连接。
///
/// 白盒件拿不到 `for "test"` 那一份 import（工具链的现状），所以这里全是同步用例。

///|
suberror ProbeOpaque {
  Opaque(String)
}

///|
/// 造一条不属于 FTP 错误族的失败：适配层要把它归到"传输那一档"，而不是当服务端的回答。
fn opaque_error(text : String) -> Error {
  let raised = try {
    raise ProbeOpaque::Opaque(text)
  } catch {
    err => err
  }
  raised
}

///|
fn storage_text(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(d) => "InvalidInput: " + d
    @model.StorageError::NotSupported(d) => "NotSupported: " + d
    @model.StorageError::NotFound(d) => "NotFound: " + d
    @model.StorageError::Platform(d) => "Platform: " + d
    @model.StorageError::Recorder(d) => "Recorder: " + d
  }
}

///|
test "normalize_key folds the harmless segments and refuses the load-bearing ones" {
  assert_eq(normalize_key("a//b/./c/"), "a/b/c")
  assert_eq(normalize_key("/2026/10/note.txt"), "2026/10/note.txt")
  assert_eq(normalize_key(""), "")
  let up = try {
    let _ = normalize_key("a/../b")
    "no-error"
  } catch {
    err => storage_text(err)
  }
  assert_true(
    up.has_prefix("InvalidInput: ftp key must not contain a '..' segment"),
  )
  let crlf = try {
    let _ = normalize_key("a\rb")
    "no-error"
  } catch {
    err => storage_text(err)
  }
  assert_true(
    crlf.has_prefix("InvalidInput: ftp key must not contain CR or LF"),
  )
}

///|
test "remote_of always yields an absolute path and the three parts split without loss" {
  assert_eq(remote_of("2026/10/note.txt"), "/2026/10/note.txt")
  assert_eq(remote_of(""), "/")
  assert_eq(dir_of_key("2026/10/note.txt"), "2026/10")
  assert_eq(name_of_key("2026/10/note.txt"), "note.txt")
  assert_eq(ext_of_key("2026/10/note.txt"), "txt")
  // 根下的对象没有目录部分；没有点的路径 ext 是空串而不是整名
  assert_eq(dir_of_key("note.txt"), "")
  assert_eq(name_of_key("note"), "note")
  assert_eq(ext_of_key("note"), "")
  // 扩展名只看文件名那一段：`a.b/archive` 的文件名是 `archive`，没有点
  assert_eq(ext_of_key("a.b/archive"), "")
  assert_eq(ext_of_key("a.b/note.tar.gz"), "gz")
}

///|
test "url_of synthesizes an openable address when no domain was given" {
  let bare = FtpPlatformConfig::new("ftp-1", "192.0.2.1", "u", "p")
  assert_eq(url_base(bare), "ftp://192.0.2.1:21")
  assert_eq(
    url_of(bare, "2026/10/note.txt"),
    "ftp://192.0.2.1:21/2026/10/note.txt",
  )
  let given = FtpPlatformConfig::new(
    "ftp-1",
    "192.0.2.1",
    "u",
    "p",
    domain=Some("ftp://files.example.invalid/"),
  )
  assert_eq(url_of(given, "a/b.txt"), "ftp://files.example.invalid/a/b.txt")
  // 往返：拼出去的 URL 要能原样折回 key，别的域名一律不猜
  let back = relative_of_url(given, "ftp://files.example.invalid/a/b.txt")
  assert_eq(back, Some("a/b.txt"))
  assert_eq(relative_of_url(given, "https://other.invalid/a/b.txt"), None)
  assert_eq(relative_of_url(bare, url_of(bare, "x/y.txt")), Some("x/y.txt"))
}

///|
test "is_absent takes only the three FTP codes that mean 'not there'" {
  for code in [550, 551, 553] {
    assert_true(
      is_absent(@ftplib.FtpError::ServerError(code~, msg="no such thing")),
    )
  }
  for code in [425, 450, 530, 230] {
    assert_false(
      is_absent(@ftplib.FtpError::ServerError(code~, msg="other answer")),
    )
  }
  assert_false(is_absent(opaque_error("socket said no")))
}

///|
test "map_error folds the library's families into the port's five buckets" {
  let server = map_error(
    @ftplib.FtpError::ServerError(code=550, msg="Could not get file size."),
  )
  // 服务端的码要留在文案里：排查时这句比任何归一都有用
  assert_eq(storage_text(server), "Platform: ftp 550: Could not get file size.")
  let injection = map_error(@ftplib.FtpError::InvalidCommand(arg="a\rb"))
  assert_true(
    storage_text(injection).has_prefix("InvalidInput: ftp command refused"),
  )
  let timeout = map_error(@ftplib.FtpError::RequestTimeout)
  assert_eq(storage_text(timeout), "Platform: ftp timeout")
  let other = map_error(opaque_error("connection refused"))
  assert_true(storage_text(other).has_prefix("Platform: ftp transport"))
}

///|
test "an aggregated library error is read through its first mappable member" {
  let joined = @ftplib.FtpErrors::MultipleErrors(errors=[
    @ftplib.FtpError::ServerError(code=550, msg="first answer"),
    @ftplib.FtpError::RequestTimeout,
  ])
  let mapped = storage_text(map_error(joined))
  assert_true(mapped.has_prefix("Platform: ftp 550"))
}

///|
test "the tls flag resolves the trust root and swaps the url scheme" {
  let plain = FtpPlatformConfig::new("ftp", "192.0.2.1", "u", "p")
  assert_false(plain.tls)
  let plain_root = match trust_root(plain) {
    @tls.TrustedRoot::SystemRoot => true
    _ => false
  }
  assert_true(plain_root)
  assert_eq(url_base(plain), "ftp://192.0.2.1:21")
  let tls = FtpPlatformConfig::new(
    "ftps",
    "192.0.2.1",
    "u",
    "p",
    tls=true,
    trust_pem_file="C:/ca/root.pem",
  )
  let given_path : String? = match trust_root(tls) {
    @tls.TrustedRoot::CustomPemFile(path) => Some(path)
    _ => None
  }
  assert_eq(given_path, Some("C:/ca/root.pem"))
  // 显式升级不换端口：缺省端口两种档都是 21，scheme 换成 ftps
  assert_eq(url_base(tls), "ftps://192.0.2.1:21")
  assert_eq(
    url_of(tls, "2026/11/note.txt"),
    "ftps://192.0.2.1:21/2026/11/note.txt",
  )
  // 拼出去的要能原样折回 key，往返判据与明文档同一把尺
  assert_eq(relative_of_url(tls, url_of(tls, "x/y.txt")), Some("x/y.txt"))
  assert_eq(relative_of_url(tls, "ftp://192.0.2.1:21/x/y.txt"), None)
  // 给了 domain 就照原样用：scheme 由调用方的那条串说了算
  let given = FtpPlatformConfig::new(
    "ftps",
    "192.0.2.1",
    "u",
    "p",
    domain=Some("ftps://files.example.invalid/"),
    tls=true,
  )
  assert_eq(url_base(given), "ftps://files.example.invalid")
  // 不给 PEM 就落回系统信任根
  let system = FtpPlatformConfig::new("ftps", "192.0.2.1", "u", "p", tls=true)
  let system_root = match trust_root(system) {
    @tls.TrustedRoot::SystemRoot => true
    _ => false
  }
  assert_true(system_root)
}
