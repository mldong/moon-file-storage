# mldong/moon-file-storage-ftp

FTP 后端的适配层：把 `PaiGack/ftp` 这个纯 MoonBit 客户端接到存储端口上，业务代码不需要知道
被动模式、`550` 那一族码与"这台 ftpd 到底实现了哪些命令"。

## 最小用法

```moonbit
async test "这一腿不用连服务端就能拿到的读数：能力位与响亮拒绝" {
  let platform = @ftp.FtpPlatform::new(
    @ftp.FtpPlatformConfig::new(
      "ftp-1",
      "192.0.2.1",
      "user",
      "password",
      domain=Some("ftp://files.example.invalid/"),
    ),
  )
  let caps = platform.capabilities()
  // 单层列举与移动是真做过的；剩下四档在 FTP 协议里没有对应命令
  assert_true(caps.list_files)
  assert_true(caps.same_move)
  assert_false(caps.multipart_upload)
  assert_false(caps.presigned_url)
  assert_false(caps.acl)
  assert_false(caps.metadata)
  assert_false(caps.same_copy)
  let note = @model.FileInfo::draft("ftp-1", "", "note", "txt")
  let refusal = try {
    let _ = platform.presigned_url(note, @model.PresignMethod::Get, 60)
    "no-error"
  } catch {
    error =>
      match error {
        @model.StorageError::NotSupported(detail) => "NotSupported: " + detail
        _ => "别的档"
      }
  }
  // 声明没有就必须响亮拒绝：静默接受是这条端口最不能容忍的失败形状
  assert_true(refusal.has_prefix("NotSupported: ftp has no presigned url"))
  platform.close()
  let after = try {
    let _ = platform.exists(note)
    "no-error"
  } catch {
    error =>
      match error {
        @model.StorageError::InvalidInput(detail) => "InvalidInput: " + detail
        _ => "别的档"
      }
  }
  assert_true(after.has_prefix("InvalidInput"))
}
```

上面这段跑不出真连接：`close` 只把平台标成"不再接受调用"，关掉之后再问一句拿到的也是
拨号之前的拒绝；真正断开发生在进程退出，原因写在下面最后一条。

## 这一腿的射程，以及它为什么是这个形状

- **连接是适配层自己拨的**，第一次要发命令时才连，之后复用同一条会话。S3 与 Kodo 那两条腿
  收的是已经建好的客户端，因为那两家的 SDK 不持有跨请求的句柄；FTP 的会话是长连接，端口没有
  "首次使用时再连"的位置。
- **数据通道只认服务端在 `PASV` 回包里报的地址**：适配层固定用 `disable_epsv=true` 与
  `trust_pasv_ip=true` 这一对开关。原因是客户端库把 `Tcp::addr()` 当成了对端地址，而 `async`
  运行时里它的文档原文是"Get the local address of a TCP connection"——于是控制连接记下的是
  本机地址，`EPSV` 的数据连接会拨回自己机器上（实测读数：控制 host 读到的是**客户机自己的局域网地址**，
  `STOR` 一律 `远程计算机拒绝网络连接`）。代价是 SSRF 守卫退化成"信服务端的回包"。
- **存在性靠父目录的一层列举**，不用 `MLST`/`MLSD`：本轮那台 vsftpd 3.0.3 的 `FEAT` 里就
  没有这两行。`550`/`551`/`553` 折成"不存在"，所以**权限错会被读成不存在**，这一腿不证两档可分。
- **`..` 段与 CR/LF 在拨号之前就被拒**：FTP 没有命名空间，key 里的 `/` 是真目录，把这两样的
  解释交给服务端的 `cwd` 等于让调用方写出能越出 chroot 的路径。
- **父目录逐段建**，判据是"能不能 `CWD` 进去"而不是回包文案；`MKD` 之后还要再进一次才算数。
- **`same_copy` 关掉**：参照件的 FTP 适配同样只有 `sameMove`。硬做复制就得整份取回内存再写回去，
  既不原子又把内存用量绑在对象尺寸上，不是端口这条法承诺的事。

## 装法

```bash
moon add mldong/moon-file-storage-ftp
```

`domain` 给的是这台 FTP 对外的访问前缀；不给就用拨号地址拼一条 `ftp://host:port/`——FTP 的
对象地址本来就能从端点算出来。IPv6 端点请显式给 `domain`。口令是配置里的明文字段，这个类型
不派生 `Show`/`ToJson`，所以它不会自己进日志或进记录。

## 许可

Apache-2.0。
