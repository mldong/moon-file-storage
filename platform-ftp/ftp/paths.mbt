///|
// 坐标系：端口用的 `path` 是"相对根"的 key（与 local 同一把尺），FTP 侧再把它折成
// 服务端能接受的远端路径。FTP 没有命名空间，key 里的 `/` 就是真目录，所以这一层
// 必须自己决定 `..` 与空段的含义——把它交给服务端的 cwd 解释，等于让调用方写出
// 能越出 chroot 的路径。

///|
fn trim_trailing_slash(text : String) -> String {
  let mut end = text.length()
  while end > 0 && text[end - 1] == '/' {
    end = end - 1
  }
  text[0:end].to_owned()
}

///|
/// key 里出现 CR/LF 一律先拒：控制连接是行协议，命令注入的守卫在客户端库里，
/// 但端口这一侧要给出的是 `InvalidInput`，不是隔壁库的错误类型。
fn check_key(key : String) -> Unit raise @model.StorageError {
  if key.find("\r") is Some(_) || key.find("\n") is Some(_) {
    raise @model.StorageError::InvalidInput(
      "ftp key must not contain CR or LF: " + key,
    )
  }
}

///|
/// 折成规范 key：丢掉空段与 `.` 段，拒掉 `..` 段，丢掉首尾斜杠。
fn normalize_key(key : String) -> String raise @model.StorageError {
  check_key(key)
  let parts : Array[String] = []
  for segment in key.split("/") {
    if segment.is_empty() || segment == "." {
      continue
    }
    if segment == ".." {
      raise @model.StorageError::InvalidInput(
        "ftp key must not contain a '..' segment: " + key,
      )
    }
    parts.push(segment.to_owned())
  }
  parts.join("/")
}

///|
/// 服务端要的是绝对路径：登录后 cwd 就是 chroot 根，实测 `CWD /x` 与 `MKD /x` 都认，
/// 而相对路径会随着 cwd 变（本适配层不做 `CWD`，见 `ensure_dir`），所以一律加根。
fn remote_of(key : String) -> String raise @model.StorageError {
  let normalized = normalize_key(key)
  if normalized.is_empty() {
    "/"
  } else {
    "/" + normalized
  }
}

///|
fn last_slash(text : String) -> Int32? {
  let mut found : Int32? = None
  let mut index = text.length() - 1
  while index >= 0 && found is None {
    if text[index] == '/' {
      found = Some(index)
    }
    index = index - 1
  }
  found
}

///|
/// 规范化 key 的目录部分（不带尾斜杠；根下的是空串）。
fn dir_of_key(key : String) -> String raise @model.StorageError {
  let normalized = normalize_key(key)
  match last_slash(normalized) {
    Some(index) => normalized[0:index].to_owned()
    None => ""
  }
}

///|
fn name_of_key(key : String) -> String raise @model.StorageError {
  let normalized = normalize_key(key)
  match last_slash(normalized) {
    Some(index) => normalized[index + 1:].to_owned()
    None => normalized
  }
}

///|
fn ext_of_key(key : String) -> String raise @model.StorageError {
  let name = name_of_key(key)
  let mut found : Int32? = None
  let mut index = name.length() - 1
  while index >= 0 && found is None {
    if name[index] == '.' {
      found = Some(index)
    }
    index = index - 1
  }
  match found {
    Some(index) => name[index + 1:].to_owned()
    None => ""
  }
}

///|
/// 拼 URL 的前缀。没给 `domain` 就从拨号地址算一条——FTP 的对象地址本来就能算出来。
/// IPv6 地址在这里不成立（`ftp://::1` 那种形状要自己加方括号），那种端点请显式给 `domain`。
fn url_base(config : FtpPlatformConfig) -> String {
  match config.domain {
    Some(domain) => trim_trailing_slash(domain)
    None => {
      let bare = trim_trailing_slash(config.addr)
      let with_port = if bare.find(":") is Some(_) {
        bare
      } else {
        bare + ":21"
      }
      "ftp://" + with_port
    }
  }
}

///|
fn url_of(
  config : FtpPlatformConfig,
  key : String,
) -> String raise @model.StorageError {
  url_base(config) + "/" + normalize_key(key)
}

///|
/// 只认本平台前缀下的 URL，别的域名一律不猜。
fn relative_of_url(config : FtpPlatformConfig, url : String) -> String? {
  let prefix = url_base(config) + "/"
  if url.has_prefix(prefix) {
    Some(url[prefix.length():].to_owned())
  } else {
    None
  }
}
