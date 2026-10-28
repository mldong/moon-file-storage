# mldong/moon-file-storage-cos

腾讯 COS 的存储端口适配：把 `mldong/moon-cos` 的原生 XML API 客户端（`q-sign-*` 签名、
虚主机寻址）接到 `FileStorage` 端口上，业务代码只面对 `FileInfo`、上传来源与错误分档，
不需要知道 `x-cos-*` 头族、`?uploads` 分片链与 `AccessControlPolicy`。

## 最小用法

```moonbit
async test "能力位里 acl 是真的；预签名是本地算出来的，一条请求都不发" {
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let client = @cossdk.Client::new(
    @cosconfig.Config::new(
      "ap-guangzhou",
      @cosauth.Credentials::new("ak", "sk"),
    ),
    transport,
  )
  let domain = "https://examplebucket-1250000000.cos.ap-guangzhou.myqcloud.com"
  let platform = @cos.CosPlatform::new(@cos.CosPlatformConfig::{
    platform: "cos",
    bucket: "examplebucket-1250000000",
    domain: Some(domain),
    client,
  })
  let caps = platform.capabilities()
  assert_true(caps.multipart_upload)
  assert_true(caps.presigned_url)
  assert_true(caps.metadata)
  // 与阿里云那一格正相反：写 `public-read` 被收下、匿名 GET 真取回字节，这是真桶读数
  assert_true(caps.acl)
  let intent = @model.FileInfo::draft("cos", "", "note", "txt")
  let info = intent.stamped(@model.Stamp::{
    platform: None,
    path: Some("2026/10/note.txt"),
    url: Some(domain + "/2026/10/note.txt"),
    size: None,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
  let url = platform.presigned_url(info, @model.PresignMethod::Get, 120) catch {
    _ => fail("presigned_url raised on a storage that claims the family")
  }
  assert_true(url.has_prefix(domain))
  assert_true(url.find("q-sign-algorithm=sha1") is Some(_))
  assert_true(url.find("q-sign-time=") is Some(_))
  assert_true(url.find("2026/10/note.txt") is Some(_))
}

///|
async test "没给 domain 就在发出请求之前拒；私有桶的地址不该被编成一条能打开的链接" {
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let client = @cossdk.Client::new(
    @cosconfig.Config::new(
      "ap-guangzhou",
      @cosauth.Credentials::new("ak", "sk"),
    ),
    transport,
  )
  let platform = @cos.CosPlatform::new(@cos.CosPlatformConfig::{
    platform: "cos",
    bucket: "examplebucket-1250000000",
    domain: None,
    client,
  })
  let refused = try {
    let _ = platform.get_file("https://examplebucket-1250000000.cos.ap-guangzhou.myqcloud.com/2026/10/note.txt")
    "no-error"
  } catch {
    @model.StorageError::InvalidInput(reason) => "InvalidInput:" + reason
    _ => "other"
  }
  assert_true(refused.has_prefix("InvalidInput:"))
}
```

`get_file` 那一发是**故意**选的第二档：它在建 URL／反解 key 的那一步就要 `domain`，
所以拒发生在发出任何请求之前。`presigned_url` 反而不读 `domain`——它拼的是 SDK 自家
虚主机串，两处不一致时"预签名 URL 以 domain 开头"这一档会红，上面第一档把它钉住了。

## 装法

```bash
moon add mldong/moon-file-storage-cos
```

`mldong/moon-cos` 已在注册表上，本模块的 `moon.mod` 就直接钉它那一代。开发期曾经靠一份
只在本机存在的 workspace 把未发布的隔壁仓挂成 member（`moon.mod` 的 `import` 只收
"注册表＋版本"这一种依赖），发版后那份已删。

## 用之前要知道的几件事

- `bucket` 给的是 COS 的**长命名** `<Name>-<APPID>`：appid 就在桶名里，配置面没有单独的
  appid 项，少了那一截本地就拒（拼出来的 host 永远指不到任何桶，与其拿一句服务端
  `NoSuchBucket` 不如当场响）。
- `domain` 目前只支持 SDK 那个虚主机前缀（`https://<bucket>.cos.<region>.myqcloud.com`）。
  自定义域名那一侧实测过两半：备案之后 80 端口能路由进桶（签该 `Host` 的 GET 回 200），但
  **443 的证书名还盖不住**（SAN 是 `*.cos.<region>.myqcloud.com`），而本 SDK 只拼 `https://`；
  且预签名串默认绑 host，换域名就废——只有签 `sign_host=false` 的那条能跨域名用，而这一档
  还没端上公开面。证书绑好之后要不要把 `domain` 开到自定义域，是一个要动 SDK 的独立改动。
  没给 `domain` 就在发出任何请求之前拒——私有桶的地址不是能打开的链接。
- **canned ACL 这一族报 true**：`x-cos-acl: public-read` 被收下、匿名 GET 真取回字节。
  但对象级 `public-read-write` 端点回 400 `InvalidArgument`（对象预设只有 `default`／
  `private`／`public-read` 三档），所以照原样透出服务端错误，不在本地猜档位。
- 判"对象不存在"只看 HTTP 状态码 404：真桶的 `HEAD /<key>` 打不存在的键**只有状态码、
  没有 XML 正文**，此时协议层的 `code` 是空串。
- 列举走 V1（`marker`／`NextMarker`），且适配层默认带 `encoding-type=url`：回包的键是
  一次 URL 编码，本层解回来再交给调用方，与 `put` 时用的那一串同一坐标系。
- 用户元数据两侧同一坐标系：写 `metadata~` 时键名**不带** `x-cos-meta-` 前缀，`stat`
  读回来的也是剥掉前缀的那批。
- 预签名 URL 的有效期没有公开的上限（实测过 604801 秒照签），所以本层不替自创一个顶，
  只拒"窗口不成立"。PUT 那一档不锁 Content-Type：`content_type~` 一旦给定就参与签名，
  直传方换个值发出去就是签名不符。
- 分片除最后一片外每片不得小于 1 MiB（比 AWS 的 5 MB 宽），存储契约的分片档本来就是
  5 MiB，这条腿不需要为契约改任何参数。完成件的 ETag 带 `-N` 后缀且带引号，
  本端口不存 ETag，不必为它特判。

## 许可

Apache-2.0。
