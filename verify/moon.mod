name = "mldong/moon-file-storage-verify"

version = "0.1.4"

license = "Apache-2.0"

preferred_target = "wasm"

description = "Shared platform contract suite for moon-file-storage"

import {
  "mldong/moon-hutool@0.1.6",
  "mldong/moon-file-storage@0.1.1",
  "mldong/moon-file-storage-local@0.1.1",
  "mldong/moon-file-storage-recorder-file@0.1.1",
  "mldong/moon-file-storage-s3@0.1.1",
  "mldong/moon-file-storage-qiniu@0.1.1",
  "mldong/moon-kodo@0.1.1",
  "mldong/moon-s3@0.1.2",
  "mldong/moon-oss@0.1.0",
  "mldong/moon-file-storage-ftp@0.1.1",
  "mldong/moon-file-storage-oss@0.1.0",
  "mldong/moon-cos@0.1.0",
  "mldong/moon-file-storage-cos@0.1.0",
  // 第十条腿的两件：`mldong/moon-obs` **还没上注册表**，这一行现在由根 `moon.work` 里
  // `"../moon-obs"` 那条本地 member 兑现（与 platform-obs/moon.mod 同一条约束，发版前
  // 这两个 pin 都推不动）。I6 发布 moon-obs 之后不用改这两行，要撤的是那条本地 member。
  "mldong/moon-obs@0.1.0",
  "mldong/moon-file-storage-obs@0.1.0",
  "moonbitlang/async@0.22.4",
}

readme = "README.md"

repository = "https://github.com/mldong/moon-file-storage"

keywords = [
  "moonbit",
  "file-storage",
  "s3",
  "qiniu",
  "kodo",
  "ftp",
  "oss",
  "cos",
  "obs",
  "upload",
  "presigned",
]
