# mldong/moon-file-storage-s3

S3 与 S3 兼容端点（MinIO、阿里云 / 腾讯云 / 七牛的 S3 兼容层等）的后端适配：把 `mldong/moon-s3`
的客户端接到存储端口上，业务代码不需要知道签名、寻址风格与错误码文档。

## 最小用法

```moonbit
async test "预签名是本地算出来的，不发出请求也能给出可核验的 URL" {
  let client = @sdk.Client::new(
    @sdk.Config::new(
      "https://s3.example.invalid",
      "us-east-1",
      @sigv4.Credentials::new("ak", "sk"),
    ),
    @transport.AsyncHttpTransport::new(),
  )
  let platform = @s3.S3Platform::new(@s3.S3PlatformConfig::{
    platform: "s3-2",
    bucket: "demo-bucket",
    base_path: "",
    supports_acl: false,
    domain: Some("https://cdn.example.invalid/demo-bucket"),
    client,
  })
  let caps = platform.capabilities()
  assert_true(caps.multipart_upload)
  assert_true(caps.presigned_url)
  // 能力位由端点声明：MinIO 那两台的 canned ACL 写入不做，就在这里关掉。
  assert_true(!caps.acl)
  let intent = @model.FileInfo::draft("s3-2", "", "note", "txt")
  let info = intent.stamped(@model.Stamp::{
    platform: None,
    path: Some("2026/10/note.txt"),
    url: Some("https://cdn.example.invalid/demo-bucket/2026/10/note.txt"),
    size: None,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
  let url = platform.presigned_url(info, @model.PresignMethod::Get, 120) catch {
    _ => fail("presigned_url raised on a storage that claims the family")
  }
  assert_true(url.find("X-Amz-Signature=") is Some(_))
  assert_true(url.find("2026/10/note.txt") is Some(_))
}
```

`presigned_url` 里那句"不发请求"是有前提的：签名要算的是 URL 与时间窗，端点是否**接受**这个
免凭据 URL 只能拿真端点测——本轮测过免凭据 PUT 直传成功、把签名末位改一个字符立刻 403。

## 装法

```bash
moon add mldong/moon-file-storage-s3
```

`domain` 给的是这个桶对外的访问前缀，`base_path` 当前不参与寻址（对象与列举都按调用方给的
key/path 定位）。

## 许可

Apache-2.0。
