name = "mldong/moon-file-storage-cos"

version = "0.1.1"

license = "Apache-2.0"

preferred_target = "wasm"

description = "Tencent Cloud COS platform adapter for moon-file-storage"

// 这一行按"用户真装得到的那一份"写：`mldong/moon-cos@0.1.0` 已在 mooncakes 上，
// 所以这里不需要任何本地 member 兜底（moon.mod 的 import 本来也不收路径依赖）。
import {
  "mldong/moon-hutool@0.1.7",
  "mldong/moon-file-storage@0.1.2",
  "mldong/moon-cos@0.1.3",
  "moonbitlang/async@0.22.5",
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
