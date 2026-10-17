# mldong/moon-file-storage-verify

`Platform` 端口的契约正文。一份断言集，所有后端跑同一份：新接一个平台时，这条腿跑不过就不进发布清单。
入口是 `run_contract(Fixture)`，它按顺序走对象族、手动分片五步、预签名、同平台复制与移动、单层列举、
对象 ACL、用户元数据、分片记账与门面行为，共 13 个用例函数。

`Fixture` 里三个字段是要紧的：`port` 直接给端口本身（分片／预签名／复制移动没有服务编排，契约不经门面
调端口，免得把"门面没做的事"读成"端口没有"）；`presigned_markers` 由这条腿自己报——各家签名 URL 的查询串
写法不同（S3 用 `X-Amz-Signature=`／`X-Amz-Expires=`，原生 Kodo 用 `?e=`／`&token=`），把某一家的写法
钉进共享正文，就等于让别的腿迁就一个协议细节；`recorder` 是给记账用例数行用的。

## 最小用法

```moonbit
async test "一条腿的形状：造平台、包成 Fixture、把正文交出去" {
  let root = @fs.tmpdir(prefix="moonfs-verify-doc") catch {
    err => fail("tmpdir: " + err.to_string())
  }
  let _ = @fs.mkdir(root, recursive=true, allow_exist=true) catch {
    err => fail("mkdir: " + err.to_string())
  }
  let platform = @local.LocalPlatform::new(@local.LocalConfig::{
    platform: "verify-1",
    root_dir: root,
    domain: "https://files.example.invalid",
    base_path: "uploads",
  })
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root + "/records",
  })
  let fixture = @contract.Fixture::{
    label: "doc-leg",
    platform: "verify-1",
    base_path: "uploads",
    domain: "https://files.example.invalid",
    service: @storage.Service::new([platform], recorder),
    recorder,
    port: platform,
    presigned_markers: [],
  }
  @contract.run_contract(fixture)
  let _ = @fs.rmdir(root, recursive=true) catch {
    err => println("cleanup raised " + err.to_string())
  }
}
```

`presigned_markers: []` 说的是"这个后端签不出预签名 URL"——那一格于是被要求响亮拒绝。能给预签名的后端
把 marker 填上（例如 `["X-Amz-Signature=", "X-Amz-Expires="]`），正文改判"URL 形状对不对"。

## 装法

```bash
moon add mldong/moon-file-storage-verify
```

## 判据两侧都要下真断言

- 声称**有**这一族：正向要读出真结果，负向要拿到契约规定的错误档（缺源报 `NotFound`，越界的分片号在
  发出任何请求之前就拒）。
- 声称**没有**这一族：被问到必须 `NotSupported`，且要在动手之前拒——发出去再收一个端点错误码不算拒绝。
- 没有凭据、跑不到真端点时，这条腿要打印 `SKIP IS NOT A PASS` 并让运行仍然过关；把 SKIP 读成绿灯是
  另一种红。

## 仓与进度

这份契约住在 [`mldong/moon-file-storage`](https://github.com/mldong/moon-file-storage) 仓里，
各后端的能力格子在那份 README 的集成平台进度表上。

## 许可

Apache-2.0。
