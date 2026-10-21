#!/usr/bin/env bash
# 清单机器对照：CI 的三份模块清单必须与"仓里真有的可发布模块目录"逐一对上。
#
# 三份清单都是手抄的：
#   ① publish job 里"这一轮发的是哪一件"的版本打印循环（for m in core recorder-file …）
#   ② publish 逐步（bash .github/scripts/publish-if-absent.sh <目录> <模块>）
#   ③ 消费腿逐个 `moon add` 的那串模块名
# 抄漏一处就是**静默漏发**：上一轮这条线真踩到过两处——② 漏了 platform-cos（verify 全绿、
# publish success、制品其实没上注册表），③ 从阶段 G 起就漏着 platform-oss。
# 所以判据不靠人记：条目数与磁盘目录数**算出来比**，缺一项就真红；多一项（目录已撤而清单
# 还留着）同样红，那是"发一件不存在的东西"的前兆。
#
# 用法：bash scripts/module-manifest-check.sh　（CI 的 verify job 里就是一步，本机同一条命令）
set -euo pipefail
cd "$(dirname "$0")/.."
CI=.github/workflows/ci.yml
[ -f "$CI" ] || { echo "MANIFEST CHECK FAIL: 找不到 $CI" >&2; exit 1; }

# 不发版的目录：可执行示例，发出去只多一个没人 import 的模块（README 的"状态"段同口径）。
NO_PUBLISH=" examples"
# 已建好、但**这一轮故意不进 publish 清单**的模块（它 pin 的那件 SDK 还没上注册表，加了会红在
# 依赖解析）。撤掉一档的时点必须留在 ci.yml 的 DEFER 注释里，下面核那条注释还在不在——
# 清单能偷偷删，提醒不能偷偷丢；而反过来，**目录已进了 publish 清单却还挂在这张表上也会红**。
# 现读：2026-10-21 `mldong/moon-obs@0.1.0` 上注册表后这张表就是空的（历史见 ci.yml）。
DEFER_PUBLISH=""
DEFER_MARKER="DEFER(platform-obs)"

in_list() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
mod_of() { sed -nE 's/^name = "([^"]+)".*/\1/p' "$1/moon.mod" | head -1; }

# ── 磁盘现读：顶层带 moon.mod 且 name 是 mldong/ 的目录 ────────────────────────────
DISK_DIRS="" DISK_MODS=""
for d in */; do
  d=${d%/}
  [ -f "$d/moon.mod" ] || continue
  n=$(mod_of "$d")
  case "$n" in
    mldong/*) DISK_DIRS="$DISK_DIRS $d"; DISK_MODS="$DISK_MODS $n" ;;
  esac
done

WANT_PUB_DIRS="" WANT_PUB_MODS="" WANT_CONS_MODS=""
for d in $DISK_DIRS; do
  in_list "$NO_PUBLISH" "$d" && continue
  m=$(mod_of "$d")
  WANT_CONS_MODS="$WANT_CONS_MODS $m"
  in_list "$DEFER_PUBLISH" "$d" && continue
  WANT_PUB_DIRS="$WANT_PUB_DIRS $d"
  WANT_PUB_MODS="$WANT_PUB_MODS $m"
done

# ── CI 现读：三份清单 ────────────────────────────────────────────────────────────
# ① 版本打印循环（publish job 第一步）
VER_LOOP=$(sed -nE 's/^[[:space:]]*for m in ([a-z0-9 ._-]+); do.*/\1/p' "$CI" | tr -s ' ')
# ② publish 逐步：目录 + 模块两个读数都要
PUB_PAIRS=$(grep -oE 'publish-if-absent\.sh[[:space:]]+[a-z0-9-]+[[:space:]]+mldong/[A-Za-z0-9._-]+' "$CI" |
  awk '{print $2"="$3}')
PUB_DIRS=$(printf '%s\n' "$PUB_PAIRS" | cut -d= -f1 | tr -s '\n' ' ')
PUB_MODS=$(printf '%s\n' "$PUB_PAIRS" | cut -d= -f2 | tr -s '\n' ' ')
# ③ 消费腿的模块名（只在 `for m in mldong/…` 那一段里取，别处出现的模块名不算）
CONS_MODS=$(awk '/for m in mldong\/moon-file-storage/{f=1} f{print} f&&/; do/{exit}' "$CI" |
  grep -oE 'mldong/moon-file-storage[A-Za-z0-9_-]*' | tr -s '\n' ' ')

fail=""
say_fail() { echo "MANIFEST CHECK FAIL: $*" >&2; fail="1"; }

count() { set -- $1; echo $#; }

# ── 对照：条目数 == 目录数，且逐项对得上 ───────────────────────────────────────────
echo "磁盘模块目录（现读）        : $(count "$DISK_DIRS") 项 —$DISK_DIRS"
echo "  其中不发版               :$(echo "$NO_PUBLISH")"
echo "  其中本轮推迟 publish     :$(echo "$DEFER_PUBLISH")"
echo "应进 publish 清单的模块     : $(count "$WANT_PUB_DIRS") 项 —$WANT_PUB_DIRS"
echo "CI 版本打印循环            : $(count "$VER_LOOP") 项 —$VER_LOOP"
echo "CI publish 逐步            : $(count "$PUB_DIRS") 项 —$PUB_DIRS"
echo "应进消费腿清单的模块        : $(count "$WANT_CONS_MODS") 项"
echo "CI 消费腿清单              : $(count "$CONS_MODS") 项"

# 核心那条硬判据：清单条目数与可发布模块目录数**必须相等**
if [ "$(count "$PUB_DIRS")" != "$(count "$WANT_PUB_DIRS")" ]; then
  say_fail "publish 清单 $(count "$PUB_DIRS") 项 != 磁盘可发布模块 $(count "$WANT_PUB_DIRS") 项"
fi
if [ "$(count "$CONS_MODS")" != "$(count "$WANT_CONS_MODS")" ]; then
  say_fail "消费腿清单 $(count "$CONS_MODS") 项 != 磁盘应装模块 $(count "$WANT_CONS_MODS") 项"
fi
if [ "$(count "$VER_LOOP")" != "$(count "$PUB_DIRS")" ]; then
  say_fail "版本打印循环 $(count "$VER_LOOP") 项 != publish 逐步 $(count "$PUB_DIRS") 项"
fi

for d in $WANT_PUB_DIRS; do
  in_list "$PUB_DIRS" "$d" || say_fail "publish 清单缺 $d（磁盘上有这个模块目录，CI 不发它）"
  in_list "$VER_LOOP" "$d" || say_fail "版本打印循环缺 $d"
done
for d in $PUB_DIRS; do
  in_list "$WANT_PUB_DIRS" "$d" || say_fail "publish 清单多了 $d（磁盘上没有、或它本轮该推迟）"
done
for m in $PUB_MODS; do
  in_list "$WANT_PUB_MODS" "$m" || say_fail "publish 清单里的模块名 $m 与磁盘各目录的 moon.mod name 都不对得上"
done
for m in $WANT_CONS_MODS; do
  in_list "$CONS_MODS" "$m" || say_fail "消费腿清单缺 $m（用户装得到这一件，CI 却没按'装得到'核过它）"
done
for m in $CONS_MODS; do
  in_list "$WANT_CONS_MODS" "$m" || say_fail "消费腿清单多了 $m（磁盘上没有这件，或它已撤仓）"
done

# 推迟那一档：目录要在、publish 两处不能要、消费腿要先挂着（发版那天同一条腿就真装它），
# 而且"别再漏"的提醒必须还在 ci.yml 里。这张表现在是空的 ⇒ 这一段不跑；往里加一项的规则见上面。
for d in $DEFER_PUBLISH; do
  in_list "$DISK_DIRS" "$d" || say_fail "推迟清单里的 $d 在磁盘上已不存在（这一档该删掉了）"
  in_list "$PUB_DIRS" "$d" && say_fail "$d 已在 publish 清单里，却还挂在推迟表上（该把它从 DEFER_PUBLISH 摘掉）"
  grep -q -- "$DEFER_MARKER" "$CI" ||
    say_fail "ci.yml 里找不到 $DEFER_MARKER 那条提醒（推迟的理由与撤除时点必须留在原地）"
done

if [ -n "$fail" ]; then
  echo "MANIFEST CHECK FAIL：见上面每一条——缺项就是静默漏发，多项就是发一件不存在的东西" >&2
  exit 1
fi
defer_note="推迟 $(count "$DEFER_PUBLISH") 项已带撤除时点"
[ -n "$(echo "$DEFER_PUBLISH" | tr -d ' ')" ] || defer_note="无推迟项"
echo "MANIFEST CHECK PASS：publish 清单 $(count "$PUB_DIRS") 项 == 磁盘可发布模块 $(count "$WANT_PUB_DIRS") 项；消费腿清单 $(count "$CONS_MODS") 项 == 应装 $(count "$WANT_CONS_MODS") 项；$defer_note"
