# mldong/moon-file-storage-recorder-file

把上传记录落成本机 JSON Lines：一行一条对象记录，分片子记录另存一张。换后端不改这一层，
想换存法（数据库、云端表）也只换这一层——它实现的是 `Recorder` 端口。

## 最小用法

```moonbit
async test "记录写得进读得出，按会话号清理子记录" {
  let root = @fs.tmpdir(prefix="moonfs-readme-record") catch {
    err => fail("tmpdir: " + err.to_string())
  }
  let _ = @fs.mkdir(root, recursive=true, allow_exist=true) catch {
    err => fail("mkdir: " + err.to_string())
  }
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root,
  })
  let intent = @model.FileInfo::draft("local-9", "uploads", "note", "txt")
  let info = intent.stamped(@model.Stamp::{
    platform: None,
    path: Some("uploads/note.txt"),
    url: Some("https://files.example.invalid/uploads/note.txt"),
    size: Some(7L),
    create_time: Some(1760000000000L),
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
  let first = recorder.save(info) catch {
    _ => fail("save raised")
  }
  assert_true(first)
  // 同一个 URL 再存一次不改写已有行——判"这条记录还在不在"要用另一次读取。
  let again = recorder.save(info) catch {
    _ => fail("second save raised")
  }
  assert_true(!again)
  let row = recorder.get_by_url(info.url) catch {
    _ => fail("get_by_url raised")
  }
  match row {
    Some(found) => assert_eq(found.size, Some(7L))
    None => fail("the row written above is not readable back")
  }
  let _ = recorder.save_file_part(@model.FilePartInfo::{
    platform: "local-9",
    upload_id: "up-1",
    part_number: 1,
    size: 4096L,
    etag: "\"e\"",
  }) catch {
    _ => fail("save_file_part raised")
  }
  let parts = recorder.part_rows() catch {
    _ => fail("part_rows raised")
  }
  assert_eq(parts.length(), 1)
  let _ = recorder.delete_file_part_by_upload_id("up-1") catch {
    _ => fail("delete_file_part_by_upload_id raised")
  }
  let cleared = recorder.delete(info.url) catch {
    _ => fail("delete raised")
  }
  assert_true(cleared)
  let _ = @fs.rmdir(root, recursive=true) catch {
    err => println("cleanup raised " + err.to_string())
  }
}
```

`part_rows` 是这个实现自带的读回入口，不属于端口：端口只承诺写与清，读回是本机文件才可做的
事。验收要求就是"另起一个实例读回并数盘上的行"，而不是相信写调用没抛就是写进去了。

## 单写取舍

一张表一个写者：追加写不串行化，多进程同时往同一张表写会交错。要并发写的场景请换实现。

## 装法

```bash
moon add mldong/moon-file-storage-recorder-file
```

## 许可

Apache-2.0。
