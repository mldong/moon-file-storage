///|
/// 适配层需要的环境：桶、拼 URL 用的域名、是否开块级校验，以及已经建好的 SDK 客户端。
///
/// 这里**不复制** `base_path` 那一位——对象位置一律由 `FileInfo.base_path` 与
/// `list_files` 的 `path` 决定（与 `@model.object_key` 同一把尺），平台侧再放一份
/// 只会让"写在哪"与"读在哪"有两个答案。
pub(all) struct QiniuPlatformConfig {
  /// 记录里的平台名（参照件用的是 `qiniu`）
  platform : String
  /// 只作读数与自证用；请求侧的桶在 `client` 里，两处不一致会当场报红
  bucket : String
  /// 拼 `FileInfo.url` 与私有下载 URL 的域名。**不给就没有 URL**：
  /// 七牛的回包里没有可公开打开的链接，编一条出来等于在记录里放一条打不开的地址
  domain : String?
  /// `check_crc` 默认 false（照参照件 `UploadOptions.checkCrc`）；开着时表单侧带整份
  /// crc32、分块侧逐块比 md5，不等就在合并之前抛
  check_crc : Bool
  client : @sdk.Client
  /// 只为 `download` 留着：取对象字节走的是"GET 那条签名过的 URL"，不是 Kodo 的 API
  transport : &@transport.Transport
}

///|
pub fn QiniuPlatformConfig::new(
  platform : String,
  client : @sdk.Client,
  transport : &@transport.Transport,
  domain~ : String? = None,
  check_crc~ : Bool = false,
) -> QiniuPlatformConfig {
  QiniuPlatformConfig::{
    platform,
    bucket: client.bucket(),
    domain,
    check_crc,
    client,
    transport,
  }
}
