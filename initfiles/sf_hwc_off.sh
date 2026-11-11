#!/system/bin/sh
# ============================================================================
# sf_hwc_off.sh —— 让 SurfaceFlinger 永久关闭 HWC 合成（改走 GLES）
#
# 【这个脚本解决什么问题】
#
# ★★ 2026-11-10 复核：本段最初的推断已被实测推翻，原文保留在
#    git 历史与 README 里，这里改写为结论，避免后人照着错的前提改代码。
#
# 原始推断（错误）
#   认为 4.4.4 的 hwc_layer_1_t 在 offset 16 有一个独立于 handle 的
#   buffer 指针，7.1 把它并进了 union，于是 transform 之后整体错位 4 字节，
#   厂商 HWC 按 4.4.4 偏移读 7.1 的数组，把 visibleRegionScreen.numRects
#   当 rects 指针解引用、把 releaseFenceFd 写到 planeAlpha 上，踩坏堆。
#
# 实测结论（正确）：两版在 0~72 偏移上逐字段完全一致，sizeof 都是 96
#       字段                  4.4.4     7.1
#       --------------------  -----     -----
#       compositionType          0         0
#       hints                    4         4
#       flags                    8         8
#       handle                  12        12      <-- 4.4.4 没有 buffer 字段
#       transform               16        16
#       blending                20        20
#       sourceCrop              24        24
#       displayFrame            40        40
#       visibleRegionScreen     56        56
#       acquireFenceFd          64        64
#       releaseFenceFd          68        68
#       planeAlpha              72        72
#       _pad[3]              73..75    73..75
#       ---- 76 之后才分叉，且都不影响厂商 ----
#       4.4.4: reserved[24-19] = 20 字节（"reserved for future use"，
#              厂商只读不写）
#       7.1  : surfaceDamage(8) + reserved[96-84] = 12 字节
#              （surfaceDamage 只给 HWC2 的部分刷新用，4.4.4 厂商从不写）
#
# 三条互相独立的证据
#   1) 直接对照 CM11 源码树（= Android 4.4.4 原文）：
#      /home/dy/WorkBuddy AI/cm-11.0/hardware/libhardware/include/
#      hardware/hwcomposer.h —— offset 12 直接就是 handle，没有 buffer。
#   2) 编译期 offsetof 断言：wb_tmp/chk_hwc_layout.c 逐项验证 7.1 侧布局，
#      13 条断言全过，与上表吻合。
#   3) 运行期反证：厂商 HWC 的 dump() 能正确打印每层的 blend/xform/src/dst
#      （dumpsys SurfaceFlinger 的 "Nvidia HWC" 段）。结构体若错位，
#      这些值必然是垃圾。实测打印为 blend 0x105 xform 0x0
#      src(0,0,1920,1080) dst(0,0,1920,1080)，完全正确。
#
# 同样被推翻的还有「SF 每 40~100 秒崩一次」
#   /data/tombstones 里从头到尾**没有一条 surfaceflinger 的 tombstone**
#   （SF 是原生进程，真段错误必留 tombstone）。当时看到的黑屏其实是
#   com.cyanogenmod.trebuchet 的 RenderThread 抛 EGL_BAD_NATIVE_WINDOW
#   （tombstone_07~09），是画面已经坏掉之后的**结果**，不是 SF 崩了。
#
# 但「必须关掉厂商合成」这个结论**仍然成立**，只是原因完全不同
#
#   2026-11-10 第二轮实测：把 SurfaceFlinger 里另外三个也会触发 skip 的
#   标志一起清零（命令 1014 daltonize / 1015 colorMatrix / 1030 secondary），
#   使 layer 的 flags 从 0x0001 变成 0x0000，厂商 HWC 立刻从
#       Compositor: surfaceflinger (override)
#   变成
#       Compositor: glcomposer
#   也就是它开始真的自己合成了 —— 然后 SurfaceFlinger 当场 SIGSEGV，
#   pid 从 257 变成 20252，Visible layers 归 0，screencap 只剩 10 KB
#   （永久黑屏，所有客户端 BufferQueue 变孤儿）。
#
#   崩溃栈（logcat -b crash，这是本项目第一次拿到 SF 的真实 tombstone）：
#       signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0xc
#       #00 libutils.so          android::RefBase::decStrong+37
#       #01 hwcomposer.tegra.so  android::sp<GraphicBuffer>::operator=+22
#       #02 hwcomposer.tegra.so  destroy_graphic_buffer+8
#       #03 hwcomposer.tegra.so
#       #04 hwcomposer.tegra.so  glc_set+1096
#       #05 hwcomposer.tegra.so  hwc_composite_set+252
#       #06 hwcomposer.tegra.so
#       #07 libsurfaceflinger.so
#
#   即崩在厂商 HWC 自己的 GL 合成器里：destroy_graphic_buffer 对一个
#   已经释放的 GraphicBuffer 做 sp<> 赋值，decStrong 打到野指针上
#   （fault addr 0xc 是 RefBase 的引用计数成员偏移）。
#   这是 4.4.4 厂商 blob 在 7.1 上**内部状态机**不兼容，跟 layer 结构体
#   的字段布局毫无关系 —— 所以「写个字段翻译 shim」这条路是死路。
#
#   结论：厂商的合成路径（persist.tegra.compositor=glcomposer）在本机
#   一用就崩，必须让它永远不参与合成。做法就是给所有 layer 置
#   HWC_SKIP_LAYER，让厂商只处理最后那一个 HWC_FRAMEBUFFER_TARGET。
#   本脚本正是干这个的，**不可省略**。
#
#   ★ 顺带发现一个隐藏风险：除了本脚本设的 mDebugDisableHWC，SF 里还有
#     三个标志会顺带触发同一个 skip 分支（mDaltonize / mHasColorMatrix /
#     mHasSecondaryColorMatrix，见 SurfaceFlinger_hwc1.cpp:1313）。
#     也就是说系统平时是"双保险"。一旦有代码路径把颜色矩阵清掉而
#     mDebugDisableHWC 又恰好是 0，SF 立刻就会崩。
#     所以 mDebugDisableHWC=1 必须是**主保险**，不能只依赖颜色标志。
#
#   开关 ro.ardbeg.sf_hwc_off 仍然保留（默认 1），但把值改成 0 会让
#   厂商合成路径生效，**会黑屏**。留着它只是为了以后万一修好了
#   hwcomposer.tegra.so 的 glcomposer 崩溃时，能一行属性切回去验证。
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
#   Tegra K1 的 GPU 应付 1080p 桌面合成没有问题。
#   注意：**不需要**写什么 "hwcomposer shim 做 layer 字段翻译" ——
#   字段本来就一致（见上面 2026-11-10 复核）。厂商 HWC 在本机不用
#   overlay，是它自己的判定（Composite policy: auto + 各 layer 带
#   HWC_SKIP_LAYER），跟结构体无关。
#   如果以后想让视频走硬件 overlay 来省 GPU，方向是修
#   libnvcap_video.so 缺失的符号（见下），而不是翻译 layer 结构体：
#       E hwcomposer: failed to load libnvcap_video.so: dlopen failed:
#         cannot locate symbol "_ZN7android12MemoryDealerC1EjPKc"
#         referenced by "/system/vendor/lib/libnvomxadaptor.so"
#   7.1 的 libbinder 只导出三参数版
#   _ZN7android12MemoryDealerC1EjPKcj（多一个 uint32_t flags），
#   补一个 mov r3,#0 的跳板即可。
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
# 【2026-11-10 新增】总开关：ro.ardbeg.sf_hwc_off
#
#   1（默认）= 启动后把 mDebugDisableHWC 置 1，禁止厂商 HWC 参与合成。
#              这是 2026-11-05 以来一直验证过的稳定配置，保守保留。
#   0        = 本脚本不干预，SurfaceFlinger 用厂商 HWC 自己判断。
#              2026-11-10 实测可正常运行，且性能上与 1 无差别
#              （厂商 HWC 本机不用 overlay，两种设置下都是全 GLES 合成）。
#
#   为什么用 ro.* 而不是 persist.*：
#     persist.* 属性要等 init 执行 on post-fs-data 里的 load_persist_props
#     才读进属性空间，而本脚本由 zz-sf-hwc-off.rc 的 on post-fs 拉起，
#     那一刻 persist 属性还是空的，读出来必然是 ""，开关会永远失效。
#     ro.* 来自 /system/build.prop，在 on init 阶段就已加载完毕，安全。
#
#   修改方法（二选一）：
#     a) 在 device/nvidia/ardbeg/system.prop 里加一行
#            ro.ardbeg.sf_hwc_off=0
#        然后重打 OTA 包；
#     b) 临时验证（需 remount /system 可写）：
#            mount -o remount,rw /system
#            sed -i 's/^ro.ardbeg.sf_hwc_off=.*/ro.ardbeg.sf_hwc_off=0/' \
#                /system/build.prop
#            reboot
# ---------------------------------------------------------------------------
if [ "$(/system/bin/getprop ro.ardbeg.sf_hwc_off)" = "0" ]; then
    log_msg "ro.ardbeg.sf_hwc_off=0, 不干预 HWC（leave HWC enabled）"
    exit 0
fi

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
