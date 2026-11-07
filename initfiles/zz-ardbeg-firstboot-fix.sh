#!/system/bin/sh
# =============================================================================
# [CM14.1-on-ardbeg 新增 2026-11-06] 首次开机收尾：绕过 SetupWizard + 点亮屏幕
#
# 这个脚本解决「TWRP 四清刷完包之后屏幕一直黑、看不到桌面」。
#
# 为什么四清之后才会出现：dirty flash 时 /data 里已经有上次开机的产物
# （device_provisioned=1、SetupWizard 走完过、屏幕被用户唤醒过），
# 所以看不出问题；四清把 /data 清空之后，下面几件事全部要重来，
# 每一件在 7.1-on-4.4.4 这套环境里都会卡住。
#
# -----------------------------------------------------------------------------
# 【问题 1：SetupWizard 无限崩溃】
#
# 四清后 device_provisioned=0，AMS 会把 com.cyanogenmod.setupwizard 拉起来。
# 但它 onCreate 里无条件调 disableComponentsForMissingFeatures()，其中：
#
#     SetupWizardUtils.disableApplication(this,
#             "com.google.android.tungsten.setupwraith", ...);
#
# 而本机 /system/priv-app/ 里只有 LineageSetupWizard，**没有 setupwraith**
# （那是 TV 版专用的 Google SetupWraith，编译时没进 PRODUCT_PACKAGES）。
# 于是：
#
#     java.lang.IllegalArgumentException: Unknown package:
#         com.google.android.tungsten.setupwraith
#       at SetupWizardUtils.disableApplication(SetupWizardUtils.java:294)
#       at SetupWizardUtils.disableComponentsForMissingFeatures(...:264)
#       at SetupWizardApp.onCreate(SetupWizardApp.java:104)
#
# 实测崩 40 次以上，每次崩溃 AMS 都重启它，屏幕永远是黑的。
#
# 修法：pm disable 掉它 + 直接标记 device_provisioned=1。
# 这样 AMS 认为设备已配置，转而启动 HOME（本机是 Trebuchet）。
#
# 注：本机**没有** LeanbackLauncher（TV 专用桌面），PRODUCT_PACKAGES 里
# 只有 Trebuchet（com.cyanogenmod.trebuchet，手机版 launcher3）。
# 它没有遥控器方向键导航，但用鼠标/触屏能操作，至少能看到桌面。
#
# -----------------------------------------------------------------------------
# 【问题 2：display 卡在 OFF，画面全黑】
#
# 症状（2026-11-06 实测）：
#     dumpsys power   ->  mWakefulness=Awake         ← 唤醒是成功的
#     dumpsys display ->  DisplayDeviceInfo state OFF ← 但 display 没切 ON
#     dumpsys SurfaceFlinger -> 只有 KeyguardScrim 一个 layer，
#                               numLayers=0 / layerStack=4294967295
#
# 根因：/sys/class/backlight/ 是**空的** —— 本机内核（原厂 4.4.4 预编译）
# 没有注册 pwm-backlight 之类的背光设备。LightsService.setBrightness()
# 实际什么都不做，DisplayPowerController 拿不到「亮度已设置」的确认，
# 就一直不把 display 切到 ON。
#
# 关键实测：input keyevent 224 (WAKEUP) 只能把 mWakefulness 改成 Awake，
# **不能**让 display 变 ON；但执行
#     settings put system screen_brightness 255
# 之后 dumpsys display 立刻从 state OFF 变成 state ON。
# 说明只有 SettingsProvider 的 onBrightnessChanged 能触发 DPC 重新评估，
# 绕过那个卡住的等待。这是本机点亮屏幕的唯一可靠开关。
#
# 【重大认知修正】screencap 不能用来判断屏幕是否点亮：
#     SurfaceFlinger 里 DisplayDevice 带 isSecure=1（FLAG_SECURE），
#     7.1 在 secure display 上 screencap 会直接挂住或返回纯黑 PNG。
# 之前「10595 字节纯黑 = 黑屏」的判断是被 FLAG_SECURE 误导。
# 正确判据是 dumpsys display 的 DisplayDeviceInfo state。
#
# 另外两个配套设置：
#   screen_off_timeout = 2147483647  默认是 60000 (1 分钟)，睡醒后 display
#                                     又回 OFF，所以必须设成永不休眠
#   secure lockscreen.disabled = 1   本机是 TV 形态，不该有锁屏
#
# -----------------------------------------------------------------------------
# 【问题 3：KeyguardScrim 残留 + Launcher/SystemUI 进程死亡】
#
# 实测 pidof com.cyanogenmod.trebuchet 和 pidof com.android.systemui 一度
# 都为空，但 dumpsys window 里 mFocusedApp 仍指向
#     com.cyanogenmod.trebuchet/com.android.launcher3.Launcher
# —— 那是进程死亡后的残留 ActivityRecord，SF 里只剩僵尸 KeyguardScrim
# 图层（numLayers=0 / powerMode=0），看起来就是全黑。
#
# logcat 里的直接证据：
#     F/libc: Fatal signal 6 (SIGABRT) ... tid (RenderThread)  ← Trebuchet
#     E/ActivityManager: ANR in com.android.systemui
#     I/ActivityManager: Process com.android.systemui (pid 1429) has died
#     I/ActivityManager: Process com.cyanogenmod.trebuchet (pid 25846) has died
#     W/ActivityManager: lowmemorykiller daemon socket open failed  (刷屏)
#
# 所以一次性拉起桌面是不够的：Trebuchet 的 RenderThread 会在运行中崩。
# 本脚本负责「首次点亮」，另由 zz-ardbeg-home-watchdog.sh 常驻兜底，
# 每 15 秒检查桌面进程与 display 状态，死了就重拉、OFF 就重新点亮。
#
# 注：lmkd 在本机根本没起来（init.svc.lmkd 空、/dev/socket/lmkd 不存在，
# 手动执行 /system/bin/lmkd 也会立刻退出）。旧内核有内核态
# lowmemorykiller 驱动（/sys/module/lowmemorykiller/parameters/minfree
# = 1536,2048,4096,16384），AMS 会降级成直接写 oom_score_adj，
# 所以功能没丢，只是每次 trimApplications() 刷一条 warning。
# 不要试图手工拉起 lmkd：它的 rc 带 critical，反复崩溃会触发 reboot。
#
# -----------------------------------------------------------------------------
# 【★ settings 命令的两个坑，改这个脚本前必须知道 ★】
#
# 1) /system/bin/settings 不是原生命令，它其实是：
#        exec app_process /system/bin com.android.commands.settings.SettingsCmd "$@"
#    也就是启一个完整 ART VM。**它写完值之后不会退出**（实测
#    settings get 打印出结果后进程仍挂着，timeout 12/18 全是 rc=124）。
#    所以每一条都必须用 timeout 包住，包括 get。
#
# 2) 更坑的是：app_process 启动 + 连 SettingsProvider + 写盘要十几秒。
#    实测 timeout 10 的 settings put system screen_off_timeout 2147483647
#    **没有生效**，读回来还是 60000；而脚本原来的 timeout 20 能生效。
#    所以这里统一用 timeout 30（留足余量），并且**不能为了"加速"缩短**。
#
# 为了不把首启拖到 6 x 30 = 180 秒，把互不依赖的 put 分组并行执行后
# wait。SettingsProvider 内部有 mLock 串行化，并发写是安全的。
#
# -----------------------------------------------------------------------------
# 【★ 判据陷阱：不能用 grep "state OFF" ★】
#
# dumpsys display 里同时有三行：
#     DisplayDeviceInfo{ ... state ON ...}      ← 真实状态
#     mBaseDisplayInfo{ ... state ON ...}
#     mOverrideDisplayInfo{ ... state OFF ...} ← 这个永远可能是 OFF
# 只 grep "state OFF" 会永远命中，导致脚本误判「屏幕没亮」。
# 必须只取第一行 DisplayDeviceInfo 判断。
#
# -----------------------------------------------------------------------------
# 【怎么恢复 SetupWizard】
#
#     adb shell pm enable com.cyanogenmod.setupwizard
#     adb shell settings put global device_provisioned 0
#     adb shell settings put secure user_setup_complete 0
#
# 但要注意它还是会崩（缺 setupwraith），所以除非补上那个包，否则别恢复。
#
# -----------------------------------------------------------------------------
# 【问题 4（2026-11-06 深夜新增）：用户仍反馈黑屏，挖到底的第三层根因】
#
# 前面三个问题都修完之后，display 已经是 ON、进程也都在，但用户看到的
# 仍是黑屏。这次用 dumpsys window / dumpsys SurfaceFlinger / tombstone
# 把整条链路彻底挖到底，确认黑屏是三层叠加，缺一不可：
#
# (1) persist.sys.ui.hw=1 —— 我们自己设备树 lineage_tv.mk 写进去的。
#     frameworks/base/core/java/android/view/Window.java:755
#         mHardwareAccelerated = hardwareAccelerated
#                 || SystemProperties.getBoolean(PROPERTY_HARDWARE_UI, false);
#     它让**每个** app 窗口强制走 HWUI / RenderThread。本机是原厂 4.4.4
#     的 NVIDIA Tegra EGL 驱动（/system/vendor/lib/libEGL_tegra_impl.so），
#     display 状态放在线程局部存储里，7.1 的 RenderThread 在另一个线程
#     调 eglGetDisplay，于是 eglChooseConfig 返回 EGL_BAD_DISPLAY。
#     实测 tombstone_02：
#         pid 9669 tid 10722 name RenderThread >>> com.cyanogenmod.trebuchet
#         Abort message: 'Failed to choose config, error = EGL_BAD_DISPLAY'
#         #06 libhwui.so ... #13 RenderThread::threadLoop
#     SystemUI / Trebuchet / Settings / Email 全都这样反复 SIGABRT。
#
# (2) KeyguardService 反复断开 -> KeyguardScrim 永不撤。
#     SystemUI 一死，PhoneWindowManager.removeWindowLw()(3409-3435 行) 在
#     状态栏窗口被移除时调 mKeyguardDelegate.showScrim()；
#     KeyguardServiceDelegate.onScreenTurningOn()(290-303 行) 在
#     mKeyguardService == null 时也 showScrim() 并打
#         "onScreenTurningOn(): no keyguard service!"
#     而 hideScrim() 只有两个入口：
#         KeyguardShowDelegate.onDrawn()   (100 行，要 keyguard 绘制完成)
#         bindService() 返回 false 的分支 (149 行)
#     keyguard 画不出来 -> onDrawn 永不回调 -> scrim 常驻，WMS 把 Launcher
#     窗口判成 mViewVisibility=0x4 / mObscured=true，logcat 刷
#         "Screen frozen for +4s911ms due to Window{... KeyguardScrim}"
#
# (3) 窗口淡入动画卡住 -> SurfaceFlinger layer alpha 恒为 0x00。
#     实测 dumpsys SurfaceFlinger 里 ImageWallpaper 和
#     "Starting com.cyanogenmod.trebuchet" 两个 layer 的 alpha 都是 0x00，
#     即使窗口已 VISIBLE，合成出来仍是全黑。把三个 animation scale 设成 0
#     之后 alpha 立刻变 0xff，Launcher 窗口
#         mViewVisibility 0x4 -> 0x0,  mHaveFrame false -> true。
#
# 【实测有效的三把钥匙（本脚本 + build.prop 一起固化）】
#   a) persist.sys.ui.hw=0  —— 写进 lineage_tv.mk / build.prop 开机即生效；
#                              本脚本再 setprop 一次，兜住 dirty flash 时
#                              /data/property 里残留的旧值 1。
#   b) 不禁用 KeyguardService —— a) 生效后 SystemUI 不再崩，onDrawn() 能
#                              正常回调，scrim 自己变 GONE。实测
#                              deviceHasKeyguard=false /
#                              KeyguardScrim mViewVisibility=0x8。
#                              曾试过 pm disable keyguard service，
#                              没有必要，反而可能让 bindService 行为不确定。
#   c) 三个 animation scale=0 —— 让窗口 layer 立刻进入 alpha=0xff。
#
# 【判据：不能用 screencap】
#   DisplayDeviceInfo 带 FLAG_SECURE（isSecure=1），secure display 上
#   screencap 固定返回 10595 字节纯黑 PNG。判断画面要用
#   dumpsys window windows 的 mViewVisibility 与 dumpsys SurfaceFlinger 的
#   layer alpha；display ON 只代表背光/电源状态，不代表桌面可见。
#
# 【补丁集成缺口（本轮核查发现，必须记住）】
#   patches/frameworks/native/opengl/libs/EGL/egl_display.cpp.patch
#   已经应用到源码（egl_display.cpp:157 是 `if (cnx->dso)`），但 out/ 被
#   清空后编译产物没有重新生成，repack/tools/apply_overlay.py 的 FILES 里
#   也没有 libEGL.so，所以设备上 /system/lib/libEGL.so 仍是旧版
#   md5 3cd50337aeb9aa2220b5007f786cf8bc，补丁**实际没进包**。
#   本轮用 a) 绕开；将来恢复全量编译后必须把补丁版 libEGL.so 注册进 FILES
#   （apply_overlay.py 里已预留条目与说明），才谈得上把 ui.hw 改回 1。
#
# -----------------------------------------------------------------------------
# 【问题 5（2026-11-06 深夜新增）：浏览器「闪退」与 WiFi/蓝牙开机不自启】
#
# (1) 浏览器「闪退」其实不是崩溃。抓 logcat-jelly.txt 实测：
#         I WebViewFactory: Loading com.android.webview 52.0.2743.100
#         I cr_BrowserStartup: Initializing chromium process, singleProcess=true
#         I ActivityManager: Displayed org.lineageos.jelly/.MainActivity: +1s365ms
#     没有 FATAL EXCEPTION / tombstone / ANR，Jelly 冷启动是成功的。
#     真正原因是 zz-ardbeg-home-watchdog.sh 的 launcher_visible() 恒 false：
#     旧实现用 `dumpsys window windows | grep -A1 ...Launcher` 取
#     mViewVisibility，但原始 dumpsys 里 Window # 的紧邻下一行是
#     mDisplayId/mSession/mClient，可见性在十几行之后。于是守护每 90 秒
#     执行一次 am start HOME，把用户从浏览器/设置里踢回桌面，主观就是
#     「应用一闪就退」。修法见两个脚本里修正后的 launcher_visible() 与
#     常驻守护新增的 foreground_is_home() 守卫。本脚本第 8 步同样换了
#     紧凑列表判据，避免首启时白跑三轮抢前台。
#
# (1b)【2026-11-07 补记：首启脚本自己也会抢前台，不止常驻守护】
#     上面那次只修了「判据恒 false」，没有修「什么时候允许干预」。
#     本脚本是 class late_start + oneshot，每次开机跑一遍，但一遍并不短：
#     第 1 步等 PackageManager、第 4/4b/5 步每条 settings put 都是
#     app_process 起 ART VM 要十几秒、第 9 步还要等 WiFi/BT 自启，
#     整条链路实测延续到开机后 1~2 分钟。这段时间里用户（或自动化验收）
#     完全可能已经打开视频播放器 / 浏览器 / 设置。此时 Launcher 窗口
#     mViewVisibility=0x8 (GONE) 是**正常状态**，launcher_visible()
#     必然返回 false，第 8 步就会误判成「黑屏」并 am start HOME，
#     把用户从应用里踢回桌面 —— 主观表现和浏览器闪退一模一样。
#
#     真机证据（四清后干净刷入 hwdec 包，跑 tools/verify_hwdec.sh）：
#       16:54:08.868 ActivityManager: START ... gallery3d/.app.MovieActivity
#       16:54:09.748 OMXMaster: makeComponentInstance(OMX.Nvidia.h264.decode)
#       16:54:09.772 NvMMLiteOpen : BlockType = 261   ← 硬解本来已经正常
#       16:54:09.885 fb_fix: launcher window not visible (round 0)...
#       16:54:11.621 ActivityManager: START ... trebuchet/...Launcher
#       16:54:11.639 NuPlayerDriver: reset(...)       ← 播放被硬生生打断
#       16:54:11.649 NvMMDecTVMRDestroyParser: NvAvpClose
#     结果 H.264 在 20 秒窗口内没跑出 EOS detected，硬解专项 23 PASS/1 FAIL；
#     同一轮 H.265 因为 fb_fix 只跑一次没被踢，EOS detected=2。
#     这反证是首启脚本的一次性误伤，不是 NVIDIA OMX 解码器故障。
#     修法：第 8 步补 foreground_is_home()，与常驻守护同一套语义。
#
# (2) WiFi / 蓝牙 开机自启需要「两条路径」，只做一条都不够：
#     全量编译路径
#         overlay/packages/providers/SettingsProvider/res/values/defaults.xml
#         的 def_wifi_on / def_bluetooth_on。DatabaseHelper.java:2622/2628
#         在 settings 数据库首次创建时写入 Settings.Global。
#     文件级重打包路径（当前交付走的就是这条）
#         上面那个 XML 要编进 SettingsProvider.apk 的 resources.arsc 才生效，
#         而重打包链路只替换文件、不重编 APK，改 XML 对现包完全没有效果。
#         所以本脚本第 9 节做运行时兜底。
#     蓝牙尤其不能只靠 `settings put global bluetooth_on 1`：
#         BluetoothManagerService 构造函数只在 system_server 启动时读一次
#         isBluetoothPersistedStateOn()，它的 ContentObserver 只监听
#         BLE_SCAN_ALWAYS_AVAILABLE，不监听 BLUETOOTH_ON。事后写值只影响
#         **下一次**开机，当前这次不会亮。
#         实测有效的组合（2026-11-06，同一台设备）：
#             settings put global bluetooth_on 1          （先持久化）
#             service call bluetooth_manager 6 s16 com.android.settings
#                                                        （再显式 enable）
#         事务号 6 来自 IBluetoothManager.aidl 的第 6 个方法 enable(String)，
#         实测 OFF -> ON 成功；脚本以 root 运行，
#         ActivityManager.checkComponentPermission 对 uid 0 一律放行。
#         Android 7.1 的 svc 只有 power/data/wifi/usb/nfc，**没有 bluetooth**。
#     WiFi 简单得多：svc wifi enable 会自己把 wifi_on 写回 1
#         （实测 disable -> 0，enable -> 1），不必手工 settings put。
#
# (3) 「开机自动打开」不等于「自动连上」。四清后 /data/misc/wifi 是空的，
#     WiFi 开着也停在 DISCONNECTED。第 9 节在 wpa_supplicant.conf 里
#     没有任何 network 块时，把
#         /system/etc/wifi/ardbeg_default_network.conf
#     的 network={...} 段追加进去，删掉空的 networkHistory.txt，
#     再开 WiFi。实测 20 秒内 mNetworkInfo 变成 CONNECTED/CONNECTED。
#     用户后来自己配过网络时脚本完全不介入，绝不覆盖用户数据。
#
# 详见 patches/README.md 第十五章。
# =============================================================================

LOG_TAG=fb_fix
HOME_ACT='com.cyanogenmod.trebuchet/com.android.launcher3.Launcher'
# 【2026-11-06 修正】必须写绝对路径 /system/bin/log。
#   原来写成 `log() { log -t ...; }` 是**函数自递归**：shell 里函数优先级
#   高于外部命令，函数体内的 log 又调回自己，永远不会执行 /system/bin/log。
#   实测 `logcat -d -s fb_fix` 一条都没有，却把每次调用的递归回退栈打成
#   一串 stdout 噪声，白丢掉整条首启链路的日志，排障时非常误事。
#   常驻守护那边用的是 /system/bin/log 绝对路径，所以没这个问题。
log() { /system/bin/log -t "$LOG_TAG" "$*" 2>/dev/null; echo "[$LOG_TAG] $*"; }

# 只取第一行 DisplayDeviceInfo 判断真实 display 状态，见头部「判据陷阱」
display_is_on() {
    dumpsys display 2>/dev/null \
        | grep 'DisplayDeviceInfo{' | head -1 | grep -q 'state ON'
}

# 触发 DisplayPowerController 重新评估：亮度必须真的变一次才会发
# onBrightnessChanged，写同一个值不算变化，所以 254 <-> 255 交替。
BRIGHT_TMP=/data/local/tmp/.fb_fix_bright
brightness_toggle() {
    cur=$(cat "$BRIGHT_TMP" 2>/dev/null)
    if [ "$cur" = "254" ]; then nxt=255; else nxt=254; fi
    timeout 30 settings put system screen_brightness "$nxt" >/dev/null 2>&1
    echo "$nxt" > "$BRIGHT_TMP"
}

log "firstboot fix start"

# ---------------------------------------------------------------------------
# 0) 关掉 app 级硬件加速（黑屏根因 (1)，见头部「问题 4」）
#    build.prop 里已经是 0，这里再写一次，专门兜住 dirty flash 时
#    /data/property/persist.sys.ui.hw 里残留的旧值 1。
#    persist 属性写入后，对之后新启动的进程立即生效。
# ---------------------------------------------------------------------------
setprop persist.sys.ui.hw 0
log "persist.sys.ui.hw=0 (HWUI/RenderThread off)"

# ---------------------------------------------------------------------------
# 1) 等 PackageManager 就绪
#    pm 命令要连 system_server，开机早期会直接失败，所以轮询。
# ---------------------------------------------------------------------------
i=0
while [ $i -lt 240 ]; do
    if pm path android >/dev/null 2>&1; then
        log "package manager ready after ${i}s"
        break
    fi
    sleep 1
    i=$((i+1))
done

# ---------------------------------------------------------------------------
# 2) 禁用 SetupWizard（它缺 setupwraith，必然无限崩）
#    这一步很快，先做掉，让 HOME 解析立刻落到 Trebuchet 上。
# ---------------------------------------------------------------------------
pm disable com.cyanogenmod.setupwizard >/dev/null 2>&1
am force-stop com.cyanogenmod.setupwizard >/dev/null 2>&1
log "setupwizard disabled"

# ---------------------------------------------------------------------------
# 3) 立刻唤醒 + 显式拉起桌面
#    - 用 -n 显式指定组件：隐式 HOME intent 在 SetupWizard 刚被 disable
#      的那几秒里有可能解析到残留的 ActivityRecord，实测显式组件更稳。
#    - 这一步不依赖 settings，秒级完成，让用户尽早看到东西。
# ---------------------------------------------------------------------------
input keyevent 224 >/dev/null 2>&1            # KEYCODE_WAKEUP
sleep 1
wm dismiss-keyguard >/dev/null 2>&1
am start -n "$HOME_ACT" >/dev/null 2>&1
log "wakeup + home started"

# ---------------------------------------------------------------------------
# 4) 配置类设置（并行写，减少首启等待）
#    注意每条都必须 timeout 30，原因见头部「两个坑」。
# ---------------------------------------------------------------------------
timeout 30 settings put global device_provisioned 1 >/dev/null 2>&1 &
timeout 30 settings put secure user_setup_complete 1 >/dev/null 2>&1 &
timeout 30 settings put secure lockscreen.disabled 1 >/dev/null 2>&1 &
wait
log "provisioned / lockscreen flags set"

# ---------------------------------------------------------------------------
# 4b) 关掉全部窗口/过渡/动画时长缩放（黑屏根因 (3)，见头部「问题 4」）
#     不关的话 SurfaceFlinger 里窗口淡入 layer 的 alpha 会卡在 0x00：
#     窗口即使 mViewVisibility=0x0、mHaveFrame=true，合成出来依然全黑。
#     这三条是 Settings.Global，存在 settings.db 里，重启不丢；
#     四清之后本脚本会重新写一遍。
#     同样必须 timeout 30（settings 是 app_process，见头部「两个坑」）。
# ---------------------------------------------------------------------------
timeout 30 settings put global window_animation_scale 0 >/dev/null 2>&1 &
timeout 30 settings put global transition_animation_scale 0 >/dev/null 2>&1 &
timeout 30 settings put global animator_duration_scale 0 >/dev/null 2>&1 &
wait
log "animation scales = 0 (window layer alpha fix)"

# ---------------------------------------------------------------------------
# 5) 屏幕类设置（并行写）
#    screen_off_timeout 必须 >= timeout 才能生效，不要改成小值。
#    stay_on_while_plugged_in=7 (AC+USB+无线) 等价 svc power stayon true，
#    本机 adb 常连着 USB，插电保活可防止 display 回落。
# ---------------------------------------------------------------------------
timeout 30 settings put system screen_off_timeout 2147483647 >/dev/null 2>&1 &
timeout 30 settings put global stay_on_while_plugged_in 7 >/dev/null 2>&1 &
wait
timeout 30 settings put system screen_brightness 255 >/dev/null 2>&1 &
wait
echo 255 > "$BRIGHT_TMP"
log "screen settings applied (timeout=MAX, stayon=7, brightness=255)"

# ---------------------------------------------------------------------------
# 6) 多轮确认 display 真的 ON
#    实测首次开机偶尔要 2~3 轮 DPC 重算才切过来，每轮用 254/255 交替
#    保证 brightness 真的发生变化（写相同值不会触发 onBrightnessChanged）。
#    每轮之间唤醒一次，避免设备又睡回去。
# ---------------------------------------------------------------------------
r=0
while [ $r -lt 4 ]; do
    if display_is_on; then
        log "display is ON after ${r} extra round(s)"
        break
    fi
    log "display still OFF (round $r), toggle brightness + wakeup"
    input keyevent 224 >/dev/null 2>&1
    brightness_toggle
    sleep 2
    r=$((r+1))
done

# ---------------------------------------------------------------------------
# 7) 收尾：再确认桌面进程活着（RenderThread 可能已经崩了）
#    常驻的 zz-ardbeg-home-watchdog.sh 会持续兜底，这里只做首轮补拉。
# ---------------------------------------------------------------------------
sleep 2
if [ -z "$(pidof com.cyanogenmod.trebuchet 2>/dev/null)" ]; then
    log "launcher not running, restart it"
    am start -n "$HOME_ACT" >/dev/null 2>&1
fi
# ---------------------------------------------------------------------------
# 8) 关键：确认桌面**窗口**真的可见，而不只是 display ON / 进程活着
#
#    旧版脚本只查 display_is_on + pidof，实测会出现：
#        display state ON、Launcher 进程在、mFocusedApp 指向 Launcher，
#        但窗口 mViewVisibility=0x4 / mHaveFrame=false / mHasSurface=false，
#        SF layer alpha=0x00 —— 用户看到的仍是一整块黑屏。
#    所以这里直接查 WMS 里 Launcher 窗口的 mViewVisibility。
#    grep -A1 取 "Window #N ... Launcher}:" 后面紧跟的那一行。
#
# 【2026-11-06 修正判据】上面这句「紧跟的那一行」是错的，原始 dumpsys 里
#   Window # 行的下一行是 mDisplayId=... mSession=...，mViewVisibility
#   在十几行之后。旧判据恒为 false，首启时会白跑 3 轮
#   dismiss-keyguard / am start HOME / brightness_toggle，
#   常驻守护更严重（每 90 秒把用户从任何 app 踢回桌面，表现为
#   「浏览器闪退」）。正确做法是先 grep -E 压成「标题 + 可见性」
#   两行一组的紧凑列表，再 grep -B1 反查哪个可见窗口是 Launcher；
#   toybox grep 的 -A/-B 遇 -m1 会丢上下文行，这里一律不带 -m。
#
# 【2026-11-07 推翻下面这条旧假设】
#   旧注释写的是「首启阶段第 7 步已经 am start HOME，前台本就应该是桌面，
#   所以不需要像常驻守护那样再加 foreground_is_home() 守卫」。这是错的：
#   本脚本跑完一遍要 1~2 分钟（见头部「问题 5」(1b)），用户完全可能在这
#   段时间里打开视频 / 浏览器。那时 Launcher 窗口 GONE 是正常状态，
#   launcher_visible() 必然 false，脚本就会误判黑屏并 am start HOME 抢前台。
#   实测把 H.264 播放打断在 1.9 秒处，硬解专项因此假红一项 EOS detected。
#
#   所以这里补上与常驻守护一致的 foreground_is_home()：
#     只有「mResumedActivity 仍是 Launcher」且「Launcher 窗口不可见」
#     才是真正的 KeyguardScrim 遮挡 / 黑屏，才允许干预；
#     前台是别的应用时一次都不许 am start HOME。
#   注意 grep -m1 在这里没有 -A/-B 上下文参数，不受 toybox 那条坑影响。
# ---------------------------------------------------------------------------
launcher_visible() {
    dumpsys window windows 2>/dev/null \
        | grep -E 'Window #|mViewVisibility=' \
        | grep -B1 'mViewVisibility=0x0' \
        | grep -q 'com.cyanogenmod.trebuchet/com.android.launcher3.Launcher'
}

# 前台 Activity 是不是 HOME。四清首启时若用户/测试已经打开别的应用，
# 这里返回 false，第 8 步必须立刻收手，不能把人踢回桌面。
foreground_is_home() {
    dumpsys activity activities 2>/dev/null \
        | grep -m1 'mResumedActivity' \
        | grep -q 'com.cyanogenmod.trebuchet'
}

q=0
while [ $q -lt 3 ]; do
    if launcher_visible; then
        log "launcher window VISIBLE after ${q} extra round(s)"
        break
    fi
    # 【守卫】用户正在用别的应用时，Launcher 窗口 GONE 完全正常。
    # 绝不能在这里 am start HOME，否则就是 2026-11-07 抓到的
    # 「视频/浏览器被踢回桌面」。
    if ! foreground_is_home; then
        log "non-HOME app in foreground, skip HOME restart (normal, not black screen)"
        break
    fi
    log "HOME in foreground but window hidden (round $q), dismiss keyguard + restart HOME"
    wm dismiss-keyguard >/dev/null 2>&1
    am start -n "$HOME_ACT" >/dev/null 2>&1
    input keyevent 224 >/dev/null 2>&1
    brightness_toggle
    sleep 3
    q=$((q+1))
done

if display_is_on; then
    if launcher_visible; then
        log "firstboot fix done: display ON + launcher window VISIBLE"
    elif ! foreground_is_home; then
        log "firstboot fix done: display ON, non-HOME app in foreground (expected)"
    else
        log "firstboot fix done: display ON but launcher window still hidden, watchdog will retry"
    fi
else
    log "firstboot fix done: display STILL OFF, watchdog will keep retrying"
fi

# ---------------------------------------------------------------------------
# 9) [2026-11-06 新增] WiFi / 蓝牙 开机自启 + WiFi 自动连接
#
#    完整推导见头部「问题 5」。这里只写三条必须记住的实现约束：
#      a) 本 rc 是 class late_start + oneshot，**每次开机都会跑一遍**，
#         不是「只在第一次开机跑」。所以下面所有写操作都必须幂等，
#         并且绝对不能在用户已经配过网络时覆盖 /data/misc/wifi。
#      b) 文件级重打包不会重编 SettingsProvider.apk，defaults.xml 里的
#         def_wifi_on / def_bluetooth_on 对当前这个包是无效的，
#         当前这次开机只能靠这里的运行时调用拉起来。
#      c) settings 是 app_process 启的 ART VM，写值要十几秒且写完不退出，
#         一律 timeout 30；判状态不要再用 settings get（又要 15 秒），
#         改用 dumpsys，零额外进程。
# ---------------------------------------------------------------------------
WIFI_DIR=/data/misc/wifi
WPA_CONF="$WIFI_DIR/wpa_supplicant.conf"
NET_HISTORY="$WIFI_DIR/networkHistory.txt"
NET_TEMPLATE=/system/etc/wifi/ardbeg_default_network.conf
BT_CALLER_PKG=com.android.settings

# 只取第一行 Wi-Fi is enabled/disabled。
# 不能用 grep -q 'enabled' 全表扫：dumpsys wifi 里还有一堆
# "xxx enabled: true" 的行，会误判。
wifi_is_enabled() {
    dumpsys wifi 2>/dev/null \
        | grep -m1 'Wi-Fi is ' | grep -q 'Wi-Fi is enabled'
}

# dumpsys bluetooth_manager 的 Bluetooth Status 段第一行是 enabled:，
# 第二行才是 state:。这里只判 state: ON/OFF，避免和 enabled: 混淆。
bt_is_on() {
    dumpsys bluetooth_manager 2>/dev/null | grep -q '  state: ON'
}

# ---- 9.1 预置默认 WiFi 网络（四清后自动连）------------------------------
# 只在「一个 network 块都没有」时才注入。判据用 ^network= 而不是
# network={ ：toybox grep 的 BRE 里 '{' 需要转义才表示区间，写成
# '^network=' 既避开这个坑又同样准确。
# 模板里 network= 必须顶格，sed 才能抽到；注释全在它之前。
if [ -f "$NET_TEMPLATE" ]; then
    if [ ! -f "$WPA_CONF" ] || ! grep -q '^network=' "$WPA_CONF"; then
        log "no saved wifi network -> inject default from $NET_TEMPLATE"
        # 先关 WiFi：supplicant 正在跑的时候改 conf 会被它自己的
        # update_config=1 回写覆盖，实测必须先 disable 再写。
        svc wifi disable >/dev/null 2>&1
        sleep 2
        if [ ! -f "$WPA_CONF" ]; then
            # 底图里连 conf 都没有（四清后的极端情况），用 ROM 自带的
            # 静态头部打底；它含 ctrl_interface / update_config 等必需项。
            cp /system/etc/wifi/wpa_supplicant.conf "$WPA_CONF" 2>/dev/null
        fi
        sed -n '/^network=/,$p' "$NET_TEMPLATE" >> "$WPA_CONF" 2>/dev/null
        # 空历史必须删：WifiConfigManager 会拿 networkHistory.txt 里的
        # 空内存态把刚写进去的网络覆盖掉。实测删掉后 20 秒内自动连上。
        rm -f "$NET_HISTORY"
        chown wifi:wifi "$WPA_CONF" 2>/dev/null
        chmod 0660 "$WPA_CONF" 2>/dev/null
        log "default wifi network injected (owner wifi:wifi, mode 0660)"
    else
        log "wifi network already configured -> leave /data/misc/wifi untouched"
    fi
else
    log "no $NET_TEMPLATE -> skip wifi network preset"
fi

# ---- 9.2 WiFi 开机开启 ----------------------------------------------------
# svc wifi enable 自己就会把 Settings.Global.WIFI_ON 写回 1
# （实测 svc wifi disable -> 0，svc wifi enable -> 1），
# 不需要再手工 settings put global wifi_on 1。
# 开机早期 WifiService 可能还没注册，svc 会失败，所以带重试。
i=0
while [ $i -lt 15 ] && ! wifi_is_enabled; do
    svc wifi enable >/dev/null 2>&1
    sleep 2
    i=$((i+1))
done
if wifi_is_enabled; then
    log "wifi enabled after ${i} retry(s)"
else
    log "WARN: wifi still disabled after ${i} retry(s)"
fi

# ---- 9.3 蓝牙开机开启 -----------------------------------------------------
# 顺序不能反：先写持久化状态，再显式 enable。
#   BluetoothManagerService 的构造函数只在 system_server 启动时读一次
#   Settings.Global.BLUETOOTH_ON，之后没有任何 ContentObserver 监听它；
#   所以只 settings put 的话，当前这次开机蓝牙还是 OFF，要等下次重启。
#   enable() 走 Binder 事务 6（IBluetoothManager.aidl 第 6 个方法
#   enable(String packageName)）；7.1 的 svc 没有 bluetooth 子命令，
#   这是唯一不弹权限对话框的命令行途径。脚本由 init 以 root 启动，
#   ActivityManager.checkComponentPermission 对 uid 0 放行
#   BLUETOOTH_ADMIN，实测 OFF -> ON 成功。
timeout 30 settings put global bluetooth_on 1 >/dev/null 2>&1 &
wait
if bt_is_on; then
    log "bluetooth already ON (persisted state=1)"
else
    service call bluetooth_manager 6 s16 "$BT_CALLER_PKG" >/dev/null 2>&1
    # enable() 是异步的：MESSAGE_ENABLE 交给 handler，绑定蓝牙进程要几秒。
    j=0
    while [ $j -lt 10 ] && ! bt_is_on; do
        sleep 2
        j=$((j+1))
    done
    if bt_is_on; then
        log "bluetooth enabled via binder tx6 after ${j} x 2s"
    else
        log "WARN: bluetooth still OFF (persisted bluetooth_on=1 for next boot)"
    fi
fi

# ---- 9.4 记录自动连接结果（只判，不强拉）--------------------------------
# 关联由 wpa_supplicant / WifiConfigManager 自己完成，这里不调用
# enableNetwork()，避免和框架的选网逻辑抢状态机。
sleep 3
if dumpsys wifi 2>/dev/null | grep -m1 'mNetworkInfo' | grep -q 'CONNECTED/CONNECTED'; then
    log "wifi auto-connected (mNetworkInfo CONNECTED/CONNECTED)"
else
    log "wifi enabled but not associated yet; supplicant will keep scanning"
fi
log "connectivity fix done"
