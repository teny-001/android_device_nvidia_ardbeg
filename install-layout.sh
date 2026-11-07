#!/bin/sh
#
# install-layout.sh —— 把 merged/ 里的两个兄弟树展开到 AOSP 源码树
#
# 位置：device/nvidia/ardbeg/install-layout.sh（本仓库根）
# 用法：
#     ./install-layout.sh                      # 自动推断源码树根
#     ./install-layout.sh /path/to/cm-14.1    # 显式指定
#     ./install-layout.sh --check             # 只检查，不写入
#
# 【为什么需要这个脚本】
#   GitHub 一个仓库只有一个根目录。Android 的惯例是「device 仓库根 =
#   device/<vendor>/<device>/」，但本次移植在 device/nvidia/ 下还需要两个
#   并列目录：
#     1) ardbeg_tv/    —— lunch cm_ardbeg_tv-eng 时 CM_BUILD=ardbeg_tv，
#                          build/core/product_config.mk 用
#                          `find device -path "*/ardbeg_tv/lineage.mk"` 定位
#                          产品文件。没有它直接报
#                          "Cannot locate config makefile for product ..."。
#     2) shield-common/ —— BoardConfig.mk 的 BOARD_SEPOLICY_DIRS 引用
#                          sepolicy/common 与 sepolicy/lineage-common，
#                          BOARD_SECCOMP_POLICY 引用 seccomp/。
#   两者无法同时成为仓库根，因此以快照形式放在 merged/，clone 后由本脚本
#   展开。这样既满足「合并成一个仓库上传」，又保持 clone 后可直接 lunch，
#   还不会和 LineageOS 官方 manifest 里 device/nvidia/* 的 path 产生嵌套冲突。
#
# 【幂等性】
#   用 cp -a 覆盖 merged/ 里存在的同名文件，不删除源码树里的其它内容。
#   重复执行结果一致；若源码树里已有官方较新的 shield-common，请自行决定
#   是否要保留（本脚本会覆盖同名文件，但不会删你新增的文件）。
#
# 【注意】本脚本只展开目录，不打 AOSP 补丁。补丁是另一步：
#     cd device/nvidia/ardbeg/patches && ./check.sh && ./install.sh
#

HERE=$(cd "$(dirname "$0")" && pwd)
MODE=write

case "${1:-}" in
    --check)
        MODE=check
        ROOT=${2:-$(cd "$HERE/../../.." && pwd)}
        ;;
    '')
        ROOT=$(cd "$HERE/../../.." && pwd)
        ;;
    *)
        ROOT=$1
        ;;
esac

say() { printf '%s\n' "$*"; }
fail() { say "FATAL: $*"; exit 1; }

# ---- 校验本仓库自身 ----
[ -f "$HERE/AndroidProducts.mk" ] || fail "本脚本不在 device/nvidia/ardbeg 仓库根：$HERE"
[ -f "$HERE/merged/ardbeg_tv/lineage.mk" ] || fail "缺 merged/ardbeg_tv/lineage.mk"
[ -d "$HERE/merged/shield-common/sepolicy/common" ] || fail "缺 merged/shield-common/sepolicy/common"
[ -d "$HERE/merged/shield-common/seccomp" ] || fail "缺 merged/shield-common/seccomp"

# ---- 校验源码树根 ----
# build/core 是 AOSP / LineageOS 源码树最稳定的标志；不校验 device/nvidia 是否
# 存在，因为全新 checkout 时它可能还没被创建。
[ -d "$ROOT/build/core" ] || fail "'$ROOT' 不像源码树根（缺 build/core），请用 ./install-layout.sh <aosp-root> 指定"
say "源码树根 : $ROOT"
say "仓库位置 : $HERE"
say "模式     : $MODE"

if [ "$MODE" = check ]; then
    for pair in "device/nvidia/ardbeg_tv/lineage.mk" \
                "device/nvidia/shield-common/sepolicy/common" \
                "device/nvidia/shield-common/seccomp"; do
        if [ -e "$ROOT/$pair" ]; then
            say "  OK      $pair 已存在"
        else
            say "  MISSING $pair"
        fi
    done
    exit 0
fi

# ---- 展开 ----
mkdir -p "$ROOT/device/nvidia/ardbeg_tv" "$ROOT/device/nvidia/shield-common" \
    || fail "无法创建 device/nvidia 下的目标目录（权限不足？）"

cp -a "$HERE/merged/ardbeg_tv/."     "$ROOT/device/nvidia/ardbeg_tv/" \
    || fail "展开 ardbeg_tv 失败"
cp -a "$HERE/merged/shield-common/." "$ROOT/device/nvidia/shield-common/" \
    || fail "展开 shield-common 失败"

# ---- 结果校验：必须在展开后立刻做，避免「看起来成功了但其实路径不对」----
[ -f "$ROOT/device/nvidia/ardbeg_tv/lineage.mk" ] \
    || fail "展开后仍缺 device/nvidia/ardbeg_tv/lineage.mk"
[ -f "$ROOT/device/nvidia/ardbeg_tv/AndroidProducts.mk" ] \
    || fail "展开后仍缺 device/nvidia/ardbeg_tv/AndroidProducts.mk"
[ -d "$ROOT/device/nvidia/shield-common/sepolicy/common" ] \
    || fail "展开后仍缺 shield-common/sepolicy/common"
[ -d "$ROOT/device/nvidia/shield-common/sepolicy/lineage-common" ] \
    || fail "展开后仍缺 shield-common/sepolicy/lineage-common"
[ -d "$ROOT/device/nvidia/shield-common/seccomp" ] \
    || fail "展开后仍缺 shield-common/seccomp"

say ""
say "展开完成："
say "  device/nvidia/ardbeg_tv/      <- merged/ardbeg_tv"
say "  device/nvidia/shield-common/  <- merged/shield-common"
say ""
say "下一步（缺一不可）："
say "  1) cd $HERE/patches && ./check.sh && ./install.sh"
say "  2) cd $ROOT && . build/envsetup.sh && lunch cm_ardbeg_tv-eng && mka bacon"
say ""
say "提示：若用 LineageOS 官方 manifest 同步过 shield-common，本脚本会覆盖同名"
say "      文件但不会删除其它文件；请确认 revision 为 cm-14.1。"
exit 0
