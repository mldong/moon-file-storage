///|
/// The port every storage adapter implements. It carries four families: the
/// object family (`save`/`get_file`/`exists`/`delete`/`download`), the manual
/// multipart family (five steps), the presigned URL family and the same-storage
/// copy/move optimizations. `@model.Capabilities` is how a platform declares
/// which of those it has; a family it declares absent must refuse with
/// `NotSupported` when called, not accept the call and do nothing.
///
/// Multipart steps take the `FileInfo` handed back by `init_multipart` — the
/// session id travels on `FileInfo.upload_id`, the same field the reference
/// framework uses, so a caller can persist it and resume later.
pub(open) trait Platform {
  fn name(Self) -> String
  fn capabilities(Self) -> @model.Capabilities
  async fn save(Self, @model.FileInfo, @model.UploadSource) -> @model.FileInfo? raise @model.StorageError
  async fn get_file(Self, String) -> @model.FileInfo? raise @model.StorageError
  async fn exists(Self, @model.FileInfo) -> Bool raise @model.StorageError
  async fn delete(Self, @model.FileInfo) -> Bool raise @model.StorageError
  async fn download(Self, @model.FileInfo, &@io.Writer) -> Unit raise @model.StorageError

  /// 手动分片-初始化：给出一条半成品对象的 `upload_id`
  async fn init_multipart(Self, @model.FileInfo) -> @model.FileInfo raise @model.StorageError
  /// 手动分片-上传一片：`part_number` 从 1 起，越界要在使用任何请求之前拒掉
  async fn upload_part(Self, @model.FileInfo, Int32, @model.UploadSource) -> @model.FilePartInfo raise @model.StorageError
  /// 手动分片-列举已上传的分片，从 `part_number_marker` 之后取一页
  async fn list_parts(Self, @model.FileInfo, Int32) -> @model.PartPage raise @model.StorageError
  /// 手动分片-完成：按分片号顺序拼成最终对象，回一条可读的 `FileInfo`
  async fn complete_multipart(Self, @model.FileInfo, Array[@model.FilePartInfo]) -> @model.FileInfo raise @model.StorageError
  /// 手动分片-放弃：丢掉已上传的分片，不留下最终对象
  async fn abort_multipart(Self, @model.FileInfo) -> Unit raise @model.StorageError

  /// 预签名 URL：`Get` 给免凭据下载，`Put` 给前端直传；不带凭据的 URL 才叫预签名
  fn presigned_url(Self, @model.FileInfo, @model.PresignMethod, Int32) -> String raise @model.StorageError

  /// 同存储平台复制：源必须是本平台的既有对象，缺失报 `NotFound`
  async fn same_copy(Self, @model.FileInfo, @model.FileInfo) -> @model.FileInfo raise @model.StorageError
  /// 同存储平台移动：复制成功后源不再存在
  async fn same_move(Self, @model.FileInfo, @model.FileInfo) -> @model.FileInfo raise @model.StorageError
  /// 列举单层目录：`path` 与 `exists`/`delete` 同一坐标系（local 相对根目录、对象存储相对桶），
  /// `filename_prefix` 交给服务端前缀承担，`marker` 是上一页的续页符
  async fn list_files(Self, String, String, String?) -> @model.FileListing raise @model.StorageError
  /// 设置对象级 canned ACL。参考件对不认识的 ACL 值返回 false，这里那种值根本构造不出来
  async fn set_file_acl(Self, @model.FileInfo, @model.CannedAcl) -> Unit raise @model.StorageError
  fn close(Self) -> Unit
}
