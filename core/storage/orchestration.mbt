///|
/// 门面之上的五族编排：端口只回答"这个存储会不会做"，这里负责**做完整的一件事**——
/// 分片要把记录写到哪一步、复制移动要走平台自己的路还是走"取回来再传上去"、
/// 列举与 ACL 在存储不做时该给调用方什么。
///
/// 语义逐条抄参考件 `f7baa6e` 的执行器，偏差只留在结构层，每条写在用到的地方：
/// `InitiateMultipartUploadActuator` / `UploadPartActuator` /
/// `CompleteMultipartUploadActuator` / `AbortMultipartUploadActuator` /
/// `CopyActuator` / `MoveActuator`。

///|
/// `Check.uploadPart` / `completeMultipartUpload` / `abortMultipartUpload` /
/// `listParts` 那四组前置检查在本模型里的对应形状：platform、base_path、path、
/// filename 都是非可选串，"没传"就是空串；会话号与定位键仍是可选。
/// 返回值是会话号，四个调用点都要用它。
fn check_session(
  info : @model.FileInfo,
  action : String,
) -> String raise @model.StorageError {
  let missing = if info.platform.is_empty() {
    "platform"
  } else if info.base_path.is_empty() {
    "base_path"
  } else if info.path.is_empty() {
    "path"
  } else if info.filename.is_empty() {
    "filename"
  } else if info.upload_id is None {
    "upload_id"
  } else {
    ""
  }
  match missing {
    "" => ()
    field => {
      let head = "multipart " + action + " needs " + field + " on FileInfo"
      raise InvalidInput(head)
    }
  }
  match info.upload_id {
    Some(id) => id
    None => ""
  }
}

///|
/// 初始化分片：端口开会话 ⇒ 打上 INITIATE ⇒ 落记录。
///
/// 这一步与对象族的 `save` **故意不同**：参考件 `UploadActuator` 忽略记录器返回的
/// false（东西已经在那儿了，账没记上是另一件事），而 `InitiateMultipartUploadActuator`
/// 在记录没落下时直接抛——因为会话号只活在那条记录里，账没落地等于这一路再也接不上。
pub async fn Service::init_multipart(
  self : Service,
  intent : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  let platform = self.pick(intent.platform)
  let started = platform.init_multipart(intent)
  let staged = started.with_upload_status(@model.upload_status_initiate)
  let recorded = self.recorder.save(staged)
  if !recorded {
    let head = "multipart init: no record was kept for " + staged.url
    raise Recorder(head + ", so the upload id would be unrecoverable")
  }
  staged
}

///|
pub async fn Service::upload_part(
  self : Service,
  info : @model.FileInfo,
  part_number : Int32,
  source : @model.UploadSource,
) -> @model.FilePartInfo raise @model.StorageError {
  let _ = check_session(info, "upload_part")
  let part = self.pick(info.platform).upload_part(info, part_number, source)
  self.recorder.save_file_part(part)
  part
}

///|
pub async fn Service::list_parts(
  self : Service,
  info : @model.FileInfo,
  part_number_marker : Int32,
) -> @model.PartPage raise @model.StorageError {
  let _ = check_session(info, "list_parts")
  self.pick(info.platform).list_parts(info, part_number_marker)
}

///|
/// 完成分片：`parts` 给 `None` 就是"请把这会话的分片列出来再合并"（参考件那句
/// `partInfoList == null && supportInfo.getIsSupportListParts()` 的形状），本库没有
/// 把 list_parts 单独立成一个能力位，所以这条由存储自己回话——它不做列举就报
/// `NotSupported`，比"门面静默给一张空清单"诚实。
///
/// 合并完先落账（update）再清分片子记录，与参考件同序；参考件随后还会把文件下载
/// 一遍重新识别 ContentType 并二次 update，那一步它自己也是 `catch (Exception
/// ignored)`，本库没有 ContentType 探测件，明确不做（不是待办，是没这条能力）。
pub async fn Service::complete_multipart(
  self : Service,
  info : @model.FileInfo,
  parts : Array[@model.FilePartInfo]?,
) -> @model.FileInfo raise @model.StorageError {
  let upload_id = check_session(info, "complete_multipart")
  let platform = self.pick(info.platform)
  let staged = info.with_upload_status(@model.upload_status_complete)
  let given = match parts {
    None => self.list_parts(staged, 0).parts
    Some(list) => list
  }
  let done = platform
    .complete_multipart(staged, given)
    .with_upload_status(@model.upload_status_complete)
  self.recorder.update(done)
  self.recorder.delete_file_part_by_upload_id(upload_id)
  done
}

///|
/// 放弃分片：端口先取消会话，再清子记录、再删那条 INITIATE 的账——顺序照
/// `AbortMultipartUploadActuator`。账删失败不回头去救对象：会话已经没了。
pub async fn Service::abort_multipart(
  self : Service,
  info : @model.FileInfo,
) -> Unit raise @model.StorageError {
  let upload_id = check_session(info, "abort_multipart")
  let platform = self.pick(info.platform)
  platform.abort_multipart(info)
  self.recorder.delete_file_part_by_upload_id(upload_id)
  let _ = self.recorder.delete(info.url)
}

///|
/// 复制与移动共用的目标记录：目标平台没写就是"跟源同一个"，路径与文件名相同要拦
/// （参考件 `CopyActuator.sameCopy` 开头那两条）。
fn destination_draft(
  src : @model.FileInfo,
  dest : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  // 参考件的 pretreatment 里 path 与 basePath 都从源文件起步，调用方只改写想改的
  // 那几格；这里留空就当"沿用源的"，否则 draft 的空串会被当成另一个位置。
  let platform = if dest.platform.is_empty() {
    src.platform
  } else {
    dest.platform
  }
  let path = if dest.path.is_empty() { src.path } else { dest.path }
  if src.path + src.filename == path + dest.filename {
    raise InvalidInput("source and destination are the same path")
  }
  let draft = dest.with_platform(platform)
  let placed = draft.stamped(@model.Stamp::{
    platform: None,
    path: Some(path),
    url: None,
    size: None,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
  @model.FileInfo::copy_destination(src, placed, @date.now_millis())
}

///|
/// 三档分派照 `CopyActuator.isSameCopy` / `MoveActuator.isSameMove`：`Same` 是
/// "必须走平台自己那一路"，存储不做就响亮地拒；`Cross` 永远不走；`Auto`（默认）在
/// 源与目标是同一个存储且该存储有这一族时走平台路径，否则走通用路径。
fn copy_uses_same(
  mode : @model.CopyMode,
  same_platform : Bool,
  supported : Bool,
) -> Bool raise @model.StorageError {
  match mode {
    @model.CopyMode::Same => {
      if !supported {
        raise NotSupported("this storage has no same-platform copy")
      }
      true
    }
    @model.CopyMode::Cross => false
    @model.CopyMode::Auto => same_platform && supported
  }
}

///|
fn move_uses_same(
  mode : @model.MoveMode,
  same_platform : Bool,
  supported : Bool,
) -> Bool raise @model.StorageError {
  match mode {
    @model.MoveMode::Same => {
      if !supported {
        raise NotSupported("this storage has no same-platform move")
      }
      true
    }
    @model.MoveMode::Cross => false
    @model.MoveMode::Auto => same_platform && supported
  }
}

///|
/// 跨平台复制：把源对象取回来再上传。
///
/// 参考件是一边下载一边上传（`Downloader … .inputStream(in -> upload(in, …))`）。
/// 本库改成**经一块盘中转、以流的形式喂给上传**：这一版 async 的 task group 闭包
/// 带不了类型化的 raise，把子任务的错误安全地递出来要在门面里藏一个影子变量，
/// 而"下载侧失败了上传侧还在读"这种半路状态正是最难查的那类。代价是临时盘占一份
/// 对象大小、多一遍 IO；换成 `UploadSource::Stream` 而不是整份读进内存，是为了
/// 不把内存也搭进去。

///|
/// 中转目录是这一支唯一留下的东西：删不掉就报出来，不把它变成第二次失败。
async fn drop_staging(staging : String) -> Unit {
  let _ = @fs.rmdir(staging, recursive=true) catch {
    err => println("cleanup " + staging + " raised " + err.to_string())
  }
}

///|
pub async fn Service::cross_copy(
  self : Service,
  src : @model.FileInfo,
  draft : @model.FileInfo,
) -> @model.FileInfo raise @model.StorageError {
  // 每一步的 await 都只放在函数体的语句位置：这一版 async 里 `catch` 分支与 `if`
  // 分支都不是 await 上下文（编译器报 wanted StorageError / has Error），所以失败
  // 那一支只能直接往上传，**留下一个中转目录不删**。要在这条路上做清理，得先把
  // "分支里能不能异步"这件事解决掉，而不是在门面里塞影子变量。
  let staging = @fs.tmpdir(prefix="moonfs-crosscopy") catch {
    err => raise Platform("cannot make a staging area: " + err.to_string())
  }
  println("cross-copy staging under " + staging)
  let path = staging + "/object"
  let writer = @fs.create(path) catch {
    err => raise Platform("cannot open the staging file: " + err.to_string())
  }
  // 失败就往上传，不在这里兜：兜住要重新抛出就得写 catch-all，而编译器明确提醒
  // catch-all 会把取消一类的运行时错误一起吃掉（fragile_catch_all）。代价是这一条
  // 失败路径上中转文件与中转目录都留着——和本函数顶上那句一起记账的。
  self.download(src, writer)
  let size = writer.size() catch {
    err => {
      writer.close()
      raise Platform("staging file has no size: " + err.to_string())
    }
  }
  writer.close()
  let reader = @fs.open(path, mode=ReadOnly) catch {
    err => raise Platform("cannot read the staging file: " + err.to_string())
  }
  let uploaded = self.save(
    draft,
    @model.UploadSource::Stream(reader, Some(size)),
  )
  reader.close()
  let _ = drop_staging(staging) catch {
    err => println("staging cleanup did not finish: " + err.to_string())
  }
  uploaded
}

///|
/// 复制。同平台那一支走端口的 `same_copy` 并落一条新记录（参考件
/// `_fileStorage.sameCopy(...); _fileRecorder.save(destFileInfo)`），跨平台那一支
/// 走通用上传（记录由 `save` 落）。
pub async fn Service::copy(
  self : Service,
  src : @model.FileInfo,
  dest : @model.FileInfo,
  mode~ : @model.CopyMode = Auto,
) -> @model.FileInfo raise @model.StorageError {
  let draft = destination_draft(src, dest)
  let source = self.pick(src.platform)
  let same_platform = src.platform == draft.platform
  let supported = source.capabilities().same_copy
  if copy_uses_same(mode, same_platform, supported) {
    let copied = source.same_copy(src, draft)
    let recorded = self.recorder.save(copied)
    if !recorded {
      let head = "recorder kept no row for the copy at " + copied.url
      println(head + "; the object is there but unreadable by url")
    }
    copied
  } else {
    self.cross_copy(src, draft)
  }
}

///|
/// `move_file`（`move` 是本语言保留字，参考件旧版 API 就叫 moveFile）。

///|
/// 移动。两支都在"目标已就位"之后清源；**源还在原地就抛，不回头删目标**——参考件
/// `MoveActuator` 两处都是这个语义（"如果源文件删除失败，则表示移动失败"），结果
/// 就是同一份内容在两个位置各留一份，交给调用方处置。把这件事在门面里悄悄回滚掉，
/// 等于把一次可见的失败换成一次不可见的删除。
/// 判据取"源还在不在"而不是 `delete` 的返回值，原因写在下面那句注释里。
pub async fn Service::move_file(
  self : Service,
  src : @model.FileInfo,
  dest : @model.FileInfo,
  mode~ : @model.MoveMode = Auto,
) -> @model.FileInfo raise @model.StorageError {
  let draft = destination_draft(src, dest)
  let source = self.pick(src.platform)
  let same_platform = src.platform == draft.platform
  let supported = source.capabilities().same_move
  let moved = if move_uses_same(mode, same_platform, supported) {
    let moved = source.same_move(src, draft)
    let recorded = self.recorder.save(moved)
    if !recorded {
      let head = "recorder kept no row for the move at " + moved.url
      println(head + "; the object is there but unreadable by url")
    }
    moved
  } else {
    // 参考件跨档移动就是"复制，然后删源"，复制那一支自己还会落账。
    self.cross_copy(src, draft)
  }
  // 源必须真的不在这儿了。判据不能用 `delete` 的返回值：参考件走的是 hutool 的
  // `FileUtil.del`，路径不存在时它回 **true**，所以 sameMove 把源搬走之后再删源
  // 一定"成功"；而本库的 `delete` 回答的是"我删掉了一个东西吗"，同平台那一支
  // 走到这里源早就不在了，拿它当失败就成了永真红。清账照旧交给 delete。
  let _ = self.delete(src)
  if self.exists(src) {
    let head = "move left two copies: the source at " +
      src.url +
      " is still there"
    raise Platform(head)
  }
  moved
}

///|
/// 单层列举。存储不做这一族时给 `None`，对应参考件 `listFiles` 在
/// `isSupportListFiles` 为 false 时回空/回 notSupport——不是抛错，因为"这个后端
/// 没有目录视图"是配置事实不是失败。真去列了却报错才往上传。
pub async fn Service::list_files(
  self : Service,
  platform : String,
  path : String,
  filename_prefix : String,
  marker : String?,
) -> @model.FileListing? raise @model.StorageError {
  let target = self.pick(platform)
  if !target.capabilities().list_files {
    None
  } else {
    Some(target.list_files(path, filename_prefix, marker))
  }
}

///|
/// 设置对象 ACL。返回 false ＝ 这个存储不做这件事（参考件 `setFileAcl` 的布尔
/// 语义：不支持、或给了它不认识的值），真去设置而端点出问题则往上传 `StorageError`。
/// 本模型的 ACL 是三档枚举，"不认识的值"在类型上就构造不出来。
pub async fn Service::set_file_acl(
  self : Service,
  info : @model.FileInfo,
  acl : @model.CannedAcl,
) -> Bool raise @model.StorageError {
  let target = self.pick(info.platform)
  if !target.capabilities().acl {
    false
  } else {
    target.set_file_acl(info, acl)
    true
  }
}

///|
/// 预签名 URL：存储没有这一族时给 `None`，对应参考件"无法生成则返回 null"。
pub fn Service::presigned_url(
  self : Service,
  info : @model.FileInfo,
  verb : @model.PresignMethod,
  expires_seconds : Int32,
) -> String? raise @model.StorageError {
  let target = self.pick(info.platform)
  if !target.capabilities().presigned_url {
    None
  } else {
    Some(target.presigned_url(info, verb, expires_seconds))
  }
}
