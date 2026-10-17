# mldong/moon-file-storage

统一文件存储的核心层：数据模型、两个端口（`Platform` 后端、`Recorder` 上传记录）、以及把两者
编排成一条调用链的 `Service`。这个包不认识任何具体后端，也不发 HTTP 请求。

## 最小用法

```moonbit
async test "记录是意图加存储回填的字段，不是调用方自己拼的字符串" {
  let draft = @model.FileInfo::draft("local-1", "uploads", "report", "pdf")
  assert_eq(draft.url, "")
  assert_eq(draft.original_filename, "report")
  let stamped = draft.stamped(@model.Stamp::{
    platform: None,
    path: Some("uploads/2026/10/"),
    url: Some("https://files.example.invalid/uploads/2026/10/report.pdf"),
    size: Some(4096L),
    create_time: Some(1760000000000L),
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
  assert_eq(stamped.ext, "pdf")
  assert_eq(stamped.size, Some(4096L))
  // 空着的 `platform` 沿用原值：一次只改想改的那几格。
  assert_eq(stamped.platform, "local-1")
  let keyed = @model.object_key("uploads", "a/b.txt")
  assert_eq(keyed, "uploads/a/b.txt")
  // ACL 只有三档，参考件那种"不认识的 ACL 返回 false"在这里构造不出来。
  assert_eq(@model.CannedAcl::PublicRead.header_value(), "public-read")
  assert_true(stamped != draft)
}
```

`Service` 把对象族（`save` / `get_file` / `exists` / `download` / `delete`）与五族编排
（手动分片五步、预签名、同平台复制与移动、单层列举、对象 ACL）都收在一处；后端只提供端口，
"这件事整做起来是什么样"住在这里。跨平台复制与移动在存储不做同平台优化时走通用路径：把对象
取回来再传上去。

## 端口语义

- 能力位说的是这套存储有没有这一族，不是这一次调用会不会成功。声称没有的成员被问到必须以
  `NotSupported` 拒掉，且要在动手之前拒——发出去收一个端点错误码不算拒绝。
- 记录落不下去时不撤回已写好的对象：账没落地是看得见的失败。
- 门面上遇到"这个后端没有这一族"给空值（`None` / `false`），与参考件
  `listFiles` 回 notSupport、预签名回 null、`setFileAcl` 回 false 同形。

## 装法

```bash
moon add mldong/moon-file-storage
```

代次现读 `moon.mod`。还需要一个后端模块（`moon-file-storage-local` 或
`moon-file-storage-s3`）和一个记录器（`moon-file-storage-recorder-file`）。

## 许可

Apache-2.0。
