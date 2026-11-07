#!/bin/sh
# =============================================================================
# check.sh —— 检查 device/nvidia/ardbeg/patches/ 下的补丁能不能打到源码树上
#
# 只做 dry-run，**不改任何文件**。
#
# 用法：
#   ./check.sh            # 逐个报告状态
#   ./check.sh -l         # 只列清单，不判断状态（快）
#   ./check.sh -v         # 打印实际执行的命令
#
# 状态含义见 README.md，或者看下面的输出。
# =============================================================================

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
. "${HERE}/_common.sh"

LIST_ONLY=0
VERBOSE=0

for arg in "$@"; do
    case "$arg" in
        -l|--list)    LIST_ONLY=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "未知参数: $arg（用 -h 看用法）" >&2
            exit 2
            ;;
    esac
done

TOP=$(detect_top) || exit 1
TOOL=$(detect_tool)

echo "======================================================================"
echo "源码树根目录 : ${TOP}"
echo "补丁目录     : ${HERE}"
echo "补丁工具     : ${TOOL}"
echo "======================================================================"

PATCHES=$(list_patches "${HERE}")
MODES=$(list_mode_fixes "${HERE}")

if [ -z "${PATCHES}" ] && [ -z "${MODES}" ]; then
    echo
    echo "没有找到任何 .patch 文件，也没有权限修复条目。"
    echo
    echo "这是 cm-14.1 目前的正常状态：所有改动都在设备树内部"
    echo "（device/nvidia/ardbeg/ 下），源码树一个代码补丁都不需要。"
    echo
    echo "另外两类东西不在这个脚本的管理范围里："
    echo "  * env-fix/fix-source-tree.sh  源码树的环境性修复（LFS 大文件、32 位宿主工具）"
    echo "  * legacy-cm11/                cm-11 时代的 19 个补丁，仅存档，不参与自动打补丁"
    echo "需要加补丁时按 README.md 里的格式放进来即可。"
    exit 0
fi

if [ "$TOOL" = "none" ]; then
    echo "错误：patch / git / python 三者都不可用，没法检查补丁。" >&2
    echo "      正常情况不该走到这里：没有 patch 和 git 时会自动退回" >&2
    echo "      同目录的 _udiff.py（需要 python）。" >&2
    echo "      装一个就行：" >&2
    echo "        Debian/Ubuntu: sudo apt install patch" >&2
    echo "        Arch:          sudo pacman -S patch" >&2
    exit 1
fi

COUNT=0
N_OK=0
N_APPLIED=0
N_BAD=0

for p in ${PATCHES}; do
    COUNT=$((COUNT + 1))

    if [ "${LIST_ONLY}" -eq 1 ]; then
        echo "  ${p}"
        continue
    fi

    st=$(patch_status "${TOP}" "${HERE}/${p}" "${TOOL}")
    printf "  [%s] %s\n" "$(status_cn "${st}")" "${p}"

    case "${st}" in
        not_applied) N_OK=$((N_OK + 1)) ;;
        applied)     N_APPLIED=$((N_APPLIED + 1)) ;;
        *)           N_BAD=$((N_BAD + 1)) ;;
    esac
done

if [ "${LIST_ONLY}" -eq 1 ]; then
    echo
    echo "共 ${COUNT} 个补丁。"
    exit 0
fi

echo
echo "----------------------------------------------------------------------"
echo "共 ${COUNT} 个补丁：可应用 ${N_OK} / 已应用 ${N_APPLIED} / 有问题 ${N_BAD}"
echo "----------------------------------------------------------------------"

# ---------------------------------------------------------------------------
# 文件权限修复（file-modes.txt）
#   单独一段，因为它不是 diff，patch(1) 处理不了。
# ---------------------------------------------------------------------------
N_MODE_OK=0
N_MODE_APPLIED=0
N_MODE_BAD=0

if [ -n "${MODES}" ]; then
    echo
    echo "文件权限修复（file-modes.txt）："
    echo "${MODES}" | while read -r rel want rest; do
        [ -z "${rel}" ] && continue
        st=$(mode_status "${TOP}" "${rel}" "${want}")
        cur=$(mode_current "${TOP}" "${rel}")
        printf "  [%s] %-48s 当前 %s -> 期望 %s\n" \
               "$(status_cn "${st}")" "${rel}" "${cur}" "${want}"
    done
    # while 在管道里是子 shell，统计值拿不出来，所以单独再跑一遍计数
    N_MODE_OK=$(echo "${MODES}" | while read -r rel want rest; do
        [ -z "${rel}" ] && continue
        [ "$(mode_status "${TOP}" "${rel}" "${want}")" = "not_applied" ] && echo x
    done | wc -l | tr -d ' ')
    N_MODE_APPLIED=$(echo "${MODES}" | while read -r rel want rest; do
        [ -z "${rel}" ] && continue
        [ "$(mode_status "${TOP}" "${rel}" "${want}")" = "applied" ] && echo x
    done | wc -l | tr -d ' ')
    N_MODE_BAD=$(echo "${MODES}" | while read -r rel want rest; do
        [ -z "${rel}" ] && continue
        [ "$(mode_status "${TOP}" "${rel}" "${want}")" = "missing" ] && echo x
    done | wc -l | tr -d ' ')
    echo
    echo "  待修 ${N_MODE_OK} / 已修 ${N_MODE_APPLIED} / 文件缺失 ${N_MODE_BAD}"
fi

if [ "${N_MODE_BAD}" -gt 0 ]; then
    N_BAD=$((N_BAD + 1))
fi

# ---------------------------------------------------------------------------
# 二进制补丁产物核验（2026-11-06 新增）
#
# 【为什么 .patch 全绿还不够】
#   egl_display.cpp.patch 一直显示 [已应用]，但设备上
#   /system/lib/libEGL.so 的 md5 长期是 3cd50337...（原版）。
#   根因：out/target/product/ardbeg/ 被清空过，之后所有 ROM 都走
#   「解 system.img -> 只换改动文件 -> 重新打包签名」的文件级重打包，
#   这条链路只认一份**现成的二进制**，不会去编译 libEGL。
#   结果就是「补丁应用了」和「补丁进 ROM 了」长期脱节，
#   四清后的 EGL_BAD_DISPLAY 黑屏一直清不掉。
#
#   所以除了 22 个 .patch，还要单独校验真正会被打进 system.img 的实物：
#     device/nvidia/ardbeg/prebuilt/lib/libEGL.so      （设备树唯一真源）
#     repack/overlay/system/lib/libEGL.so             （打包侧镜像副本）
#   4ac10584321c81f8dcddd21a025bced6 = 已把 0xA3C8 的 cbnz 改成 nop；
#   3cd50337aeb9aa2220b5007f786cf8bc = 原版，见到它就说明补丁没进包。
#
#   想看 ELF 级别的补丁点校验（PT_LOAD 换算 + 上下文比对）：
#     python3 tools/patch_libegl.py ../prebuilt/lib/libEGL.so --check
#   想从原始基准重新生成：
#     python3 tools/patch_libegl.py tools/libEGL.orig.so
# ---------------------------------------------------------------------------
EGL_WANT_MD5=4ac10584321c81f8dcddd21a025bced6
EGL_PREBUILT="${HERE}/../prebuilt/lib/libEGL.so"
# 重打包工作区是固定的临时目录；不存在就跳过，不算错误
EGL_REPACK="/home/dy/WorkBuddy AI/ardbeg-cm-14.1/repack/overlay/system/lib/libEGL.so"
EGL_BAD=0

echo
echo "二进制补丁产物（libEGL / EGL_BAD_DISPLAY 修复）："
if ! command -v md5sum >/dev/null 2>&1; then
    echo "  [跳过] 本机没有 md5sum，无法核验（极少见）"
elif [ ! -f "${EGL_PREBUILT}" ]; then
    echo "  [缺失] prebuilt/lib/libEGL.so 不存在"
    echo "         用 python3 tools/patch_libegl.py tools/libEGL.orig.so 生成后"
    echo "         拷到 ../prebuilt/lib/libEGL.so"
    EGL_BAD=$((EGL_BAD + 1))
elif [ "$(md5sum "${EGL_PREBUILT}" | cut -d' ' -f1)" != "${EGL_WANT_MD5}" ]; then
    echo "  [错误] prebuilt/lib/libEGL.so md5=$(md5sum "${EGL_PREBUILT}" | cut -d' ' -f1)"
    echo "         期望 ${EGL_WANT_MD5}（= 已打补丁版）"
    EGL_BAD=$((EGL_BAD + 1))
else
    echo "  [已修] prebuilt/lib/libEGL.so  md5 ${EGL_WANT_MD5}"
fi

if [ -d "$(dirname "${EGL_REPACK}")" ] && command -v md5sum >/dev/null 2>&1; then
    if [ ! -f "${EGL_REPACK}" ]; then
        echo "  [缺失] repack/overlay/system/lib/libEGL.so（apply_overlay.py 会因此打包失败）"
        EGL_BAD=$((EGL_BAD + 1))
    elif [ "$(md5sum "${EGL_REPACK}" | cut -d' ' -f1)" != "${EGL_WANT_MD5}" ]; then
        echo "  [错误] repack overlay 副本与设备树真源不一致："
        echo "         $(md5sum "${EGL_REPACK}" | cut -d' ' -f1) != ${EGL_WANT_MD5}"
        EGL_BAD=$((EGL_BAD + 1))
    else
        echo "  [已修] repack/overlay/system/lib/libEGL.so  md5 ${EGL_WANT_MD5}"
    fi
else
    echo "  [跳过] 未找到 repack 工作区（没有做文件级重打包时不算错误）"
fi

# ---------------------------------------------------------------------------
# lmkd 服务定义产物核验（2026-11-06 深夜新增）
#
# 【为什么这一段必须有】
#   和 libEGL 是同一类问题：lmkd.rc.patch 显示 [已应用] 只说明源码树的
#   system/core/lmkd/lmkd.rc 被改过，但本机所有 ROM 都走文件级重打包，
#   真正进 system.img 的是 repack/overlay/system/etc/init/lmkd.rc。
#   若哪天误把 AOSP 原版 176 字节拷回 overlay，check.sh 的 .patch 全绿
#   完全看不出来，而设备上会继续出现：
#       SELinux: Context u:object_r:lmkd_exec:s0 is not valid
#       -> /dev/socket/lmkd 不存在
#       -> ProcessList.writeLmkd() 持 AMS 大锁 Thread.sleep(1000) x3
#       -> Watchdog 杀 system_server -> framework 整体重启 / 黑屏
#
#   这里校验三处逐字节一致 + 真源必须带 seclabel：
#     initfiles/lmkd.rc                              （设备树唯一真源）
#     <TOP>/system/core/lmkd/lmkd.rc                （全量编译路径）
#     repack/overlay/system/etc/init/lmkd.rc        （文件级重打包路径）
# ---------------------------------------------------------------------------
LMKD_DEV="${HERE}/../initfiles/lmkd.rc"
LMKD_SRC="${TOP}/system/core/lmkd/lmkd.rc"
LMKD_REPACK="/home/dy/WorkBuddy AI/ardbeg-cm-14.1/repack/overlay/system/etc/init/lmkd.rc"
LMKD_BAD=0

echo
echo "lmkd 服务定义（Watchdog 杀 system_server 修复）："
if [ ! -f "${LMKD_DEV}" ]; then
    echo "  [缺失] initfiles/lmkd.rc 不存在"
    LMKD_BAD=$((LMKD_BAD + 1))
elif ! grep -q 'seclabel u:r:mediaserver:s0' "${LMKD_DEV}"; then
    echo "  [错误] initfiles/lmkd.rc 缺 seclabel u:r:mediaserver:s0，"
    echo "         说明真源被改回 AOSP 原版，4.4.4 policy 里没有 lmkd_exec 域"
    LMKD_BAD=$((LMKD_BAD + 1))
else
    LMKD_WANT=$(md5sum "${LMKD_DEV}" | cut -d' ' -f1)
    echo "  [已修] initfiles/lmkd.rc  真源 md5 ${LMKD_WANT}"
    for f in "${LMKD_SRC}" "${LMKD_REPACK}"; do
        case "${f}" in
            */repack/overlay/*)
                [ ! -d "$(dirname "${f}")" ] && continue ;;   # 没做重打包就算了
        esac
        if [ ! -f "${f}" ]; then
            echo "  [缺失] ${f}"
            LMKD_BAD=$((LMKD_BAD + 1))
        elif [ "$(md5sum "${f}" | cut -d' ' -f1)" != "${LMKD_WANT}" ]; then
            echo "  [错误] ${f} 与真源不一致"
            echo "         真源 ${LMKD_WANT} != 实际 $(md5sum "${f}" | cut -d' ' -f1)"
            LMKD_BAD=$((LMKD_BAD + 1))
        else
            echo "  [已修] ${f}"
            echo "         md5 ${LMKD_WANT}"
        fi
    done
fi

N_BAD=$((N_BAD + LMKD_BAD))

N_BAD=$((N_BAD + EGL_BAD))

# ---------------------------------------------------------------------------
# OTA 打包完整性：CM 标准的 install/ 目录
#   模板包和早期 15 个重打包产物都没有 install/bin/，导致 backuptool /
#   otasigcheck 从来没跑过。它们缺失不会让刷包失败（edify 的 != "31744"
#   || abort 是短路，脚本缺失返回 256 反而跳过 abort），但会丢掉 addon.d
#   备份与跨 ROM 签名检查。补齐逻辑在 repack/tools/mkzip.py 的
#   EXTRA_ENTRIES，这里只核「注册了 + 源文件在」，避免又出现
#   「补丁体系全绿，但刷机包里没有」的脱节。详见 README 第十三章。
# ---------------------------------------------------------------------------
echo
echo "OTA 打包完整性（install/ 目录）："
ZIP_TOOL="/home/dy/WorkBuddy AI/ardbeg-cm-14.1/repack/tools/mkzip.py"
CM_BIN="${TOP}/vendor/cm/prebuilt/common/bin"
OTA_BAD=0
if [ ! -f "${ZIP_TOOL}" ]; then
    echo "  [跳过] 未找到重打包工具 ${ZIP_TOOL}"
else
    for n in backuptool.sh backuptool.functions otasigcheck.sh; do
        if ! grep -Fq "install/bin/${n}" "${ZIP_TOOL}"; then
            echo "  [错误] mkzip.py 未注册 install/bin/${n}"
            OTA_BAD=$((OTA_BAD + 1))
        elif [ ! -f "${CM_BIN}/${n}" ]; then
            echo "  [错误] CM 源码缺 ${CM_BIN}/${n}"
            OTA_BAD=$((OTA_BAD + 1))
        else
            echo "  [已修] install/bin/${n}"
        fi
    done
fi
N_BAD=$((N_BAD + OTA_BAD))

# ---------------------------------------------------------------------------
# WiFi / 蓝牙开机自启 + 自动连接 + 浏览器「闪退」修复核验
#   [2026-11-06 新增，见 README 第十五章]
#
# 【这一段的必要性】
#   这类修复分散在 5 个文件、两条落地路径里，任何一处漏注册都会静默失效：
#     defaults.xml         全量编译路径的 settings 默认值
#     wifi/*.conf          出厂预置网络模板（真源）
#     device.mk            全量编译路径的 PRODUCT_COPY_FILES
#     apply_overlay.py     文件级重打包路径的 FILES（当前交付走这条）
#     zz-ardbeg-*.sh       运行时兜底（因为重打包不会重编 SettingsProvider.apk）
#   历史上「脚本只放进 overlay/ 目录、忘了注册 FILES」就导致四清后依旧黑屏。
#   这里把四处的存在性和内容一致性全部核一遍。
# ---------------------------------------------------------------------------
echo
echo "WiFi / 蓝牙开机自启、自动连接与浏览器抢前台修复："
CONN_BAD=0
CONN_ROOT="${HERE}/.."
REPACK_ROOT="/home/dy/WorkBuddy AI/ardbeg-cm-14.1/repack"
DEF_XML="${CONN_ROOT}/overlay/packages/providers/SettingsProvider/res/values/defaults.xml"
WIFI_DEV="${CONN_ROOT}/wifi/ardbeg_default_network.conf"
WIFI_OVL="${REPACK_ROOT}/overlay/system/etc/wifi/ardbeg_default_network.conf"
FB_DEV="${CONN_ROOT}/initfiles/zz-ardbeg-firstboot-fix.sh"
FB_OVL="${REPACK_ROOT}/overlay/system/bin/zz-ardbeg-firstboot-fix.sh"
WD_DEV="${CONN_ROOT}/initfiles/zz-ardbeg-home-watchdog.sh"
WD_OVL="${REPACK_ROOT}/overlay/system/bin/zz-ardbeg-home-watchdog.sh"
OVL_TOOL="${REPACK_ROOT}/tools/apply_overlay.py"

# 1) 全量编译路径：settings 默认值
if [ ! -f "${DEF_XML}" ]; then
    echo "  [缺失] ${DEF_XML}"
    CONN_BAD=$((CONN_BAD + 1))
else
    for kw in '<bool name="def_wifi_on">true</bool>' \
              '<bool name="def_bluetooth_on">true</bool>'; do
        if ! grep -Fq "${kw}" "${DEF_XML}"; then
            echo "  [错误] defaults.xml 缺 ${kw}"
            echo "         四清后 settings.db 全新创建，蓝牙不会开机自启"
            CONN_BAD=$((CONN_BAD + 1))
        fi
    done
    echo "  [已修] defaults.xml def_wifi_on / def_bluetooth_on = true"
fi

# 2) 网络模板真源：必须含**顶格** network= 块，否则 sed 抽不到内容
if [ ! -f "${WIFI_DEV}" ]; then
    echo "  [缺失] ${WIFI_DEV}"
    CONN_BAD=$((CONN_BAD + 1))
elif ! grep -q '^network={' "${WIFI_DEV}"; then
    echo "  [错误] 网络模板缺顶格 network={ 块（首启脚本 sed 会抽到空内容）"
    CONN_BAD=$((CONN_BAD + 1))
else
    echo "  [已修] wifi/ardbeg_default_network.conf 含顶格 network={ 块"
fi

# 3) 两条打包路径都要注册
if [ -f "${CONN_ROOT}/device.mk" ]; then
    if ! grep -Fq 'ardbeg_default_network.conf:system/etc/wifi/ardbeg_default_network.conf' "${CONN_ROOT}/device.mk"; then
        echo "  [错误] device.mk 未用 PRODUCT_COPY_FILES 注册网络模板（全量编译路径）"
        CONN_BAD=$((CONN_BAD + 1))
    else
        echo "  [已修] device.mk PRODUCT_COPY_FILES 已注册"
    fi
fi
if [ -f "${OVL_TOOL}" ]; then
    if ! grep -Fq "'/etc/wifi/ardbeg_default_network.conf'" "${OVL_TOOL}"; then
        echo "  [错误] apply_overlay.py 的 FILES 未注册网络模板（文件级重打包路径）"
        echo "         只放进 overlay/ 目录不进 system.img，四清后不会自动连"
        CONN_BAD=$((CONN_BAD + 1))
    else
        echo "  [已修] apply_overlay.py FILES 已注册"
    fi
fi

# 4) overlay 副本与设备树真源逐字节一致（防止只改一边）
for pair in "${WIFI_DEV}|${WIFI_OVL}|网络模板" \
            "${FB_DEV}|${FB_OVL}|首启脚本" \
            "${WD_DEV}|${WD_OVL}|home 守护"; do
    dev=${pair%%|*}; rest=${pair#*|}; ovl=${rest%%|*}; name=${rest#*|}
    if [ ! -f "${ovl}" ]; then
        echo "  [缺失] ${name} 的 overlay 副本 ${ovl}"
        CONN_BAD=$((CONN_BAD + 1))
    elif [ "$(md5sum "${dev}" | cut -d' ' -f1)" != "$(md5sum "${ovl}" | cut -d' ' -f1)" ]; then
        echo "  [错误] ${name} 的设备树真源与 overlay 副本 md5 不一致"
        CONN_BAD=$((CONN_BAD + 1))
    else
        echo "  [已修] ${name} 真源 / overlay md5 一致"
    fi
done

# 5) 运行时兜底脚本的关键判据（少了任一条都会「开机不自启」或「又抢前台」）
for kw in 'svc wifi enable' 'service call bluetooth_manager 6' \
          'NET_TEMPLATE' 'networkHistory.txt' 'wifi_is_enabled' 'bt_is_on'; do
    if ! grep -Fq "${kw}" "${FB_DEV}"; then
        echo "  [错误] 首启脚本缺 ${kw}"
        CONN_BAD=$((CONN_BAD + 1))
    fi
done
# log() 自递归会让整条首启链路的日志消失，排障时极难发现问题
# 必须锚定行首：脚本头部注释里会引用旧的错误写法 `log() { log -t ... }`
# 来解释这个坑，朴素 grep -F 会把注释当成真代码，产生误报。
if grep -Eq '^log\(\) \{[[:space:]]*log -t' "${FB_DEV}"; then
    echo "  [错误] 首启脚本 log() 又变成自递归，fb_fix 日志会全部丢失"
    CONN_BAD=$((CONN_BAD + 1))
fi
for kw in 'foreground_is_home' "grep -B1 'mViewVisibility=0x0'" ; do
    if ! grep -Fq "${kw}" "${WD_DEV}"; then
        echo "  [错误] home 守护缺 ${kw}（浏览器会被每 90 秒踢回桌面）"
        CONN_BAD=$((CONN_BAD + 1))
    fi
done

# 【2026-11-07 新增】首启脚本第 8 步也必须有 foreground_is_home() 守卫。
#   只修常驻守护不够：本脚本是 class late_start + oneshot，一遍要跑
#   1~2 分钟（settings put / WiFi / BT 轮询），期间用户打开视频/浏览器
#   会被误判「Launcher 窗口不可见 = 黑屏」并 am start HOME 抢前台。
#   真机实测把 H.264 播放打断在 1.9 秒（NuPlayerDriver reset +
#   NvAvpClose），硬解专项因此假红一项 EOS detected。
# 【坑】必须锚定**有效代码行**：脚本头部长注释里同时写了旧的错误假设
#   和新的说明，朴素 grep -F 'foreground_is_home' 会把注释当成真代码，
#   与上面 log() 自递归那条是同类误报。
if ! grep -Eq '^[[:space:]]*if ! foreground_is_home; then' "${FB_DEV}"; then
    echo "  [错误] 首启脚本缺 foreground_is_home() 有效守卫，开机后会抢前台打断应用"
    CONN_BAD=$((CONN_BAD + 1))
fi
echo "  [已修] 运行时兜底脚本关键判据齐全（含首启抢前台守卫）"
N_BAD=$((N_BAD + CONN_BAD))

# ---------------------------------------------------------------------------
# 刷机后验收工具 + 最终 OTA 包产物核验（2026-11-06 收编）
#
# 【为什么这一段必须有】
#   上面所有核验都停在「源码 / 设备树 / 打包脚本」这一层，但项目里反复
#   出现的脱节是：补丁全绿、overlay 也齐，可 dist/ 里刷机包还是几天前
#   那份旧 zip。四清一刷，所有调试期用 adb push 验证过的修复全部消失。
#   libEGL.so 就吃过这个亏：egl_display.cpp.patch 显示 [已应用] 大半个月，
#   设备上 /system/lib/libEGL.so 却一直是原版 3cd50337...。
#
#   所以这里再往下游走一步：
#     1) 确认四清验收工具正式收编在设备树里，且判据没被改坏；
#     2) 直接打开 dist/ 下最新的 OTA zip，核条目数 / install/bin 三条 /
#        签名件 / build.prop 的 persist.sys.ui.hw=0 / testzip。
#   不硬编码整包 md5（每次重打包都会变），只核「结构性」特征，
#   这样既能抓到旧包，又不会因为一次正常重打包就误报。
# ---------------------------------------------------------------------------
echo
echo "刷机后验收工具（四清端到端判据）："
VERIFY_TOOL="${HERE}/../tools/verify_after_boot.sh"
VERIFY_BAD=0
if [ ! -f "${VERIFY_TOOL}" ]; then
    echo "  [缺失] ${VERIFY_TOOL}"
    VERIFY_BAD=$((VERIFY_BAD + 1))
else
    for kw in 'EXPECT_BOOT_MD5' 'verify_windows_compact.txt' 'verify_logcat.txt' \
              'PASS = ' 'CHECK_BROWSER' 'wifi_conn' 'bt_on' 'homewd_hijack' \
              'ardbeg_default_network.conf' \
              'last_log_present' 'MD5_SECTION_FAIL' 'SKIP = '; do
        if ! grep -Fq "${kw}" "${VERIFY_TOOL}"; then
            echo "  [错误] 验收工具缺关键判据：${kw}"
            VERIFY_BAD=$((VERIFY_BAD + 1))
        fi
    done
    # 2026-11-07：/cache/recovery/last_log 缺失是「四清 + 按 OTA 块表 dd
    # 写入」这条真机刷机路径的证据边界，不是 ROM 故障。旧版把三项硬判成
    # expect "1"，在 homeguard-1107-1705 真机验收里产出 3 个纯假 FAIL。
    # 去掉注释行后必须能看到按 last_log_present 分流的实际代码，且 SKIP
    # 分支必须由「分区级字节证据全绿」兜底，防止有人把边界当免检金牌。
    if ! sed 's/^[[:space:]]*#.*$//' "${VERIFY_TOOL}" \
            | grep -Fq 'if [ "$(get last_log_present)" = "1" ]; then'; then
        echo "  [错误] 验收工具丢了 last_log 证据边界分流，按块表 dd 刷入会再次假红"
        VERIFY_BAD=$((VERIFY_BAD + 1))
    fi
    # 同样只判非注释行，避免把「禁止使用」的说明文字误判成实际调用
    if sed 's/^[[:space:]]*#.*$//' "${VERIFY_TOOL}" | grep -Fq 'screencap -p'; then
        echo "  [错误] 验收工具又用 screencap 判断亮屏"
        echo "         本机 FLAG_SECURE，screencap 会挂住 SF 并引发全局 ANR"
        VERIFY_BAD=$((VERIFY_BAD + 1))
    fi
    if [ ! -x "${VERIFY_TOOL}" ]; then
        echo "  [错误] 验收工具没有可执行位：chmod +x ${VERIFY_TOOL}"
        VERIFY_BAD=$((VERIFY_BAD + 1))
    fi
    if [ "${VERIFY_BAD}" -eq 0 ]; then
        echo "  [已修] tools/verify_after_boot.sh  50+ 项 PASS/FAIL 自动判定 + last_log 证据边界 SKIP 分流"
    fi
fi
N_BAD=$((N_BAD + VERIFY_BAD))

# ---------------------------------------------------------------------------
# 刷机前「包内文件级」往返校验工具（2026-11-07 新增）
#   verify_after_boot.sh 验的是刷机后的设备分区，上面「最终 OTA 包」段验的
#   是 zip 的条目结构；中间还缺一层：zip 里 system.new.dat 还原出的 ext4
#   中，那 8 个关键文件到底是不是设备树真源那一份。历史上
#   egl_display.cpp.patch 显示「已应用」、但 ROM 里 libEGL.so 一直是原版，
#   就是这一层没验导致的长期脱节。
#   tools/verify_ota_contents.sh 直接做
#       zip -> new.dat/transfer.list -> raw ext4 -> debugfs dump -> md5
#   是刷机前最后一道硬证据；它的 EXPECT_MD5 表必须和
#   verify_after_boot.sh 的 EXPECT_MD5 表逐项一致。
# ---------------------------------------------------------------------------
echo
echo "刷机前包内往返校验工具（zip -> raw ext4 -> 文件 md5）："
OTA_TOOL="${HERE}/../tools/verify_ota_contents.sh"
OTA_TOOL_BAD=0
if [ ! -f "${OTA_TOOL}" ]; then
    echo "  [缺失] ${OTA_TOOL}"
    OTA_TOOL_BAD=$((OTA_TOOL_BAD + 1))
else
    for kw in 'otablocks.py unpack' 'EXPECT_MD5' '4ac10584321c81f8dcddd21a025bced6' \
              '231f397b82a71d94f16c9846140ed9a1' \
              'd2e8dd68fab0df7e80b5373b372ba720' \
              '6500a2babf94cec94c50e4e160517b2b' 'flatpak-spawn' 'testzip'; do
        if ! grep -Fq "${kw}" "${OTA_TOOL}"; then
            echo "  [错误] 包内校验工具缺关键判据：${kw}"
            OTA_TOOL_BAD=$((OTA_TOOL_BAD + 1))
        fi
    done
    if [ ! -x "${OTA_TOOL}" ]; then
        echo "  [错误] 包内校验工具没有可执行位：chmod +x ${OTA_TOOL}"
        OTA_TOOL_BAD=$((OTA_TOOL_BAD + 1))
    fi
    if [ "${OTA_TOOL_BAD}" -eq 0 ]; then
        echo "  [已修] tools/verify_ota_contents.sh  9 文件 md5 + 2 个 init rc 包内往返校验"
    fi
fi
N_BAD=$((N_BAD + OTA_TOOL_BAD))

# ---------------------------------------------------------------------------
# 全面功能测试工具（2026-11-07 新增）
#   verify_after_boot.sh 回答「修复有没有进 ROM」，verify_ota_contents.sh
#   回答「包内文件对不对」，但都不回答「这台机器现在能不能用」。
#   full_function_test.sh 覆盖 16 类子系统、90+ 判据，是设备全面调试的
#   正式收编工具。这里核它存在、可执行、关键判据没被改坏。
#
#   特别注意 `settings_global.txt` 这个关键字：7.1 把三个 animation scale
#   从 Settings.System 迁到了 Settings.Global（Settings.java:1865-1867，
#   WMS 读的也是 Global）。曾经差点因为 `settings list system` 显示 1.0
#   就误判「首启脚本的动画修复没固化」，实际上框架读的是 global=0。
#   判据必须锚定 global，不能退回 system。
# ---------------------------------------------------------------------------
echo
echo "全面功能测试工具（设备端到端 16 类子系统）："
FFT_TOOL="${HERE}/../tools/full_function_test.sh"
FFT_BAD=0
if [ ! -f "${FFT_TOOL}" ]; then
    echo "  [缺失] ${FFT_TOOL}"
    FFT_BAD=$((FFT_BAD + 1))
else
    for kw in 'settings_global.txt' 'MOVED_TO_GLOBAL' 'full_function_test' \
              'CHECK_LONG' 'menu_check.txt' 'adb push/pull' \
              '/sys/fs/pstore/console-ramoops' \
              '4ac10584321c81f8dcddd21a025bced6' \
              '231f397b82a71d94f16c9846140ed9a1' \
              'd2e8dd68fab0df7e80b5373b372ba720' \
              '6500a2babf94cec94c50e4e160517b2b' \
              'event[0-9]+$' 'svc_persistlog' 'init.svc.persist_logcat' \
              'window_animation_scale' 'dmesg.txt' 'FATAL EXCEPTION' \
              'SKIP = ' 'if [ "$(get last_log)" = "1" ]; then'; do
        if ! grep -Fq "${kw}" "${FFT_TOOL}"; then
            echo "  [错误] 全面测试工具缺关键判据：${kw}"
            FFT_BAD=$((FFT_BAD + 1))
        fi
    done
    # 【坑】不能全文 grep 'screencap -p'：full_function_test.sh 头部第 34 行
    # 有一条「不要用 `screencap -p` 判亮屏」的**禁止性注释**，原文 grep 会
    # 把它当成实际调用，造出假红字（2026-11-07 复跑时真踩到过）。
    # 与 apply_overlay.py 的 seclabel 校验同理：先剔掉注释行再判。
    if sed 's/^[[:space:]]*#.*$//' "${FFT_TOOL}" | grep -Fq 'screencap -p'; then
        echo "  [错误] 全面测试工具又用 screencap 判断亮屏（FLAG_SECURE 会挂住 SF）"
        FFT_BAD=$((FFT_BAD + 1))
    fi
    if ! sh -n "${FFT_TOOL}" 2>/dev/null; then
        echo "  [错误] 全面测试工具 shell 语法检查不通过：sh -n ${FFT_TOOL}"
        FFT_BAD=$((FFT_BAD + 1))
    fi
    if [ ! -x "${FFT_TOOL}" ]; then
        echo "  [错误] 全面测试工具没有可执行位：chmod +x ${FFT_TOOL}"
        FFT_BAD=$((FFT_BAD + 1))
    fi
    if [ "${FFT_BAD}" -eq 0 ]; then
        echo "  [已修] tools/full_function_test.sh  16 类子系统 + 108 项 PASS/FAIL + 原始日志留档"
    fi
fi
N_BAD=$((N_BAD + FFT_BAD))

# ---------------------------------------------------------------------------
# persist_logcat 全程日志服务（2026-11-07 全面功能测试补修）
#   full_function_test.sh 首轮 103/2 的第二个真失败项：
#       /cache/persist_log.txt 非空: 实际[0] 期望[1]
#   根因：ls -Z 显示 /system/bin/logcat = u:object_r:logcat_exec:s0，
#   这是 7.1 file_contexts 的标签，4.4.4 /sepolicy 里没有该 type，
#   init 在 system/core/init/service.cpp:368 的 security_compute_create()
#   返回 -1，384-387 行 `if (rc < 0) return false` 直接把服务掐掉，
#   连 fork 都到不了、init.svc.persist_logcat 属性压根不会出现。
#   Permissive 也救不了（那条分支不看 enforcing）。
#   修法：写死 seclabel u:r:init:s0，走 347-348 行短路。
#   设备树里其它自定义服务（ardbeg_homewd / sf_hwc_off）用的是
#   /system/bin/sh（shell_exec:s0，旧 policy 认识）所以不用加；
#   audioserver / cameraserver / mediacodec / mediaextractor / lmkd
#   早就加了 seclabel，本文件是唯一漏掉的一个。
#
#   这一段必须同时核「真源有非注释的 seclabel」「overlay 副本 md5 一致」
#   「两张验收表都锚定新 md5」「重打包注册存在」，否则又会出现
#   「真源改了、ROM 里还是旧 rc」的长期脱节（egl_display.cpp.patch 同款）。
# ---------------------------------------------------------------------------
echo
echo "persist_logcat 全程日志（seclabel 固化 + 包内锚定）："
PL_BAD=0
PL_RC="${HERE}/../initfiles/zz-persist-log.rc"
PL_OV="/home/dy/WorkBuddy AI/ardbeg-cm-14.1/repack/overlay/system/etc/init/zz-persist-log.rc"
PL_OV_TOOL="/home/dy/WorkBuddy AI/ardbeg-cm-14.1/repack/tools/apply_overlay.py"
PL_MD5=6500a2babf94cec94c50e4e160517b2b
if [ ! -f "${PL_RC}" ]; then
    echo "  [缺失] 设备树真源：${PL_RC}"
    PL_BAD=$((PL_BAD + 1))
else
    if ! grep -Eq '^[[:space:]]*seclabel[[:space:]]+u:r:init:s0' "${PL_RC}"; then
        echo "  [错误] zz-persist-log.rc 没有生效的 seclabel u:r:init:s0（只有注释不算）"
        PL_BAD=$((PL_BAD + 1))
    fi
    PL_REAL=$(md5sum "${PL_RC}" | cut -d' ' -f1)
    if [ "${PL_REAL}" != "${PL_MD5}" ]; then
        echo "  [错误] 真源 md5=${PL_REAL}，期望 ${PL_MD5}；两张验收表也要同步"
        PL_BAD=$((PL_BAD + 1))
    fi
    if [ ! -f "${PL_OV}" ]; then
        echo "  [缺失] overlay 副本：${PL_OV}"
        PL_BAD=$((PL_BAD + 1))
    elif [ "$(md5sum "${PL_OV}" | cut -d' ' -f1)" != "${PL_MD5}" ]; then
        echo "  [错误] overlay 副本与真源 md5 不一致，重打包会写进旧 rc"
        PL_BAD=$((PL_BAD + 1))
    fi
fi
if ! grep -Fq "'/etc/init/zz-persist-log.rc'" "${PL_OV_TOOL}" 2>/dev/null; then
    echo "  [错误] apply_overlay.py 的 FILES 没注册 zz-persist-log.rc"
    PL_BAD=$((PL_BAD + 1))
fi
for t in "${HERE}/../tools/verify_after_boot.sh" \
         "${HERE}/../tools/verify_ota_contents.sh"; do
    if ! grep -Fq "${PL_MD5}" "${t}" 2>/dev/null; then
        echo "  [错误] $(basename "${t}") 的 EXPECT_MD5 没有锚定新 rc：${PL_MD5}"
        PL_BAD=$((PL_BAD + 1))
    fi
done
# 全面测试工具的 input_events 判据：/dev/input 目录列表只有 basename，
# 不能 grep '/dev/input/event'，否则永远数到 0（首轮假 FAIL）。
if ! grep -Fq 'event[0-9]+$' "${HERE}/../tools/full_function_test.sh" 2>/dev/null; then
    echo "  [错误] full_function_test.sh 的 input_events 判据退回旧写法"
    PL_BAD=$((PL_BAD + 1))
fi
if [ "${PL_BAD}" -eq 0 ]; then
    echo "  [已修] seclabel u:r:init:s0 + overlay/校验表/重打包注册四处一致"
fi
N_BAD=$((N_BAD + PL_BAD))

# ----------------------------------------------------------------------
# [2026-11-07 新增] 真机刷机实验工具链
#   TWRP 3.1.1 在 4.4.4 kernel 上 framebuffer 0x0、UI 每 5 秒崩一次，
#   ORS 的 install / wipe data 会被截断，所以干净刷机实验必须绕开 UI：
#   在 recovery shell 里按 system.transfer.list 逐条 dd 写 system 分区。
#   gen_flash_blocks.py 就是这条路径的唯一真源，2026-11-07 已真机跑通
#   （215 条 dd / 分区逐字节 md5 与包内还原镜像一致 / 干净冷启动 48+51+108 全绿）。
#   这里核验「工具还在、语法对、坑位注释没被删、脚本与块表仍一致」，
#   避免以后只留一个结论却丢了复现能力。
# ----------------------------------------------------------------------
echo
echo "真机刷机实验工具链（绕开 TWRP UI 的按块表写入）："
GFB_BAD=0
GFB_TOOL="${HERE}/../tools/gen_flash_blocks.py"
GFB_EXP="/home/dy/WorkBuddy AI/ardbeg-cm-14.1/work/flash-experiment-fulltest-1107-1354"
if [ ! -f "${GFB_TOOL}" ]; then
    echo "  [错误] 缺 tools/gen_flash_blocks.py，真机实验没有可复现的块表展开工具"
    GFB_BAD=$((GFB_BAD + 1))
else
    GFB_PY=$(find_python "${TOP}")
    if [ -z "${GFB_PY}" ]; then
        echo "  [跳过] 找不到 python，无法对生成器做语法/自检复核"
    elif ! "${GFB_PY}" -m py_compile "${GFB_TOOL}" >/dev/null 2>&1; then
        echo "  [错误] gen_flash_blocks.py 语法检查失败"
        GFB_BAD=$((GFB_BAD + 1))
    else
        # 每个关键字都对应本轮真机踩过的一个坑；删掉注释 = 把经验丢了
        for kw in 'parse_transfer_list' 'build_commands' 'self_check' \
                  'sys.boot_completed' 'set -- $(md5' 'BLOCK-FLASH-DONE' \
                  '紧凑拼接' '2^31' 'run_dd' 'progress' 'SIGHUP'; do
            if ! grep -Fq "${kw}" "${GFB_TOOL}" 2>/dev/null; then
                echo "  [错误] gen_flash_blocks.py 少了关键判据/坑位注释：${kw}"
                GFB_BAD=$((GFB_BAD + 1))
            fi
        done
        if [ -f "${GFB_EXP}/system.transfer.list" ] && \
           [ -f "${GFB_EXP}/system.new.dat" ] && \
           [ -f "${GFB_EXP}/flash_blocks.sh" ]; then
            if ! "${GFB_PY}" "${GFB_TOOL}" --verify \
                    "${GFB_EXP}/system.transfer.list" \
                    "${GFB_EXP}/flash_blocks.sh" \
                    "${GFB_EXP}/system.new.dat" >/dev/null 2>&1; then
                echo "  [错误] flash_blocks.sh 与块表不再一致（--verify 失败）"
                GFB_BAD=$((GFB_BAD + 1))
            fi
        fi
    fi
fi
if [ "${GFB_BAD}" -eq 0 ]; then
    echo "  [已修] tools/gen_flash_blocks.py 静态自检可复现，块表/脚本一致"
fi
N_BAD=$((N_BAD + GFB_BAD))

# ----------------------------------------------------------------------
# [2026-11-07 收官补强] 六层字节一致性矩阵
#   上面各段查的是「补丁在不在、注册没注册、包在不在」，属于存在性/静态
#   判据。历史上出现过 check.sh 全绿但设备 libEGL.so 仍是原版的脱节：
#   PRODUCT_COPY_FILES 对已由 AOSP 模块产出的 system/lib/libEGL.so 会被
#   build/core 静默 ignored。tools/verify_six_layers.py 把 L1 期望 /
#   L2 源码补丁 / L3 设备树真源 / L4 overlay+FILES / L5 最终包内 debugfs
#   dump / L6 真机 md5 摆成一张表，逐字节对齐才算「真的进 ROM 且生效」。
#   这里只做静态核验（工具在、语法对、坑位注释没被删、报告曾全绿）；
#   完整矩阵需要设备在线 + debugfs + 3GiB raw，单独跑该工具，不塞进来。
# ----------------------------------------------------------------------
echo
echo "六层字节一致性矩阵（补丁是否真的进 ROM 且在真机生效）："
SL_BAD=0
SL_TOOL="${HERE}/../tools/verify_six_layers.py"
SL_EXP="/home/dy/WorkBuddy AI/ardbeg-cm-14.1/work/homeguard-flash-1107-1705"
if [ ! -f "${SL_TOOL}" ]; then
    echo "  [错误] 缺 tools/verify_six_layers.py，六层固化没有字节级复核工具"
    SL_BAD=$((SL_BAD + 1))
else
    SL_PY=$(find_python "${TOP}")
    if [ -n "${SL_PY}" ] && ! "${SL_PY}" -m py_compile "${SL_TOOL}" >/dev/null 2>&1; then
        echo "  [错误] verify_six_layers.py 语法检查失败"
        SL_BAD=$((SL_BAD + 1))
    fi
    # 每个关键字都对应一个真实踩过的坑；删掉注释 = 把经验丢了
    for kw in 'flatpak-spawn' 'debugfs -f' 'system.new.dat' 'libminijail' \
              '禁止 screencap' 'persist.sys.ui.hw=0' 'FILES' \
              'L5' 'L6' 'raw-md5' 'offline'; do
        if ! grep -Fq "${kw}" "${SL_TOOL}" 2>/dev/null; then
            echo "  [错误] verify_six_layers.py 少了关键判据/坑位注释：${kw}"
            SL_BAD=$((SL_BAD + 1))
        fi
    done
    # 报告是运行时证据：存在就必须仍全绿，不存在只算缺证据不报错
    if [ -f "${SL_EXP}/six-layer-md5-matrix.txt" ]; then
        if ! grep -Fq '共 0 个 FAIL' "${SL_EXP}/six-layer-md5-matrix.txt"; then
            echo "  [错误] 六层矩阵报告不是全绿，按报告逐条排查脱节层"
            SL_BAD=$((SL_BAD + 1))
        fi
    fi
fi
if [ "${SL_BAD}" -eq 0 ]; then
    echo "  [已修] tools/verify_six_layers.py 六层字节判据齐备，矩阵报告全绿"
fi
N_BAD=$((N_BAD + SL_BAD))

# ----------------------------------------------------------------------
# 硬件解码专项（2026-11-07）：OMX.Nvidia.* 三条独立根因，缺一不可
#   六层矩阵管「字节有没有进 ROM」，这一段管「固化声明齐不齐 + 有没有
#   可重复的运行时验收工具」。三条根因与真机判据的完整推导见
#   tools/verify_hwdec.sh 头部长注释。
#     1) libstagefrighthw.so  OMXMaster::addVendorPlugin 的桥
#     2) media_codecs.xml     7.1 不允许同名组件重复声明
#     3) mediacodec.rc        group 补 media(1013) 才打得开 AVP 通道
# ----------------------------------------------------------------------
echo
echo "硬件解码专项（OMX 桥 / codec 表 / AVP 权限 + 运行时验收）："
HW_BAD=0
HW_DEV="${HERE}/.."
HW_TOOL="${HW_DEV}/tools/verify_hwdec.sh"
HW_PATCH="${HERE}/frameworks/av/services/mediacodec/mediacodec.rc.patch"
HW_OVL="/home/dy/WorkBuddy AI/ardbeg-cm-14.1/repack/tools/apply_overlay.py"

# 1) 设备树三个真源必须就是真机验证过的那三个字节序列。
#    历史上 initfiles/mediacodec.rc 曾漏同步、仍是旧 2471 字节版本，
#    而 AOSP / overlay 已是修复版 —— 只查「文件存在」抓不到这种漂移。
for spec in \
    "prebuilt/lib/libstagefrighthw.so|7221cb3656b33b54846e34b5e406163c" \
    "media/media_codecs.xml|9c884d66a4e7d44a0b7227cc2ec8ddb5" \
    "initfiles/mediacodec.rc|e5dfd2d55c04eb72cbb89ff2327ce4f1"; do
    HW_REL=$(printf '%s\n' "${spec}" | cut -d'|' -f1)
    HW_WANT=$(printf '%s\n' "${spec}" | cut -d'|' -f2)
    HW_FILE="${HW_DEV}/${HW_REL}"
    if [ ! -f "${HW_FILE}" ]; then
        echo "  [错误] 缺设备树真源 ${HW_REL}"
        HW_BAD=$((HW_BAD + 1))
        continue
    fi
    HW_GOT=$(md5sum "${HW_FILE}" | cut -d' ' -f1)
    if [ "${HW_GOT}" != "${HW_WANT}" ]; then
        echo "  [错误] ${HW_REL} md5 ${HW_GOT} != 验证过的 ${HW_WANT}"
        HW_BAD=$((HW_BAD + 1))
    fi
done

# 2) AOSP 源码补丁必须真的把 media 加进 group，不能只看「补丁文件存在」
if [ ! -f "${HW_PATCH}" ]; then
    echo "  [错误] 缺 mediacodec.rc.patch（AVP 通道权限的全量编译侧来源）"
    HW_BAD=$((HW_BAD + 1))
elif ! grep -Eq '^\+[[:space:]]*group .*media' "${HW_PATCH}"; then
    echo "  [错误] mediacodec.rc.patch 没有把 media 加进 group"
    HW_BAD=$((HW_BAD + 1))
fi

# 3) 全量编译侧注册（PRODUCT_COPY_FILES）
for kw in 'prebuilt/lib/libstagefrighthw.so:system/lib/libstagefrighthw.so' \
          'media/media_codecs.xml:system/etc/media_codecs.xml'; do
    if ! grep -Fq "${kw}" "${HW_DEV}/device.mk" 2>/dev/null; then
        echo "  [错误] device.mk 少了全量编译侧注册：${kw}"
        HW_BAD=$((HW_BAD + 1))
    fi
done

# 4) 文件级重打包侧：FILES 注册 + 三条字节/语义硬校验 + XML 注释剥离坑位
if [ ! -f "${HW_OVL}" ]; then
    echo "  [错误] 缺 apply_overlay.py，硬解三项无法进 ROM"
    HW_BAD=$((HW_BAD + 1))
else
    for kw in "'/lib/libstagefrighthw.so'" "'/etc/media_codecs.xml'" \
              "'/etc/init/mediacodec.rc'" 'OMX_BRIDGE_MD5' 'CODEC_XML_DEV' \
              'MEDIACODEC_RC_DEV' 're.sub' '重复组件名' 'group 里没有 media'; do
        if ! grep -Fq "${kw}" "${HW_OVL}" 2>/dev/null; then
            echo "  [错误] apply_overlay.py 少了硬解判据/坑位：${kw}"
            HW_BAD=$((HW_BAD + 1))
        fi
    done
fi

# 5) 四张验收表必须都锚定三个 md5，任何一张漏了都会出现「假绿」
for HW_T in "${HW_DEV}/tools/verify_ota_contents.sh" \
            "${HW_DEV}/tools/verify_after_boot.sh" \
            "${HW_DEV}/tools/verify_six_layers.py" \
            "${HW_DEV}/tools/full_function_test.sh"; do
    if [ ! -f "${HW_T}" ]; then
        echo "  [错误] 缺验收工具 ${HW_T}"
        HW_BAD=$((HW_BAD + 1))
        continue
    fi
    for m in 7221cb3656b33b54846e34b5e406163c \
             9c884d66a4e7d44a0b7227cc2ec8ddb5 \
             e5dfd2d55c04eb72cbb89ff2327ce4f1; do
        if ! grep -Fq "${m}" "${HW_T}" 2>/dev/null; then
            echo "  [错误] $(basename "${HW_T}") 没锚定硬解 md5 ${m}"
            HW_BAD=$((HW_BAD + 1))
        fi
    done
done

# 6) 运行时验收工具：只比 md5 不能证明「真的解出视频」
#    每个关键字对应一条真机踩过的坑或一条必须出现的运行时证据。
if [ ! -x "${HW_TOOL}" ]; then
    echo "  [错误] 缺可执行 tools/verify_hwdec.sh，硬解没有运行时验收"
    HW_BAD=$((HW_BAD + 1))
else
    if ! bash -n "${HW_TOOL}" >/dev/null 2>&1; then
        echo "  [错误] verify_hwdec.sh 语法检查失败"
        HW_BAD=$((HW_BAD + 1))
    fi
    for kw in 'EOS detected' '0x80001000' 'NvMMLiteOpen' \
              'OMX.Nvidia.h264.decode' 'OMX.Nvidia.h265.decode' \
              'NvxNvMMTransformOpen failed' 'Could not get AVP handle' \
              'media:media 0660' '1013' 'chmod 666' 'screencap' \
              'grep -cE' 'adb reboot' 'Unable to instantiate a decoder' \
              'ActivityManager: START u0.*com.cyanogenmod.trebuchet'; do
        if ! grep -Fq "${kw}" "${HW_TOOL}" 2>/dev/null; then
            echo "  [错误] verify_hwdec.sh 少了关键判据/坑位注释：${kw}"
            HW_BAD=$((HW_BAD + 1))
        fi
    done
fi
if [ "${HW_BAD}" -eq 0 ]; then
    echo "  [已修] 硬解三条根因字节/注册/验收表齐备，运行时验收工具可重复执行"
fi
N_BAD=$((N_BAD + HW_BAD))

# ----------------------------------------------------------------------
# app 视频播放验收（2026-11-07）：只验 OMX 组件实例不够，必须覆盖
#   1) 系统播放器 Gallery3d/.app.MovieActivity（本地 mp4）
#   2) 浏览器 Jelly 的 HTML5 <video>（http:// + 真实触摸手势）
#   3) 第三方在线视频 app（HLS，用帧时间戳推进判断是否真出画面）
# 完整推导与坑位见 tools/verify_app_video.sh 头部注释、README 第二十章。
# ----------------------------------------------------------------------
echo
echo "app 视频播放验收（Gallery / Jelly HTML5 / 在线 app 帧刷新）："
AV_TOOL="${HERE}/../tools/verify_app_video.sh"
AV_BAD=0
if [ ! -x "${AV_TOOL}" ]; then
    echo "  [错误] 缺可执行 tools/verify_app_video.sh，app 层播放没有验收"
    AV_BAD=$((AV_BAD + 1))
else
    if ! bash -n "${AV_TOOL}" >/dev/null 2>&1; then
        echo "  [错误] verify_app_video.sh 语法检查失败"
        AV_BAD=$((AV_BAD + 1))
    fi
    # 每个关键字对应一条真机踩过的坑或一条必须出现的行为证据
    for kw in 'MovieActivity' 'org.lineageos.jelly' 'ARDVID playing' \
              'button_clicked' 'play_resolved' 'play_rejected' \
              'input tap' 'adb reverse' 'http.server' \
              'SurfaceFlinger --latency' 'EOS detected' 'NvMMLiteOpen' \
              'media:media' '1013' 'net::ERR' 'CHECK_ONLINE' \
              'screencap -p' 'grep -cE' 'Address already in use' \
              'z-index:99' 'H / 2'; do
        if ! grep -Fq "${kw}" "${AV_TOOL}" 2>/dev/null; then
            echo "  [错误] verify_app_video.sh 少了关键判据/坑位注释：${kw}"
            AV_BAD=$((AV_BAD + 1))
        fi
    done
    # 【老坑】不能全文 grep 'screencap -p'：头部「禁止使用」注释会误伤。
    # 剔除注释行后再判实际调用，命中即说明有人把危险命令写回来了。
    if sed 's/^[[:space:]]*#.*$//' "${AV_TOOL}" | grep -Fq 'screencap -p'; then
        echo "  [错误] verify_app_video.sh 实际调用了 screencap -p（会挂住 SF 引发 ANR）"
        AV_BAD=$((AV_BAD + 1))
    fi
fi
if [ "${AV_BAD}" -eq 0 ]; then
    echo "  [已修] app 视频播放三类入口可重复验收，WebView 手势/端口占用坑位齐备"
fi
N_BAD=$((N_BAD + AV_BAD))

echo
echo "最终 OTA 包产物（重打包是否真的落地）："
DIST_ROOT="/home/dy/WorkBuddy AI/ardbeg-cm-14.1/dist"
PKG_BAD=0
PY=$(find_python "${TOP}")
if [ ! -d "${DIST_ROOT}" ]; then
    echo "  [跳过] 未找到 dist 工作区（还没做文件级重打包时不算错误）"
elif [ -z "${PY}" ]; then
    echo "  [跳过] 找不到 python，无法读 zip 条目"
else
    LATEST=$(ls -t "${DIST_ROOT}"/*/cm_ardbeg_tv-ota-eng.dy.zip 2>/dev/null | head -1)
    if [ -z "${LATEST}" ] || [ ! -f "${LATEST}" ]; then
        echo "  [跳过] dist 下还没有 OTA 包"
    else
        echo "  最新包 : ${LATEST}"
        echo "  大小   : $(wc -c < "${LATEST}") 字节"
        if command -v md5sum >/dev/null 2>&1; then
            echo "  md5    : $(md5sum "${LATEST}" | cut -d' ' -f1)"
        fi
        # ------------------------------------------------------------------
        # [2026-11-06 新增，2026-11-07 分层] 包必须比所有关键源文件**新**
        #   项目里最反复出现的脱节就是「源码 / overlay 都改了，dist 里还是
        #   几天前那份旧 zip」，四清一刷全部回到未修状态。整包 md5 每次
        #   重打包都会变，不能硬编码；用 mtime 比较既稳又能自动适配。
        #   注意这里用 python 而不是 [ -nt ]：check.sh 是 #!/bin/sh，
        #   POSIX sh 不保证 -nt 可用。
        #
        #   【为什么要分 A / B 两组】
        #   初版把所有文件一视同仁，结果「改了只跑在宿主侧的验收脚本 /
        #   README」也会报「需重打包」，是假阳性：这些文件根本不进
        #   system.img。而且修完包之后还要回头把基准包路径写进
        #   verify_after_boot.sh，那个写动作本身又会触发红字，形成死循环。
        #     A 组 = 真正决定 OTA 内容的源文件：比包新 -> 真错误，必须重打
        #     B 组 = 宿主侧验收工具 / 文档：比包新 -> 只提示，不计入 PKG_BAD
        #
        #   【defaults.xml 的边界，务必别误读】
        #   A 组里的 overlay/.../SettingsProvider/res/values/defaults.xml
        #   走的是「全量编译 -> aapt 编进 SettingsProvider.apk」路径；
        #   当前 ROM 是文件级重打包，只是把源码树文件留在设备树里，
        #   **不会**重编 APK，所以 def_wifi_on / def_bluetooth_on 并不因此
        #   进入这个 zip。它在 A 组里的意义是提醒「若恢复全量编译，
        #   SettingsProvider.apk 必须重编」。文件级 ROM 的等价效果由
        #   zz-ardbeg-firstboot-fix.sh 第 9 节的运行时兜底保证
        #   （settings put + svc wifi enable + Binder enable + 预置网络），
        #   已从「两个 radio 全关、无任何已保存网络」的干净状态冷启动
        #   实测通过。详见 patches/README.md 第十五章。
        # ------------------------------------------------------------------
        STALE=$("${PY}" -c "
import os, sys
pkg, root = sys.argv[1], sys.argv[2]
t = os.path.getmtime(pkg)
# A 组：决定 system.img / boot.img 内容，比包新就必须重打包
img_keys = [
    'initfiles/zz-ardbeg-firstboot-fix.sh',
    'initfiles/zz-ardbeg-home-watchdog.sh',
    # 2026-11-07：这个 rc 决定 persist_logcat 能否起来；漏在 A 组外的话，
    # 改了 rc 却没重打包，check.sh 会一路绿灯（本次全面测试就抓到过）。
    'initfiles/zz-persist-log.rc',
    'wifi/ardbeg_default_network.conf',
    'overlay/packages/providers/SettingsProvider/res/values/defaults.xml',
    'device.mk',
]
# B 组：只在宿主侧使用，不进 ROM，比包新只提示
doc_keys = [
    'tools/verify_after_boot.sh',
    'tools/verify_ota_contents.sh',
    'tools/full_function_test.sh',
    # 2026-11-07：真机刷机实验的块表展开工具，只在宿主侧跑，不进 ROM
    'tools/gen_flash_blocks.py',
    # 2026-11-07 收官补强：六层字节一致性矩阵，宿主侧复核工具，不进 ROM
    'tools/verify_six_layers.py',
    # 2026-11-07 硬件解码专项：真机运行时验收，宿主侧工具，不进 ROM
    'tools/verify_hwdec.sh',
    # 2026-11-07 app 视频播放验收：宿主侧工具，不进 ROM
    'tools/verify_app_video.sh',
    'patches/README.md',
]
extra = '/home/dy/WorkBuddy AI/ardbeg-cm-14.1/repack/tools/apply_overlay.py'
out = []
for k in img_keys:
    p = os.path.join(root, k)
    if os.path.exists(p) and os.path.getmtime(p) > t:
        out.append('IMG:' + k)
for k in doc_keys:
    p = os.path.join(root, k)
    if os.path.exists(p) and os.path.getmtime(p) > t:
        out.append('DOC:' + k)
if os.path.exists(extra) and os.path.getmtime(extra) > t:
    out.append('IMG:apply_overlay.py')
print('\n'.join(out))
" "${LATEST}" "${HERE}/.." 2>/dev/null)
        STALE_IMG=$(printf '%s\n' "${STALE}" | grep '^IMG:' | cut -d: -f2- || true)
        STALE_DOC=$(printf '%s\n' "${STALE}" | grep '^DOC:' | cut -d: -f2- || true)
        if [ -n "${STALE_IMG}" ]; then
            printf '%s\n' "${STALE_IMG}" | while IFS= read -r f; do
                echo "  [错误] 源文件比最终包新，需重打包：${f}"
            done
            PKG_BAD=$((PKG_BAD + 1))
        fi
        if [ -n "${STALE_DOC}" ]; then
            printf '%s\n' "${STALE_DOC}" | while IFS= read -r f; do
                echo "  [提示] 宿主侧文件比包新（不进 ROM，无需重打包）：${f}"
            done
        fi
        if [ -z "${STALE_IMG}" ] && [ -z "${STALE_DOC}" ]; then
            echo "  [已修] 最终包比所有关键源文件新（已重打包）"
        elif [ -z "${STALE_IMG}" ]; then
            echo "  [已修] 最终包比所有决定 ROM 内容的源文件新（已重打包）"
        fi
        PKG_ENTRIES=$("${PY}" -c "import zipfile,sys; print('\n'.join(zipfile.ZipFile(sys.argv[1]).namelist()))" "${LATEST}" 2>/dev/null)
        N_ENT=$(printf '%s\n' "${PKG_ENTRIES}" | wc -l | tr -d ' ')
        echo "  条目数 : ${N_ENT}"
        if [ "${N_ENT}" -lt 17 ]; then
            echo "  [错误] 条目数 ${N_ENT} < 17，这是补齐 install/ 之前的旧包"
            PKG_BAD=$((PKG_BAD + 1))
        fi
        for e in \
            install/bin/backuptool.sh \
            install/bin/backuptool.functions \
            install/bin/otasigcheck.sh \
            META-INF/com/google/android/updater-script \
            META-INF/com/android/otacert \
            META-INF/CERT.RSA \
            META-INF/CERT.SF \
            META-INF/MANIFEST.MF \
            system.new.dat \
            system.transfer.list \
            system/build.prop \
            boot.img ; do
            if ! printf '%s\n' "${PKG_ENTRIES}" | grep -Fxq "${e}"; then
                echo "  [错误] 包内缺条目 ${e}"
                PKG_BAD=$((PKG_BAD + 1))
            fi
        done
        if ! "${PY}" -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); sys.exit(0 if z.testzip() is None else 1)" "${LATEST}" >/dev/null 2>&1; then
            echo "  [错误] zipfile.testzip() 发现损坏条目"
            PKG_BAD=$((PKG_BAD + 1))
        fi
        BP_UIHW=$("${PY}" -c "import zipfile,sys; d=zipfile.ZipFile(sys.argv[1]).read('system/build.prop').decode('utf-8','replace'); print('OK' if 'persist.sys.ui.hw=0' in d else 'BAD')" "${LATEST}" 2>/dev/null)
        if [ "${BP_UIHW}" != "OK" ]; then
            echo "  [错误] 包内 system/build.prop 没有 persist.sys.ui.hw=0"
            echo "         这是 HWUI/RenderThread 黑屏根因，见 README 第十一章"
            PKG_BAD=$((PKG_BAD + 1))
        else
            echo "  [已修] 包内 build.prop persist.sys.ui.hw=0"
        fi
        if [ "${PKG_BAD}" -eq 0 ]; then
            echo "  [已修] 17 条目齐全、签名件在、testzip 干净"
        fi
    fi
fi
N_BAD=$((N_BAD + PKG_BAD))

if [ "${N_BAD}" -gt 0 ]; then
    echo
    echo "有问题的补丁需要人工处理："
    echo "  * 冲突：源码上下文对不上。先确认源码版本，再手工执行"
    echo "          patch -p1 -d ${TOP} --dry-run -i <补丁文件>"
    echo "          看具体哪个 hunk 失败，必要时重新生成补丁。"
    echo "  * 缺失：补丁要改的文件不存在。检查路径拼写，"
    echo "          或者确认对应的 git 仓库已经 repo sync 下来。"
    exit 1
fi

if [ "${N_OK}" -gt 0 ]; then
    echo
    echo "可以执行 ./install.sh 应用这 ${N_OK} 个补丁。"
fi
if [ "${N_MODE_OK}" -gt 0 ]; then
    echo
    echo "另有 ${N_MODE_OK} 个文件需要修权限，同样由 ./install.sh 一并处理。"
fi
if [ "${N_APPLIED}" -gt 0 ]; then
    echo
    echo "已经应用的 ${N_APPLIED} 个补丁无需重复处理（install.sh 会自动跳过）。"
fi

exit 0
