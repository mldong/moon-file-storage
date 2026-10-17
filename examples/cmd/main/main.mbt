///|
/// 走门面的最小可运行示例（不发布）：真读写走本机磁盘那条腿，零网络。
/// 起法：moon run --target wasm examples/cmd/main
///
/// 每一步都把读数打出来——示例的意义就是"用户照抄能跑出这几行"，所以这里
/// 不打"SDK 已初始化"那种任何实现都能打出来的话。
///
/// 第二条平台是 S3 那一档，只构造不请求（没有可用端点时发请求就是假读数）：
/// 它出现的作用是证明"换一个 Platform 就换一个后端"这件事在门面上是真成立的——
/// `platform_names` 与 `capabilities` 都把它算进去了。

///|
/// `StorageError` carries no `Show` instance in this toolchain, so the reading is
/// spelled out rather than printed through a method that does not exist.
fn describe(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(detail) => "InvalidInput: " + detail
    @model.StorageError::NotSupported(detail) => "NotSupported: " + detail
    @model.StorageError::NotFound(detail) => "NotFound: " + detail
    @model.StorageError::Platform(detail) => "Platform: " + detail
    @model.StorageError::Recorder(detail) => "Recorder: " + detail
  }
}

///|
/// `@io.Writer` 的最低实现只需要 `write_once`；把字节收进数组就够了，
/// 示例不假设调用方用什么落盘。
struct Sink {
  bytes : Array[Byte]
}

///|
pub impl @io.Writer for Sink with fn write_once(
  self,
  data : Bytes,
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
  for index in offset..<(offset + len) {
    let _ = self.bytes.push(data[index])
  }
  len
}

///|
pub extend Sink with @io.Writer::{write, write_once, write_reader}

///|
async fn read_back(
  service : @storage.Service,
  info : @model.FileInfo,
) -> String {
  let sink = Sink::{ bytes: [], }
  service.download(info, sink) catch {
    err => abort("download: " + describe(err))
  }
  @utf8.decode_lossy(Bytes::from_array(sink.bytes))
}

///|
fn s3_platform(bucket : String) -> @s3.S3Platform {
  // 凭据与端点都是占位串：这条腿在这里只用于展示门面按平台名分派，不发出请求。
  let client = @sdk.Client::new(
    @sdk.Config::new(
      "https://s3.example.invalid",
      "us-east-1",
      @sigv4.Credentials::new("example", "example"),
    ),
    @transport.AsyncHttpTransport::new(),
  )
  @s3.S3Platform::new(@s3.S3PlatformConfig::{
    platform: "s3-1",
    bucket,
    base_path: "",
    supports_acl: true,
    domain: Some("https://files.example.invalid/" + bucket),
    client,
  })
}

///|
/// 第三条平台是七牛原生 Kodo 那一档，同样只构造不请求。它在这里的作用是
/// 把"能力位按平台各报各的"这件事演出来：同一个门面里 S3 那条报支持 ACL、
/// 这条报不支持，预签名那条两家都报支持但一家只签 GET——
/// 门面靠这些位分派，不是靠"调调看会不会成功"。
fn qiniu_platform(bucket : String) -> @qiniu.QiniuPlatform {
  let transport = @transport.AsyncHttpTransport::new()
  let region = match @kodoconfig.Region::with_region_id("z0") {
    None => abort("z0 is always constructible")
    Some(one) => one
  }
  let client = @kodo.Client::new(
    transport,
    @kodoauth.Auth::new("example", "example") catch {
      err => abort("auth: " + err.text())
    },
    @kodoconfig.Config::new(region, use_https=true),
    bucket,
  ) catch {
    err => abort("client: " + err.text())
  }
  @qiniu.QiniuPlatform::new(
    @qiniu.QiniuPlatformConfig::new(
      "qiniu-1",
      client,
      transport,
      domain=Some("https://files.example.invalid"),
    ),
  )
}

///|
/// FTP 这一条只演能力位：它的会话是长连接，而示例不发任何真请求——四档 absent 的拒绝
/// 与输入校验都排在拨号之前，所以这里的凭据是假的也不会连出去。
fn ftp_platform() -> @ftp.FtpPlatform {
  @ftp.FtpPlatform::new(
    @ftp.FtpPlatformConfig::new(
      "ftp-1",
      "files.example.invalid",
      "example-user",
      "example-password",
      domain=Some("ftp://files.example.invalid/"),
    ),
  )
}

///|
async fn run(root : String, record_root : String) -> Unit {
  let local_platform = @local.LocalPlatform::new(@local.LocalConfig::{
    platform: "local-1",
    root_dir: root,
    domain: "https://files.example.invalid",
    base_path: "uploads",
  })
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: record_root,
  })
  let platforms : Array[&@platform.Platform] = [
    local_platform,
    s3_platform("example-bucket"),
    qiniu_platform("example-bucket"),
    ftp_platform(),
  ]
  let service = @storage.Service::new(platforms, recorder)

  let names = service.platform_names()
  println("platforms: " + names.join(", "))
  let caps = service.capabilities("local-1") catch {
    err => abort("capabilities: " + describe(err))
  }
  let local_reading = "capabilities: multipart=" +
    caps.multipart_upload.to_string() +
    " list=" +
    caps.list_files.to_string() +
    " presigned=" +
    caps.presigned_url.to_string() +
    " acl=" +
    caps.acl.to_string()
  println(local_reading)
  let s3_caps = service.capabilities("s3-1") catch {
    err => abort("capabilities(s3-1): " + describe(err))
  }
  let s3_reading = "s3-1 presigned=" +
    s3_caps.presigned_url.to_string() +
    " acl=" +
    s3_caps.acl.to_string()
  println(s3_reading)
  let kodo_caps = service.capabilities("qiniu-1") catch {
    err => abort("capabilities(qiniu-1): " + describe(err))
  }
  let kodo_reading = "qiniu-1 presigned=" +
    kodo_caps.presigned_url.to_string() +
    " acl=" +
    kodo_caps.acl.to_string() +
    " metadata=" +
    kodo_caps.metadata.to_string()
  println(kodo_reading)
  let ftp_caps = service.capabilities("ftp-1") catch {
    err => abort("capabilities(ftp-1): " + describe(err))
  }
  let ftp_reading = "ftp-1 list=" +
    ftp_caps.list_files.to_string() +
    " move=" +
    ftp_caps.same_move.to_string() +
    " copy=" +
    ftp_caps.same_copy.to_string() +
    " presigned=" +
    ftp_caps.presigned_url.to_string() +
    " multipart=" +
    ftp_caps.multipart_upload.to_string()
  println(ftp_reading)

  let intent = @model.FileInfo::draft("local-1", "uploads", "hello", "txt")
  let source = @model.UploadSource::Bytes(@utf8.encode("hello from the facade"))
  let saved = service.save(intent, source) catch {
    err => abort("save: " + describe(err))
  }
  let size = saved.size.unwrap_or(-1L)
  println("saved url=" + saved.url + " size=" + size.to_string())

  let here = service.exists(saved) catch {
    err => abort("exists: " + describe(err))
  }
  println("exists: " + here.to_string())

  let text = read_back(service, saved)
  println("download read=" + text)

  let looked = service.get_file(saved.url) catch {
    err => abort("get_file: " + describe(err))
  }
  match looked {
    Some(found) => println("get_file platform=" + found.platform)
    None => abort("get_file returned nothing for a url it just issued")
  }

  let removed = service.delete(saved) catch {
    err => abort("delete: " + describe(err))
  }
  let gone = service.exists(saved) catch {
    err => abort("exists after delete: " + describe(err))
  }
  println("deleted=" + removed.to_string() + " exists_now=" + gone.to_string())
  service.close()
}

///|
async fn main {
  let root = @fs.tmpdir(prefix="moonfs-example") catch {
    err => abort("tmpdir: " + err.to_string())
  }
  let _ = @fs.mkdir(root, recursive=true, allow_exist=true) catch {
    err => abort("mkdir: " + err.to_string())
  }
  run(root, root + "/records")
  let _ = @fs.rmdir(root, recursive=true) catch {
    err => println("cleanup " + root + " raised " + err.to_string())
  }
  println("example finished, workspace removed")
}
