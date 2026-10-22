name = "mldong/moon-file-storage-verify"

version = "0.1.5"

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
  "mldong/moon-cos@0.1.1",
  "mldong/moon-file-storage-cos@0.1.0",
  // 第十条腿的两件。`mldong/moon-obs@0.1.0` 已于 2026-10-21 上注册表（那两天它靠根
  // `moon.work` 里的影子 member `"../moon-obs"` 兑现，同一条约束见 platform-obs/moon.mod）；
  // `mldong/moon-file-storage-obs@0.1.0` 是本仓的兄弟模块，平时由 workspace member 解析，
  // **publish 的包体自检从注册表取它** ⇒ 发 verify 必须排在 platform-obs 之后（拓扑序，不是排版）。
  "mldong/moon-obs@0.1.1",
  "mldong/moon-file-storage-obs@0.1.0",
  "moonbitlang/async@0.22.5",
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
