///|
/// FTP 适配层需要的环境。
///
/// 这里不复制 `base_path`：对象位置一律由 `FileInfo.base_path` 与 `list_files` 的
/// `path` 决定（与 `@model.object_key` 同一把尺），平台侧再放一份只会让"写在哪"与
/// "读在哪"有两个答案。
///
/// 口令是明文字段：这个端口族没有"存凭据"的地方，也不派生 `Show`/`ToJson`，
/// 所以它不会自己进日志或进记录——但调用方把它读出来之后往哪儿打印，是调用方的事。
pub(all) struct FtpPlatformConfig {
  /// 记录里的平台名（参照件用的是 `ftp`；FTPS 档由调用方起名，比如 `ftps`）
  platform : String
  /// `host` 或 `host:port`；不给端口就走 21（TLS 档也走 21：显式升级不换端口）
  addr : String
  user : String
  password : String
  /// 拼 `FileInfo.url` 的前缀，参照件的形状是 `ftp://host/`（结尾带斜杠）。
  /// 不给就从拨号地址拼一条——FTP 的对象地址是**能从端点算出来的**，
  /// 这一点与 Kodo 不同（那边编一条出来就是打不开的假 URL）。
  domain : String?
  /// 控制连接与数据连接的等待上限
  timeout_ms : Int32
  /// FTPS 开关：true 时控制连接在明文拨入后发 `AUTH TLS` 升级（RFC 4217），
  /// 数据通道由库按 `PROT P` 一并加密。隐式 TLS（990 端口直连握手）没有接：
  /// 现在的 FTPS 服务端几乎都是显式那档，需要隐式时在库的 `dial(tls~)` 上另开。
  tls : Bool
  /// 私有 CA 的 PEM 文件路径；空串 = 系统信任根（wasm 档经运行时宿主走 OS 校验）。
  /// 只在 `tls` 为 true 时被消费。
  trust_pem_file : String
}

///|
pub fn FtpPlatformConfig::new(
  platform : String,
  addr : String,
  user : String,
  password : String,
  domain~ : String? = None,
  timeout~ : Int32 = 15000,
  tls~ : Bool = false,
  trust_pem_file~ : String = "",
) -> FtpPlatformConfig {
  FtpPlatformConfig::{
    platform,
    addr,
    user,
    password,
    domain,
    timeout_ms: timeout,
    tls,
    trust_pem_file,
  }
}
