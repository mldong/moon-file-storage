///|
/// FTP 没有错误命名空间：服务端只给三位数加一行话。
///
/// 这里把 550/551/553 认成"不存在"，是因为 vsftpd 3.0.3 对"进不去的目录""读不到的
/// 文件""删不掉的文件"回的是同一族码，而端口要的是"没有就返回 `false`/`None`"。
/// 代价写在 README：**权限错会被读成不存在**，这一腿不证两档可分。
fn is_absent(error : Error) -> Bool {
  match error {
    @ftplib.FtpError::ServerError(code=c, msg=_) =>
      c == 550 || c == 551 || c == 553
    _ => false
  }
}

///|
/// 客户端库的错误族折进端口的五档。`Platform` 那一档把服务端的码原样带在文案里，
/// 不折叠成"平台错了"了事——排查时那句"550 Could not get file size"比什么都值钱。
fn map_error(error : Error) -> @model.StorageError {
  match error {
    @ftplib.FtpError::InvalidCommand(arg=a) =>
      @model.StorageError::InvalidInput("ftp command refused: " + a)
    @ftplib.FtpError::UnsupportedListLine(line=l) =>
      @model.StorageError::Platform("ftp list line: " + l)
    @ftplib.FtpError::UnsupportedListDate(field=f) =>
      @model.StorageError::Platform("ftp list date: " + f)
    @ftplib.FtpError::ParseError(msg=m) =>
      @model.StorageError::Platform("ftp parse: " + m)
    @ftplib.FtpError::RequestTimeout =>
      @model.StorageError::Platform("ftp timeout")
    @ftplib.FtpError::ServerError(code=c, msg=m) =>
      @model.StorageError::Platform("ftp " + c.to_string() + ": " + m)
    // 一次操作聚合成多条时，取第一条能落进上面这些档的：`to_string()` 只打到构造子名，
    // 整串打出来没有读数（实测："PaiGack/ftp.FtpErrors"）。
    @ftplib.FtpErrors::MultipleErrors(errors=_) => {
      let flat = @ftplib.flatten_errors(error)
      match flat {
        [] => @model.StorageError::Platform("ftp failed")
        _ => map_error(flat[0])
      }
    }
    // 剩下的是运行时层的（`@socket` 的 OSError、TLS 的读数等），库不包它们
    _ => @model.StorageError::Platform("ftp transport: " + error.to_string())
  }
}
