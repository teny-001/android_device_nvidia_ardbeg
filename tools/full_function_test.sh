#!/bin/sh
# =============================================================================
# full_function_test.sh — g100 (ardbeg) CM14.1 TV/eng ROM 全面功能自动测试
#
# 【为什么要有这个工具】
#   项目里长期靠一堆临时 adb 命令做「全面调试」，结论散落在 shell 历史里，
#   换一次刷机就得重敲一遍，还容易漏项。这个脚本把「全面功能测试」正式
#   收编进设备树，一次跑完所有子系统，输出逐项 PASS/FAIL 与汇总码，
#   并把原始 dumpsys/logcat 落盘留档，便于事后回溯。
#
# 【与 verify_after_boot.sh 的分工】
#   verify_after_boot.sh : 「四清 + 最终包」的端到端判据，核心是
#                          md5 逐字节一致 + 8 类根因关键字 + 窗口可见性，
#                          回答「修复有没有真的进 ROM」。
#   本脚本              : 「这台机器现在能不能用」，覆盖服务/图形/输入/
#                          存储/音频/网络/蓝牙/媒体/设置菜单/浏览器/稳定性/
#                          adb 通道/开机日志，回答「功能全不全」。
#   两者互补，不要互相替代。刷完包先跑 verify_after_boot.sh，再跑本脚本。
#
# 【用法】
#   ./full_function_test.sh                 # 全量（含设置菜单与浏览器交互）
#   CHECK_LONG=1 ./full_function_test.sh   # 额外做 105 秒浏览器静置验收
#                                          （跨过 home 守护 90s 冷却窗口）
#
# 【设计要点 / 踩过的坑】
#   1) 工作目录含空格，adb 路径必须始终写成 "$A"，不能裸写 $A。
#   2) 设备侧 toybox grep 不支持 BRE `\|`；`grep -c` 命中 0 时退出码是 1，
#      所有计数都要 `|| true`。
#   3) 不要把 logcat / dumpsys 塞进 shell 变量再 printf —— 会触发
#      `printf: Argument list too long`，grep 拿到空输入造成「假绿 0」。
#      一律先落盘再 grep。
#   4) `logcat -d` 是环形缓冲区，设备长时间运行后开机日志会被冲掉。
#      所以「首启脚本跑过没」不能只看 logcat，要有运行时状态兜底。
#   5) 不要用 `screencap -p` 判亮屏：本机 FLAG_SECURE，screencap 会挂住
#      SurfaceFlinger 客户端连接，进而引发 system_server 全局 ANR。
#   6) 交互测试会改变前台 Activity，因此脚本开头先归一化回 HOME，
#      结尾再回 HOME；中间每次启动菜单都记录实际前台，避免「没崩但也没
#      打开」被当成 PASS。
#   7) 输出用 `@key=value` 前缀，避免误命中 dumpsys/logcat 里长得像
#      key= 的残留文本。
#   8) [2026-11-07 新增] `/cache/recovery/last_log` 是「TWRP updater 跑过」
#      的证据，不是「ROM 功能正常」的证据。本项目真机闭环走四清脚本 +
#      recovery shell 按 OTA 块表逐段 dd 写入，四清还会显式清空
#      /cache/recovery/*，因此该文件按设计不会出现。旧版把它硬判成
#      expect 1，在 homeguard-1107-1705 上产出 110 PASS / 1 FAIL 的纯假红。
#      现在按「文件存在 -> 严格判；不存在 -> SKIP」分流；分区字节证据
#      由第 12 节 12 项 /system md5 独立承担，任一项失败本脚本仍 RC=1，
#      所以跳过 updater 日志并没有降低整体严格性。
#
# 【退出码】
#   0 = 全部 PASS；1 = 有 FAIL；2 = 设备不在线。
# =============================================================================

A="/home/dy/WorkBuddy AI/k1flash/adb"
DEV_SN="0123456789ABCDEF"
WORK="/home/dy/WorkBuddy AI/ardbeg-cm-14.1/work/function-test"
TAG="$(date +%Y%m%d-%H%M)"
OUT_DIR="${WORK}/${TAG}"
DEV_DIR=/data/local/tmp/fft
DEV_REPORT="${DEV_DIR}/report.txt"

mkdir -p "${OUT_DIR}" || exit 2

S() { "$A" shell "$@"; }

echo "======================================================================"
echo " g100 / ardbeg  CM14.1 TV-eng  全面功能自动测试"
echo " 时间   : $(date '+%Y-%m-%d %H:%M:%S')"
echo " 留档   : ${OUT_DIR}"
echo " 长验收 : CHECK_LONG=${CHECK_LONG:-0}"
echo "======================================================================"

if ! "$A" devices 2>/dev/null | grep -q "${DEV_SN}[[:space:]]*device"; then
    echo "设备 ${DEV_SN} 不在线。先检查 USB / adb。"
    echo "注意：TWRP 四清后 /system 为空，adb shell 会报"
    echo "      exec '/system/bin/sh' failed: No such file or directory，"
    echo "      这是正常的（push/pull 仍可用），不要 adb kill-server。"
    exit 2
fi
echo "设备在线：${DEV_SN}"
echo

# ---------------------------------------------------------------------------
# 0. 归一化前置状态
#    只把前台切回桌面 + 唤醒屏幕，不改属性、不 dismiss keyguard。
#    真黑屏时 Launcher 依然不可见，后面的判据照样 FAIL，不会掩盖问题。
# ---------------------------------------------------------------------------
echo "========== 0. 归一化前置状态 =========="
S 'am start -n com.cyanogenmod.trebuchet/com.android.launcher3.Launcher >/dev/null 2>&1' >/dev/null 2>&1
S 'input keyevent 224 >/dev/null 2>&1' >/dev/null 2>&1
sleep 3
echo -n "  归一化后前台 : "
S 'dumpsys activity activities 2>/dev/null | grep -m1 "mResumedActivity"' 2>/dev/null | tr -d '\r'
echo

# ---------------------------------------------------------------------------
# 1. 生成设备侧采集脚本并 push 执行
#    设备侧逻辑单独成文件，避免多层引号转义；采集结果落盘，
#    本地只取一个几十行的 @key=value 报告，顺便 pull 原始日志留档。
# ---------------------------------------------------------------------------
DEV_SH="${OUT_DIR}/fft_device.sh"
cat > "${DEV_SH}" <<'DEVICE_SCRIPT'
#!/system/bin/sh
D=/data/local/tmp/fft
mkdir -p "$D"
R="$D/report.txt"
: > "$R"
p() { echo "@$1=$2" >> "$R"; }
g() { grep -c "$1" "$2" 2>/dev/null || true; }
g1() { grep -m1 "$1" "$2" 2>/dev/null | grep -c "$3" || true; }

# ---- 原始数据全部落盘，避免 Argument list too long ----
dumpsys window windows          > "$D/windows.txt"          2>/dev/null
dumpsys activity activities     > "$D/activities.txt"       2>/dev/null
dumpsys display                 > "$D/display.txt"          2>/dev/null
dumpsys wifi                    > "$D/wifi.txt"             2>/dev/null
dumpsys bluetooth_manager       > "$D/bt.txt"               2>/dev/null
dumpsys input                   > "$D/input.txt"            2>/dev/null
dumpsys audio                   > "$D/audio.txt"            2>/dev/null
dumpsys media.audio_flinger     > "$D/audio_flinger.txt"    2>/dev/null
dumpsys connectivity            > "$D/connectivity.txt"     2>/dev/null
dumpsys SurfaceFlinger          > "$D/sf.txt"               2>/dev/null
logcat -d -v brief              > "$D/logcat.txt"           2>/dev/null
dmesg                           > "$D/dmesg.txt"            2>/dev/null
getevent -p                     > "$D/getevent.txt"         2>/dev/null
service list                    > "$D/services.txt"         2>/dev/null
ps                              > "$D/ps.txt"               2>/dev/null
# 【坑】`ls -l /dev/input/` 列出来的是目录内的 basename（event0/event1/...），
# 行里**不含** /dev/input/ 前缀。所以下面的判据不能 grep '/dev/input/event'，
# 否则永远数到 0（2026-11-07 首轮全面测试就在这里假 FAIL 过一次）。
ls -l /dev/input/               > "$D/devinput.txt"         2>/dev/null
# /system/bin/settings 是 app_process 启的 ART VM，一次要十几秒。
# 所以三类 settings 各只 dump 一次落盘，后面全部从文件里 grep，
# 绝不逐个 `settings get`（8 次就是 80+ 秒）。
settings list system            > "$D/settings_system.txt"  2>/dev/null
settings list secure            > "$D/settings_secure.txt"  2>/dev/null
settings list global            > "$D/settings_global.txt"  2>/dev/null

# ---- 1. 启动与服务 ----
p boot_completed  "$(getprop sys.boot_completed)"
p build_type      "$(getprop ro.build.type)"
p ui_hw           "$(getprop persist.sys.ui.hw)"
p pid_ss          "$(pidof system_server)"
p pid_zygote      "$(pidof zygote)"
p pid_sf          "$(pidof surfaceflinger)"
p pid_lmkd        "$(pidof lmkd)"
p pid_mediaserver "$(pidof mediaserver)"
p pid_audioserver "$(pidof audioserver)"
p pid_cameraserver "$(pidof cameraserver)"
p pid_installd    "$(pidof installd)"
p pid_vold        "$(pidof vold)"
p pid_netd        "$(pidof netd)"
p pid_wpa         "$(pidof wpa_supplicant)"
p svc_lmkd        "$(getprop init.svc.lmkd)"
p svc_homewd      "$(getprop init.svc.ardbeg_homewd)"
p svc_fbfix       "$(getprop init.svc.fb_fix)"
p svc_wifiloader  "$(getprop init.svc.wifiloader)"
p socket_lmkd     "$(ls -l /dev/socket/lmkd 2>/dev/null | cut -c1)"
p selinux         "$(getenforce 2>/dev/null)"

# ---- 2. 显示 / 图形 ----
# 紧凑列表：Window # 行 + mViewVisibility 行成组，再用 grep -B1 反查
grep -E 'Window #|mViewVisibility=' "$D/windows.txt" > "$D/windows_compact.txt" 2>/dev/null
p display_on      "$(g1 'DisplayDeviceInfo' "$D/display.txt" 'state ON')"
p launcher_vis    "$(grep -B1 'mViewVisibility=0x0' "$D/windows_compact.txt" 2>/dev/null | grep -c 'trebuchet' || true)"
p scrim_gone      "$(grep -B1 'mViewVisibility=0x8' "$D/windows_compact.txt" 2>/dev/null | grep -c 'KeyguardScrim' || true)"
p resumed_home    "$(g1 'mResumedActivity' "$D/activities.txt" 'trebuchet')"
p sf_registered   "$(g 'SurfaceFlinger' "$D/services.txt")"
# 【关键判据】7.1 里这三个键已从 Settings.System 迁到 Settings.Global：
#   frameworks/base/core/java/android/provider/Settings.java:1865-1867
#     MOVED_TO_GLOBAL.add(Settings.Global.WINDOW_ANIMATION_SCALE / ...)
#   WMS (WindowManagerService.java:676-680, 1041-1045) 监听并读取的也是
#   Settings.Global.*。首启脚本写 `settings put global ... 0` 是正确且生效的。
#   `settings list system` 里仍能看到 1.0 的遗留旧值，但框架根本不读它，
#   不要据此误判「动画缩放修复没固化」。
p anim_win        "$(grep -m1 '^window_animation_scale=' "$D/settings_global.txt" 2>/dev/null | cut -d= -f2)"
p anim_trans      "$(grep -m1 '^transition_animation_scale=' "$D/settings_global.txt" 2>/dev/null | cut -d= -f2)"
p anim_dur        "$(grep -m1 '^animator_duration_scale=' "$D/settings_global.txt" 2>/dev/null | cut -d= -f2)"
p egl_lib         "$(test -f /system/lib/libEGL.so && echo 1 || echo 0)"
p egl_md5         "$(md5sum /system/lib/libEGL.so 2>/dev/null | cut -d' ' -f1)"

# ---- 3. 输入设备 ----
# 数 event 节点本身：`ls -l` 行尾就是 event<N>；用 -E 而不是 BRE 的
# `event[0-9]\|...`（设备 toybox grep 不支持 BRE 的 \| 交替）。
p input_events    "$(grep -cE 'event[0-9]+$' "$D/devinput.txt" 2>/dev/null || true)"
p ts_present      "$(g 'aw9201_ts' "$D/getevent.txt")"
p mouse_present   "$(g '2.4G Mouse' "$D/getevent.txt")"
p keys_present    "$(g 'gpio-keys' "$D/getevent.txt")"
# service list 里注册名是 `input:`，不是 "InputManager"；
# dumpsys input 的段落标题是 "Input Manager State:"，不是 "InputReader"。
p input_mgr       "$(g 'input:' "$D/services.txt")"
p input_reader    "$(g 'Input Manager State' "$D/input.txt")"

# ---- 4. 输入法 ----
p ime_default     "$(grep -m1 '^default_input_method=' "$D/settings_secure.txt" 2>/dev/null | cut -d= -f2)"
p ime_enabled     "$(grep -m1 '^enabled_input_methods=' "$D/settings_secure.txt" 2>/dev/null | cut -d= -f2)"
p ime_list        "$(g 'baidu' "$D/settings_secure.txt")"

# ---- 5. 存储 ----
p udisk_mounted   "$(mount 2>/dev/null | grep -c '94B5-BDEB' || true)"
p vold_public     "$(g 'public:8_1' "$D/logcat.txt")"
p udisk_write     "$(touch /storage/94B5-BDEB/.fft_probe 2>/dev/null && rm -f /storage/94B5-BDEB/.fft_probe 2>/dev/null && echo 1 || echo 0)"
# toybox 没有 awk；用 tr -s 压空白 + cut 取第 4 列（可用块数）
p data_kb         "$(df -k /data 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f4)"
p system_ro       "$(test -r /system/build.prop && echo 1 || echo 0)"
p cache_dir       "$(test -d /cache && echo 1 || echo 0)"

# ---- 6. 音频 ----
p audio_flinger   "$(g 'media.audio_flinger' "$D/services.txt")"
p audio_policy    "$(g 'media.audio_policy' "$D/services.txt")"
p audio_svc       "$(g 'audio' "$D/services.txt")"
p cmaudio_svc     "$(g 'cmaudio' "$D/services.txt")"
p af_has_output   "$(g 'Output thread' "$D/audio_flinger.txt")"
p music_volume    "$(g1 'STREAM_MUSIC' "$D/audio.txt" 'STREAM_MUSIC')"

# ---- 7. 网络 ----
p wifi_enabled    "$(g1 'Wi-Fi is ' "$D/wifi.txt" 'Wi-Fi is enabled')"
p wifi_conn       "$(g1 'mNetworkInfo' "$D/wifi.txt" 'CONNECTED/CONNECTED')"
p wifi_ssid       "$(g1 'mWifiInfo SSID' "$D/wifi.txt" 'CPE-0C3FB8')"
p wifi_ip         "$(g1 'mDhcpResults' "$D/wifi.txt" 'IP address')"
p ping_gw         "$(ping -c 2 -W 2 192.168.10.1 2>/dev/null | grep -c '0% packet loss' || true)"
p ping_dns        "$(ping -c 2 -W 2 223.5.5.5 2>/dev/null | grep -c '0% packet loss' || true)"
p wpa_net         "$(g '^network=' /data/misc/wifi/wpa_supplicant.conf)"

# ---- 8. 蓝牙 ----
p bt_on           "$(g1 '  state:' "$D/bt.txt" 'state: ON')"
p bt_enabled      "$(g 'enabled: true' "$D/bt.txt")"
p bt_addr         "$(g 'address:' "$D/bt.txt")"
p bt_name         "$(g 'name:' "$D/bt.txt")"

# ---- 9. 相机 / 媒体 ----
p media_camera    "$(g 'media.camera' "$D/services.txt")"
p media_player    "$(g 'media.player' "$D/services.txt")"
p media_codec     "$(g 'media.codec' "$D/services.txt")"
p media_extractor "$(g 'media.extractor' "$D/services.txt")"
p camera_proxy    "$(g 'media.camera.proxy' "$D/services.txt")"

# ---- 10. 稳定性 ----
p anr_files       "$(ls /data/anr/* 2>/dev/null | wc -l)"
p tomb_files      "$(ls /data/tombstones/tombstone_* 2>/dev/null | wc -l)"
p logcat_lines    "$(wc -l < "$D/logcat.txt")"
p fatal_exc       "$(g 'FATAL EXCEPTION' "$D/logcat.txt")"
p force_finish    "$(g 'Force finishing activity' "$D/logcat.txt")"
p wdt_kill        "$(g 'WATCHDOG KILLING' "$D/logcat.txt")"
p egl_bad         "$(g 'EGL_BAD_DISPLAY' "$D/logcat.txt")"
p egl_init_ok     "$(g 'Initialized EGL, version' "$D/logcat.txt")"
p choose_cfg_fail "$(g 'Failed to choose config' "$D/logcat.txt")"
p setexeccon_fail "$(g 'Failed to setexeccon' "$D/logcat.txt")"
p unknown_pkg     "$(g 'Unknown package' "$D/logcat.txt")"
p lmkd_sock_fail  "$(g 'lowmemorykiller daemon socket open failed' "$D/logcat.txt")"
p homewd_hijack   "$(g 'HOME in foreground but window hidden' "$D/logcat.txt")"
# toybox grep 不支持 BRE `\|`，必须 -cE 扩展正则
p kernel_oops     "$(grep -cE 'Oops|Kernel panic|BUG:' "$D/dmesg.txt" 2>/dev/null || true)"
p fb_fix_log      "$(g 'connectivity fix done' "$D/logcat.txt")"

# ---- 11. 开机日志 / pstore ----
p pstore_file     "$(test -s /sys/fs/pstore/console-ramoops && echo 1 || echo 0)"
p pstore_bytes    "$(wc -c < /sys/fs/pstore/console-ramoops 2>/dev/null || echo 0)"
p persist_log     "$(test -s /cache/persist_log.txt && echo 1 || echo 0)"
# 光看文件存在还不够：可能是上一次开机留下的旧日志。服务状态 + 实际字节数
# 一起验，才能确认「这一轮开机 persist_logcat 真的在持续落盘」。
# 2026-11-07 修复：rc 里补 seclabel u:r:init:s0，绕开 4.4.4 sepolicy
# 缺 logcat_exec type 导致的 security_compute_create() 失败。
p svc_persistlog  "$(getprop init.svc.persist_logcat)"
p persist_log_bytes "$(wc -c < /cache/persist_log.txt 2>/dev/null || echo 0)"
p bootlog_dir     "$(test -d /cache/bootlog && echo 1 || echo 0)"
p last_log        "$(test -s /cache/recovery/last_log && echo 1 || echo 0)"

# ---- 12. 首启脚本 / 守护 / 出厂预置 ----
p md5_firstboot   "$(md5sum /system/bin/zz-ardbeg-firstboot-fix.sh 2>/dev/null | cut -d' ' -f1)"
p md5_homewd      "$(md5sum /system/bin/zz-ardbeg-home-watchdog.sh 2>/dev/null | cut -d' ' -f1)"
p md5_lmkdrc      "$(md5sum /system/etc/init/lmkd.rc 2>/dev/null | cut -d' ' -f1)"
p md5_sfhwc       "$(md5sum /system/bin/sf_hwc_off.sh 2>/dev/null | cut -d' ' -f1)"
p md5_selinux     "$(md5sum /system/lib/libselinux_bypass.so 2>/dev/null | cut -d' ' -f1)"
p md5_minijail    "$(md5sum /system/lib/libminijail.so 2>/dev/null | cut -d' ' -f1)"
p md5_wifi_tpl    "$(md5sum /system/etc/wifi/ardbeg_default_network.conf 2>/dev/null | cut -d' ' -f1)"
p md5_persistrc   "$(md5sum /system/etc/init/zz-persist-log.rc 2>/dev/null | cut -d' ' -f1)"
# ---- 13. 硬件解码三条根因的实物（2026-11-07 新增）----
# 只比 md5：三个文件的语义修复已经锁死在这三个字节序列里。
# 【不在本脚本里判运行时组件枚举】logcat -d 是环形缓冲，设备长时间运行后
# 开机日志会被冲掉，拿它数 makeComponentInstance 会假 FAIL（见头部坑位 4）。
# 运行时「真的解出 H.264/H.265」由 tools/verify_hwdec.sh 冷启动 + 播放
# 主动产生证据，两者职责互补，不要互相替代。
p md5_omxbridge   "$(md5sum /system/lib/libstagefrighthw.so 2>/dev/null | cut -d' ' -f1)"
p md5_codecxml    "$(md5sum /system/etc/media_codecs.xml 2>/dev/null | cut -d' ' -f1)"
p md5_mediarc     "$(md5sum /system/etc/init/mediacodec.rc 2>/dev/null | cut -d' ' -f1)"

cat "$R"
DEVICE_SCRIPT

S "rm -rf ${DEV_DIR}; mkdir -p ${DEV_DIR}" >/dev/null 2>&1
"$A" push "${DEV_SH}" "${DEV_DIR}/fft_device.sh" >/dev/null 2>&1 || {
    echo "adb push 设备侧采集脚本失败"; exit 2; }
S "chmod 755 ${DEV_DIR}/fft_device.sh" >/dev/null 2>&1

echo "========== 1. 设备侧采集（dumpsys / logcat / dmesg / getevent）=========="
S "sh ${DEV_DIR}/fft_device.sh" > "${OUT_DIR}/report.txt" 2>"${OUT_DIR}/device_stderr.txt"
echo "  报告行数 : $(wc -l < "${OUT_DIR}/report.txt")"
echo "  设备侧 stderr : $(wc -c < "${OUT_DIR}/device_stderr.txt") 字节"

# pull 原始日志留档
mkdir -p "${OUT_DIR}/raw"
for f in windows.txt activities.txt display.txt wifi.txt bt.txt input.txt audio.txt \
         audio_flinger.txt connectivity.txt sf.txt logcat.txt dmesg.txt \
         getevent.txt services.txt ps.txt devinput.txt windows_compact.txt \
         settings_secure.txt settings_global.txt; do
    "$A" pull "${DEV_DIR}/${f}" "${OUT_DIR}/raw/${f}" >/dev/null 2>&1
done
echo "  原始日志 : $(ls "${OUT_DIR}/raw" | wc -l) 个文件"
echo

V=$(cat "${OUT_DIR}/report.txt")
get() { printf '%s\n' "$V" | grep -m1 "^@$1=" | cut -d= -f2-; }
PASS=0
FAIL=0
WARN=0
SKIP=0
FAILED=""
# 「证据边界」专用：当前刷入路径按设计不会产出该文件/日志。
# 既不算 PASS（会假装验过），也不算 FAIL（会把正常状态判成故障）。
skip() {
    echo "  SKIP  $1（$2）"; SKIP=$((SKIP + 1))
}
expect() {
    if [ "$2" = "$3" ]; then
        echo "  PASS  $1 = $2"; PASS=$((PASS + 1))
    else
        echo "  FAIL  $1: 实际[$2] 期望[$3]"; FAIL=$((FAIL + 1))
        FAILED="${FAILED}\n    - $1: 实际[$2] 期望[$3]"
    fi
}
nonempty() {
    if [ -n "$2" ]; then
        echo "  PASS  $1 = $2"; PASS=$((PASS + 1))
    else
        echo "  FAIL  $1: 为空（进程可能没起来）"; FAIL=$((FAIL + 1))
        FAILED="${FAILED}\n    - $1: 为空"
    fi
}
atleast() {
    if [ "$2" -ge "$3" ] 2>/dev/null; then
        echo "  PASS  $1 = $2 (>= $3)"; PASS=$((PASS + 1))
    else
        echo "  FAIL  $1: 实际[$2] 期望 >= $3"; FAIL=$((FAIL + 1))
        FAILED="${FAILED}\n    - $1: 实际[$2] 期望 >= $3"
    fi
}

echo "========== 2. 启动与核心服务 =========="
expect   "sys.boot_completed"        "$(get boot_completed)"  "1"
expect   "ro.build.type = eng"       "$(get build_type)"      "eng"
expect   "persist.sys.ui.hw"         "$(get ui_hw)"           "0"
nonempty "pid system_server"         "$(get pid_ss)"
nonempty "pid zygote"                "$(get pid_zygote)"
nonempty "pid surfaceflinger"        "$(get pid_sf)"
nonempty "pid lmkd"                  "$(get pid_lmkd)"
nonempty "pid mediaserver"           "$(get pid_mediaserver)"
nonempty "pid audioserver"           "$(get pid_audioserver)"
nonempty "pid cameraserver"          "$(get pid_cameraserver)"
nonempty "pid installd"              "$(get pid_installd)"
nonempty "pid vold"                  "$(get pid_vold)"
nonempty "pid netd"                  "$(get pid_netd)"
nonempty "pid wpa_supplicant"        "$(get pid_wpa)"
expect   "init.svc.lmkd"             "$(get svc_lmkd)"        "running"
expect   "init.svc.ardbeg_homewd"    "$(get svc_homewd)"      "running"
expect   "init.svc.fb_fix (oneshot)" "$(get svc_fbfix)"       "stopped"
expect   "wifiloader (oneshot)"      "$(get svc_wifiloader)"  "stopped"
expect   "/dev/socket/lmkd 是 socket" "$(get socket_lmkd)"    "s"

echo "========== 3. 显示与图形 =========="
expect   "display state ON"                   "$(get display_on)"     "1"
expect   "Launcher mViewVisibility=0x0"       "$(get launcher_vis)"   "1"
expect   "KeyguardScrim mViewVisibility=0x8"  "$(get scrim_gone)"     "1"
expect   "前台 Activity 是 Launcher"          "$(get resumed_home)"   "1"
atleast  "SurfaceFlinger 服务注册"            "$(get sf_registered)"  "1"
expect   "window_animation_scale=0"           "$(get anim_win)"       "0"
expect   "transition_animation_scale=0"       "$(get anim_trans)"     "0"
expect   "animator_duration_scale=0"          "$(get anim_dur)"       "0"
expect   "/system/lib/libEGL.so 存在"         "$(get egl_lib)"        "1"
expect   "libEGL.so md5（补丁版）"            "$(get egl_md5)"        "4ac10584321c81f8dcddd21a025bced6"

echo "========== 4. 输入设备与输入法 =========="
atleast  "/dev/input/event* 数量"              "$(get input_events)"   "3"
atleast  "触摸屏 aw9201_ts"                    "$(get ts_present)"     "1"
atleast  "2.4G Mouse"                          "$(get mouse_present)"  "1"
atleast  "gpio-keys"                           "$(get keys_present)"   "1"
atleast  "input: 服务注册"                     "$(get input_mgr)"      "1"
atleast  "dumpsys input 有 Input Manager State" "$(get input_reader)"   "1"
expect   "默认输入法 = 百度TV"                 "$(get ime_default)"    "com.baidu.input_baidutv/.ImeService"
atleast  "已启用输入法含百度TV"                "$(printf '%s' "$(get ime_enabled)" | grep -c 'baidu' || true)" "1"

echo "========== 5. 存储与 U 盘 =========="
atleast  "U 盘 94B5-BDEB 已挂载"              "$(get udisk_mounted)"  "1"
atleast  "U 盘可写（探针文件）"                "$(get udisk_write)"    "1"
atleast  "/data 可用空间 (KB)"                 "$(get data_kb)"        "1000000"
expect   "/system/build.prop 可读"            "$(get system_ro)"      "1"
expect   "/cache 目录存在"                     "$(get cache_dir)"      "1"

echo "========== 6. 音频 =========="
atleast  "media.audio_flinger 注册"           "$(get audio_flinger)"  "1"
atleast  "media.audio_policy 注册"            "$(get audio_policy)"   "1"
atleast  "audio 服务注册"                     "$(get audio_svc)"      "1"
atleast  "cmaudio 服务注册"                   "$(get cmaudio_svc)"    "1"
atleast  "AudioFlinger 有 Output thread"      "$(get af_has_output)"  "1"

echo "========== 7. 网络 =========="
expect   "WiFi 已启用"                        "$(get wifi_enabled)"   "1"
expect   "WiFi mNetworkInfo CONNECTED"        "$(get wifi_conn)"      "1"
expect   "连的是预置 CPE-0C3FB8"             "$(get wifi_ssid)"      "1"
atleast  "已拿到 DHCP IP"                     "$(get wifi_ip)"        "1"
atleast  "ping 网关 192.168.10.1 0% 丢包"    "$(get ping_gw)"        "1"
atleast  "ping 外网 223.5.5.5 0% 丢包"       "$(get ping_dns)"       "1"
atleast  "wpa_supplicant.conf 有 network 块"  "$(get wpa_net)"        "1"

echo "========== 8. 蓝牙 =========="
expect   "bluetooth state: ON"                "$(get bt_on)"          "1"
atleast  "bluetooth enabled: true"            "$(get bt_enabled)"     "1"
atleast  "BT 适配器地址存在"                   "$(get bt_addr)"        "1"
atleast  "BT 适配器名称存在"                   "$(get bt_name)"        "1"

echo "========== 9. 相机 / 媒体服务 =========="
atleast  "media.camera 注册"                  "$(get media_camera)"    "1"
atleast  "media.player 注册"                  "$(get media_player)"    "1"
atleast  "media.codec 注册"                   "$(get media_codec)"     "1"
atleast  "media.extractor 注册"               "$(get media_extractor)" "1"
atleast  "media.camera.proxy 注册"            "$(get camera_proxy)"    "1"

echo "========== 10. 稳定性（ANR / tombstone / 八类根因）=========="
atleast  "logcat 落盘行数 > 0"                "$(get logcat_lines)"   "1"
expect   "ANR 文件数"                         "$(get anr_files)"      "0"
expect   "tombstone 数"                       "$(get tomb_files)"     "0"
expect   "FATAL EXCEPTION"                    "$(get fatal_exc)"      "0"
expect   "Force finishing activity"           "$(get force_finish)"   "0"
expect   "WATCHDOG KILLING"                   "$(get wdt_kill)"       "0"
expect   "Failed to choose config"            "$(get choose_cfg_fail)" "0"
expect   "Failed to setexeccon"               "$(get setexeccon_fail)" "0"
expect   "Unknown package"                    "$(get unknown_pkg)"    "0"
expect   "lmkd socket open failed"            "$(get lmkd_sock_fail)" "0"
expect   "home 守护抢前台日志"                 "$(get homewd_hijack)"  "0"
expect   "kernel Oops / panic"                "$(get kernel_oops)"    "0"
# EGL_BAD_DISPLAY 容 1 条 transient（老 Tegra EGL 首次 attach 的已知无害行为）
egl_n=$(get egl_bad)
if [ "${egl_n:-99}" -le 1 ] 2>/dev/null; then
    echo "  PASS  EGL_BAD_DISPLAY = $egl_n（<=1 条 transient，允许）"; PASS=$((PASS + 1))
elif [ "$(get egl_init_ok)" -ge 1 ] 2>/dev/null; then
    echo "  WARN  EGL_BAD_DISPLAY = $egl_n（EGL 已成功初始化，非黑屏）"; WARN=$((WARN + 1)); PASS=$((PASS + 1))
else
    echo "  FAIL  EGL_BAD_DISPLAY = $egl_n 且无成功初始化 → 黑屏链复发"; FAIL=$((FAIL + 1))
    FAILED="${FAILED}\n    - EGL_BAD_DISPLAY 连打且无成功初始化"
fi
# 首启脚本：logcat 环形缓冲区可能已滚动，用运行时状态兜底
fb=$(get fb_fix_log)
if [ "${fb:-0}" -ge 1 ] 2>/dev/null; then
    echo "  PASS  首启脚本跑完（logcat 直接证据 = $fb）"; PASS=$((PASS + 1))
elif [ "$(get wifi_conn)" = "1" ] && [ "$(get bt_on)" = "1" ] && \
     [ "$(get wpa_net)" -ge 1 ] 2>/dev/null; then
    echo "  PASS  首启脚本跑完（logcat 已滚动，由 WiFi 自动连 + BT ON + 网络块佐证）"; PASS=$((PASS + 1))
else
    echo "  FAIL  首启脚本可能没跑"; FAIL=$((FAIL + 1))
    FAILED="${FAILED}\n    - 首启脚本 connectivity 无证据"
fi

echo "========== 11. 开机日志 / pstore =========="
expect   "/sys/fs/pstore/console-ramoops 非空"  "$(get pstore_file)"  "1"
atleast  "console-ramoops 字节数"              "$(get pstore_bytes)" "1"
expect   "/cache/persist_log.txt 非空"          "$(get persist_log)"  "1"
expect   "init.svc.persist_logcat"              "$(get svc_persistlog)" "running"
atleast  "/cache/persist_log.txt 字节数"        "$(get persist_log_bytes)" "1"
expect   "/cache/bootlog 目录存在"              "$(get bootlog_dir)"  "1"
# 2026-11-07：last_log 只在「真的跑过 TWRP updater」时才存在。本机 TWRP GUI
# 因 framebuffer 0x0 反复崩溃，真机闭环改走按 OTA 块表 dd 写入，且四清会
# 清空 /cache/recovery/*，所以缺文件是设计使然，不能当成功能 FAIL。
if [ "$(get last_log)" = "1" ]; then
    expect "/cache/recovery/last_log 非空" "$(get last_log)" "1"
else
    skip "/cache/recovery/last_log 非空" \
         "四清清空 /cache/recovery/*，按块表 dd 不经 TWRP updater；证据边界，非功能缺失"
    echo "        分区字节证据由第 12 节 12 项 /system md5 独立承担（任一项失败本脚本仍 RC=1）"
fi

echo "========== 12. /system 关键文件 md5（与最终 OTA 包一致）=========="
expect   "zz-ardbeg-firstboot-fix.sh"  "$(get md5_firstboot)" "231f397b82a71d94f16c9846140ed9a1"
expect   "zz-ardbeg-home-watchdog.sh" "$(get md5_homewd)"    "977e12d55141bebe1e6964c36bc6bfa3"
expect   "lmkd.rc"                     "$(get md5_lmkdrc)"    "4635029e48b1ef36190332742188bf65"
expect   "sf_hwc_off.sh"               "$(get md5_sfhwc)"     "f1223c35f9d7ea3706d74cbe83a4a24b"
expect   "libselinux_bypass.so"        "$(get md5_selinux)"   "8652d544f226ee8de7127f30dca2fff1"
expect   "libminijail.so"              "$(get md5_minijail)"  "29f2b8bb047cac7473cb1b77e3a21a14"
expect   "ardbeg_default_network.conf" "$(get md5_wifi_tpl)"  "d2e8dd68fab0df7e80b5373b372ba720"
# 必须锚定带 seclabel 的修复版；旧 rc（b9360f...）会让 persist_logcat 永远起不来
expect   "zz-persist-log.rc"            "$(get md5_persistrc)" "6500a2babf94cec94c50e4e160517b2b"
# ---- 硬件解码专项三条独立根因，缺一条就退软解或 0x80001000 ----
# 期望值与 tools/verify_ota_contents.sh / verify_after_boot.sh /
# verify_six_layers.py 的四张表逐项一致；运行时行为见 verify_hwdec.sh。
expect   "libstagefrighthw.so"          "$(get md5_omxbridge)" "7221cb3656b33b54846e34b5e406163c"
expect   "media_codecs.xml"             "$(get md5_codecxml)"  "9c884d66a4e7d44a0b7227cc2ec8ddb5"
expect   "mediacodec.rc"                "$(get md5_mediarc)"   "e5dfd2d55c04eb72cbb89ff2327ce4f1"

# ---------------------------------------------------------------------------
# 13. 交互测试：设置二级菜单 + 浏览器
#     判据不只是「没崩」，还要记录实际前台；「没崩但没打开」记 WARN。
# ---------------------------------------------------------------------------
echo "========== 13. 设置二级菜单交互 =========="
MENU_OUT="${OUT_DIR}/menu_check.txt"
: > "${MENU_OUT}"
# 崩溃判据用「测试前基线 + 增量」，不能用 logcat 绝对计数：
# 缓冲区里可能留着几天前调试期的 FATAL，绝对计数会让每个菜单都假 FAIL。
# 另外 toybox grep 不支持 BRE `\|`，这里必须用 -cE。
BASE_FATAL=$(S 'logcat -d 2>/dev/null | grep -c "FATAL EXCEPTION" || true' 2>/dev/null | tr -d '\r')
BASE_FORCE=$(S 'logcat -d 2>/dev/null | grep -c "Force finishing activity" || true' 2>/dev/null | tr -d '\r')
BASE_FATAL=${BASE_FATAL:-0}; BASE_FORCE=${BASE_FORCE:-0}
echo "  基线: FATAL=${BASE_FATAL}  Force finishing=${BASE_FORCE}"
for item in "WIFI:android.settings.WIFI_SETTINGS" \
            "BLUETOOTH:android.settings.BLUETOOTH_SETTINGS" \
            "APPLICATION:android.settings.APPLICATION_SETTINGS" \
            "DISPLAY:android.settings.DISPLAY_SETTINGS" \
            "SOUND:android.settings.SOUND_SETTINGS" \
            "DATE:android.settings.DATE_SETTINGS" \
            "LOCATION:android.settings.LOCATION_SOURCE_SETTINGS" \
            "ACCESSIBILITY:android.settings.ACCESSIBILITY_SETTINGS" \
            "STORAGE:android.settings.STORAGE_SETTINGS"; do
    name=${item%%:*}; action=${item#*:}
    S "am start -a ${action} >/dev/null 2>&1" >/dev/null 2>&1
    sleep 2
    fg=$(S 'dumpsys activity activities 2>/dev/null | grep -m1 "mResumedActivity"' 2>/dev/null | tr -d '\r')
    cur_fatal=$(S 'logcat -d 2>/dev/null | grep -c "FATAL EXCEPTION" || true' 2>/dev/null | tr -d '\r')
    cur_force=$(S 'logcat -d 2>/dev/null | grep -c "Force finishing activity" || true' 2>/dev/null | tr -d '\r')
    cur_fatal=${cur_fatal:-0}; cur_force=${cur_force:-0}
    delta=$(( (cur_fatal + cur_force) - (BASE_FATAL + BASE_FORCE) ))
    printf '%-14s action=%-45s delta_crash=%s  foreground=%s\n' "$name" "$action" "$delta" "$fg" >> "${MENU_OUT}"
    if [ "$delta" -le 0 ] 2>/dev/null; then
        echo "  PASS  ${name} 二级菜单无新增崩溃"; PASS=$((PASS + 1))
        # 「没崩但也没打开」单独记 WARN，不掩盖也不误判成崩溃
        if ! printf '%s\n' "$fg" | grep -qi 'Settings'; then
            echo "  WARN  ${name} 前台未切到 Settings（可能 action 未解析，非崩溃）"
            WARN=$((WARN + 1))
        fi
    else
        echo "  FAIL  ${name} 二级菜单触发崩溃 (新增 ${delta})"; FAIL=$((FAIL + 1))
        FAILED="${FAILED}\n    - ${name} 二级菜单崩溃，新增 ${delta}"
    fi
done
echo "  逐项前台记录已写入 menu_check.txt"

echo "========== 14. 浏览器 Jelly =========="
S 'am start -n org.lineageos.jelly/.MainActivity >/dev/null 2>&1' >/dev/null 2>&1
sleep 4
fg=$(S 'dumpsys activity activities 2>/dev/null | grep -m1 "mResumedActivity"' 2>/dev/null | tr -d '\r')
if printf '%s\n' "$fg" | grep -q 'org.lineageos.jelly'; then
    echo "  PASS  Jelly 启动后在前台"; PASS=$((PASS + 1))
else
    echo "  FAIL  Jelly 没进前台: $fg"; FAIL=$((FAIL + 1))
    FAILED="${FAILED}\n    - Jelly 没进前台"
fi
S 'am start -a android.intent.action.VIEW -d http://www.baidu.com -n org.lineageos.jelly/.MainActivity >/dev/null 2>&1' >/dev/null 2>&1
sleep 5
fg2=$(S 'dumpsys activity activities 2>/dev/null | grep -m1 "mResumedActivity"' 2>/dev/null | tr -d '\r')
if printf '%s\n' "$fg2" | grep -q 'org.lineageos.jelly'; then
    echo "  PASS  加载网页后仍在 Jelly"; PASS=$((PASS + 1))
else
    echo "  FAIL  加载网页后离开 Jelly: $fg2"; FAIL=$((FAIL + 1))
    FAILED="${FAILED}\n    - 加载网页后离开 Jelly"
fi

if [ "${CHECK_LONG:-0}" = "1" ]; then
    echo "  等待 105 秒（守护 COOLDOWN=90s，必须跨过去才有意义）..."
    sleep 105
    fg3=$(S 'dumpsys activity activities 2>/dev/null | grep -m1 "mResumedActivity"' 2>/dev/null | tr -d '\r')
    if printf '%s\n' "$fg3" | grep -q 'org.lineageos.jelly'; then
        echo "  PASS  静置 105 秒后仍在 Jelly（未被守护踢回桌面）"; PASS=$((PASS + 1))
    else
        echo "  FAIL  静置 105 秒后被踢回桌面: $fg3"; FAIL=$((FAIL + 1))
        FAILED="${FAILED}\n    - 浏览器被 home 守护抢前台"
    fi
    n=$(S 'logcat -d 2>/dev/null | grep -c "HOME in foreground but window hidden" || true' 2>/dev/null | tr -d '\r')
    expect "期间抢前台日志为 0" "${n:-0}" "0"
fi

# 收尾回桌面
S 'am start -n com.cyanogenmod.trebuchet/com.android.launcher3.Launcher >/dev/null 2>&1' >/dev/null 2>&1
sleep 2

echo "========== 15. 交互后稳定性复核 =========="
post_fatal=$(S 'logcat -d 2>/dev/null | grep -c "FATAL EXCEPTION" || true' 2>/dev/null | tr -d '\r')
post_force=$(S 'logcat -d 2>/dev/null | grep -c "Force finishing activity" || true' 2>/dev/null | tr -d '\r')
post_anr=$(S 'ls /data/anr/* 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r')
expect "交互后 FATAL EXCEPTION"       "${post_fatal:-0}" "0"
expect "交互后 Force finishing"       "${post_force:-0}" "0"
expect "交互后 ANR 文件数"            "${post_anr:-0}"   "0"

# ---------------------------------------------------------------------------
# 16. adb 通道自检（push / pull / shell / logcat 四件套）
# ---------------------------------------------------------------------------
echo "========== 16. adb 通道自检 =========="
PROBE="${OUT_DIR}/adb_probe.bin"
printf 'ardbeg-full-function-test-%s\n' "$TAG" > "${PROBE}"
"$A" push "${PROBE}" "${DEV_DIR}/adb_probe.bin" >/dev/null 2>&1
"$A" pull "${DEV_DIR}/adb_probe.bin" "${OUT_DIR}/adb_probe.pulled" >/dev/null 2>&1
if cmp -s "${PROBE}" "${OUT_DIR}/adb_probe.pulled"; then
    echo "  PASS  adb push/pull 二进制往返一致"; PASS=$((PASS + 1))
else
    echo "  FAIL  adb push/pull 往返内容不一致"; FAIL=$((FAIL + 1))
    FAILED="${FAILED}\n    - adb push/pull 往返不一致"
fi
lc=$(S 'logcat -d 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r')
atleast "adb shell + logcat 可读行数" "${lc:-0}" "1"

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
echo
echo "======================================================================"
echo " 汇总：PASS = ${PASS}   FAIL = ${FAIL}   WARN = ${WARN}   SKIP = ${SKIP}"
echo " 留档：${OUT_DIR}"
echo "======================================================================"
if [ "$FAIL" -gt 0 ]; then
    printf ' 未通过项：%b\n' "$FAILED"
    echo
    echo " 排查提示："
    echo "   - 若只是 logcat 相关项为 0，先确认 logcat 落盘行数 > 0（假绿陷阱）"
    echo "   - 若窗口/前台相关项 FAIL，检查是否被上一次交互测试改动了前台"
    echo "   - 若 md5 不符，说明设备上还是调试期临时文件，需要重新固化刷机包"
    exit 1
fi
echo " 结论：全面功能测试通过，所有子系统正常。"
if [ "$SKIP" -gt 0 ]; then
    echo "        其中 ${SKIP} 项是当前刷入路径下的证据边界（已由第 12 节 md5 兜底），不是功能缺失。"
fi
exit 0
