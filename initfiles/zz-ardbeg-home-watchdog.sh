#!/system/bin/sh
# =============================================================================
# [CM14.1-on-ardbeg 新增 2026-11-06] 桌面 / 显示 常驻自愈守护
#
# 配套 zz-ardbeg-firstboot-fix.sh（负责首次点亮）和
# zz-ardbeg-home-watchdog.rc（负责开机自动拉起本脚本）。
#
# -----------------------------------------------------------------------------
# 【为什么一次性脚本不够，必须常驻】
#
# 2026-11-06 实机 logcat 证据（设备 cm_ardbeg_tv-eng，开机约 20 分钟）：
#
#     F/libc    (25846): Fatal signal 6 (SIGABRT), code -6 in tid 2357
#                        (RenderThread)
#     E/ActivityManager( 1428): ANR in com.android.systemui
#     I/ActivityManager( 1428): Process com.android.systemui (pid 1429) has died
#     I/ActivityManager( 1428): Process com.cyanogenmod.trebuchet
#                               (pid 25846) has died
#     W/ActivityManager( 1428): Re-adding persistent process ...
#
# 即 Trebuchet 的 RenderThread 会在运行中 SIGABRT（4.4.4 的 NVIDIA
# GL/HWC 驱动与 7.1 的 RenderThread/hwui 不兼容），SystemUI 也会 ANR。
# 两者死后：
#     dumpsys window  里 mFocusedApp 仍残留 Launcher 的 ActivityRecord
#     dumpsys SurfaceFlinger 里只剩僵尸 KeyguardScrim 图层
#         layerStack=4294967295 / numLayers=0 / powerMode=0 / isSecure=1
# 屏幕表现就是全黑，而且**不会自己恢复** —— 因为 AMS 认为 HOME 已经在前台。
#
# 所以必须有个常驻进程，周期性检查「桌面进程是否真的活着」。
#
# -----------------------------------------------------------------------------
# 【第二个职责：display 掉回 OFF 时重新点亮】
#
# 本机 /sys/class/backlight/ 为空，LightsService 写不进背光，
# DisplayPowerController 常卡在等「亮度已设置」的确认。
# 实测：
#     input keyevent 224 (WAKEUP) -> mWakefulness=Awake，但 display 仍 OFF
#     settings put system screen_brightness <变化的值> -> display 立刻 ON
# 只有 SettingsProvider 的 onBrightnessChanged 能触发 DPC 重新评估。
#
# 因此本守护在检测到 display OFF 时做一次 254/255 交替写入（写同一个值
# 不算变化，不会触发回调），并冷却 90 秒，避免频繁启动 settings 的
# app_process VM 拖慢系统。
#
# -----------------------------------------------------------------------------
# 【★ 两个必须遵守的坑 ★】
#
# 1) 判据不能用 grep "state OFF"。dumpsys display 里 mOverrideDisplayInfo
#    那行可能永远是 state OFF，会误判。只取第一行 DisplayDeviceInfo。
#
# 2) /system/bin/settings 是 app_process 启的 ART VM，写完不退出，
#    且启动+写盘要十几秒。必须 timeout 30（实测 timeout 10 写不进去），
#    并且不能缩短。详见 zz-ardbeg-firstboot-fix.sh 头部。
#
# 3) screencap 不能用来判断亮屏：DisplayDevice 带 isSecure=1，
#    secure display 上 screencap 会挂住或返回纯黑 PNG。
#
# -----------------------------------------------------------------------------
# 【第三个职责（2026-11-06 深夜新增）：桌面「窗口」可见性，不只是进程】
#
# 旧版只查 display_is_on + pidof，被实测打脸：
#     display state ON、Launcher 进程在、mFocusedApp 指向 Launcher，
#     但 WMS 里 Launcher 窗口 mViewVisibility=0x4 / mHaveFrame=false /
#     mHasSurface=false，SurfaceFlinger 里 ImageWallpaper 和
#     "Starting com.cyanogenmod.trebuchet" 两个 layer 的 alpha 都是 0x00
#     —— 合成出来仍然是一整块黑屏，用户看不到桌面。
#
# 根因链见 zz-ardbeg-firstboot-fix.sh 头部「问题 4」：
#     persist.sys.ui.hw=1 -> RenderThread EGL_BAD_DISPLAY SIGABRT
#     -> KeyguardService 反复断开 -> KeyguardScrim 永不 hide
#     -> 窗口淡入动画卡住 -> layer alpha=0x00
#
# 现在 build.prop 已把 persist.sys.ui.hw 改成 0、首启脚本把三个
# animation_scale 设成 0，但守护仍需兜住「运行中窗口又掉回不可见」，
# 所以每轮额外查一次 WMS 里 Launcher 窗口的 mViewVisibility。
#
# 【判据】grep -A1 取 "Window #N ... Launcher}:" 后面紧跟的一行。
#   不能用 screencap：DisplayDevice 带 isSecure=1 / FLAG_SECURE，
#   secure display 上固定返回 10595 字节纯黑 PNG。
# -----------------------------------------------------------------------------
# 【为什么服务名是 ardbeg_homewd】
#   7.1 的 init 在 ServiceParser::IsValidName() 里硬性限制服务名 <= 16
#   字符（service.cpp），超了只会打一行 dmesg "invalid service name"，
#   文件照样显示 Parsing ... took 0.01s，极难发现。ardbeg_homewd = 13。
# =============================================================================

TAG=ardbeg_homewd
HOME_ACT='com.cyanogenmod.trebuchet/com.android.launcher3.Launcher'
INTERVAL=15
COOLDOWN=90
BRIGHT_TMP=/data/local/tmp/.ardbeg_homewd_bright

log_msg() { /system/bin/log -t "$TAG" "$*" 2>/dev/null; }

# 只看第一行 DisplayDeviceInfo，避开 mOverrideDisplayInfo 的干扰
display_is_on() {
    /system/bin/dumpsys display 2>/dev/null \
        | grep 'DisplayDeviceInfo{' | head -1 | grep -q 'state ON'
}

# 亮度必须真的变化才会触发 onBrightnessChanged，所以 254 <-> 255 交替
brightness_toggle() {
    cur=$(cat "$BRIGHT_TMP" 2>/dev/null)
    if [ "$cur" = "254" ]; then nxt=255; else nxt=254; fi
    timeout 30 settings put system screen_brightness "$nxt" >/dev/null 2>&1
    echo "$nxt" > "$BRIGHT_TMP"
    log_msg "brightness toggled to $nxt"
}

# ---------------------------------------------------------------------------
# 桌面窗口是否真的 VISIBLE（0x0）。进程在 / display ON 都不代表可见。
#
# 【2026-11-06 修复：这个函数原来恒为 false，是「浏览器闪退」的根因】
#   旧实现：
#       dumpsys window windows | grep -A1 '...Launcher' | grep -q 'mViewVisibility=0x0'
#   但原始 dumpsys 里 `Window #N Window{... Launcher}:` 的紧邻下一行是
#       mDisplayId=0 stackId=1 mSession=... mClient=...
#   `mViewVisibility=0x0 mHaveFrame=... mObscured=...` 在十几行之后，
#   -A1 根本取不到。实测**已经回到桌面**时这个函数依然返回 rc=1。
#
#   后果：主循环第 3 步每 90 秒无条件执行一次
#       wm dismiss-keyguard + am start HOME + brightness_toggle
#   把用户从 Jelly 浏览器 / 设置 / 输入法等任何 app 踢回桌面，
#   主观表现就是「应用一闪就退」；brightness_toggle 还要起一个 ART VM
#   去写 settings，卡顿也跟着来。这不是应用崩溃（logcat 里既没有
#   FATAL EXCEPTION 也没有 tombstone），是守护进程主动抢前台。
#
#   修法分两层：
#     1) 先把 dumpsys 压成「窗口标题 + 可见性」两行一组的紧凑列表，
#        再反查「哪个可见窗口是 Launcher」。不能直接 -A1；
#        toybox grep 的 -A/-B 遇 -m1 会丢上下文行，这里一律不带 -m。
#     2) 调用方再加 foreground_is_home() 守卫（见下方函数），
#        只有「前台理应是桌面」时才允许干预。
# ---------------------------------------------------------------------------
launcher_visible() {
    /system/bin/dumpsys window windows 2>/dev/null \
        | grep -E 'Window #|mViewVisibility=' \
        | grep -B1 'mViewVisibility=0x0' \
        | grep -q 'com.cyanogenmod.trebuchet/com.android.launcher3.Launcher'
}

# 前台 Activity 是不是 HOME。用来区分「桌面窗口被 KeyguardScrim 挡住」
# 和「用户自己打开了别的应用」——后者桌面窗口 GONE 完全正常，
# 绝对不能 am start HOME 抢回来。
foreground_is_home() {
    /system/bin/dumpsys activity activities 2>/dev/null \
        | grep -m1 'mResumedActivity' \
        | grep -q 'com.cyanogenmod.trebuchet'
}

log_msg "watchdog started (interval=${INTERVAL}s, cooldown=${COOLDOWN}s)"

# 开机早期 system_server 还没起来，dumpsys/pidof 都是空的，
# 此时什么都不做，避免误判成「桌面死了」而反复 am start。
while [ "$(/system/bin/getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    sleep 2
done
sleep 10

last_fix=0
while true; do
    now=$(/system/bin/date +%s 2>/dev/null)
    [ -z "$now" ] && now=0

    # ---- 1) 桌面进程存活检查 -------------------------------------------
    # 用 pidof 而不是 dumpsys activity：AMS 里残留的 ActivityRecord 会
    # 让人误以为 HOME 还在前台，只有 pidof 能反映真实进程状态。
    if [ -z "$(/system/bin/pidof com.cyanogenmod.trebuchet 2>/dev/null)" ]; then
        log_msg "launcher dead -> am start -n $HOME_ACT"
        /system/bin/am start -n "$HOME_ACT" >/dev/null 2>&1
        # 给 zygote 一点时间 fork + 完成首次绘制，再进入下一轮
        sleep 3
    fi

    # ---- 2) display 状态检查（带冷却） --------------------------------
    if ! display_is_on; then
        elapsed=$((now - last_fix))
        if [ "$elapsed" -ge "$COOLDOWN" ]; then
            log_msg "display OFF -> wakeup + brightness toggle"
            /system/bin/input keyevent 224 >/dev/null 2>&1   # KEYCODE_WAKEUP
            brightness_toggle
            last_fix=$now
        fi
    fi

    # ---- 3) 桌面窗口可见性检查（带冷却） -----------------------------
    # 与 display 共用一个 last_fix 冷却，避免同一轮里同时启动多个
    # settings/app_process VM 拖慢系统。
    #
    # 【必须先看前台是不是 HOME】
    #   用户打开浏览器 / 设置 / 输入法时，Launcher 窗口自然会变成
    #   mViewVisibility=0x8 (GONE)。如果只判 launcher_visible()，就会把
    #   这种完全正常的场景当成「桌面被遮罩挡住」，每 90 秒把用户踢回
    #   桌面一次 —— 这就是 2026-11-06 抓到的「浏览器闪退」。
    #   只有 mResumedActivity 仍是 Launcher、但它的窗口却不可见，
    #   才是真正需要 dismiss-keyguard + restart HOME 的异常。
    if foreground_is_home && ! launcher_visible; then
        elapsed=$((now - last_fix))
        if [ "$elapsed" -ge "$COOLDOWN" ]; then
            log_msg "HOME in foreground but window hidden -> dismiss keyguard + restart HOME"
            /system/bin/wm dismiss-keyguard >/dev/null 2>&1
            /system/bin/am start -n "$HOME_ACT" >/dev/null 2>&1
            /system/bin/input keyevent 224 >/dev/null 2>&1
            brightness_toggle
            last_fix=$now
        fi
    fi

    sleep "$INTERVAL"
done
