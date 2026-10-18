name = "mldong/moon-file-storage-cos"

version = "0.1.0"

license = "Apache-2.0"

preferred_target = "wasm"

description = "Tencent Cloud COS platform adapter for moon-file-storage"

// `mldong/moon-cos` 还没发版：这一行现在由 `moonfs-dev/moon.work` 的本地 member 兑现
// （moon.mod 的 import 不收路径依赖）。发版后不用改这里，把那份工作区里的 member 删掉
// 即可——版本号写在这儿的形状就是用户真装得到的那一份。
import {
  "mldong/moon-hutool@0.1.6",
  "mldong/moon-file-storage@0.1.1",
  "mldong/moon-cos@0.1.0",
  "moonbitlang/async@0.22.4",
}

readme = "README.md"

repository = "https://github.com/mldong/moon-file-storage"

keywords = [
  "moonbit",
  "file-storage",
  "tencent",
  "cos",
  "upload",
  "presigned",
]
