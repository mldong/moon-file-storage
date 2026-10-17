///|
/// The reference framework hands `save` a half-filled `FileInfo` and lets the
/// platform stamp the storage-specific fields. Building that draft from outside
/// means writing all 26 fields, so the empty-but-valid shape and the **single**
/// field-copy helper live here — MoonBit has no record-update syntax in this
/// version, and every layer that stamps a field would otherwise repeat the copy.

///|
pub fn FileInfo::draft(
  platform : String,
  base_path : String,
  filename : String,
  ext : String,
) -> FileInfo {
  {
    id: None,
    url: "",
    size: None,
    filename,
    original_filename: filename,
    base_path,
    path: "",
    ext,
    content_type: None,
    platform,
    th_url: None,
    th_filename: None,
    th_size: None,
    th_content_type: None,
    object_id: None,
    object_type: None,
    metadata: Map([]),
    user_metadata: Map([]),
    th_metadata: Map([]),
    th_user_metadata: Map([]),
    attr: Map([]),
    file_acl: None,
    th_file_acl: None,
    hash_info: None,
    upload_id: None,
    upload_status: None,
    create_time: 0L,
  }
}

///|
/// Fields a storage or the facade may overwrite after a write. Absent means
/// "keep what the receiver had".
pub(all) struct Stamp {
  platform : String?
  path : String?
  url : String?
  size : Int64?
  create_time : Int64?
  /// 分片上传会话号：`init_multipart` 打进去，后续四步都从 `FileInfo` 上取回来
  upload_id : String?
  /// 分片上传进行到哪一步（`upload_status_initiate` / `upload_status_complete`）：
  /// 只有门面上分片族会写它，普通上传不碰
  upload_status : String?
  /// 覆盖式写入：`None` 保留原值，`Some(map)` 整张替换（存储侧读回的用户元数据
  /// 与调用方给的不在同一张表上，逐键合并会把"存储里没这个键"读成"沿用请求值"）
  user_metadata : Map[String, String]?
}

///|
pub fn FileInfo::stamped(self : FileInfo, stamp : Stamp) -> FileInfo {
  {
    id: self.id,
    url: match stamp.url {
      Some(url) => url
      None => self.url
    },
    size: match stamp.size {
      Some(size) => Some(size)
      None => self.size
    },
    filename: self.filename,
    original_filename: self.original_filename,
    base_path: self.base_path,
    path: match stamp.path {
      Some(path) => path
      None => self.path
    },
    ext: self.ext,
    content_type: self.content_type,
    platform: match stamp.platform {
      Some(platform) => platform
      None => self.platform
    },
    th_url: self.th_url,
    th_filename: self.th_filename,
    th_size: self.th_size,
    th_content_type: self.th_content_type,
    object_id: self.object_id,
    object_type: self.object_type,
    metadata: self.metadata,
    user_metadata: match stamp.user_metadata {
      Some(metadata) => metadata
      None => self.user_metadata
    },
    th_metadata: self.th_metadata,
    th_user_metadata: self.th_user_metadata,
    attr: self.attr,
    file_acl: self.file_acl,
    th_file_acl: self.th_file_acl,
    hash_info: self.hash_info,
    upload_id: match stamp.upload_id {
      Some(upload_id) => Some(upload_id)
      None => self.upload_id
    },
    upload_status: match stamp.upload_status {
      Some(status) => Some(status)
      None => self.upload_status
    },
    create_time: match stamp.create_time {
      Some(time) => time
      None => self.create_time
    },
  }
}

///|
pub fn FileInfo::with_platform(self : FileInfo, platform : String) -> FileInfo {
  self.stamped(Stamp::{
    platform: Some(platform),
    path: None,
    url: None,
    size: None,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
}

///|
pub fn FileInfo::with_upload_status(
  self : FileInfo,
  status : String,
) -> FileInfo {
  self.stamped(Stamp::{
    platform: None,
    path: None,
    url: None,
    size: None,
    create_time: None,
    upload_id: None,
    upload_status: Some(status),
    user_metadata: None,
  })
}

///|
/// The destination record a copy or a move writes. `draft` carries the caller's
/// choices (platform, path, filename, ext); everything that describes **the bytes**
/// comes off the source, and the create time is the moment of the copy — the same
/// field list `CopyActuator.sameCopy` / `MoveActuator.sameMove` build, including
/// `original_filename` (which is the end-user's file name, not the stored one) and
/// the four metadata maps, which are copied rather than aliased so that a later
/// write to one row cannot change the other.
pub fn FileInfo::copy_destination(
  src : FileInfo,
  draft : FileInfo,
  create_time : Int64,
) -> FileInfo {
  {
    id: None,
    url: "",
    size: src.size,
    filename: draft.filename,
    original_filename: src.original_filename,
    base_path: src.base_path,
    path: draft.path,
    ext: draft.ext,
    content_type: src.content_type,
    platform: draft.platform,
    th_url: None,
    th_filename: draft.th_filename,
    th_size: src.th_size,
    th_content_type: src.th_content_type,
    object_id: src.object_id,
    object_type: src.object_type,
    metadata: src.metadata.copy(),
    user_metadata: src.user_metadata.copy(),
    th_metadata: src.th_metadata.copy(),
    th_user_metadata: src.th_user_metadata.copy(),
    attr: src.attr.copy(),
    file_acl: src.file_acl,
    th_file_acl: src.th_file_acl,
    hash_info: src.hash_info,
    upload_id: None,
    upload_status: None,
    create_time,
  }
}

///|
pub fn FileInfo::with_create_time(
  self : FileInfo,
  create_time : Int64,
) -> FileInfo {
  self.stamped(Stamp::{
    platform: None,
    path: None,
    url: None,
    size: None,
    create_time: Some(create_time),
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
}
