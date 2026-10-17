# moon-file-storage

x-file-storage 的 MoonBit 等价物：一个存储端口、一份平台契约、多个后端适配。业务代码只认识
`Service`，换后端就是换一个 `Platform`。

依赖面刻意收窄：HTTP 传输用 `mldong/moon-hutool` 的 `http` 包（可注入端口 + 官方
`moonbitlang/async/http` 薄适配），摘要与日期时间同出一库；S3 与七牛 Kodo 两个协议的客户端
是本生态位里的自研件，各自独立成仓。

| 模块 | 装什么 |
|---|---|
| `mldong/moon-file-storage` | 数据模型、`Platform` 与 `Recorder` 两个端口、`Service` 门面 |
| `mldong/moon-file-storage-local` | 本机磁盘后端 |
| `mldong/moon-file-storage-s3` | S3 与 S3 兼容端点的后端适配 |
| `mldong/moon-file-storage-qiniu` | 七牛 Kodo 的后端适配 |
| `mldong/moon-file-storage-ftp` | FTP 后端适配（长连接自拨、`..` 与 CR/LF 在拨号前拒） |
| `mldong/moon-file-storage-recorder-file` | 把上传记录落成本机 JSON Lines |
| `mldong/moon-file-storage-verify` | 那份平台契约正文，新平台照着写一条腿 |
| [`mldong/moon-s3`](https://github.com/mldong/moon-s3) | S3 客户端与 Signature V4 签名（独立仓） |
| [`mldong/moon-kodo`](https://github.com/mldong/moon-kodo) | 七牛 Kodo 原生协议客户端：上传令牌、两族请求签名、表单与分块上传、对象族（独立仓） |

## 集成平台进度

状态符号：**☑** 已验证——正向／负向／回归三档都在那条腿上真跑过；**☐** 还没做；**✗** 明确不支持——
协议或参考件里没有这一族，被问到就响亮拒绝。判据都来自同一份契约正文
（`mldong/moon-file-storage-verify`），档位是 `moon test --target wasm -j 1`；"分片"要五步全过，
"存在"要存在性与取回两项全过。契约里"预签名"这一格按各家签得出来的动词实测：签得出的腿要把 URL
形状钉住，签不出的腿要响亮拒绝——两边都不许静默过关。

| 平台 / 接入路径 | 集成方式 | 载体 | 上传 | 下载 | 删除 | 存在 | 列举 | 分片 | 预签名 | 复制 | 移动 | ACL | Metadata |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 本机磁盘 | 自研适配 | 本仓 | ☑ | ☑ | ☑ | ☑ | ☑ | ☑ | ✗ | ☑ | ☑ | ✗ | ✗ |
| S3 兼容端点 | 自研 SDK | [moon-s3](https://github.com/mldong/moon-s3) | ☑ | ☑ | ☑ | ☑ | ☑ | ☑ | ☑ | ☑ | ☑ | ✗ ① | ☑ |
| 七牛 / S3 兼容端点 | s3 协议 | [moon-s3](https://github.com/mldong/moon-s3) | ☐ ② | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| 七牛 / 原生 Kodo | 自研 SDK | [moon-kodo](https://github.com/mldong/moon-kodo) | ☑ | ☑ | ☑ | ☑ | ☑ | ☑ | ☑ ③ | ☑ | ☑ | ✗ | ☑ |
| FTP | 第三方件 | [PaiGack/moonbit_ftp](https://github.com/PaiGack/moonbit_ftp) | ☑ ④ | ☑ | ☑ | ☑ | ☑ | ✗ | ✗ | ✗ | ☑ | ✗ | ✗ |
| 阿里云 OSS | 待开发 | 待开发 | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| 腾讯云 COS | 待开发 | 待开发 | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |

角标说明：

1. S3 兼容端点的 ACL 记 ✗ 而不是 ☐：`GET /key?acl` 通，`PUT /key?acl` 在 MinIO 上回 501
   `NotImplemented`，而同一请求换错密钥回 403——拒的是这个操作，不是请求形状或签名。适配层按端点
   声明能力（`supports_acl`），关着就在发出请求之前 `NotSupported`；换成真支持 canned ACL 的端点，
   接入方把开关打开，那一格才改记 ☑。
2. 七牛的 S3 兼容端点整行记 ☐ 而不是 ✗：实测判死过——区域是 `cn-south-1`、签名确被校验，但桶级列举
   403，而 CDN 上确存的键答 `NoSuchKey`。判死不写成"不支持"，因为那是端点行为而不是协议射程。
3. 原生 Kodo 只签 GET（参照实现如此）；PUT 那一档由上传令牌承担（`Auth::upload_token`），
   不是预签名 URL——所以这一格给 ☑ 而不同 S3 那行的两个动词。
4. FTP 这行的 ☑ 记的是"本地跑绿"，不是"已接入"：载体库把连接的本机地址当成对端地址存
   （[PaiGack/moonbit_ftp#1](https://github.com/PaiGack/moonbit_ftp/issues/1)），非自环服务端上数据通道
   拨回客户机自己；本轮靠适配层硬钉 `disable_epsv` + `trust_pasv_ip` 借来可用性，SSRF 守卫因此退化。
   上游修好、这对开关摘掉、同一份正文复跑绿之后，这行才改记接入完成。三个 ✗ 是 FTP 的协议射程——
   参照实现同样只给 `sameMove`。

还有一条判据上的更正值得留在表边：共享正文一度用 `!same_copy || !same_move` 把复制与移动捆在同一个
断言臂里，只声明其中一族的平台会被误判成"拒绝姿势不对"；现在按能力位逐族走。

另有两条验证通道不在这张表里，住的地方也不同：按能力位全声称"没有"的那条在本仓
（`verify/refuse_contract`，把 ✗ 一侧的拒绝姿势钉住）；收 canned ACL 写入与虚主机寻址的那两档在
[`moon-s3`](https://github.com/mldong/moon-s3) 仓的 live 测试里（`S3_VHL_*` 与 `S3_VHOST_*` 两组 env）。
那两个端点是一次性夹具：不起它们时这两档打 `SKIP IS NOT A PASS`；canned ACL 的 ☑ 一侧此前在同一条
moto 夹具上取过三档读回，要复现得自己把那个夹具起起来。

## 最小用法

```moonbit
struct ReadmeRootSink {
  bytes : Array[Byte]
}

fn ReadmeRootSink::new() -> ReadmeRootSink {
  ReadmeRootSink::{ bytes : [], }
}

pub impl @io.Writer for ReadmeRootSink with fn write_once(
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

pub extend ReadmeRootSink with @io.Writer::{ write, write_once, write_reader }

async fn readme_root_flow(root : String) -> String raise {
  let platform = @local.LocalPlatform::new(@local.LocalConfig::{
    platform: "local-1",
    root_dir: root,
    domain: "https://files.example.invalid",
    base_path: "uploads",
  })
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root + "/records",
  })
  let service = @storage.Service::new([platform], recorder)
  let intent = @model.FileInfo::draft("local-1", "uploads", "note.txt", "txt")
  let saved = service.save(
    intent,
    @model.UploadSource::Bytes(@utf8.encode("hello from moon-file-storage")),
  )
  let sink = ReadmeRootSink::new()
  service.download(saved, sink)
  let text = @utf8.decode_lossy(Bytes::from_array(sink.bytes))
  let removed = service.delete(saved)
  assert_true(text == "hello from moon-file-storage")
  assert_true(removed)
  saved.url
}

async test "本机那条腿能存能取，URL 由存储回给你" {
  let root = @fs.tmpdir(prefix="moonfs-readme") catch {
    err => fail("tmpdir: " + err.to_string())
  }
  let _ = @fs.mkdir(root, recursive=true, allow_exist=true) catch {
    err => fail("mkdir: " + err.to_string())
  }
  let url = readme_root_flow(root)
  assert_eq(url, "https://files.example.invalid/uploads/note.txt")
  let _ = @fs.rmdir(root, recursive=true) catch {
    err => println("cleanup raised " + err.to_string())
  }
}
```

`FileInfo` 交给存储的是意图（哪个平台、哪个前缀、叫什么名），存储把 `path`、`url`、`size`
填回来，`Service` 再盖上创建时间并落一条记录——后面凭 URL 找回对象走的就是那条记录。

## 装法

```bash
moon add mldong/moon-file-storage
moon add mldong/moon-file-storage-local
moon add mldong/moon-file-storage-recorder-file
moon add moonbitlang/async
```

接 S3 或七牛再各加一层：`mldong/moon-file-storage-s3`（配 `mldong/moon-s3`）、
`mldong/moon-file-storage-qiniu`（配 `mldong/moon-kodo`）。代次现读各模块 `moon.mod` 的 `version`。
本仓自己就是个 `moon.work` 工作区，`moon test --target wasm` 一把跑全部模块。

## 新接一个平台

把 `mldong/moon-file-storage-verify` 引上，照本机那条腿的形状写一个测试包：造一个 `Fixture`
（你的 `Platform` ＋ 一个记录器 ＋ 一个前缀），调 `run_contract(fixture)`。这份正文覆盖对象族、
手动分片五步、预签名、同平台复制与移动、列举、ACL、用户元数据；声称没有的那一族，被问到必须拿到
`NotSupported`。跑不过就别进发布清单。

## 验收口径

- 每个后端跑同一份契约，`false` 档也要真断：声称没有某一族，被问到就必须 `NotSupported`，
  不能应下来却什么也不做。
- 能力位说的是这套存储有没有这一族，不是这一次调用会不会成功；各家兼容端点的差别由接入方声明。
- 记不上账不撤回已写好的对象：账没落地是看得见的失败，悄悄删对象是不可见的丢数据。
- 本机验收全在 wasm 档；native 只 `moon check`，运行证据交流水线。
- CI 里没有凭据的那几条腿会打 `SKIP IS NOT A PASS` 并照样过关——**CI 的绿覆盖的是单元档与发布物
  形状，不是真端点**。真端点要在带凭据的环境里按同一份正文另跑一次。
- 上面这段 `moonbit` 由 `scripts/readme-check.sh` 抽进独立工程真编译真跑，跑不过就是门禁红。

## 状态

七件走 mooncakes 发布的模块：门面 `mldong/moon-file-storage`、四件平台适配（`-local`／`-s3`／`-qiniu`／`-ftp`）、
文件记录器 `-recorder-file`、契约套件 `-verify`；`examples` 不发。次序与门禁在同仓
`.github/workflows/ci.yml` 的 publish job（拓扑序：门面先，`-verify` 最后）。当前代次与依赖 pin 一律现读——
注册表上该模块的页面，或 `moon add <模块>` 之后 `moon.mod` 回写的那一行，本文件不写死版本号。

公共 API 一旦发布就是冻结对象（`Platform` 与 `Recorder` 的方法签名、`Capabilities` 的七个能力位）：
改形状要前进代次，而且**连注释都要重发才上注册表页面**（发布包根就是模块目录，页面读的是那份 README）。
FTP 那件的进度表状态仍是"载体库未满足接入条件"——包发得出、装得到，但那条腿的接入判据没满足，
别把"已发布"读成"已可用"。

## 许可

Apache-2.0。
