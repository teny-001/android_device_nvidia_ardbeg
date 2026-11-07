#!/bin/bash
# =============================================================================
# verify_hwdec.sh —— ardbeg CM14.1 硬件解码专项真机验收（可重复执行）
#
# 用法:
#     ./verify_hwdec.sh                       # 默认冷启动后跑完整 H.264 + H.265
#     ./verify_hwdec.sh --no-reboot          # 不重启，只验当前运行状态 + 播放
#     ./verify_hwdec.sh /path/to/outdir      # 指定留档目录
#
# 退出码 0 = 硬解全通过；非 0 = 有 FAIL（报告里逐条列出）。
#
# -----------------------------------------------------------------------------
# 【为什么单独做这个工具】
#   patches/check.sh / verify_six_layers.py 只能证明「三条修复的字节进了
#   ROM」，不能证明「OMX.Nvidia.* 真的被创建并解出了视频」。历史上多次
#   出现三个文件 md5 全对、但播放仍报 0x80001000 的情况，所以必须有一层
#   **运行时**证据：组件枚举 → 实例创建 → NvMMLiteOpen → EOS detected。
#   tools/full_function_test.sh 里三个 md5_ 采集行只负责字节，本工具负责
#   行为，两者互补，不要互相替代。
#
# -----------------------------------------------------------------------------
# 【硬件解码三条独立根因，缺一不可】（2026-11-07 真机定位）
#   1) system/lib/libstagefrighthw.so
#      OMXMaster::addVendorPlugin() 会 dlopen("libstagefrighthw.so") 再
#      dlsym 无参 createOMXPlugin / _ZN7android15createOMXPluginEv。
#      旧注释误判「7.1 要 createOMXPlugin(bool secure)」，把 4.4 blob 从
#      device.mk 里排除了，导致 ROM 里完全没有这个桥，OMX.Nvidia.* 一条
#      都注册不上，全部退回 OMX.google.* 软解。
#      实测：本树 frameworks/av/media/libstagefright/omx/OMXMaster.cpp 用的
#      正是无参 CreateOMXPluginFunc；hardware/nvidia/libstagefrighthw/
#      omxplugin.cpp（官方 cm-14.1 桥）同样是无参。
#
#   2) system/etc/media_codecs.xml
#      4.4 原版允许同一组件名以多个 type 属性重复声明。7.1 的
#      MediaCodecList.cpp:737 有
#          if (mUpdate != (index >= 0)) return -EINVAL;
#      第二次遇到同名组件即终止解析，parseTopLevelXMLFile() 随后
#      mCodecInfos.clear()，整张 codec 表清空。ACodec::findMatchingCodecs()
#      拿到空列表，打印 "Unable to instantiate a decoder for type
#      'video/avc' with err 0xfffffffe" (NAME_NOT_FOUND)。
#      修法：改写成 <MediaCodec name="..."><Type .../></MediaCodec>。
#
#   3) system/etc/init/mediacodec.rc 的 group 补 media(1013)
#      7.1 把编解码从 mediaserver(uid 1013) 拆成独立 mediacodec(uid 1046)，
#      primary gid 是 camera(1006)，supplementary groups 原本只有
#      1005/1026/1031。原厂 4.4.4 ueventd 把 /dev/tegra_avpchannel 设成
#      media:media 0660，进程不在 media 组 → libnvavp.so 的 NvAvpOpen()
#      失败 → "Could not get AVP handle" →
#      "NvxVideoDecoderAcquireResources : NvxNvMMTransformOpen failed" →
#      ACodec ERROR(0x80001000) (InsufficientResources)。
#      内核 nvavp 固件是加载成功的，纯用户态权限问题。
#
# -----------------------------------------------------------------------------
# 【真机踩过的坑，全部写进判据】
#   * AVP handle 首次 open 失败后被 NvMM 缓存在进程内，所以「事后
#     chmod 666 节点」对已经启动的进程完全无效；必须先修 group 再冷启动。
#     因此本工具**拒绝**把 chmod 666 当成通过：会检查节点是否仍是
#     media:media 0660。靠放大权限蒙混过关不算固化。
#   * `stop; start` 不是可靠的 framework 重启方式：实测 media.codec pid
#     不变、随后 am 报 DeadObjectException。要干净证据必须 `adb reboot`。
#   * `dumpsys media.codec` 实测 RC=0 但输出为空，不能把「0 字节」当成
#     服务不存在；要結合 service list / ps / logcat 判。
#   * 设备 toybox grep 不支持 BRE `\|`，统一用 grep -cE。
#   * 绝不能用 screencap -p 判亮屏：FLAG_SECURE 屏会挂住 SurfaceFlinger
#     客户端连接，system_server 拿不到 SF 锁会全局 ANR。
#   * logcat / dumpsys 输出一律先落盘再 grep，不能塞进 shell 变量，
#     否则 printf: Argument list too long，grep 拿到空输入造成「假绿」。
#   * 样片放 /data/local/tmp 并 chmod 666，Gallery3d 才读得到；
#     /sdcard 下没有现成样片。
#   * 播放后 EOS 附近常有一条 `dequeueBuffer failed: NO_INIT(-19)`，
#     是收尾阶段正常行为，不算硬解失败，不要加进失败关键字。
#   * 已知遗留 `libnvcap_video.so` / `_ZN7android12MemoryDealerC1EjPKc`
#     属于 hwcomposer / video capture 路径，libnvomx.so 不引用它，
#     不影响普通 H.264/H.265 解码，不纳入本工具判据。
#   * 【2026-11-07 新增判据】播放期间绝不能出现
#     `ActivityManager: START u0 {... com.cyanogenmod.trebuchet/...Launcher}`。
#     首次干净刷入后曾出现 23 PASS / 1 FAIL（H.264 缺 EOS），日志显示
#     16:54:09 硬解已经 NvMMLiteOpen 成功，但 16:54:11 首启脚本
#     zz-ardbeg-firstboot-fix.sh 第 8 步把「用户打开视频播放器」误判成
#     「Launcher 窗口不可见 = 黑屏」，am start HOME 抢前台，
#     NuPlayerDriver 被 reset 在 1.9 秒，NvAvpClose，根本播不到 EOS。
#     这不是解码器故障，但会让硬解验收假红。修法是给首启脚本补
#     foreground_is_home() 守卫；本工具把「HOME 抢前台」设为 0 容忍的
#     硬判据，防止以后回归。
#
# -----------------------------------------------------------------------------
# 【实测基线（2026-11-07 16:20 干净冷启动，见 work/hwdec-1107-1522/fix-v3）】
#   三文件 md5：
#     libstagefrighthw.so  7221cb3656b33b54846e34b5e406163c
#     media_codecs.xml     9c884d66a4e7d44a0b7227cc2ec8ddb5
#     mediacodec.rc        e5dfd2d55c04eb72cbb89ff2327ce4f1
#   冷启动 makeComponentInstance 63 条，含 OMX.Nvidia.h264.decode /
#   h265.decode / mp4.decode / mpeg2v.decode / vp8.decode。
#   H.264 与 H.265 均跑到 "NVMMLITE_TVMR: EOS detected"，
#   且 0x80001000 / NvxNvMMTransformOpen failed 计数均为 0。
#   /dev/tegra_avpchannel 保持 crw-rw---- media media（未 chmod 666）。
# =============================================================================

set -uo pipefail

A="/home/dy/WorkBuddy AI/k1flash/adb"
DEV="-s 0123456789ABCDEF"
ROOT="/home/dy/WorkBuddy AI/ardbeg-cm-14.1"
SAMPLE_DIR="$ROOT/work/hwdec-1107-1522"
H264_LOCAL="$SAMPLE_DIR/test-h264-720p.mp4"
H265_LOCAL="$SAMPLE_DIR/test-h265-720p.mp4"
DEV_DIR=/data/local/tmp/hwdec-verify

REBOOT=1
OUT=""
for arg in "$@"; do
    case "$arg" in
        --no-reboot) REBOOT=0 ;;
        -h|--help)   echo "用法: $0 [--no-reboot] [输出目录]"; exit 0 ;;
        *)           OUT="$arg" ;;
    esac
done
[ -n "$OUT" ] || OUT="$ROOT/work/hwdec-verify-$(date +%m%d-%H%M)"
mkdir -p "$OUT"

S() { "$A" $DEV shell "$1"; }

PASS=0
FAIL=0
FAILED=""
expect() {
    if [ "$2" = "$3" ]; then
        printf '  PASS  %-48s = %s\n' "$1" "$2"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %-48s 实际[%s] 期望[%s]\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1)); FAILED="${FAILED}\n    - $1: 实际[$2] 期望[$3]"
    fi
}
atleast() {
    if [ "$((${2:-0}))" -ge "$3" ] 2>/dev/null; then
        printf '  PASS  %-48s = %s (>= %s)\n' "$1" "$2" "$3"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %-48s 实际[%s] 期望 >= %s\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1)); FAILED="${FAILED}\n    - $1: 实际[$2] 期望 >= $3"
    fi
}
cnt() { grep -cE "$1" "$2" 2>/dev/null || true; }

echo "======================================================================"
echo " ardbeg CM14.1 硬件解码专项验收"
echo " 设备   : 0123456789ABCDEF"
echo " 冷启动 : $([ "$REBOOT" = 1 ] && echo 是 || echo 否)"
echo " 留档   : $OUT"
echo "======================================================================"

# ---------------------------------------------------------------------------
# 0) 前置：设备在线 + 样片齐全
# ---------------------------------------------------------------------------
echo
echo "========== 0. 前置检查 =========="
if ! "$A" devices 2>/dev/null | grep -q '0123456789ABCDEF[[:space:]]*device'; then
    echo "  [FATAL] 设备不在线，先检查 USB / adb。退出。"
    exit 2
fi
for f in "$H264_LOCAL" "$H265_LOCAL"; do
    if [ ! -f "$f" ]; then
        echo "  [FATAL] 缺测试样片 $f"
        echo "          样片是硬解验收的输入，不能省。退出。"
        exit 2
    fi
done
echo "  设备在线，H.264/H.265 样片齐全"

"$A" $DEV root >/dev/null 2>&1
S "rm -rf $DEV_DIR; mkdir -p $DEV_DIR" >/dev/null 2>&1
"$A" $DEV push "$H264_LOCAL" "$DEV_DIR/h264.mp4" >/dev/null 2>&1
"$A" $DEV push "$H265_LOCAL" "$DEV_DIR/h265.mp4" >/dev/null 2>&1
S "chmod 666 $DEV_DIR/h264.mp4 $DEV_DIR/h265.mp4" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 1) 可选冷启动：保证 MediaCodecList 用当前 /system 的 XML 重新解析
#    【坑】不能 stop; start，media.codec pid 不变、后续 am 会 DeadObjectException
# ---------------------------------------------------------------------------
if [ "$REBOOT" = 1 ]; then
    echo
    echo "========== 1. 冷启动（重新解析 codec 表 / 重建 AVP handle）=========="
    "$A" $DEV reboot >/dev/null 2>&1
    sleep 3
    "$A" $DEV wait-for-device >/dev/null 2>&1
    b=""; n=0
    for n in $(seq 1 100); do
        b=$(S 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r')
        [ "$b" = "1" ] && break
        sleep 2
    done
    expect "sys.boot_completed" "$b" "1"
    echo "  （${n} 次轮询后启动完成）"
    sleep 8
    "$A" $DEV root >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
# 2) 三条修复的字节 + 运行时权限
#    只比 md5 不够，还要证明「没靠 chmod 666 蒙混」以及「进程真在 media 组」
# ---------------------------------------------------------------------------
echo
echo "========== 2. 三条修复的字节与运行时权限 =========="
S 'logcat -d -v threadtime' > "$OUT/logcat-state.txt" 2>&1
S '
echo "@m_bridge=$(md5sum /system/lib/libstagefrighthw.so 2>/dev/null | cut -d" " -f1)"
echo "@m_xml=$(md5sum /system/etc/media_codecs.xml 2>/dev/null | cut -d" " -f1)"
echo "@m_rc=$(md5sum /system/etc/init/mediacodec.rc 2>/dev/null | cut -d" " -f1)"
echo "@node=$(ls -l /dev/tegra_avpchannel 2>/dev/null)"
echo "@groups=$(for p in $(pgrep -f media.codec); do grep "^Groups:" /proc/$p/status; done | head -1)"
echo "@codec_svc=$(service list 2>/dev/null | grep -c "media.codec")"
echo "@omx_count=$(logcat -d 2>/dev/null | grep -c makeComponentInstance)"
' > "$OUT/state.txt" 2>&1
get() { grep -m1 "^@$1=" "$OUT/state.txt" | cut -d= -f2- | tr -d '\r'; }

expect "libstagefrighthw.so md5" "$(get m_bridge)" "7221cb3656b33b54846e34b5e406163c"
expect "media_codecs.xml md5"   "$(get m_xml)"    "9c884d66a4e7d44a0b7227cc2ec8ddb5"
expect "mediacodec.rc md5"      "$(get m_rc)"     "e5dfd2d55c04eb72cbb89ff2327ce4f1"

NODE=$(get node)
# 必须是 media:media 0660（crw-rw----），绝不能是 666
case "$NODE" in
    crw-rw----*media*media*) echo "  PASS  /dev/tegra_avpchannel 保持 media:media 0660"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL  /dev/tegra_avpchannel 权限异常: [$NODE]"
       echo "        注意：chmod 666 能临时解出视频，但不算修复（没固化）"
       FAIL=$((FAIL+1)); FAILED="${FAILED}\n    - AVP 节点权限被放大或属主不对" ;;
esac
if printf '%s' "$(get groups)" | grep -qw 1013; then
    echo "  PASS  mediacodec supplementary groups 含 media(1013)"; PASS=$((PASS+1))
else
    echo "  FAIL  mediacodec groups 缺 1013: [$(get groups)]"
    FAIL=$((FAIL+1)); FAILED="${FAILED}\n    - mediacodec 进程不在 media 组"
fi
atleast "media.codec binder 服务已注册" "$(get codec_svc)" "1"
# 【坑】logcat -d 是环形缓冲，开机那 63 条 makeComponentInstance 十几分钟后
# 就会被冲掉。--no-reboot 是「快速复用当前状态」模式，不该拿它数开机日志，
# 否则会假 FAIL；完整证据走默认的冷启动模式。
if [ "$REBOOT" = 1 ]; then
    atleast "冷启动 OMX 组件枚举条数"   "$(get omx_count)" "50"
else
    echo "  SKIP  冷启动 OMX 组件枚举条数（--no-reboot，开机日志可能已被冲掉）"
fi

# ---------------------------------------------------------------------------
# 3) 逐个播放样片，判「真的走了 NVIDIA OMX 硬解」
#    判据：组件实例 + NvMMLiteOpen + EOS detected + 三类失败关键字全 0
# ---------------------------------------------------------------------------
play_one() {
    # 【坑·set -u】bash 的 `local a=1 b="$a"` 里 $a 是在本条语句赋值*之前*
    # 展开的，此时 a 还未绑定，set -u 会直接报 "a: 未绑定的变量" 并中断。
    # 必须拆成两条 local：先声明 tag，再用它拼 log 路径。
    local tag="$1" file="$2" comp="$3"
    local log="$OUT/logcat-$tag.txt"
    echo
    echo "========== 3.$tag 播放 $tag（$comp）=========="
    S 'logcat -c' >/dev/null 2>&1
    S "am start -a android.intent.action.VIEW -d file://$DEV_DIR/$file -t video/mp4" \
        > "$OUT/am-$tag.txt" 2>&1
    sleep 20
    S 'logcat -d -v threadtime' > "$log" 2>&1
    atleast "$tag logcat 行数"            "$(wc -l < "$log")"                            "50"
    atleast "$tag 组件实例 $comp"          "$(cnt "makeComponentInstance\($comp\)" "$log")" "1"
    atleast "$tag NvMMLiteOpen"            "$(cnt 'NvMMLiteOpen' "$log")"                "1"
    atleast "$tag EOS detected"            "$(cnt 'EOS detected' "$log")"                "1"
    expect  "$tag 0x80001000 错误"          "$(cnt '0x80001000' "$log")"                 "0"
    expect  "$tag NvxNvMMTransformOpen 失败" "$(cnt 'NvxNvMMTransformOpen failed' "$log")" "0"
    expect  "$tag Unable to instantiate"   "$(cnt 'Unable to instantiate a decoder' "$log")" "0"
    expect  "$tag Could not get AVP handle" "$(cnt 'Could not get AVP handle' "$log")"   "0"
    # 首启脚本 / 常驻守护都不许在播放期间把 HOME 拉到前台（见头部坑位）
    expect  "$tag 播放期间 HOME 抢前台"      "$(cnt 'ActivityManager: START u0.*com.cyanogenmod.trebuchet' "$log")" "0"
    echo "  关键日志："
    grep -E "makeComponentInstance\($comp\)|NvMMLiteOpen|EOS detected" "$log" \
        | head -4 | sed 's/^/    /'
}
play_one h264 h264.mp4 'OMX.Nvidia.h264.decode'
play_one h265 h265.mp4 'OMX.Nvidia.h265.decode'

# ---------------------------------------------------------------------------
# 4) 收尾：回到桌面，避免把视频播放器留在前台影响后续验收脚本
# ---------------------------------------------------------------------------
S 'am start -n com.cyanogenmod.trebuchet/com.android.launcher3.Launcher' >/dev/null 2>&1

echo
echo "======================================================================"
echo " 汇总：PASS = $PASS   FAIL = $FAIL"
echo " 留档：$OUT"
echo "======================================================================"
if [ "$FAIL" -gt 0 ]; then
    printf ' 未通过项：%b\n' "$FAILED"
    echo
    echo " 排查顺序："
    echo "   1) md5 不对 → 设备上还是调试期临时文件，按六层矩阵重打包刷入"
    echo "   2) 组件枚举 < 50 → 查 libstagefrighthw.so / media_codecs.xml"
    echo "   3) 0x80001000 → 查 mediacodec group 是否含 media、节点是否被 chmod 过"
    echo "   4) 全部通过但没有 EOS → 查样片是否损坏 / Gallery3d 是否真的起播"
    exit 1
fi
echo " 结论：NVIDIA OMX 硬件解码在真机生效，H.264 / H.265 均跑到 EOS。"
exit 0
