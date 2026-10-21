name = "mldong/moon-file-storage-obs"

version = "0.1.0"

license = "Apache-2.0"

preferred_target = "wasm"

description = "Huawei Cloud OBS platform adapter for moon-file-storage"

// 这一行按"用户真装得到的那一份"写，但 `mldong/moon-obs` **现在还没上注册表**：
// 它这一轮由隔壁根 `moon.work` 里 `"../moon-obs"` 那条本地 member 兑现（moon.mod 的
// import 本来不收路径依赖）。**发版前这个 pin 不能推**——推了 CI 会从注册表解析不到
// `mldong/moon-obs@0.1.0`。I6 正式发布 `moon-obs` 之后，这一行不用改（版本号写的就是
// 那一份），要撤的是根 `moon.work` 里那条本地 member。
import {
  "mldong/moon-hutool@0.1.6",
  "mldong/moon-file-storage@0.1.1",
  "mldong/moon-obs@0.1.0",
  "moonbitlang/async@0.22.4",
}

readme = "README.md"

repository = "https://github.com/mldong/moon-file-storage"

keywords = [ "moonbit", "file-storage", "huawei", "obs", "upload", "presigned" ]
