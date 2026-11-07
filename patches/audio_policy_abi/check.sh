#!/bin/sh
# =============================================================================
# check.sh —— 检查 audio_policy.tegra.so 的 ABI 补丁是否已生效
#
# 用法：  ./check.sh
# 返回：  0 = 已打补丁（或已是最新）
#         1 = 尚未打补丁（用的是厂商原始 blob，音频 HAL 加载不起来）
#         2 = 文件缺失或版本不认识
#
# 背景见同目录 patch_audio_policy.py 顶部的长注释。
# =============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${ANDROID_BUILD_TOP:-$(cd "$HERE/../../../../.." && pwd)}
BLOB="$ROOT/vendor/nvidia/ardbeg/proprietary/lib/hw/audio_policy.tegra.so"

# 厂商原始 blob 与打完补丁后的 md5（patch_audio_policy.py 生成，逐字节可复现）
MD5_ORIG=c4b51bf2e7381986b3782ef1c8f4a25a
MD5_PATCHED=8ed729dd0b5ea11b9464b2973df3d1dc

if [ ! -f "$BLOB" ]; then
    echo "[check] 找不到 $BLOB"
    exit 2
fi

SUM=$(md5sum "$BLOB" | awk '{print $1}')

case "$SUM" in
    "$MD5_PATCHED")
        echo "[check] 已打补丁 (md5=$SUM)"
        echo "        audio_policy.tegra.so 的 ops 偏移已对齐 CM11(4.4.4)"
        exit 0
        ;;
    "$MD5_ORIG")
        echo "[check] 尚未打补丁 (md5=$SUM)"
        echo "        厂商 blob 是 4.3 时代的 ABI，loadHwModule 会打到"
        echo "        aps_open_output_on_module 上，导致音频 HAL 加载失败。"
        echo "        请执行 ./install.sh"
        exit 1
        ;;
    *)
        echo "[check] md5 不认识: $SUM"
        echo "        文件可能被换过版本，请先确认再决定是否打补丁。"
        exit 2
        ;;
esac
