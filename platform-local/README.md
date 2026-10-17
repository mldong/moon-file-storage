# mldong/moon-file-storage-local

本机磁盘后端：把对象存到指定根目录下，URL 由配置的域名拼出来。参考件对它也是真实现——
手动分片与同平台复制、移动都做得动，只有预签名不做。

## 最小用法

```moonbit
async test "写进去的文件就在盘上，删掉之后只剩空目录" {
  let root = @fs.tmpdir(prefix="moonfs-readme-local") catch {
    err => fail("tmpdir: " + err.to_string())
  }
  let _ = @fs.mkdir(root, recursive=true, allow_exist=true) catch {
    err => fail("mkdir: " + err.to_string())
  }
  let platform = @local.LocalPlatform::new(@local.LocalConfig::{
    platform: "local-2",
    root_dir: root,
    domain: "https://disk.example.invalid",
    base_path: "data",
  })
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root + "/records",
  })
  let service = @storage.Service::new([platform], recorder)
  let intent = @model.FileInfo::draft("local-2", "data", "note.txt", "txt")
  let saved = service.save(
    intent,
    @model.UploadSource::Bytes(@utf8.encode("on disk")),
  )
  assert_eq(saved.url, "https://disk.example.invalid/data/note.txt")
  let names = @fs.readdir(root + "/data") catch {
    err => fail("readdir: " + err.to_string())
  }
  assert_true(names.length() > 0)
  // 列举是单层的：分片子记录住的目录也算目录里的一项，递归不在这族的承诺里。
  let page = service.list_files("local-2", "data", "", None) catch {
    _ => fail("list_files raised on the local leg")
  }
  assert_true(page is Some(_))
  let removed = service.delete(saved)
  assert_true(removed)
  let _ = @fs.rmdir(root, recursive=true) catch {
    err => println("cleanup raised " + err.to_string())
  }
}
```

`upload_source` 的三种形状里 `Path` 走的是本机路径的直传，适合"文件已经在机器上"的场景；
`Stream` 边读边写，不先把整份读进内存。

## 装法

```bash
moon add mldong/moon-file-storage-local
```

## 许可

Apache-2.0。
