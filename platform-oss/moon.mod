name = "mldong/moon-file-storage-oss"

version = "0.1.0"

license = "Apache-2.0"

preferred_target = "wasm"

description = "Alibaba Cloud OSS platform adapter for moon-file-storage"

// `mldong/moon-oss` 还没发版：这一行现在由隔壁 `moon.work` 的本地 member
// 兑现（moon.mod 的 import 不收路径依赖）。发版后不用改这里，删掉那份 `moon.work`
// 即可——版本号写在这儿的形状就是用户真装得到的那一份。
import {
  "mldong/moon-hutool@0.1.5",
  "mldong/moon-file-storage@0.1.0",
  "mldong/moon-oss@0.1.0",
  "moonbitlang/async@0.22.4",
}

readme = "README.md"

repository = "https://github.com/mldong/moon-file-storage"

keywords = [
  "moonbit",
  "file-storage",
  "aliyun",
  "oss",
  "upload",
  "presigned",
]
