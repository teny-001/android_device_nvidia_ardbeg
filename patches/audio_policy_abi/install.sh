#!/bin/sh
# =============================================================================
# install.sh —— 给厂商预编译的 audio_policy.tegra.so 打 ABI 对齐补丁
#
# 用法：  ./install.sh
#
# 做什么：
#   把 vendor/nvidia/ardbeg/proprietary/lib/hw/audio_policy.tegra.so 里
#   AudioPolicyCompatClient 那 10 处读 audio_policy_service_ops 的偏移
#   整体减 4（因为 4.4.4 比 4.3 少了一个 invalidate_input 成员），
#   并停用 invalidateInput。
#
# 为什么必须这么做：
#   这个 blob 是 NVIDIA 按 Android 4.3 的头文件编译的，而 CM11 是 4.4.4。
#   struct audio_policy_service_ops 从第 9 项起整体前移一格，
#   于是 blob 调 load_hw_module（偏移 64）实际打到 aps_open_output_on_module，
#   传进去的「模块句柄」其实是字符串指针，AudioFlinger 查不到就**静默返回 0**。
#   结果：AudioPolicyManagerBase 报 "could not open HW module primary"，
#        而且一条别的日志都没有；dumpsys 里 Output devices 恒为 00000000。
#
# 安全性：
#   - 只改 Thumb 16 位定长指令里的 imm5 字段，不动长度、不动地址、不动重定位
#   - 改之前先校验原机器码与预期完全一致，不一致就拒绝修改
#   - 自动备份原文件到 audio_policy.tegra.so.orig
#   - 可用 ./uninstall.sh 一键回滚
# =============================================================================
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${ANDROID_BUILD_TOP:-$(cd "$HERE/../../../../.." && pwd)}
BLOB="$ROOT/vendor/nvidia/ardbeg/proprietary/lib/hw/audio_policy.tegra.so"
ORIG="$BLOB.orig"

PYTHON=${PYTHON:-python3}

if [ ! -f "$BLOB" ]; then
    echo "[install] 找不到 $BLOB"
    exit 2
fi

# 已经打过补丁就直接退出（幂等）
if "$HERE/check.sh" >/dev/null 2>&1; then
    echo "[install] 已经是打过补丁的版本，无需重复操作"
    exit 0
fi

# 备份原文件（只在第一次备份，避免把已打补丁的文件覆盖成备份）
if [ ! -f "$ORIG" ]; then
    cp -p "$BLOB" "$ORIG"
    echo "[install] 已备份原文件 -> $(basename "$ORIG")"
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

"$PYTHON" "$HERE/patch_audio_policy.py" "$ORIG" "$TMP"

# 校验结果，防止打歪
SUM=$(md5sum "$TMP" | awk '{print $1}')
if [ "$SUM" != "8ed729dd0b5ea11b9464b2973df3d1dc" ]; then
    echo "[install] 打补丁后的 md5 不符合预期: $SUM"
    echo "          未修改原文件，请检查 patch_audio_policy.py"
    exit 1
fi

cp "$TMP" "$BLOB"
chmod 644 "$BLOB"
echo "[install] 完成，已写入 $BLOB"
echo "[install] 重新编译后 system/lib/hw/audio_policy.tegra.so 即为对齐版本"
