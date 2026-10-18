# mldong/moon-file-storage-oss

阿里云 OSS 的存储端口适配：把 `mldong/moon-oss` 的原生协议客户端（V4 签名、虚主机寻址）
接到 `FileStorage` 端口上，业务代码只面对 `FileInfo`、上传来源与错误分档，不需要知道
`x-oss-*` 头族、`?uploads` 分片链与 `NoSuchKey`。

## 最小用法

```moonbit
async test "能力位报 false 的那一族就地拒绝；预签名是本地算出来的，一条请求都不发" {
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let client = @sdk.Client::new(
    @config.Config::new(
      "https://oss-cn-zhangjiakou.example.invalid",
      "cn-zhangjiakou",
      @auth.Credentials::new("ak", "sk"),
    ),
    transport,
  )
  let platform = @oss.OssPlatform::new(@oss.OssPlatformConfig::{
    platform: "oss",
    bucket: "demo-bucket",
    domain: Some("https://demo-bucket.oss-cn-zhangjiakou.example.invalid"),
    client,
  })
  let caps = platform.capabilities()
  assert_true(caps.multipart_upload)
  assert_true(caps.presigned_url)
  assert_true(caps.metadata)
  // 能力位由实测决定：写 public-read 被桶侧拒 403 AccessDenied，读回的 grant 是 default
  assert_true(!caps.acl)
  let intent = @model.FileInfo::draft("oss", "", "note", "txt")
  let info = intent.stamped(@model.Stamp::{
    platform: None,
    path: Some("2026/10/note.txt"),
    url: Some("https://demo-bucket.oss-cn-zhangjiakou.example.invalid/2026/10/note.txt"),
    size: None,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
  let url = platform.presigned_url(info, @model.PresignMethod::Get, 120) catch {
    _ => fail("presigned_url raised on a storage that claims the family")
  }
  assert_true(url.find("x-oss-signature=") is Some(_))
  assert_true(url.find("2026/10/note.txt") is Some(_))
  let refused = try {
    platform.set_file_acl(info, @model.CannedAcl::PublicRead)
    "no-error"
  } catch {
    @model.StorageError::NotSupported(reason) => "NotSupported:" + reason
    _ => "other"
  }
  assert_true(refused.has_prefix("NotSupported:"))
}
```

`presigned_url` 里那句"不发请求"是有前提的：签名算的是 URL 与时间窗，端点是否**接受**这条
免凭据 URL 只能拿真端点测——本轮测过免凭据 GET 回 200、按 PUT 直传也回 200。

## 装法

```bash
moon add mldong/moon-file-storage-oss
```

本机开发期不是这一条：`mldong/moon-oss` 还没上注册表，而 `moon.mod` 的 `import` 只收
"注册表＋版本"这一种依赖（路径依赖现读报错
`moon.mod only supports versioned registry dependencies in import`），所以隔壁那份
`moon.work` 用 `members` 把 `../../moon-oss` 与 `../core` 挂进来——这是临时的本地 pin，
`moon-oss` 发版后整份删掉，`moon.mod` 里那行 `"mldong/moon-oss@0.1.0"` 一个字都不用改。
本模块也还没进仓根的 `moon.work`（那是另一件事）。

## 用之前要知道的几件事

- `domain` 给的是这个桶对外的访问前缀，且必须是 SDK 那个虚主机地址（或指回同一个桶的
  CDN 域名）：`presigned_url` 回的是 SDK 按自家 endpoint 拼的串，两处不一致时
  "预签名 URL 以 domain 开头"这一档会红。没给 `domain` 就响亮拒绝——私有桶的地址不是
  能打开的链接，编一条出来等于往记录里放一条打不开的地址。
- **canned ACL 这一族报 false**：`x-oss-object-acl: public-read` 被桶侧拒（403
  `AccessDenied / Put public object acl is not allowed`），`private` 才收，而读回来的
  grant 是 `default` 不是 `private`。所以 `set_file_acl` 在发出任何请求之前就抛
  `NotSupported`，不拿一条服务端 403 冒充"这一族做不到"。
- 判"对象不存在"只看 HTTP 状态码 404：真桶的 `HEAD /<key>` 打不存在的键**只有状态码、
  没有 XML 正文**，此时协议层的 `code` 是空串。
- 寻址风格没有开关：OSS 只收虚主机风格（path 风格回 403 `SecondLevelDomainForbidden`），
  这件事在 `moon-oss` 里就定死了。
- 用户元数据两侧同一坐标系：写 `metadata~` 时键名**不带** `x-oss-meta-` 前缀，`stat`
  读回来的也是剥掉前缀的那批，本适配层把它折回 `FileInfo.user_metadata`。
- 预签名 PUT **不锁 Content-Type**：`content_type~` 一旦给定就参与签名，直传方换个值
  发出去就是 `SignatureDoesNotMatch`。有效期上限 604800 秒（永久密钥那一档），越界在本地拒。
- 分片除最后一片外每片不得小于 100KB；存储契约的分片档本来就是 5 MiB，所以这条腿不需要
  为契约改任何参数。完成件的 ETag 带 `-N` 后缀，本端口不存 ETag，不必为它特判。

## 许可

Apache-2.0。
