///|
/// 适配层需要的环境：桶、拼 URL 用的域名，以及已经建好的 SDK 客户端。
///
/// region／endpoint／凭据都不在这里出现：它们属于 `@config.Config`，由调用方在造
/// `@sdk.Client` 时给（凭据是调用方从自家环境拼出来的 `@auth.Credentials`，本仓任何
/// 文件都不带它的值）。适配层再存一份，"这个桶在哪个主机"就有了两个答案。
///
/// 也不复制 `base_path`：对象位置一律由 `FileInfo.base_path` 与 `list_files` 的
/// `path` 决定（与 `@model.object_key` 同一把尺），口径照 `platform-cos`／`platform-oss`。
pub(all) struct ObsPlatformConfig {
  /// 记录里的平台名（参照件用的是 `obs`）
  platform : String
  /// OBS 每条请求都自带桶名（虚主机寻址把桶拼进主机），所以这一位是真在用
  bucket : String
  /// 拼 `FileInfo.url`、`get_file` 反解 key 的域名。**不给就响亮拒绝**：私有桶的
  /// 虚主机地址不是"能打开的链接"，编一条出来等于往记录里放一条打不开的地址。
  /// 它必须是 SDK 那个虚主机前缀（`https://<桶>.obs.<区域>.myhuaweicloud.com`）——
  /// 原生 V4 签名把 `Host` 算进签名头（`X-Amz-SignedHeaders=host`），预签名串与这个
  /// 域名不一致时，契约腿"预签名 URL 以 domain 开头"那一档会红。
  ///
  /// 自定义域名这一位现在还不能顶，姿势照 `platform-cos` 对 `DOMAIN` 的处理（响亮忽略，
  /// 不默默拿它派生公开 URL）：测试桶上 DNS 已解析、http 能路由进桶（403 是 ACL 的答案），
  /// 但 443 的证书**没绑**那个域名（https 撞 TLS 名称不匹配），而本 SDK 只拼 `https://`。
  /// 证书绑好之后要不要放开这一位，是一个要动 SDK 公开面的独立改动。
  ///
  /// 一条与 S3 兼容面不同的事实留在这里作数：**原生面允许匿名请求**（裸读回 403
  /// `AccessDenied`，是 ACL 的答案），兼容面才是 `400 NotSupportAnonymous`——所以
  /// `public-read` 对象的公开 URL 在原生面是真能匿名打开的（2026-10-19 真桶实测：
  /// 写 `public-read` 后匿名 GET 200，改回 `private` 又 403）。
  domain : String?
  client : @sdk.Client
}
