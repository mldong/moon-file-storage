#!/usr/bin/env bash
# 把每个 README 的「最小用法」代码块逐字抽出来，灌进一个独立工程，真编译真跑。
#
# 判的是"文档写的形状就是用户抄了能跑的东西"。本仓各模块走 source 一档（临时 workspace 的
# members 指向仓内各模块，清单就是下面 MODULES，与 CI 的 publish／消费腿两份清单由
# scripts/module-manifest-check.sh 一起对照）；各家 SDK 走注册表一档——pin 从消费它们的模块
# 现读，装的是用户今天真装得到的那份。**唯一例外是 mldong/moon-obs**：注册表还没有这一代，
# 靠隔壁那份 clone 挂成 member 兑现（下面 AUTO_MEMBERS 那段），I6 发版后这一档自动并回注册表。
# EXTRA_MEMBERS 仍可用：SDK 改动还没发版、要先验 README 时把邻居仓挂进工作区。
#
# 通过 = 零警告 + failed: 0。警告不许豁免：抽出来的代码是真代码，报警告就是真问题。
set -euo pipefail
: "${MOON_HOME:?需要先 export MOON_HOME}"
cd "$(dirname "$0")/.."
REPO=$(pwd -W 2>/dev/null || pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/moonfs-readme-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

MODULES=(core platform-local platform-s3 platform-qiniu platform-ftp platform-oss platform-cos platform-obs recorder-file verify)
CHECK="$WORK/readme_check"
mkdir -p "$CHECK"

# 曾经有一档 AUTO_MEMBERS：本地找得到 `../moon-obs` 就自动把它挂进这份临时工作区，用来兑现
# 还没上注册表的那条 pin。2026-10-21 `mldong/moon-obs@0.1.0` 发了版之后这一档**必须没有**：
# 目录在不在本机就决定 README 验的是源码还是注册表那份，两侧口径会静默分叉（而这道门禁判的
# 正是"用户抄了能不能跑"）。要挂还没发版的 SDK，一律显式用 EXTRA_MEMBERS。
MEMBERS="${EXTRA_MEMBERS:-}"

{
  echo 'members = ['
  for m in "${MODULES[@]}"; do echo "  \"$REPO/$m\","; done
  # SDK 还在各自仓里、注册表上取不到时，把它们也挂进这份临时工作区（CI 与本机联调用）。
  for x in $MEMBERS; do echo "    \"$x\","; done
  echo '  "./readme_check",'
  echo ']'
} > "$WORK/moon.work"

VERSION=$(sed -nE 's/^version = "([^"]+)".*/\1/p' core/moon.mod | head -1)
ASYNC=$(sed -nE 's/.*"moonbitlang\/async@([^"]+)".*/\1/p' core/moon.mod | head -1)
# HTTP 传输端口的 pin 从"需要它的那个模块"现读，别从 core 取（core 不引 http 包）
HUTOOL=$(sed -nE 's/.*"mldong\/moon-hutool@([^"]+)".*/\1/p' core/moon.mod | head -1)
# 已进注册表的那几家 SDK，pin 从"消费它的那个适配层"现读，别写死版本号：
# 这条 README 检查因此打在**用户真装得到的那份**上，而不是隔壁仓的源码。
S3PIN=$(sed -nE 's/.*"mldong\/moon-s3@([^"]+)".*/\1/p' platform-s3/moon.mod | head -1)
KODOPIN=$(sed -nE 's/.*"mldong\/moon-kodo@([^"]+)".*/\1/p' platform-qiniu/moon.mod | head -1)
OSSPIN=$(sed -nE 's/.*"mldong\/moon-oss@([^"]+)".*/\1/p' platform-oss/moon.mod | head -1)
COSPIN=$(sed -nE 's/.*"mldong\/moon-cos@([^"]+)".*/\1/p' platform-cos/moon.mod | head -1)
OBSPIN=$(sed -nE 's/.*"mldong\/moon-obs@([^"]+)".*/\1/p' platform-obs/moon.mod | head -1)
# EXTRA_MEMBERS 是发布前那条跨仓联调路：邻居模块进了工作区就不再往 import 里写注册表 pin，
# 否则同一个模块会出现两条依赖（工作区成员与注册表各一）。
EM_NAMES=""
for x in $MEMBERS; do
  EM_NAMES="$EM_NAMES $(sed -nE 's/^name = "([^"]+)".*/\1/p' "$x/moon.mod" | head -1)"
done
if ! printf '%s' "$EM_NAMES" | grep -q "mldong/moon-obs"; then
  echo "提示：platform-obs 的 README 那条腿要 mldong/moon-obs@$OBSPIN，而这一代注册表上还没有（I6 才发）。" \
    "本地/CI 都靠把工作区里现成的 ../moon-obs 挂成 member 来兑现（这一步已自动找过一次）；" \
    "两处都没有时它会红在依赖解析——那是真红，不是夹具掉了。"
fi
{
  echo 'name = "mldong/readme_check"'
  echo 'version = "0.0.0"'
  echo 'preferred_target = "wasm"'
  echo 'import {'
  # 每个模块的 pin 从它**自己的** moon.mod 现读，不拿 core 的版本号套全仓：一件没发布过
  # （版本可以停在 0.1.0）而其余已进 0.1.1 时，套同一号会让 workspace 报
  # "member 覆盖了依赖要求的那一代"——零警告口径下那条警告就把整道门禁钉红。
  for pair in "core:mldong/moon-file-storage" \
              "platform-local:mldong/moon-file-storage-local" \
              "platform-s3:mldong/moon-file-storage-s3" \
              "platform-qiniu:mldong/moon-file-storage-qiniu" \
              "platform-ftp:mldong/moon-file-storage-ftp" \
              "platform-oss:mldong/moon-file-storage-oss" \
              "platform-cos:mldong/moon-file-storage-cos" \
              "platform-obs:mldong/moon-file-storage-obs" \
              "recorder-file:mldong/moon-file-storage-recorder-file" \
              "verify:mldong/moon-file-storage-verify"; do
    d=${pair%%:*}; pkg=${pair#*:}
    v=$(sed -nE 's/^version = "([^"]+)".*/\1/p' "$REPO/$d/moon.mod" | head -1)
    echo "  \"$pkg@$v\","
  done
  for pair in "mldong/moon-s3@$S3PIN" "mldong/moon-kodo@$KODOPIN" "mldong/moon-oss@$OSSPIN" "mldong/moon-cos@$COSPIN" "mldong/moon-obs@$OBSPIN"; do
    name=${pair%%@*}
    case " $EM_NAMES " in
      *" $name "*) ;;
      *) echo "  \"$pair\"," ;;
    esac
  done
  for x in $MEMBERS; do
    en=$(sed -nE 's/^name = "([^"]+)".*/\1/p' "$x/moon.mod" | head -1)
    ev=$(sed -nE 's/^version = "([^"]+)".*/\1/p' "$x/moon.mod" | head -1)
    echo "  \"$en@$ev\","
  done
  echo "  \"moonbitlang/async@$ASYNC\","
  echo "  \"mldong/moon-hutool@$HUTOOL\","
  echo '}'
} > "$CHECK/moon.mod"

python - "$REPO" "$CHECK" <<'PY'
import io, os, re, sys

repo, check = sys.argv[1], sys.argv[2]
files = ["README.md"] + [
    os.path.join(m, "README.md")
    for m in ("core", "platform-local",
              "platform-s3", "platform-qiniu", "platform-ftp", "platform-oss", "platform-cos", "platform-obs", "recorder-file", "verify")
]
# alias -> 包路径；抽出来的代码里出现过 @alias. 才引，多引一个包对包本身就是 unused_package。
ALIASES = [
    ("model", "mldong/moon-file-storage/model"),
    ("platform", "mldong/moon-file-storage/platform"),
    ("storage", "mldong/moon-file-storage/storage"),
    ("transport", "mldong/moon-hutool/http"),
    ("sdk", "mldong/moon-s3/s3"),
    ("osssdk", "mldong/moon-oss/oss"),
    ("ossauth", "mldong/moon-oss/auth"),
    ("ossconfig", "mldong/moon-oss/config"),
    ("osserr", "mldong/moon-oss/error"),
    ("oss", "mldong/moon-file-storage-oss/oss"),
    ("cossdk", "mldong/moon-cos/cos"),
    ("cosauth", "mldong/moon-cos/auth"),
    ("cosconfig", "mldong/moon-cos/config"),
    ("coserr", "mldong/moon-cos/error"),
    ("cos", "mldong/moon-file-storage-cos/cos"),
    # OBS 那一族按现读别名来：平台件是 @obs，SDK 四件是 @obssdk／@obsauth／@obsconfig／@obserr
    # （出处＝platform-obs/README.md 的最小用法块与 verify/obs_contract/moon.pkg 的 import 行）。
    ("obssdk", "mldong/moon-obs/obs"),
    ("obsauth", "mldong/moon-obs/auth"),
    ("obsconfig", "mldong/moon-obs/config"),
    ("obserr", "mldong/moon-obs/error"),
    ("obs", "mldong/moon-file-storage-obs/obs"),
    ("sigv4", "mldong/moon-s3/sigv4"),
    ("kodo", "mldong/moon-kodo/kodo"),
    ("kodoauth", "mldong/moon-kodo/auth"),
    ("kodoconfig", "mldong/moon-kodo/config"),
    ("qiniu", "mldong/moon-file-storage-qiniu/qiniu"),
    ("ftp", "mldong/moon-file-storage-ftp/ftp"),
    ("s3", "mldong/moon-file-storage-s3/s3"),
    ("local", "mldong/moon-file-storage-local/local"),
    ("record", "mldong/moon-file-storage-recorder-file/file"),
    ("contract", "mldong/moon-file-storage-verify/contract"),
]
RUNTIME = [
    ("fs", "moonbitlang/async/fs"),
    ("io", "moonbitlang/async/io"),
    ("utf8", "moonbitlang/core/encoding/utf8"),
]

blocks = []
for rel in files:
    path = os.path.join(repo, rel)
    if not os.path.exists(path):
        continue
    src = io.open(path, encoding="utf-8").read()
    found = re.search(r"## 最小用法\s+```moonbit\n(.*?)\n```", src, re.S)
    if not found:
        print("skip (no 最小用法 block): %s" % rel)
        continue
    code = found.group(1)
    if "async test" not in code and "test \"" not in code:
        raise SystemExit("README block without a test: %s" % rel)
    name = re.sub(r"[^a-z0-9]+", "_", rel.replace("/README.md", "").replace(".md", ""))
    io.open(os.path.join(check, "readme_%s_test.mbt" % name), "w",
            encoding="utf-8", newline="\n").write(code + "\n")
    blocks.append((rel, code))
if not blocks:
    raise SystemExit("一个 README 代码块都没抽到，这条门禁等于没跑")

allcode = "\n".join(c for _, c in blocks)
entries = []
for alias, pkg in ALIASES + RUNTIME:
    if ("@" + alias + ".") in allcode:
        entries.append('  "%s" @%s,' % (pkg, alias))
# async 运行时只在抽出来的代码真用得上时才引：某仓的文档块可能是纯同步的（例如只算签名与 URL），
# 无条件引就是 unused_package 警告，零警告口径下会把那条仓的门禁永久钉红。
if any(tok in allcode for tok in ("async test", "await ", "@async.")):
    entries.append('  "moonbitlang/async",')
Q = chr(34)
text = (
    "import {" + "\n" + "\n".join(entries) + "\n"
    + "} for " + Q + "test" + Q + "\n\n"
    + "supported_targets = " + Q + "wasm+native" + Q + "\n"
)
io.open(os.path.join(check, "moon.pkg"), "w", encoding="utf-8", newline="\n").write(text)
print("extracted %d block(s), imports %d" % (len(blocks), len(entries)))
PY

cd "$WORK"
log=$(moon test --target wasm -j 1 ./readme_check 2>&1) || true
printf '%s\n' "$log" | tail -5
if printf '%s' "$log" | grep -q "Warning"; then
  printf '%s\n' "$log" | grep -B2 -A 8 "Warning" | head -40
  echo "README CHECK FAIL: 抽出来的代码有警告（零警告口径下这是错误）" >&2
  exit 1
fi
if printf '%s' "$log" | grep -q "failed: 0"; then
  echo "README CHECK PASS（零警告，真编译真跑）"
else
  echo "README CHECK FAIL" >&2
  exit 1
fi
