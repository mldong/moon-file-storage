///|
pub(all) struct S3PlatformConfig {
  platform : String
  bucket : String
  /// 当前未参与寻址：对象与列举都按调用方给的 key/path 定位（`FileInfo.base_path`
  /// 与 `list_files` 的 `path`）。留着是因为删它是公共形状变更，与本轮判据无关。
  base_path : String
  /// canned ACL 这一族**由端点决定**能不能写：两台 MinIO（共享 :9000 与自起的
  /// RELEASE.2025-09-07）实测 `PUT /key?acl` 回 501 NotImplemented，而同一请求
  /// 换错密钥回 403 SignatureDoesNotMatch（⇒ 请求形状与签名都没问题，是端点不做
  /// 该操作）；`GET /key?acl` 则是通的。AWS S3 支持写，故默认 true，
  /// 由接入方按自家端点关掉。
  supports_acl : Bool
  domain : String?
  client : @sdk.Client
}
