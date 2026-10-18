///|
/// 适配层需要的环境：桶、拼 URL 用的域名，以及已经建好的 SDK 客户端。
///
/// region／endpoint／凭据都不在这里出现：它们属于 `@config.Config`，由调用方在造
/// `@sdk.Client` 时给（凭据是调用方从自家环境拼出来的 `@auth.Credentials`，本仓任何
/// 文件都不带它的值）。适配层再存一份，"这个桶在哪个主机"就有了两个答案。
///
/// 也不复制 `base_path`：对象位置一律由 `FileInfo.base_path` 与 `list_files` 的
/// `path` 决定（与 `@model.object_key` 同一把尺）。`platform-s3` 那位只是不动已发布
/// 的公共形状，新件按 `platform-qiniu` 的口径不带。
pub(all) struct OssPlatformConfig {
  /// 记录里的平台名（参照件用的是 `oss`）
  platform : String
  /// OSS 每条请求都自带桶名（不像 Kodo 把桶钉死在客户端里），所以这一位是真在用
  bucket : String
  /// 拼 `FileInfo.url`、`get_file` 反解 key 的域名。**不给就响亮拒绝**：私有桶的
  /// 虚主机地址不是"能打开的链接"，编一条出来等于往记录里放一条打不开的地址。
  /// 它必须是 SDK 那个虚主机前缀（`https://<桶>.<endpoint>`）或指回同一个桶的 CDN
  /// 域名——`presigned_url` 回的是 SDK 按自家 endpoint 拼的串，两处不一致时契约腿
  /// "预签名 URL 以 domain 开头"那一档会红。
  domain : String?
  client : @sdk.Client
}
