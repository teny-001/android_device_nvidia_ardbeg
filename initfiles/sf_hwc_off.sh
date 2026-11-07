#!/system/bin/sh
# ============================================================================
# sf_hwc_off.sh —— 让 SurfaceFlinger 永久关闭 HWC 合成（改走 GLES）
#
# 【这个脚本解决什么问题】
#   本机用的是 g100 原厂 Android 4.4.4 的 hwcomposer.tegra.so，跑在
#   CM14.1(Nougat 7.1.2) 的 SurfaceFlinger 里。两代的 hwc_layer_1_t 虽然
#   都被 padding 到 96 字节（步长一致，不越界），但字段偏移从 offset 16
#   开始整体错位 4 字节：
#
#       字段                  4.4.4     7.1
#       --------------------  -----     -----
#       compositionType          0         0
#       hints                    4         4
#       flags                    8         8
#       handle                  12        12
#       buffer                  16        (无，被 transform 顶替)
#       transform               20        16
#       blending                24        20
#       sourceCrop              28        24
#       displayFrame            44        40
#       visibleRegionScreen     60        56
#       acquireFenceFd          68        64
#       releaseFenceFd          72        68
#
#   结果：厂商 HWC 按 4.4.4 的偏移去读 7.1 的 layer 数组，
#   把 visibleRegionScreen.numRects 读成 rects 指针、
#   把 acquireFenceFd 读成 rects 指针去解引用，
#   并且把 releaseFenceFd 写到 7.1 的 planeAlpha/_pad 上，
#   真正的 releaseFenceFd(offset 68) 永远是未初始化的垃圾。
#
#   实测后果（logcat -b crash）：
#     F libc : Fatal signal 11 (SIGSEGV), fault addr 0x8
#     #00 pthread_mutex_lock+1
#     #01 je_tcache_bin_flush_large+132
#     #03 je_malloc+762
#     #04 operator new
#     #05 libsurfaceflinger.so
#   也就是 jemalloc 的堆被写坏，然后在某次 malloc 时炸掉。
#   SF 每 40~100 秒崩一次，而且**崩一次就永久黑屏**：
#   所有客户端的 BufferQueue 变成孤儿，框架层没有"SF 重启了"的通知，
#   WMS 不会重建 Surface，窗口层级完好但每个 Layer 都没有 buffer。
#
# 【为什么用 GLES 合成就能躲开】
#   SurfaceFlinger 有个隐藏的 binder 命令（SurfaceFlinger_hwc1.cpp:3290）：
#       case 1008:  // toggle use of hw composer
#           n = data.readInt32();
#           mDebugDisableHWC = n ? 1 : 0;
#           invalidateHwcGeometry();
#           repaintEverything();
#   设成 1 之后，所有 layer 的 compositionType 都被强制成 HWC_FRAMEBUFFER，
#   全部由 GPU 用 OpenGL ES 合成到 framebuffer target，
#   厂商 HWC 只需要处理最后那一个 FB TARGET layer，
#   于是它再也不会去遍历/改写客户端 layer 数组，堆就不会被踩坏。
#
# 【实测数据（2026-11-05 23:09 那次开机，最干净的一次）】
#   uptime 39s  sf=261  png=25 KB    （FallbackHome，启动中）
#   uptime 66s  sf=261  png=1.85 MB  （桌面完整渲染）
#   uptime 93s  sf=261  png=1.85 MB
#   uptime 334s sf=261  ss=1669      （5.5 分钟内 SF 与 system_server 的
#                                      pid 全程未变，一次都没崩）
#   对比修改前：SF 每 40~100 秒崩一次，崩完永久黑屏。
#
# 【代价】
#   所有合成都走 GPU，没有硬件 overlay，功耗和带宽会高一些。
#   Tegra K1 的 GPU 应付 1080p 桌面合成没有问题，实测操作流畅。
#   等以后写好 hwcomposer shim（做 4.4.4 <-> 7.1 的 layer 字段翻译），
#   就可以去掉这个脚本、恢复硬件合成。
#
# 【为什么要循环监控】
#   SF 如果还是崩了（比如 EGL 驱动自身的问题），init 会重启它，
#   新 SF 的 mDebugDisableHWC 又回到默认 0，所以必须盯着 pid 变化，
#   一变就重新设置。
#
# 【为什么不注入任何输入事件】
#   中间试过用 input keyevent 去"踢"一下让 SF 出帧，结论是**不需要且有副作用**：
#     - 不需要：上面的实测数据里，uptime 66 秒桌面就自己渲染出来了，
#       而注入逻辑最早也要到 boot_completed+30s（约 uptime 75 秒）才动作；
#     - 有副作用：KEYCODE_WAKEUP(224) 在本机被 gpio-keys 映射成电源键，
#       会弹出"关机 / 重新启动"的 GlobalActions；
#       改用 KEYCODE_DPAD_DOWN(20) 又会在桌面上移动焦点、误开 DeskClock。
#   真正决定屏幕能不能出来的，是 disableHWC 设置得够不够早：
#     - 用 on post-fs-data（uptime 40 秒才触发）：SF 在 44 秒已崩，来不及；
#     - 用 on post-fs（uptime 2 秒就设置好）：SF 不崩，66 秒自动出桌面。
#   所以这里只做诊断记录，绝不干扰用户操作。
# ============================================================================

LOG_TAG="sf_hwc_off"

log_msg() {
    /system/bin/log -t "$LOG_TAG" "$*" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 第一步：等 SurfaceFlinger 的 binder 注册好，然后关掉 HWC 合成
# ---------------------------------------------------------------------------
set_disable_hwc() {
    # 【注意】这里必须精确匹配 "Service SurfaceFlinger: found"。
    #   service check 在服务不存在时输出的是
    #       Service SurfaceFlinger: not found
    #   里面**也包含 "found" 这个词**，所以不能只 grep found，
    #   否则会在 SF 还没注册的时候误判为"已就绪"。
    if /system/bin/service check SurfaceFlinger 2>/dev/null \
            | grep -q 'Service SurfaceFlinger: found'; then
        # 1008 = toggle use of hw composer，参数 i32 1 表示"禁用"
        /system/bin/service call SurfaceFlinger 1008 i32 1 >/dev/null 2>&1
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 【2026-11-06 深夜】删除「第二步：屏幕诊断（screencap）」—— 它会拖垮整机
#
# 原来的做法：boot_completed 后 90 秒在后台跑一次
#     /system/bin/screencap -p /data/local/tmp/.sf_hwc_off_chk.png
# 用截图文件大小判断屏幕有没有内容（纯黑约 10 KB / 正常桌面约 1.8 MB）。
#
# 【为什么必须删】
#   本机 DisplayDeviceInfo 带 FLAG_SECURE / isSecure=1。这一点在
#   zz-ardbeg-firstboot-fix.sh 第 61 行、zz-ardbeg-home-watchdog.sh
#   第 55 行都明确写过「secure display 上 screencap 会挂住或返回纯黑 PNG」，
#   但本脚本自己却还在无超时地调它 —— 注释和代码自相矛盾。
#
#   实测（2026-11-06 22:28，刷入补丁版 libEGL.so 之后）：
#     /proc/4612/cmdline = /system/bin/screencap -p
#                          /data/local/tmp/.sf_hwc_off_chk.png
#     进程从 22:28 一直挂到 22:32 都不返回，`timeout 3` 也杀不掉
#     （SIGTERM 被忽略），连带 `am broadcast MEDIA_SCANNER_SCAN_FILE`
#     也卡住。screencap 占着 SurfaceFlinger 的客户端连接不放，
#     于是 system_server 的 WindowManager 拿不到 SF 的锁，
#     binder 事务全部排队 —— 表现为**多个毫不相干的进程同时 ANR**：
#       22:27:56 SystemUI (TIME_TICK 广播)
#       22:28:06 weatherservice (executing service)
#       22:28:18 printspooler
#       22:28:33 android.process.media (USB_STATE 广播)
#       22:29:42 Trebuchet (Input dispatching timed out, wait queue 77)
#       22:29:43 SystemUI (TIME_TICK 广播)
#     ANR 后 AMS `Force finishing activity` 杀掉 Trebuchet，
#     ardbeg_homewd 再重拉，看起来就像「桌面反复死 / 一直黑屏」。
#
#   A/B 验证：把挂住的 screencap 全部 kill -9 之后，观察 60 秒，
#   ANR 计数保持 6 不再增长（EGL_BAD_DISPLAY 始终为 0），
#   证明这条链与 EGL 无关，是独立的第二个黑屏来源。
#
# 【替代方案】
#   不再做截图诊断。窗口可见性由 zz-ardbeg-home-watchdog.sh 的
#   launcher_visible()（dumpsys window windows 的 mViewVisibility）
#   和 zz-ardbeg-firstboot-fix.sh 第 8 步负责，那些路径不会碰
#   secure display 的像素读取。
#
#   如果以后确实需要截图，必须同时满足：
#     1) 用 `timeout -k 2 5` 强杀（普通 timeout 的 SIGTERM 无效）；
#     2) 只在 `dumpsys display` 确认 !isSecure 时执行；
#     3) 只在用户手动设了调试属性时启用，默认关闭。
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------
log_msg "watchdog started"

# ★ 不要再挂后台 screencap 诊断流程（do_screen_diag_async 已删除，
#   原因见上面那段长注释：它会在 FLAG_SECURE 屏上永久挂住并引发全局 ANR）。
#   本脚本现在只做一件事：盯住 surfaceflinger 的 pid，
#   一旦换了新 pid 就重新 `service call SurfaceFlinger 1008 i32 1`。

last_pid=""
while true; do
    cur_pid="$(/system/bin/pidof surfaceflinger 2>/dev/null | tr -d '\r\n')"

    if [ -n "$cur_pid" ] && [ "$cur_pid" != "$last_pid" ]; then
        # SF 是新起来的（或者第一次起来），设置一次
        if set_disable_hwc; then
            log_msg "disableHWC=1 applied to surfaceflinger pid=$cur_pid"
            last_pid="$cur_pid"
        fi
    fi

    # 1 秒一轮：SF 崩溃窗口只有 40~100 秒，轮询太慢会错过；
    # 这个循环只做 pidof + 一次 service check，开销可以忽略。
    sleep 1
done
