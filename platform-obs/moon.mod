name = "mldong/moon-file-storage-obs"

version = "0.1.1"

license = "Apache-2.0"

preferred_target = "wasm"

description = "Huawei Cloud OBS platform adapter for moon-file-storage"

// 这一行按"用户真装得到的那一份"写。2026-10-21 起 `mldong/moon-obs@0.1.0` 已在注册表
// （CI 的消费腿那一档会 `moon add` 它并按装到的那份真编译真跑），所以这一条 pin 不需要
// 任何本地 member 兑现——根 `moon.work` 里那条影子 member 同日撤掉了。
// 历史：I4/I5 那两轮它靠 `"../moon-obs"` 挂进来，那时注册表上还没有这一代，推上去会红在
// 依赖解析；换 SDK 代次时这一行要与 `moon-obs` 仓里的 `version` 同步（接力式 pin，别单改）。
import {
  "mldong/moon-hutool@0.1.7",
  "mldong/moon-file-storage@0.1.2",
  "mldong/moon-obs@0.1.3",
  "moonbitlang/async@0.22.5",
}

readme = "README.md"

repository = "https://github.com/mldong/moon-file-storage"

keywords = [ "moonbit", "file-storage", "huawei", "obs", "upload", "presigned" ]
