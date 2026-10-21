# mldong/moon-file-storage-obs

华为云 OBS 的存储端口适配：把 `mldong/moon-obs` 的原生 XML API 客户端（V4＝
`AWS4-HMAC-SHA256` 签名、虚主机寻址、`?uploads` 分片链、`X-Amz-*` 预签名参数）接到
`FileStorage` 端口上，业务代码只面对 `FileInfo`、上传来源与错误分档，不需要知道头名前缀、
`acl=` 空值参数与 `AccessControlPolicy`。

## 最小用法

```moonbit
async test "能力位里 acl 是真的；预签名是本地算出来的，一条请求都不发" {
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let client = @obssdk.Client::new(
    @obsconfig.Config::new(
      "obs.cn-north-4.myhuaweicloud.com",
      "cn-north-4",
      @obsauth.Credentials::new("ak", "sk"),
    ),
    transport,
  )
  let domain = "https://examplebucket.obs.cn-north-4.myhuaweicloud.com"
  let platform = @obs.ObsPlatform::new(@obs.ObsPlatformConfig::{
    platform: "obs",
    bucket: "examplebucket",
    domain: Some(domain),
    client,
  })
  let caps = platform.capabilities()
  assert_true(caps.multipart_upload)
  assert_true(caps.presigned_url)
  assert_true(caps.metadata)
  // 与阿里云那一格正相反：写 `public-read` 被收下、匿名 GET 真取回字节（可逆），这是真桶读数
  assert_true(caps.acl)
  let intent = @model.FileInfo::draft("obs", "", "note", "txt")
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
  assert_true(url.find("X-Amz-Algorithm=AWS4-HMAC-SHA256") is Some(_))
  assert_true(url.find("X-Amz-Expires=120") is Some(_))
  assert_true(url.find("2026/10/note.txt") is Some(_))
}

///|
async test "没给 domain 就在发出请求之前拒；私有桶的地址不该被编成一条能打开的链接" {
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let client = @obssdk.Client::new(
    @obsconfig.Config::new(
      "obs.cn-north-4.myhuaweicloud.com",
      "cn-north-4",
      @obsauth.Credentials::new("ak", "sk"),
    ),
    transport,
  )
  let platform = @obs.ObsPlatform::new(@obs.ObsPlatformConfig::{
    platform: "obs",
    bucket: "examplebucket",
    domain: None,
    client,
  })
  let refused = try {
    let _ = platform.get_file("https://examplebucket.obs.cn-north-4.myhuaweicloud.com/2026/10/note.txt")
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
moon add mldong/moon-file-storage-obs
```

本机开发期不是这一条：`mldong/moon-obs` 还没上注册表，而 `moon.mod` 的 `import` 只收
"注册表＋版本"这一种依赖，所以靠根 `moon.work` 把隔壁 `../moon-obs` 挂成 member
（**发版前这个 pin 不能推**——推了 CI 从注册表解析不到）；`moon-obs` 发布后撤掉那条
本地 member，`moon.mod` 里那行 `"mldong/moon-obs@0.1.0"` 一个字都不用改。

## 用之前要知道的几件事

- **只有 virtual-hosted 寻址**：path 风格的对象请求一律 403 `VirtualHostDomainRequired`
  （真桶实测），所以配置面没有"寻址风格"开关，SDK 的 `path_style_url` 本身永远响亮拒绝。
- `domain` 目前只支持 SDK 那个虚主机前缀（`https://<bucket>.obs.<region>.myhuaweicloud.com`）。
  自定义域名实测过两半：DNS 已解析、http 能路由进桶（403 是 ACL 的答案），但测试桶上
  **443 的证书没绑**（https 撞 TLS 名称不匹配），而本 SDK 只拼 `https://`——所以这一位
  现在照 `platform-cos` 的姿势响亮忽略，不默默拿它派生公开 URL。
- **canned ACL 报 true**：`public-read` 生效后匿名 GET 200、改回 `private` 又 403，可逆；
  原生面允许匿名请求（`403 AccessDenied` 是 ACL 的答案，不是兼容面那种
  `400 NotSupportAnonymous`），所以公开读 URL 在原生面是真能打开的。`private`／
  `public-read`／`public-read-write` 三档都被收（与 COS 拒对象级 `public-read-write`
  相反）；坏取值回 400 `InvalidArgument`，原样透出，不在本地猜档位。
- 判"对象不存在"只看 HTTP 状态码 404：`HEAD /<key>` 打不存在的键只有状态码、没有 XML
  正文，此时协议层的 `code` 是空串。abort 之后再查 `list_parts` 回 404 `NoSuchUpload`，
  同落 `NotFound`，不折叠成"空的一页"。
- 列举走 V1（`marker`／`NextMarker`）。原生面也收 `list-type=2`（回体带 `KeyCount`／
  `NextContinuationToken`、无 `Marker`），但 SDK 的承诺面只有 V1——没有参照实现的行为
  不实现，这一腿不把它写进保证。
- 用户元数据两侧同一坐标系：写 `metadata~` 时键名**不带**头前缀，`stat` 读回来的也是
  剥掉前缀的那批（V4 在原生端点的真桶头名前缀是 `x-amz-*`，那一族的选择归 SDK 一处）。
- 预签名有效期 **1..604800 秒**（永久密钥七天）在 SDK 本地把关，越界就地
  `InvalidInput`——与 COS 的"没有文档数字"相反；`Host` 必入签
  （`X-Amz-SignedHeaders=host`）。PUT 那一档不锁 Content-Type。
- 分片下限 **100KiB**（真桶实测 100KiB 过、99KiB/50KiB 回 400 `EntityTooSmall`）；
  存储契约的默认分片 5MiB 安全，这条腿不需要为契约改任何参数。分片号越界
  （`1..10000` 之外）**在发出请求之前**拒——这一格由 SDK 本地校验，落 `InvalidInput`。
- 签名 scope 里的区域**不被端点比对**（签错区域仍 200，真桶实测）：不要拿签名当"区域
  对不对"的校验手段；域名里的区域填错会从路由侧回 404 `NoSuchBucket`，两件事不是一回事。

## 许可

Apache-2.0。
