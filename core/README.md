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
  // ACL 只有三档，参考件 x-file-storage 那种"不认识的 ACL 返回 false"在这里构造不出来。
  assert_eq(@model.CannedAcl::PublicRead.header_value(), "public-read")
  assert_true(stamped != draft)
}
```

`Service` 把对象族（`save` / `get_file` / `exists` / `download` / `delete`）与五族编排
（手动分片五步、预签名、同平台复制与移动、单层列举、对象 ACL）都收在一处；后端只提供端口，
"这件事整做起来是什么样"住在这里。跨平台复制与移动在存储不做同平台优化时走通用路径：把对象
取回来再传上去。全部入口的签名（参数与返回的精确形状）在包内 `storage/pkg.generated.mbti`，
装好后在 `.mooncakes/mldong/moon-file-storage/storage/` 下就能读到。

## 端口语义

- 能力位说的是这套存储有没有这一族，不是这一次调用会不会成功。声称没有的成员被问到必须以
  `NotSupported` 拒掉，且要在动手之前拒——发出去收一个端点错误码不算拒绝。
- 记录落不下去时不撤回已写好的对象：账没落地是看得见的失败。
- 门面上遇到"这个后端没有这一族"给空值（`None` / `false`），与参考件 x-file-storage
  （dromara/x-file-storage，Java 生态统一文件存储框架，
  https://github.com/dromara/x-file-storage）的
  `listFiles` 回 notSupport、预签名回 null、`setFileAcl` 回 false 同形。

## 装法

```bash
moon add mldong/moon-file-storage
moon add moonbitlang/async
moon add mldong/moon-file-storage-local
moon add mldong/moon-file-storage-recorder-file
```

第三、四条换后端就换件，其余各档逐字 `moon add`（云厂商各档＝适配层＋协议客户端两件；构造形状
看装上的那份 `.mooncakes/mldong/moon-file-storage-<家>/README.md`）：

```bash
moon add mldong/moon-file-storage-s3
moon add mldong/moon-s3
moon add mldong/moon-file-storage-qiniu
moon add mldong/moon-kodo
moon add mldong/moon-file-storage-oss
moon add mldong/moon-oss
moon add mldong/moon-file-storage-cos
moon add mldong/moon-cos
moon add mldong/moon-file-storage-obs
moon add mldong/moon-obs
moon add mldong/moon-file-storage-ftp      # 载体 PaiGack/ftp，依赖自动进
```

记录器也可以按 `Recorder` 端口自实现。代次现读各 `moon.mod`。`moon add` 之后把下面这些 import
写进你的 `moon.pkg`（MoonBit 的传递依赖不会自动可见，少一条就会报 "containing module is not
imported"）：

```moonbit
import {
  "mldong/moon-file-storage/model",
  "mldong/moon-file-storage/platform",
  "mldong/moon-file-storage/storage",
  "mldong/moon-file-storage-local/local",
  "mldong/moon-file-storage-recorder-file/file" @record,
  "moonbitlang/async",
  "moonbitlang/async/fs",
  "moonbitlang/core/encoding/utf8",
}
```

这些 import 写在你放代码那个包的 `moon.pkg` 里：别名在主文件里用就写普通 `import { … }`；
只在 `*_test.mbt`（黑盒测试）里用则要写 `import { … } for "test"`，否则会报 unused_package
警告。

两行装配一个本机后端加一个 JSON Lines 记录器，跑通一次上传（与上面 import 逐字对应，抄进
测试包即可编译运行）：

```moonbit
async test "装上本机后端与记录器，把一次上传跑通" {
  let root = @fs.tmpdir(prefix="mfs-readme") catch {
    err => abort("tmpdir: " + err.to_string())
  }
  let local_platform = @local.LocalPlatform::new(@local.LocalConfig::{
    platform: "local-1",
    root_dir: root,
    domain: "https://files.example.invalid",
    base_path: "uploads",
  })
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root + "/records",
  })
  let platforms : Array[&@platform.Platform] = [local_platform]
  let service = @storage.Service::new(platforms, recorder)
  let intent = @model.FileInfo::draft("local-1", "uploads", "hello", "txt")
  let source = @model.UploadSource::Bytes(@utf8.encode("hello from the readme"))
  let saved = service.save(intent, source) catch {
    _ => abort("save failed")
  }
  assert_true(saved.url != "")
  assert_eq(service.exists(saved) catch { _ => false }, true)
  assert_eq(service.delete(saved) catch { _ => false }, true)
  service.close()
  let _ = @fs.rmdir(root, recursive=true) catch { _ => () }
}
```

依赖本库的包若收到 `... does not declare supported_targets` 警告（依赖的包声明了它），
在自己的 `moon.pkg` 里补一行即可，值与依赖声明同款：`supported_targets = "wasm+native+js"`
（按你的实际构建档位收窄亦可）。

## 许可

Apache-2.0。
