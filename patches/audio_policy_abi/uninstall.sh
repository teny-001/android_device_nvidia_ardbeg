#!/bin/sh
# =============================================================================
# uninstall.sh —— 撤销 audio_policy.tegra.so 的 ABI 补丁
#
# 用法：  ./uninstall.sh
#
# 从 audio_policy.tegra.so.orig 还原厂商原始 blob。
# 注意：还原之后音频会重新变哑（HAL 加载不起来），仅用于排查对比。
# =============================================================================
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${ANDROID_BUILD_TOP:-$(cd "$HERE/../../../../.." && pwd)}
BLOB="$ROOT/vendor/nvidia/ardbeg/proprietary/lib/hw/audio_policy.tegra.so"
ORIG="$BLOB.orig"

if [ ! -f "$ORIG" ]; then
    echo "[uninstall] 找不到备份 $ORIG，无法还原"
    echo "            如果确实需要原始文件，可从 git 重新 checkout："
    echo "            git checkout -- vendor/nvidia/ardbeg/proprietary/lib/hw/audio_policy.tegra.so"
    exit 2
fi

cp -p "$ORIG" "$BLOB"
chmod 644 "$BLOB"

SUM=$(md5sum "$BLOB" | awk '{print $1}')
if [ "$SUM" = "c4b51bf2e7381986b3782ef1c8f4a25a" ]; then
    echo "[uninstall] 已还原为厂商原始 blob (md5=$SUM)"
    exit 0
else
    echo "[uninstall] 还原后 md5 异常: $SUM"
    exit 1
fi
