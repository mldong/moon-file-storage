# mldong/moon-file-storage-qiniu

七牛 Kodo 的存储端口适配：把 `mldong/moon-kodo` 的原生协议客户端接到 `FileStorage` 端口上，
业务代码只面对 `FileInfo`、上传来源与错误分档，不需要知道上传令牌、`rs` / `rsf` 路径与 612。

## 最小用法

```moonbit
test "预签名两档：GET 签得出私有 URL，PUT 按参照实现响亮拒绝" {
  let transport = @transport.AsyncHttpTransport::new()
  let auth = @kodoauth.Auth::new("ak-example", "sk-example")
  let region = match @kodoconfig.Region::with_region_id("z0") {
    None => fail("z0 is always constructible")
    Some(one) => one
  }
  let client = @kodo.Client::new(
    transport,
    auth,
    @kodoconfig.Config::new(region, use_https=true),
    "demo-bucket",
  ) catch {
    _ => fail("a non-empty bucket name always constructs")
  }
  let platform = @qiniu.QiniuPlatform::new(@qiniu.QiniuPlatformConfig::new(
    "qiniu",
    client,
    transport,
    domain=Some("https://cdn.example.invalid"),
  ))
  let caps = platform.capabilities()
  assert_true(caps.multipart_upload)
  assert_true(caps.presigned_url)
  assert_true(caps.metadata)
  // 七牛没有 canned ACL 这一族：报 false，被调用就抛，不接受请求后什么都不做
  assert_true(!caps.acl)
  let info = @model.FileInfo::draft("qiniu", "2026/10", "note.txt", "txt")
  .stamped(@model.Stamp::{
    platform: None,
    path: Some("2026/10/note.txt"),
    url: None,
    size: None,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
  let url = platform.presigned_url(info, @model.PresignMethod::Get, 120)
  assert_true(url.has_prefix("https://cdn.example.invalid/2026/10/note.txt?e="))
  assert_true(url.contains("&token=ak-example:"))
  let refused = platform.presigned_url(info, @model.PresignMethod::Put, 120) catch {
    @model.StorageError::NotSupported(reason) => "NotSupported:" + reason
    _ => "other"
  }
  assert_true(refused.has_prefix("NotSupported:"))
}
```

## 装法

```bash
moon add mldong/moon-file-storage-qiniu
```

## 用之前要知道的几件事

- `domain` 必须是**真能打开这个桶的域名**。七牛不给未绑定域名的桶提供默认下载入口，
  `iovip-*` 那台会直接回 `no such domain`；`download` 与 `presigned_url` 都靠这条 URL。
- 分片族的会话号是 `FileInfo.upload_id`：`init_multipart` 打进去，后面四步凭它现签上传令牌，
  所以一个进行到一半的分片上传可以跨进程续。
- 块级校验按参照实现默认关。要开着就把 `check_crc=true` 传进配置，表单侧带整份 crc32、
  分块侧逐片比 md5，不等就在合并之前抛。
- 用户元数据两侧形状不同：写的时候是平铺字段 `x-qn-meta-<名>`，读回来的时候 `stat`
  给的是嵌套对象 `x-qn-meta`，本适配层已经把它折回 `FileInfo.user_metadata`。
- 错误分档只把 612 当成"对象不存在"（`NotFound`）；目标位已有同名对象是 614，
  服务端的其它状态码原样进 `Platform` 的文案并带上 reqid。

## 许可

Apache-2.0。
