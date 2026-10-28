name = "mldong/moon-file-storage-oss"

version = "0.1.3"

license = "Apache-2.0"

preferred_target = "wasm"

description = "Alibaba Cloud OSS platform adapter for moon-file-storage"

// 这一行按"用户真装得到的那一份"写（moon.mod 的 import 不收路径依赖，靠注册表兑现）；
// 换 SDK 代次时与 `moon-oss` 仓里的 `version` 同步（接力式 pin，别单改）。
import {
  "mldong/moon-hutool@0.1.7",
  "mldong/moon-file-storage@0.1.3",
  "mldong/moon-oss@0.20.0",
  "moonbitlang/async@0.22.5",
}

readme = "README.md"

repository = "https://github.com/mldong/moon-file-storage"

keywords = [ "moonbit", "file-storage", "aliyun", "oss", "upload", "presigned" ]
