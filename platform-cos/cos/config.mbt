///|
/// 适配层需要的环境：桶、拼 URL 用的域名，以及已经建好的 SDK 客户端。
///
/// region／凭据都不在这里出现：它们属于 `@cosconfig.Config`，由调用方在造
/// `@sdk.Client` 时给（凭据是调用方从自家环境拼出来的 `@cosauth.Credentials`，本仓任何
/// 文件都不带它的值）。适配层再存一份，"这个桶在哪个主机"就有了两个答案。
///
/// 也不复制 `base_path`：对象位置一律由 `FileInfo.base_path` 与 `list_files` 的
/// `path` 决定（与 `@model.object_key` 同一把尺），口径照 `platform-qiniu`／`platform-oss`。
pub(all) struct CosPlatformConfig {
  /// 记录里的平台名（参照件用的是 `cos`）
  platform : String
  /// COS 每条请求都自带桶名（桶名是 `<Name>-<APPID>` 长命名，appid 就在里面），
  /// 所以这一位是真在用，不是装饰
  bucket : String
  /// 拼 `FileInfo.url`、`get_file` 反解 key 的域名。**不给就响亮拒绝**：私有桶的
  /// 虚主机地址不是"能打开的链接"，编一条出来等于往记录里放一条打不开的地址。
  /// 它必须是 SDK 那个虚主机前缀（`https://<桶>.cos.<region>.myqcloud.com`）或指回同一个桶
  /// 且**已在桶侧备案**的自定义域名——原生签名默认把 `Host` 算进去，没备案的域名连不上，
  /// 备案与证书是 owner 那侧的事（阶段 H 卡 §1 第三条与 §7 第 4 条读数）。
  domain : String?
  client : @sdk.Client
}
