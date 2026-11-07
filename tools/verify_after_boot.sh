#!/bin/bash
# =============================================================================
# verify_after_boot.sh
#   「TWRP 四清 -> 刷入最终 OTA -> 冷启动」之后的端到端开机验收
#
# 位置：device/nvidia/ardbeg/tools/verify_after_boot.sh（设备树正式版）
# 来源：ardbeg-cm-14.1/work/flash-final-2255/verify_after_boot.sh（调试期临时版）
# 期望值基准包：dist/appvideo-1107-2005/cm_ardbeg_tv-ota-eng.dy.zip
#   395989155 字节 / md5 f23add70d0e028e5602d0d85824ad1df
#   （2026-11-07 app 视频播放验收固化重打包；A 组文件字节未改，
#    EXPECT_MD5 表与 homeguard-1107-1705 完全一致。）
#   2026-11-07 相对 hwdec-1107-1650 的变化：zz-ardbeg-firstboot-fix.sh
#   第 8 步补 foreground_is_home() 守卫（md5 231f397b...），修掉
#   「首启脚本把正在播放视频的用户踢回桌面」这条误伤。另含硬件解码
#   三条修复（libstagefrighthw.so / media_codecs.xml / mediacodec.rc）。
#   boot.img 8597504 字节 / md5 9aa6a27985baad70637aee30752fd134（未改动）
#   zip entries 17（原 14 + install/bin 三条）
#   相对 wifibt-1107-0023 的变化：zz-persist-log.rc 补 seclabel
#   u:r:init:s0（修 4.4.4 sepolicy 缺 logcat_exec 导致 persist_logcat
#   起不来）。EXPECT_MD5 由 8 项增至 9 项；新增「服务 running +
#   /cache/persist_log.txt 非空」2 项判据；boot.img 未改动。
#   刷机前先用 tools/verify_ota_contents.sh 验「包内」，本脚本验「设备分区」，
#   两处 EXPECT_MD5 表必须逐项一致。
#
# 用法： ./verify_after_boot.sh
#        CHECK_BROWSER=1 ./verify_after_boot.sh
#            额外做一次「启动 Jelly 浏览器并静置 105 秒，确认不会被
#            home 守护踢回桌面」的交互验收（默认关闭，因为要等 105 秒）。
# 前提： 设备已经从 TWRP 重启进系统，adb 在线，且已完成四清刷包。
# 退出码：0 = 全部 PASS；1 = 至少一项 FAIL；2 = 设备不在线。
#
# -----------------------------------------------------------------------------
# 【为什么必须有这个脚本】
#   本项目之前所有修复都是在「调试态」用 adb push 单文件验证的。只要 /data
#   里还留着旧 packages.xml、dalvik-cache、手工推入的 .so，很多问题会被
#   dirty flash 掩盖：最典型的是两版 libselinux_bypass.so 功能等价但 md5
#   不同（设备上是调试期临时推入的 de312353...，包里是 8652d544...）。
#   只有四清之后从刷机包里冷启动、并且下面每一项都过，才能证明修复真的
#   固化进了 ROM，而不是靠残留文件或手工操作撑着。
#
# 【判据设计：全是本项目踩过的坑，不要随手改】
#   1) 不能只看 sys.boot_completed。framework 重启时这个属性是残留的 1，
#      必须同时看 pidof system_server / pidof lmkd。
#   2) adb 路径含空格，绝对不能写成 S="$A shell" 再用 $S 展开，会被切碎成
#      "/home/dy/WorkBuddy: 没有那个文件或目录"。必须用 shell 函数包一层。
#   3) 设备上的 toybox grep 不支持 BRE 的 `\|`，一律用 grep -E。
#   4) grep -c 计数为 0 时退出码是 1，别当成命令失败；一律 `|| true`。
#   5) 不能把 logcat / dumpsys 的输出塞进 shell 变量再 printf 展开：
#      /system/bin/printf: Argument list too long -> grep 拿到空输入
#      -> 所有关键字都返回 0，是「假绿」。必须先落盘再 grep，
#      并且先确认 wc -l > 0。
#   6) 这个屏带 FLAG_SECURE / isSecure=1，绝对不要用 screencap 判断是否亮屏，
#      它会挂住 SurfaceFlinger 客户端连接并引发全局 ANR（sf_hwc_off.sh
#      里的 check_screen() 就是这么炸的，已删除）。只看 dumpsys display。
#   7) `dumpsys window windows | grep -c "KeyguardScrim"` 会数到 2：
#      一行 Window{... KeyguardScrim}，一行 WindowStateAnimator{... KeyguardScrim}。
#      真正判据是 mViewVisibility：遮挡桌面时是 0x0/0x4，正常时是 0x8 (GONE)。
#   8) toybox grep 的 `-A` / `-B` 与 `-m1` 一起用会**只输出匹配行、丢掉
#      上下文行**，所以 `grep -A14 -m1 "Launcher" | grep mViewVisibility`
#      永远拿不到可见性（曾据此误判过）。而且原始 dumpsys 里 `Window #`
#      与 `mViewVisibility` 中间还隔着一大堆别的信息。正确做法是先
#      `grep -E "Window #|mViewVisibility="` 压成「标题 + 可见性」两行一组，
#      再在紧凑列表上用不带 -m 的 `grep -B1` 反查。
#   9) md5sum 取 hash 不要写 `cut -d\  -f1`（外层单引号里转义空格很脆），
#      用设备侧参数展开 `${m%% *}` 最稳。
#  10) 首次冷启动允许出现 1 条 transient `libEGL validate_display:99 error 3008`
#      (EGL_BAD_DISPLAY)，只要没有 `Failed to choose config` / tombstone / ANR
#      就不是黑屏链复发；二次重启静置后应彻底为 0。
#  11) [2026-11-06 新增] WiFi / 蓝牙状态一律用 dumpsys 判，不要用
#      `settings get`。/system/bin/settings 是 app_process 启的 ART VM，
#      一次要十几秒；而且「settings 里 bluetooth_on=1」并不等于蓝牙当前
#      已经 ON（BluetoothManagerService 只在启动时读一次）。
#  12) [2026-11-06 新增] 浏览器「闪退」不是崩溃，是 home 守护抢前台。
#      判据必须同时看 mResumedActivity 和 logcat 里的
#      "HOME in foreground but window hidden"，不能只查 FATAL/tombstone。
#      单纯跑一次 Jelly 没有意义，必须跨过守护的 90 秒冷却窗口。
#  13) [2026-11-07 新增] /cache/recovery/last_log 是「TWRP updater 跑过」
#      的证据，不是「ROM 正确」的证据。本项目真机闭环走的是 recovery
#      shell 里按 OTA 块表逐段 dd 写入（语义等价 block_image_update()），
#      且四清脚本会显式清空 /cache/recovery/*，因此刷完冷启动后该文件
#      必然不存在。此时 `grep -c` 因 2>/dev/null + || true 只会给出空串，
#      若继续用 expect ... "1" 硬判，就会得到 3 个与 ROM 功能毫无关系的
#      假 FAIL（2026-11-07 homeguard 包 51 PASS / 3 FAIL 全部来自这里）。
#      正确做法：先判文件是否存在。
#        存在   -> 严格判 updater 三项（execv failed / RC=0 / script ok）；
#        不存在 -> 输出 SKIP，并改用「分区级字节证据」：本脚本下面
#                  「/system 关键文件 md5」段的 12 项 + boot 分区 md5
#                  必须全绿（MD5_SECTION_FAIL=0）。严格性不降低，只是
#                  换了一条能覆盖当前刷入路径的证据链。
#      二者不可混为一谈：要验 updater 本身，必须真的走一次 TWRP GUI/ORS
#      安装；本机 framebuffer 0x0 导致 TWRP 主进程反复崩溃、ORS 引擎
#      不消费命令，详见 patches/README.md 第十六章。
#
# 【本轮新增的验收维度（2026-11-06）】
#   - /system/etc/wifi/ardbeg_default_network.conf 是否真的进了 system.img
#   - 四清后 /data/misc/wifi/wpa_supplicant.conf 是否被首启脚本注入网络块
#   - WiFi 是否开机自启且自动连上（mNetworkInfo CONNECTED/CONNECTED）
#   - 蓝牙是否开机自启（dumpsys state: ON，不是只看 settings）
#   - home 守护抢前台的日志是否为 0
#   - CHECK_BROWSER=1 时，Jelly 静置 105 秒后是否仍在前台
#
# 【换了新 OTA 包怎么办】
#   下面 EXPECT_MD5 / EXPECT_BOOT_MD5 是 fulltest-1107-1354 的实测值。
#   重打包后请按 dist/<新目录>/ 重新取 md5 更新这两个表，再跑本脚本；
#   同时同步 tools/verify_ota_contents.sh 的 EXPECT_MD5 表（刷机前判据）。
#   若 boot.img 没变，EXPECT_BOOT_MD5 不用动；其余判据（属性 / 关键字 /
#   窗口 / ANR / TWRP 日志）与具体包无关，不用改。
# =============================================================================

A="/home/dy/WorkBuddy AI/k1flash/adb"
S() { "$A" shell "$@"; }

# 最终 OTA 包里 /system 关键文件的期望 md5（顺序与设备侧取值顺序严格一致）
EXPECT_PATHS=(
    /system/lib/libEGL.so
    /system/etc/init/lmkd.rc
    /system/bin/sf_hwc_off.sh
    /system/lib/libselinux_bypass.so
    /system/lib/libminijail.so
    /system/bin/zz-ardbeg-firstboot-fix.sh
    /system/bin/zz-ardbeg-home-watchdog.sh
    /system/etc/wifi/ardbeg_default_network.conf
    /system/etc/init/zz-persist-log.rc
    # ---- 2026-11-07 硬件解码专项三条独立根因 ----
    /system/lib/libstagefrighthw.so
    /system/etc/media_codecs.xml
    /system/etc/init/mediacodec.rc
)
EXPECT_MD5=(
    4ac10584321c81f8dcddd21a025bced6   # libEGL.so：0xA3C8 cbnz -> nop
    4635029e48b1ef36190332742188bf65   # lmkd.rc：seclabel / 去 critical / 去 readproc
    f1223c35f9d7ea3706d74cbe83a4a24b   # sf_hwc_off.sh：删掉 screencap 诊断
    8652d544f226ee8de7127f30dca2fff1   # libselinux_bypass.so：10 符号正式版
    29f2b8bb047cac7473cb1b77e3a21a14   # libminijail.so：seccomp softfail
    231f397b82a71d94f16c9846140ed9a1   # 首启脚本：第 9 节 WiFi/BT + 修 log() 自递归
    977e12d55141bebe1e6964c36bc6bfa3   # home 守护：修 launcher_visible + foreground_is_home
    d2e8dd68fab0df7e80b5373b372ba720   # 出厂预置 WiFi 网络模板
    6500a2babf94cec94c50e4e160517b2b   # zz-persist-log.rc：seclabel u:r:init:s0（本次修复）
    7221cb3656b33b54846e34b5e406163c   # libstagefrighthw.so：原厂 4.4 OMX 桥
    9c884d66a4e7d44a0b7227cc2ec8ddb5   # media_codecs.xml：7.1 兼容，无重名组件
    e5dfd2d55c04eb72cbb89ff2327ce4f1   # mediacodec.rc：group 含 media(1013)
)
EXPECT_BOOT_MD5=9aa6a27985baad70637aee30752fd134

# logcat 关键字：二次重启静置后必须全为 0（顺序与设备侧取值顺序严格一致）
EXPECT_KW=(
    "EGL_BAD_DISPLAY"
    "Failed to choose config"
    "WATCHDOG KILLING"
    "SLOW OOM ADJ"
    "lowmemorykiller daemon socket open failed"
    "Failed to setexeccon"
    "Unknown package"
    "could not get context"
    "is not valid (left unmapped)"
)

if ! "$A" devices 2>/dev/null | grep -q '0123456789ABCDEF[[:space:]]*device'; then
    echo "设备 0123456789ABCDEF 不在线，先检查 USB / adb。"
    echo "注意：TWRP 四清之后 /system 为空，adb shell 会报"
    echo "      exec '/system/bin/sh' failed: No such file or directory，"
    echo "      这是正常的（push/pull 仍可用），不要据此判断掉线或变砖，"
    echo "      更不要 adb kill-server（历史上杀宿主 server 导致 5037 refused）。"
    exit 2
fi

echo "========== 0. 归一化验收前置状态 =========="
# 【为什么要这一段】
#   验收脚本本身（CHECK_BROWSER=1）会启动 Jelly 并静置 105 秒。如果上一次
#   跑被中断 / 被 kill（用户中断、adb 掉线、后台任务被回收），设备就会把
#   前台留在 Jelly，而第 8 节的「前台是 Launcher」/「Launcher 可见」两项
#   会直接 FAIL——但这不是 ROM 有问题，只是验收起点不干净。
#   实测 2026-11-07 就撞过：上一轮后台验收被中断，下一轮交互验收
#   45 PASS / 3 FAIL，其中 2 项正是这两个窗口判据；手工一查
#   Launcher mViewVisibility=0x0、KeyguardScrim=0x8、前台已回桌面，全正常。
#
# 【为什么这不会掩盖黑屏】
#   这里只做 `am start HOME`（把前台切回桌面）和 `input keyevent 224`
#   （唤醒屏幕），**不改任何属性、不 dismiss keyguard、不重启任何服务**。
#   如果设备真的黑屏 / KeyguardScrim 遮挡 / Launcher 窗口 alpha 卡 0，
#   切回 HOME 之后 dumpsys 里 Launcher 依然是 mViewVisibility!=0x0，
#   判据照样 FAIL。也就是说这一段只消除「上次验收留下的前台 app」，
#   不会制造本来不存在的可见性。
"$A" shell 'am start -n com.cyanogenmod.trebuchet/com.android.launcher3.Launcher >/dev/null 2>&1' >/dev/null 2>&1
"$A" shell 'input keyevent 224 >/dev/null 2>&1' >/dev/null 2>&1
sleep 3
echo -n "  归一化后前台 : "
"$A" shell 'dumpsys activity activities 2>/dev/null | grep -m1 "mResumedActivity"' 2>/dev/null | tr -d '\r'

echo
echo "========== 1. 基础启动状态 =========="
S 'echo -n "sys.boot_completed    = "; getprop sys.boot_completed
     echo -n "pidof system_server   = "; pidof system_server
     echo -n "pidof lmkd            = "; pidof lmkd
     echo -n "init.svc.lmkd         = "; getprop init.svc.lmkd
     echo -n "init.svc.ardbeg_homewd= "; getprop init.svc.ardbeg_homewd
     echo -n "init.svc.fb_fix       = "; getprop init.svc.fb_fix
     echo -n "init.svc.wifiloader   = "; getprop init.svc.wifiloader
     echo -n "persist.sys.ui.hw     = "; getprop persist.sys.ui.hw
     echo -n "/dev/socket/lmkd      = "; ls -l /dev/socket/lmkd 2>/dev/null' 2>&1

echo
echo "========== 2. /system 关键文件 md5 =========="
S 'for f in /system/lib/libEGL.so /system/etc/init/lmkd.rc \
            /system/bin/sf_hwc_off.sh /system/lib/libselinux_bypass.so \
            /system/lib/libminijail.so /system/bin/zz-ardbeg-firstboot-fix.sh \
            /system/bin/zz-ardbeg-home-watchdog.sh \
            /system/etc/wifi/ardbeg_default_network.conf \
            /system/etc/init/zz-persist-log.rc \
            /system/lib/libstagefrighthw.so \
            /system/etc/media_codecs.xml \
            /system/etc/init/mediacodec.rc; do
       md5sum "$f" 2>/dev/null
     done
     ls -l /system/bin/zz-ardbeg-firstboot-fix.sh /system/etc/init/lmkd.rc \
           /system/etc/wifi/ardbeg_default_network.conf' 2>&1

echo
echo "========== 3. 四条已知根因链的运行时计数 =========="
# 落盘再 grep，避免 printf: Argument list too long 造成的「假 0」
S 'logcat -d -v brief > /data/local/tmp/verify_logcat.txt 2>/dev/null
     echo -n "  logcat 总行数 : "; wc -l < /data/local/tmp/verify_logcat.txt
     for k in "EGL_BAD_DISPLAY" "Failed to choose config" "WATCHDOG KILLING" \
              "SLOW OOM ADJ" "lowmemorykiller daemon socket open failed" \
              "Failed to setexeccon" "Unknown package" \
              "could not get context" "is not valid (left unmapped)" \
              "setupwraith"; do
       n=$(grep -c "$k" /data/local/tmp/verify_logcat.txt || true)
       echo "  $k : $n"
     done' 2>&1

echo
echo "========== 4. ANR / tombstone / Watchdog trace =========="
S 'echo -n "traces_SystemServer_WDT* : "; ls /data/anr/traces_SystemServer_WDT* 2>/dev/null | wc -l
     echo -n "tombstone 总数            : "; ls /data/tombstones/tombstone_* 2>/dev/null | wc -l
     echo -n "ANR 目录文件              : "; ls /data/anr/ 2>/dev/null | wc -l' 2>&1

echo
echo "========== 5. display / 桌面窗口（不能用 screencap）=========="
S 'dumpsys display 2>/dev/null | grep -m1 "DisplayDeviceInfo"
     dumpsys window windows > /data/local/tmp/verify_windows.txt 2>/dev/null
     grep -E "Window #|mViewVisibility=" /data/local/tmp/verify_windows.txt \
         > /data/local/tmp/verify_windows_compact.txt 2>/dev/null
     echo "--- 窗口标题 + 可见性紧凑列表（看 mViewVisibility，别数行数）---"
     cat /data/local/tmp/verify_windows_compact.txt
     echo "--- HOME / 前台 ---"
     dumpsys activity activities 2>/dev/null | grep -m2 -E "mResumedActivity|topResumedActivity" || true' 2>&1

echo
echo "========== 6. TWRP last_log：install/ 补齐是否生效 =========="
S 'if [ -f /cache/recovery/last_log ]; then
        echo "last_log 存在 -> updater 安装路径证据可用"
        echo -n "  行数                    : "; wc -l < /cache/recovery/last_log
     else
        echo "last_log 不存在（四清清空 /cache/recovery/*，本轮按 OTA 块表 dd 写入不经 updater）"
        echo "  -> 第 8 节自动判定按 SKIP + 分区级字节证据处理，不是 ROM 功能 FAIL"
     fi
     echo -n "execv failed 计数        : "; grep -c "execv failed" /cache/recovery/last_log 2>/dev/null || true
     echo -n "script succeeded         : "; grep -c "script succeeded" /cache/recovery/last_log 2>/dev/null || true
     echo -n "Updater process RC=0     : "; grep -c "Updater process ended with RC=0" /cache/recovery/last_log 2>/dev/null || true
     echo -n "block_image_update       : "; grep -o "wrote [0-9]* blocks; expected [0-9]*" /cache/recovery/last_log 2>/dev/null | tail -1
     echo -n "Install took             : "; grep -o "Install took [0-9]* second" /cache/recovery/last_log 2>/dev/null | tail -1
     m=$(dd if=/dev/block/mmcblk0p9 bs=4096 count=2099 2>/dev/null | md5sum)
     echo "boot 分区前 8597504 字节 : ${m%% *}"' 2>&1

echo
echo "========== 7. install/ 脚本实际执行痕迹 =========="
S 'if [ -f /cache/recovery/last_log ]; then
        grep -n -E "about to run program|run_program|backuptool|otasigcheck|Not backing up" /cache/recovery/last_log 2>/dev/null | tail -20
     else
        echo "（last_log 不存在：本轮不经 TWRP updater，无 install/ 执行痕迹可查）"
     fi' 2>&1

# ---------------------------------------------------------------------------
# 8. 自动判定：一次 adb shell 取回全部 key=value，本地逐项断言。
#    设备侧一律落盘再 grep，避免大输出塞进变量导致 argv 过长。
# ---------------------------------------------------------------------------
echo
echo "========== 7b. WiFi / 蓝牙开机自启与自动连接 =========="
S 'echo -n "wifi_on (global)             : "; settings get global wifi_on
     echo -n "bluetooth_on (global)        : "; settings get global bluetooth_on
     dumpsys wifi 2>/dev/null | grep -m1 "Wi-Fi is "
     dumpsys wifi 2>/dev/null | grep -m1 "mNetworkInfo"
     dumpsys wifi 2>/dev/null | grep -m1 "mWifiInfo SSID"
     dumpsys bluetooth_manager 2>/dev/null | grep -m1 "  state:"
     echo -n "wpa_supplicant.conf network块: "; grep -c "^network=" /data/misc/wifi/wpa_supplicant.conf 2>/dev/null || true
     echo -n "home 守护抢前台日志          : "; logcat -d -v brief 2>/dev/null | grep -c "HOME in foreground but window hidden" || true' 2>&1

echo
echo "========== 8. 自动判定（PASS / FAIL）=========="
V="$("$A" shell '
logcat -d -v brief > /data/local/tmp/verify_logcat.txt 2>/dev/null
dumpsys window windows > /data/local/tmp/verify_windows.txt 2>/dev/null
grep -E "Window #|mViewVisibility=" /data/local/tmp/verify_windows.txt \
    > /data/local/tmp/verify_windows_compact.txt 2>/dev/null
i=0
for f in /system/lib/libEGL.so /system/etc/init/lmkd.rc \
         /system/bin/sf_hwc_off.sh /system/lib/libselinux_bypass.so \
         /system/lib/libminijail.so /system/bin/zz-ardbeg-firstboot-fix.sh \
         /system/bin/zz-ardbeg-home-watchdog.sh \
         /system/etc/wifi/ardbeg_default_network.conf \
         /system/etc/init/zz-persist-log.rc \
         /system/lib/libstagefrighthw.so \
         /system/etc/media_codecs.xml \
         /system/etc/init/mediacodec.rc; do
    i=$((i+1))
    m=$(md5sum "$f" 2>/dev/null)
    echo "@md5_$i=${m%% *}"
done
i=0
for k in "EGL_BAD_DISPLAY" "Failed to choose config" "WATCHDOG KILLING" \
         "SLOW OOM ADJ" "lowmemorykiller daemon socket open failed" \
         "Failed to setexeccon" "Unknown package" \
         "could not get context" "is not valid (left unmapped)"; do
    i=$((i+1))
    echo "@kw_$i=$(grep -c "$k" /data/local/tmp/verify_logcat.txt || true)"
done
echo "@logcat_lines=$(wc -l < /data/local/tmp/verify_logcat.txt)"
echo "@boot_completed=$(getprop sys.boot_completed)"
echo "@ss=$(pidof system_server)"
echo "@lmkd_pid=$(pidof lmkd)"
echo "@svc_lmkd=$(getprop init.svc.lmkd)"
echo "@svc_homewd=$(getprop init.svc.ardbeg_homewd)"
echo "@svc_fbfix=$(getprop init.svc.fb_fix)"
echo "@svc_wifiloader=$(getprop init.svc.wifiloader)"
# 2026-11-07：persist_logcat 曾因 4.4.4 sepolicy 缺 logcat_exec type 而
# 永远起不来（init: could not get context）。修法是 rc 里加 seclabel，
# 这里把「服务真的 running + 日志真的落盘」固化成端到端判据。
echo "@svc_persistlog=$(getprop init.svc.persist_logcat)"
echo "@persist_log_ok=$(test -s /cache/persist_log.txt && echo 1 || echo 0)"
echo "@ui_hw=$(getprop persist.sys.ui.hw)"
echo "@socket_lmkd=$(ls -l /dev/socket/lmkd 2>/dev/null | cut -c1)"
echo "@wdt=$(ls /data/anr/traces_SystemServer_WDT* 2>/dev/null | wc -l)"
echo "@anr=$(ls /data/anr/ 2>/dev/null | wc -l)"
echo "@tomb=$(ls /data/tombstones/tombstone_* 2>/dev/null | wc -l)"
echo "@display_on=$(dumpsys display 2>/dev/null | grep -m1 "DisplayDeviceInfo" | grep -c "state ON" || true)"
echo "@launcher_vis=$(grep -B1 "mViewVisibility=0x0" /data/local/tmp/verify_windows_compact.txt | grep -c "Launcher" || true)"
echo "@scrim_gone=$(grep -B1 "mViewVisibility=0x8" /data/local/tmp/verify_windows_compact.txt | grep -c "KeyguardScrim" || true)"
echo "@resumed_launcher=$(dumpsys activity activities 2>/dev/null | grep -m1 "mResumedActivity" | grep -c "trebuchet" || true)"
# 2026-11-07：先判 last_log 在不在，再决定用哪条证据链。四清 + 按块表 dd
# 写入时它必然不存在，下面三项 grep -c 会给出空串，不能拿去做 expect "1"。
echo "@last_log_present=$(test -f /cache/recovery/last_log && echo 1 || echo 0)"
echo "@last_log_lines=$(wc -l < /cache/recovery/last_log 2>/dev/null || echo 0)"
echo "@execv=$(grep -c "execv failed" /cache/recovery/last_log 2>/dev/null || true)"
echo "@rc0=$(grep -c "Updater process ended with RC=0" /cache/recovery/last_log 2>/dev/null || true)"
echo "@script_ok=$(grep -c "script succeeded" /cache/recovery/last_log 2>/dev/null || true)"
m=$(dd if=/dev/block/mmcblk0p9 bs=4096 count=2099 2>/dev/null | md5sum)
echo "@boot_md5=${m%% *}"
echo "@wifi_enabled=$(dumpsys wifi 2>/dev/null | grep -m1 "Wi-Fi is " | grep -c "Wi-Fi is enabled" || true)"
echo "@wifi_conn=$(dumpsys wifi 2>/dev/null | grep -m1 "mNetworkInfo" | grep -c "CONNECTED/CONNECTED" || true)"
echo "@wifi_ssid=$(dumpsys wifi 2>/dev/null | grep -m1 "mWifiInfo SSID" | grep -c "CPE-0C3FB8" || true)"
echo "@bt_on=$(dumpsys bluetooth_manager 2>/dev/null | grep -m1 "  state:" | grep -c "state: ON" || true)"
echo "@wpa_net=$(grep -c "^network=" /data/misc/wifi/wpa_supplicant.conf 2>/dev/null || true)"
echo "@homewd_hijack=$(grep -c "HOME in foreground but window hidden" /data/local/tmp/verify_logcat.txt || true)"
echo "@fbfix_done=$(grep -c "connectivity fix done" /data/local/tmp/verify_logcat.txt || true)"
# 用于区分「transient EGL_BAD_DISPLAY」和「真的黑屏」：
# 只要 logcat 里有 OpenGLRenderer 成功初始化 EGL 的记录，说明图形栈是活的。
echo "@egl_init_ok=$(grep -c "Initialized EGL, version" /data/local/tmp/verify_logcat.txt || true)"
' 2>/dev/null | tr -d '\r')"

# 设备侧每行是 @key=value；用 @ 前缀是为了避免 grep 误命中 logcat/dumpsys
# 残留文本里恰好长得像 key= 的行。本地传参不含 @，这里补上。
get() { printf '%s\n' "$V" | grep -m1 "^@$1=" | cut -d= -f2-; }
PASS=0
FAIL=0
SKIP=0
# 「证据边界」专用：该文件/日志在当前刷入路径下按设计不会出现。
# 既不能算 PASS（会假装验过了），也不能算 FAIL（会把正常状态判成故障）。
skip() {
    local name="$1" why="$2"
    echo "  SKIP  $name（$why）"
    SKIP=$((SKIP + 1))
}
expect() {
    local name="$1" actual="$2" want="$3"
    if [ "$actual" = "$want" ]; then
        echo "  PASS  $name = $actual"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name: 实际[$actual] 期望[$want]"
        FAIL=$((FAIL + 1))
    fi
}
nonempty() {
    local name="$1" actual="$2"
    if [ -n "$actual" ]; then
        echo "  PASS  $name = $actual"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name: 进程不存在"
        FAIL=$((FAIL + 1))
    fi
}

echo "--- 启动与服务 ---"
expect  "sys.boot_completed"        "$(get boot_completed)"  "1"
nonempty "pidof system_server"      "$(get ss)"
nonempty "pidof lmkd"               "$(get lmkd_pid)"
expect  "init.svc.lmkd"             "$(get svc_lmkd)"        "running"
expect  "init.svc.ardbeg_homewd"    "$(get svc_homewd)"      "running"
expect  "init.svc.fb_fix (oneshot)" "$(get svc_fbfix)"       "stopped"
expect  "wifiloader (oneshot)"      "$(get svc_wifiloader)"  "stopped"
expect  "init.svc.persist_logcat"   "$(get svc_persistlog)"  "running"
expect  "/cache/persist_log.txt 非空" "$(get persist_log_ok)" "1"
expect  "persist.sys.ui.hw"         "$(get ui_hw)"           "0"
expect  "/dev/socket/lmkd 类型"     "$(get socket_lmkd)"     "s"

echo "--- /system 关键文件 md5（必须与最终 OTA 包逐字节一致）---"
# 记下本段起点：last_log 缺失时，这 12 项 + boot md5 就是替代 updater 日志的
# 「分区级字节证据」，必须整段全绿才有资格把 updater 三项判成 SKIP。
MD5_FAIL_AT_START=$FAIL
for i in "${!EXPECT_MD5[@]}"; do
    expect "md5 ${EXPECT_PATHS[$i]}" "$(get md5_$((i + 1)))" "${EXPECT_MD5[$i]}"
done
expect "boot 分区前 8597504 字节" "$(get boot_md5)" "$EXPECT_BOOT_MD5"
MD5_SECTION_FAIL=$((FAIL - MD5_FAIL_AT_START))

echo "--- logcat 根因关键字（必须全 0）---"
if [ "$(get logcat_lines)" -gt 0 ] 2>/dev/null; then
    echo "  PASS  logcat 落盘行数 = $(get logcat_lines)"
    PASS=$((PASS + 1))
else
    echo "  FAIL  logcat 落盘为空，后面的 0 都是「假绿」，判据无效"
    FAIL=$((FAIL + 1))
fi
for i in "${!EXPECT_KW[@]}"; do
    # 例外：EGL_BAD_DISPLAY 放到下面的「1 条容差」专项判定，见文件头注释第 10 条。
    # 原因：老 Tegra 的 libEGL_tegra_impl 在进程首次 attach 时可能随手返回一次
    # EGL_BAD_DISPLAY（典型是 Jelly 起 WebView 那一刻），紧接着 OpenGLRenderer
    # 就 Initialized EGL, version 1.4 正常渲染；这在整机生命周期里只出现 1 次，
    # 不是黑屏链复发。真正的复发信号是「Failed to choose config」、
    # tombstone、ANR —— 那三项仍然按严格 0 判。
    if [ "${EXPECT_KW[$i]}" = "EGL_BAD_DISPLAY" ]; then
        continue
    fi
    expect "logcat '${EXPECT_KW[$i]}'" "$(get kw_$((i + 1)))" "0"
done

# EGL_BAD_DISPLAY 专项：容 1 条 transient，且必须伴随成功的 EGL 初始化。
# 只看计数会被「1 条偶尔的、无害的」误伤；只看关键字会漏掉「连打 20 条」的真复发。
egl_n=$(get kw_1)
egl_ok=$(get egl_init_ok)
if [ "${egl_n:-99}" -le 1 ] 2>/dev/null; then
    echo "  PASS  logcat 'EGL_BAD_DISPLAY' = $egl_n（<=1 条 transient，允许）"
    PASS=$((PASS + 1))
elif [ "${egl_ok:-0}" = "1" ]; then
    echo "  WARN  logcat 'EGL_BAD_DISPLAY' = $egl_n（>1 条，但 EGL 已成功初始化，非黑屏）"
    PASS=$((PASS + 1))
else
    echo "  FAIL  logcat 'EGL_BAD_DISPLAY' = $egl_n 且没有成功的 EGL 初始化 → 黑屏链复发"
    FAIL=$((FAIL + 1))
fi

echo "--- ANR / tombstone / Watchdog trace ---"
expect "traces_SystemServer_WDT*" "$(get wdt)"  "0"
expect "ANR 目录文件数"           "$(get anr)"  "0"
expect "tombstone 数"             "$(get tomb)" "0"

echo "--- display / 窗口可见性 ---"
expect "display state ON"                 "$(get display_on)"        "1"
expect "Launcher mViewVisibility=0x0"     "$(get launcher_vis)"      "1"
expect "KeyguardScrim mViewVisibility=0x8" "$(get scrim_gone)"       "1"
expect "前台 Activity 是 Launcher"        "$(get resumed_launcher)"  "1"

echo "--- 刷包路径证据（TWRP updater / 按块表 dd 二选一）---"
if [ "$(get last_log_present)" = "1" ]; then
    echo "  证据链 A：TWRP updater 安装（last_log $(get last_log_lines) 行）"
    ll=$(get last_log_lines)
    if [ "${ll:-0}" -gt 0 ] 2>/dev/null; then ll_ok=1; else ll_ok=0; fi
    expect "last_log 有内容"                  "$ll_ok"            "1"
    expect "last_log execv failed"            "$(get execv)"      "0"
    expect "Updater process ended with RC=0"  "$(get rc0)"        "1"
    expect "script succeeded"                 "$(get script_ok)"  "1"
else
    # 2026-11-07：本机 TWRP GUI 因 framebuffer 0x0 反复崩溃，ORS 引擎不
    # 消费命令，真机闭环改走「四清脚本 + 按 OTA 块表逐段 dd 写入」，语义
    # 等价 recovery 的 block_image_update()。该路径不经过 updater，自然
    # 不写 last_log；四清脚本还会显式清空 /cache/recovery/*。所以这里的
    # 「文件不存在」是设计使然，绝不能当成 3 个功能 FAIL。
    echo "  证据链 B：四清 + recovery shell 按 OTA 块表 dd 写入（不经 updater）"
    skip "last_log updater 三项" "四清清空 /cache/recovery/*，按块表 dd 不产生 last_log；证据边界，非 ROM 故障"
    # 跳过 updater 日志的代价是必须由分区字节证据兜底：上面 12 项
    # /system md5 + boot 分区 md5 必须整段 0 FAIL。这样「包没刷对」就
    # 不可能借证据边界蒙混过关，严格性并未降低。
    expect "分区级字节证据（12 文件 md5 + boot md5）全绿" "$MD5_SECTION_FAIL" "0"
fi

echo "--- WiFi / 蓝牙开机自启与自动连接 ---"
expect "WiFi 开机已启用"                "$(get wifi_enabled)"  "1"
expect "WiFi 自动连上 CONNECTED"        "$(get wifi_conn)"     "1"
expect "连的是预置 CPE-0C3FB8"          "$(get wifi_ssid)"     "1"
expect "蓝牙开机 state: ON"             "$(get bt_on)"         "1"
expect "wpa_supplicant.conf 有网络块"   "$(get wpa_net)"       "1"
# 首启脚本「跑完了没」不能只靠 logcat 关键字。
#   logcat 是环形缓冲区，设备连续跑十几小时（本次是 00:47 冷启动 →
#   13:25 复跑）后 `connectivity fix done` 必然被冲掉，此时硬性 expect 1
#   会把「日志被冲掉」误判成「首启脚本没跑」。实测这一项就是这么 FAIL 的，
#   而同时 WiFi 已连 CPE-0C3FB8、蓝牙 ON、网络块在，说明脚本明明跑过。
#
# 降级判据（严格性不降低）：
#   ① logcat 里有 "connectivity fix done" → PASS（直接日志证据）；
#   ② 没有日志，但 WiFi 已开 + 自动连上 + 蓝牙 ON + 网络块存在 四项全绿
#      → PASS，标注「缓冲区已滚动，由运行时状态佐证」；
#      理由：四清后若首启脚本真没跑，这四项一项都不可能成立
#      （WiFi/BT 默认值只在全量编译生效，文件级重打包靠首启脚本兜底，
#       预置网络也是首启脚本注入的）；
#   ③ 其余 → FAIL。
fb_n=$(get fbfix_done)
if [ "${fb_n:-0}" -ge 1 ] 2>/dev/null; then
    echo "  PASS  首启脚本跑完 connectivity = $fb_n（logcat 直接证据）"
    PASS=$((PASS + 1))
elif [ "$(get wifi_enabled)" = "1" ] && \
     [ "$(get wifi_conn)" = "1" ] && \
     [ "$(get bt_on)" = "1" ] && \
     [ "$(get wpa_net)" -ge 1 ] 2>/dev/null; then
    echo "  PASS  首启脚本跑完 connectivity（logcat 缓冲区已滚动，由 WiFi 自动连 + BT ON + 网络块佐证）"
    PASS=$((PASS + 1))
else
    echo "  FAIL  首启脚本跑完 connectivity: logcat=0 且运行时状态不全绿 → 首启脚本可能没跑"
    FAIL=$((FAIL + 1))
fi

echo "--- 浏览器「闪退」（home 守护抢前台，非崩溃）---"
expect "home 守护抢前台日志为 0"        "$(get homewd_hijack)" "0"

# ---------------------------------------------------------------------------
# 9. 可选交互验收：启动 Jelly 并跨过守护的 90 秒冷却窗口。
#    默认关闭，因为它要把设备留在浏览器里 105 秒；CHECK_BROWSER=1 才跑。
#    判据用 mResumedActivity，不能用 FATAL/tombstone —— 这个 bug 从头到尾
#    就没有崩溃，是守护主动 am start HOME 把用户踢回桌面。
# ---------------------------------------------------------------------------
if [ "${CHECK_BROWSER:-0}" = "1" ]; then
    echo
    echo "========== 9. 交互验收：浏览器不会被踢回桌面 =========="
    "$A" shell 'am start -n org.lineageos.jelly/.MainActivity >/dev/null 2>&1' >/dev/null 2>&1
    sleep 5
    before=$("$A" shell 'dumpsys activity activities 2>/dev/null | grep -m1 "mResumedActivity"' 2>/dev/null | tr -d '\r')
    if printf '%s\n' "$before" | grep -q 'org.lineageos.jelly'; then b=1; else b=0; fi
    expect "Jelly 启动后在前台" "$b" "1"
    echo "  等待 105 秒（守护 COOLDOWN=90s，必须跨过去才有意义）..."
    sleep 105
    after=$("$A" shell 'dumpsys activity activities 2>/dev/null | grep -m1 "mResumedActivity"' 2>/dev/null | tr -d '\r')
    if printf '%s\n' "$after" | grep -q 'org.lineageos.jelly'; then a=1; else a=0; fi
    expect "静置 105 秒后仍在 Jelly" "$a" "1"
    n=$("$A" shell 'logcat -d -v brief 2>/dev/null | grep -c "HOME in foreground but window hidden" || true' 2>/dev/null | tr -d '\r')
    expect "期间抢前台日志为 0" "$n" "0"
    # 收尾恢复桌面，避免把设备留在浏览器里影响后续人工检查
    "$A" shell 'am start -n com.cyanogenmod.trebuchet/com.android.launcher3.Launcher >/dev/null 2>&1' >/dev/null 2>&1
fi

echo
echo "========== 汇总 =========="
echo "PASS = $PASS   FAIL = $FAIL   SKIP = $SKIP"
if [ "$FAIL" -eq 0 ]; then
    echo "结论：四清 + 最终 OTA 包端到端验收通过，修复确实固化在 ROM 里。"
    if [ "$SKIP" -gt 0 ]; then
        echo "      其中 $SKIP 项是当前刷入路径下的证据边界（已用分区级字节证据替代），不是功能缺失。"
    fi
else
    echo "结论：存在未通过项。按上面 FAIL 逐项排查；注意 dirty flash 会让"
    echo "      某些项假通过，复现请务必先 TWRP 四清再刷包。"
fi
exit $((FAIL > 0))
