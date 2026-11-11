LOCAL_PATH:= $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE       := fstab.ardbeg
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := fstab.ardbeg
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
# [7.1 移植修正] 模块名/安装名从 init.recovery.rc 改成 init.recovery.ardbeg.rc
#   原因：7.1 的 bootable/recovery/etc/init.rc 第 1 行是
#       import /init.recovery.${ro.hardware}.rc
#   本机 ro.hardware=ardbeg（BoardConfig.mk 的 BOARD_KERNEL_CMDLINE 里带
#   androidboot.hardware=ardbeg），所以只有 /init.recovery.ardbeg.rc
#   才会被 import。cm-11 时装成 /init.recovery.rc，7.1 上不会被加载，
#   等于文件白装（而且那份内容会重复定义 ueventd/recovery/adbd、
#   重复 mount /system /data /cache，真被加载了反而会出问题，
#   详见 init.recovery.rc 头部注释）。
LOCAL_MODULE       := init.recovery.ardbeg.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.recovery.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := init.ardbeg.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.ardbeg.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := init.ray_touch.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.ray_touch.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := init.comms.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.comms.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := init.hdcp.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.hdcp.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := init.tegra.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.tegra.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := init.tegra_emmc.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.tegra_emmc.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := init.tf.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.tf.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := init.nv_dev_board.usb.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.nv_dev_board.usb.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

# ============================================================================
# [7.1 改动] init.usb.rc 不再由设备树安装
#
#   7.1 的 system/core/rootdir/init.usb.rc 已经存在（内容与本文件基本一致，
#   同样写 /sys/class/android_usb/android0/*），两处同时安装到 root/init.usb.rc
#   会让 build 报
#       warning: overriding commands for target '.../root/init.usb.rc'
#   并且谁赢取决于解析顺序（不确定），属于必须消掉的隐患。
#
#   7.1 的版本还多了 configfs 分支（/config/usb_gadget），比 4.4 这份更完整，
#   所以保留 AOSP 的、删掉设备树的。
#
#   注意：不要把这个模块改名成 init.usb.ardbeg.rc 再装上 —— init 只 import
#   /init.usb.rc，改名后文件永远不会被读取，纯属垃圾。
# ============================================================================
# include $(CLEAR_VARS)
# LOCAL_MODULE       := init.usb.rc
# LOCAL_MODULE_TAGS  := optional eng
# LOCAL_MODULE_CLASS := ETC
# LOCAL_SRC_FILES    := init.usb.rc
# LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
# include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := init.ussrd.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.ussrd.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := init.t124.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.t124.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := init.cal.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.cal.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := init.tlk.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := init.tlk.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := power.ardbeg.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := power.ardbeg.rc
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := ueventd.ardbeg.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := ueventd.ardbeg.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

# ============================================================================
# [新增 2026-10-28] ueventd.ardbeg_sata.rc 的模块定义。
#   文件一直在 initfiles/ 里，device.mk 也一直把 ueventd.ardbeg_sata.rc 列进
#   PRODUCT_PACKAGES，但这里从来没给它建过模块 —— 于是 make 报
#   "No rule to make target ... ueventd.ardbeg_sata.rc" 直接中断。
#   这里补齐模块定义，安装位置与 ueventd.ardbeg.rc 一致（root/），
#   因为 ueventd 的 rc 必须和 /ueventd.rc 放在同一层才会被读。
# ============================================================================
include $(CLEAR_VARS)
LOCAL_MODULE       := ueventd.ardbeg_sata.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := ueventd.ardbeg_sata.rc
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)
include $(BUILD_PREBUILT)

# ============================================================================
# [新增 2026-10-28] 开机日志采集脚本 bootlog.sh
#
#   作用：由 init.tegra.rc 里的 bootlog_snapshot / bootlog_snapshot_booted
#         两个 oneshot 服务调用，把内核 dmesg、声卡/mixer 控件、pstore
#         崩溃现场、关键属性全部落到 /cache/bootlog/ 下。
#         设备进不了系统、连不上 adb 的时候，这是唯一能拿到现场的手段。
#
#   安装位置：/system/bin/bootlog.sh
#   LOCAL_MODULE_CLASS 用 EXECUTABLES 而不是 ETC，这样 build 系统会自动
#   给它 0755 权限；如果用 ETC 装到 bin 目录下，文件会是 0644，init 拉起来
#   会直接 "Permission denied"。
# ============================================================================
include $(CLEAR_VARS)
LOCAL_MODULE       := bootlog.sh
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := EXECUTABLES
LOCAL_SRC_FILES    := bootlog.sh
LOCAL_MODULE_PATH  := $(TARGET_OUT)/bin
include $(BUILD_PREBUILT)

# ============================================================================
# [新增 2026-11-05] 三个 /system 侧运行时修复件
#
#   这三个文件解决的问题都发生在**开机完成之后**，而设备树原有的
#   initfiles/*.rc 全部装到 $(TARGET_ROOT_OUT)（= ramdisk），
#   改一次就要重新打包 boot.img、重新线刷 boot 分区，调试代价太高。
#   所以统一改成装到 $(TARGET_OUT)/etc/init 和 $(TARGET_OUT)/bin，
#   随 system 分区一起走，改完只要 push 单个文件就能验证。
#
#   【为什么 /system/etc/init 下的 rc 会被 init 解析】
#   不是 init.rc 里 import 的。真正的入口是 init.ardbeg.rc 第 16 行的
#       mount_all /fstab.ardbeg
#   对应 system/core/init/builtins.cpp 的 do_mount_all()：
#   挂完 fstab 后调用 import_late()，而 import_late() 在**没有给路径参数**
#   时会遍历 /system/etc/init、/vendor/etc/init、/odm/etc/init 三个目录
#   逐个 ParseConfig()。目录走 ParseConfigDir()：readdir + 只取 DT_REG +
#   按文件名排序后依次解析（init_parser.cpp 117-142 行）。
#   => 只要 mount_all 后面不跟路径参数，这里的文件就会被加载。
#      反过来，如果哪天把 mount_all 改成带路径的形式，
#      audioserver / servicemanager / surfaceflinger 会全部消失，切记。
#
#   【为什么用 zz- 前缀】
#   ParseConfigDir() 里 std::sort() 按文件名排序，zz- 前缀保证本设备树新增的
#   文件排在 AOSP 自带的那批（atrace.rc、audioserver.rc ... vold.rc）之后。
#   这在本机有实际意义：zz-persist-log.rc 里的 on post-fs-data 段
#   要在 AOSP 那些服务的定义之后才出现，行为更好预测。
#   （init 本身对 section 顺序不敏感，这一点属于"可读性保险"，不是硬要求。）
# ============================================================================

# ---- 1) 全程持久化日志：/cache/persist_log.txt ----
#   init.tegra.rc 里的 bootlog_logcat 在 sys.boot_completed=1 时会 stop，
#   抓不到开机后的崩溃。本文件的服务永不停止，带 4x4MB 轮转。
#   详见 zz-persist-log.rc 顶部注释。
include $(CLEAR_VARS)
LOCAL_MODULE       := zz-persist-log.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := zz-persist-log.rc
LOCAL_MODULE_PATH  := $(TARGET_OUT)/etc/init
include $(BUILD_PREBUILT)

# ---- 2) 开机动画看门狗 ----
#   SF 崩溃被 init 重启后，新 SF 会把 service.bootanim.exit 置回 0，
#   而 WMS 的 mBootAnimationStopped 是一次性标志，于是动画永久盖住桌面。
#   详见 zz-bootanim-fix.rc 与 bootanim_killer.sh 顶部注释。
include $(CLEAR_VARS)
LOCAL_MODULE       := zz-bootanim-fix.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := zz-bootanim-fix.rc
LOCAL_MODULE_PATH  := $(TARGET_OUT)/etc/init
include $(BUILD_PREBUILT)

# ---- 3) 看门狗脚本本体 ----
#   用 EXECUTABLES 而不是 ETC：build 会自动给 0755，
#   否则装到 bin 下是 0644，虽然 /system/bin/sh 读它不需要 x 位，
#   但保持"bin 下的东西都可执行"这条一致性更省心。
include $(CLEAR_VARS)
LOCAL_MODULE       := bootanim_killer.sh
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := EXECUTABLES
LOCAL_SRC_FILES    := bootanim_killer.sh
LOCAL_MODULE_PATH  := $(TARGET_OUT)/bin
include $(BUILD_PREBUILT)

# ---- 4) SurfaceFlinger 关闭 HWC 合成的 rc ----
#   【2026-11-10 复核更正：下面这段旧注释的「结构体错位」结论是错的】
#   旧说法「4.4.4 的 hwc_layer_1_t 从 offset 16 起比 7.1 错位 4 字节、
#   4.4.4 有 buffer@16」已被 CM11 源码证伪：4.4.4 在 offset 12 直接是
#   handle，根本没有独立 buffer 字段；两版在 0~72 偏移上逐字段一致、
#   sizeof 都是 96，差异只在 76~96 且厂商都不碰。tombstones 里也从未
#   出现过 surfaceflinger 记录，所谓「每 40~100 秒崩一次」是误判。
#   曾经据此往 hwcomposer.h 的 offset 16 插过 buffer 字段，反而造成
#   黑屏 + EGL_BAD_NATIVE_WINDOW，那两个补丁已删除，别再碰。
#
#   【真正原因】厂商 HWC 的 glcomposer 一参与合成就崩野指针：
#       hwc_composite_set+252 -> glc_set+1096
#       -> destroy_graphic_buffer+8
#       -> sp<GraphicBuffer>::operator=+22 -> RefBase::decStrong+37
#       (fault addr 0xc)
#   崩完 SF 重启、所有 BufferQueue 变孤儿 -> 永久黑屏。
#   所以 sf_hwc_off.sh 用 service call SurfaceFlinger 1008 i32 1
#   把 mDebugDisableHWC 置 1、逼 SF 走纯 GLES 合成，是**唯一能正常
#   显示的配置**，不是保守选择。ro.ardbeg.sf_hwc_off 默认 1，置 0 会黑屏。
#   完整崩溃栈与偏移对照见 initfiles/sf_hwc_off.sh 头部注释。
#
#   【为什么用 post-fs 启动而不是 sys.boot_completed】
#   要赶在 SF 出第一帧之前把 HWC 关掉，晚了厂商 glcomposer 已经崩了；
#   boot_completed 要到 45 秒才置位，太晚。
#   详见 zz-sf-hwc-off.rc 与 sf_hwc_off.sh 顶部注释。
include $(CLEAR_VARS)
LOCAL_MODULE       := zz-sf-hwc-off.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := zz-sf-hwc-off.rc
LOCAL_MODULE_PATH  := $(TARGET_OUT)/etc/init
include $(BUILD_PREBUILT)

# ---- 5) 关闭 HWC 合成的看门狗脚本本体 ----
#   常驻轮询 SF 的 pid，一变（说明 SF 重启过）就重新设置 disableHWC，
#   并在 boot_completed 后补发一次 KEYCODE_WAKEUP 让 SF 恢复出帧。
include $(CLEAR_VARS)
LOCAL_MODULE       := sf_hwc_off.sh
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := EXECUTABLES
LOCAL_SRC_FILES    := sf_hwc_off.sh
LOCAL_MODULE_PATH  := $(TARGET_OUT)/bin
include $(BUILD_PREBUILT)

# ---- 5.4b) 帧率匹配：显示刷新率跟随片源帧率 ----
#   解决 25fps 片源在 60Hz 上的 3:2 pulldown 抖动。
#   脚本里做两件事，顺序固定：先 echo 模式到 fb0/mode 改 DC 时序，
#   再 service call SurfaceFlinger 1040 让 SF 的 DispSync 跟上。
#   1040 是本项目新加的 binder 事务码，见 patches/frameworks/native/
#   services/surfaceflinger/SurfaceFlinger_hwc1.cpp.patch。
#
#   默认关闭（persist.ardbeg.fps_match=0），原因见 zz-ardbeg-fps-match.rc。
include $(CLEAR_VARS)
LOCAL_MODULE       := zz-ardbeg-fps-match.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := zz-ardbeg-fps-match.rc
LOCAL_MODULE_PATH  := $(TARGET_OUT)/etc/init
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := ardbeg_fps_match.sh
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := EXECUTABLES
LOCAL_SRC_FILES    := ardbeg_fps_match.sh
LOCAL_MODULE_PATH  := $(TARGET_OUT)/bin
include $(BUILD_PREBUILT)

# ---- 5.4c) 视频播放 GPU 调频（2026-11-11 新增）----
#   修「关掉 HWC 之后 GPU 被 governor 压在最低档、单帧 GLES 合成赶不上
#   vsync」这一层卡顿。与 5.4b 的帧率匹配互补，两项都解决才接近无跳帧：
#     5.4b 修「片源帧率与刷新率不整除」(25fps 在 60Hz 上的 3:2 pulldown)
#     5.4c 修「合成链路本身因 GPU 低频而超时、错过 vsync」
#
#   【为什么需要】ro.ardbeg.sf_hwc_off=1（厂商 hwcomposer.tegra.so 的
#   glcomposer 在 7.1 上 SIGSEGV，见 5.4 节），1920x1080 全屏画面全部由
#   SurfaceFlinger 用 GLES 合成，GPU 成了每帧出图的必经路径。但
#   nvhost_podgov 默认 load_target=700，actmon 把「等 vsync」算成空闲，
#   播放 25fps 片源时 load 平均只有 372/1000，governor 判定「不忙」，
#   GPU 长期停在 72~180MHz（max 852MHz 一次都没上过）；同时
#   gr_idle_timeout_default_us=10000 < 60Hz 帧间隔 16.67ms，每帧之间
#   必进一次 ELPG 电源门控，唤醒后重新升频，单帧合成耗时忽长忽短，
#   经常赶不上 vsync 截止 -> 帧被推迟 -> desiredPresentTime 出现 83.3ms
#   的「跳过一帧」。
#
#   【A/B 实测，同一 25.000fps 本地片 / 同一 60Hz / 同一指标】
#     原厂默认          跳帧(83.3ms) 14.6%  理想帧(40ms) 81.6%
#                       上屏延迟 46.5ms  GPU 均频  75.6MHz  解码 24.21fps
#     应用三项参数后    跳帧(83.3ms)  6.8%  理想帧(40ms) 93.2%
#                       上屏延迟 32.4ms  GPU 均频 102.6MHz  解码 25.10fps
#     两轮解码速率/丢帧增量完全相同 -> 改善来自合成/上屏链路，不是解码能力
#     （media_codecs.xml 里 H.264 只有 ffmpeg/google 软解，但 720p/25fps 够用）。
#   三项写入值都在 debugfs，重启即丢，所以做成开机 init 服务：
#     scaling/load_target            700   -> 300
#     scaling/use_throughput_hint      0   -> 1
#     gr_idle_timeout_default_us   10000   -> 50000
#   哪些节点可写/写不动、参数含义、风险与开关，详见
#   initfiles/ardbeg_gpu_video.sh 头部注释与 zz-ardbeg-gpu-video.rc。
#
#   默认开（persist.ardbeg.gpu_video=1），置 0 恢复原厂三项默认值。
include $(CLEAR_VARS)
LOCAL_MODULE       := zz-ardbeg-gpu-video.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := zz-ardbeg-gpu-video.rc
LOCAL_MODULE_PATH  := $(TARGET_OUT)/etc/init
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := ardbeg_gpu_video.sh
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := EXECUTABLES
LOCAL_SRC_FILES    := ardbeg_gpu_video.sh
LOCAL_MODULE_PATH  := $(TARGET_OUT)/bin
include $(BUILD_PREBUILT)

# ---- 5.5) 首次开机收尾：绕过 SetupWizard + 点亮屏幕 ----
#   四清后 device_provisioned=0，AMS 拉起 SetupWizard，而它 onCreate 里
#   无条件调 disableComponentsForMissingFeatures()，其中
#   setApplicationEnabledSetting("com.google.android.tungsten.setupwraith")
#   因为本机没有 setupwraith 包（TV 版专用，没进 PRODUCT_PACKAGES）
#   直接抛 IllegalArgumentException，一分钟崩十几次，屏幕永远黑。
#
#   同时本机 /sys/class/backlight/ 是空的（内核没注册背光设备），
#   LightsService 设不了亮度 -> DisplayPowerController 不把 display 切 ON ->
#   SurfaceFlinger 不出帧 -> screencap 恒为 10595 字节纯黑。
#   显式 settings put system screen_brightness 255 能把它翻过来。
#
#   脚本幂等，调试时 `setprop ctl.start fb_fix` 可重跑。
#   详见 zz-ardbeg-firstboot-fix.sh 头部注释。
include $(CLEAR_VARS)
LOCAL_MODULE       := zz-ardbeg-firstboot-fix.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := zz-ardbeg-firstboot-fix.rc
LOCAL_MODULE_PATH  := $(TARGET_OUT)/etc/init
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := zz-ardbeg-firstboot-fix.sh
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := EXECUTABLES
LOCAL_SRC_FILES    := zz-ardbeg-firstboot-fix.sh
LOCAL_MODULE_PATH  := $(TARGET_OUT)/bin
include $(BUILD_PREBUILT)

# ---- 5.6) 桌面 / 显示 常驻自愈守护（2026-11-06 四清专项新增）----
#
#   【为什么 5.5 的 oneshot 脚本不够】
#   实机 logcat 证据：
#       F/libc: Fatal signal 6 (SIGABRT) ... tid (RenderThread)   ← Trebuchet
#       E/ActivityManager: ANR in com.android.systemui
#       I/ActivityManager: Process com.cyanogenmod.trebuchet (pid 25846) has died
#   即 4.4.4 的 NVIDIA GL/HWC 驱动与 7.1 的 hwui/RenderThread 不兼容，
#   桌面会在运行中崩。死后 AMS 里残留 Launcher 的 ActivityRecord、
#   SurfaceFlinger 里只剩僵尸 KeyguardScrim 图层（numLayers=0 /
#   powerMode=0 / isSecure=1），系统判定 "HOME 已在前台" 所以不会自恢复，
#   表现就是全黑且永不恢复。
#
#   同时 /sys/class/backlight/ 为空，DisplayPowerController 常卡在等
#   「亮度已设置」的确认；只有 settings 的 onBrightnessChanged 能让
#   display 从 OFF 翻回 ON（实测 input keyevent 224 只能改 mWakefulness）。
#
#   ardbeg_homewd 每 15s 巡检桌面进程与 display 状态：死了重拉、
#   OFF 就用 254/255 交替写亮度重新点亮（90s 冷却，避免频繁启
#   settings 的 app_process VM）。
#
#   【服务名坑】7.1 的 ServiceParser::IsValidName() 限制 <=16 字符，
#   超长只在 dmesg 打一行 "invalid service name"，rc 文件照样显示
#   Parsing ... took 0.01s，logcat 完全看不到。所以用 ardbeg_homewd(13)。
#   详见 zz-ardbeg-home-watchdog.rc / .sh 头部注释。
#
#   调试：`setprop ctl.restart ardbeg_homewd`、`logcat -s ardbeg_homewd`
include $(CLEAR_VARS)
LOCAL_MODULE       := zz-ardbeg-home-watchdog.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := zz-ardbeg-home-watchdog.rc
LOCAL_MODULE_PATH  := $(TARGET_OUT)/etc/init
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := zz-ardbeg-home-watchdog.sh
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := EXECUTABLES
LOCAL_SRC_FILES    := zz-ardbeg-home-watchdog.sh
LOCAL_MODULE_PATH  := $(TARGET_OUT)/bin
include $(BUILD_PREBUILT)

# ============================================================================
# ---- 6) media 服务自愈守护（2026-11-06 全面巡检新增）----
#
#   【要解决的现象】
#   开机一段时间后，**所有视频都放不出来**。Gallery 弹「无法播放此视频。」，
#   日志是：
#       E/MediaPlayerService: Unable to connect to media extractor service
#       E/MediaPlayer       : Unable to create media player
#   但 `service list` 里 media.extractor / media.codec 明明都在（112 / 117），
#   只是描述符是空的 []，且 `service check` 返回 not found。
#   其余 media.* 服务（media.player / media.drm / media.audio_flinger ...）全部正常。
#
#   【根因：7.1 servicemanager 的固有缺陷，不是我们设备树写错】
#   frameworks/native/cmds/servicemanager/service_manager.c:
#
#       si = find_svc(s, len);
#       if (si) {
#           if (si->handle) {
#               ALOGE("... ALREADY REGISTERED, OVERRIDE\n");
#               svcinfo_death(bs, si);      // 立刻打一条 "service 'X' died"
#           }
#           si->handle = handle;            // 换成新 handle
#       }
#       ...
#       binder_link_to_death(bs, handle, &si->death);   // cookie 永远是同一个 &si->death
#
#       static void svcinfo_death(struct binder_state *bs, void *ptr) {
#           struct svcinfo *si = (struct svcinfo *)ptr;
#           ALOGI("service '%s' died\n", str8(si->name));
#           if (si->handle) { binder_release(bs, si->handle); si->handle = 0; }
#       }
#
#   一个 svcinfo 只挂了一个 binder_death，cookie 恒为 &si->death。
#   OVERRIDE 时旧 handle 的死亡订阅没有被撤销；等旧 binder 节点真正死掉
#   （本机实测晚了 2 分钟），svcinfo_death 会被再次回调，把**刚刚装上的
#   新 handle 又清成 0**。于是服务永久失联，而进程本身一直活着。
#
#   实测时序（/cache/persist_log.txt）：
#       23:57:39  add_service('media.extractor',7b) uid=0 - ALREADY REGISTERED, OVERRIDE
#       23:57:39  service 'media.extractor' died
#       23:59:41  service 'media.extractor' died        ← 致命：把新 handle 清了
#       00:00:34  add_service('media.codec',a) uid=0 - ALREADY REGISTERED, OVERRIDE
#       00:00:34  service 'media.codec' died
#       00:02:40  service 'media.codec' died            ← 致命
#
#   【本模块做什么】
#   每 15 秒检查一次这两个服务是否还在；一旦 not found 就 `ctl.restart`。
#   实测：restart 之后 service check 立刻变回 found，
#        Gallery 立即能放 720p H.264 + AAC（NuPlayer + OMX.google.h264.decoder）。
#
#   【为什么放在 /system/etc/init/】
#   init 会解析 /system/etc/init/*.rc（开机日志有
#   "init: (Parsing /system/etc/init/mediacodec.rc took 0.00s.)"），
#   所以不需要重打 boot.img，直接 adb push 也能生效。
#
#   【长期正解】
#   patch servicemanager，给每个 handle 单独的 binder_death 结构体，
#   或在 OVERRIDE 时先 binder_unlink_to_death(&si->death)。
#   放进 device/nvidia/ardbeg/patches/frameworks/native/cmds/servicemanager/ 即可，
#   在没重编 system.img 之前先用本守护兜底。
# ============================================================================
include $(CLEAR_VARS)
LOCAL_MODULE       := zz-ardbeg-media-watchdog.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := zz-ardbeg-media-watchdog.rc
LOCAL_MODULE_PATH  := $(TARGET_OUT)/etc/init
include $(BUILD_PREBUILT)

include $(CLEAR_VARS)
LOCAL_MODULE       := ardbeg_media_watchdog.sh
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := EXECUTABLES
LOCAL_SRC_FILES    := ardbeg_media_watchdog.sh
LOCAL_MODULE_PATH  := $(TARGET_OUT)/bin
include $(BUILD_PREBUILT)

# ============================================================================
# ---- 7) 开机后把 USB 切到「MTP + ADB」（2026-11-06 新增）----
#
# 【为什么需要这个脚本】
#   用户报的现象：「usb 没有盘符」——插上电脑只有 adb，没有 MTP 设备。
#
#   完整根因链是四层，每一层都独立导致失败：
#
#     ① init 层：system/core/rootdir/init.usb.rc 里一条 mtp/ptp 的 property
#        触发都没有（7.1 把它们全搬到 init.usb.configfs.rc 了），而本机内核
#        是 4.4.4 的 NVIDIA gadget，没有 configfs，只能走 android_usb 老接口。
#        -> 已由 patches/system/core/rootdir/init.usb.rc.patch 补齐。
#
#     ② 描述符层：原厂 init.nv_dev_board.usb.rc 写的 "0x0955"/"0x70xx"
#        会被内核 sscanf("%04x") 截成 0009/0070。
#        -> 已把那个文件的 6 个 property 段整段注释。
#
#     ③ framework 层：UsbDeviceManager 构造时会强行把 mtp 从
#        persist.sys.usb.config 里删掉（b/31814300 的临时补丁，
#        UsbDeviceManager.java:358-367），然后 setEnabledFunctions(null)
#        按 persist 的 "adb" 重配 gadget。
#        -> 改 build.prop / default.prop / init.rc 全都无效，只能等它跑完
#           再改回来，所以必须 boot_completed 之后动手。
#
#     ④ binder 层：UsbService.isSupportedCurrentFunction() 的白名单
#        只认**单个**功能名（UsbService.java:306-320），传 "mtp,adb"
#        会被改写成 "none"，再回落到 getDefaultFunctions() = "adb"，
#        结果什么都没发生。而 service call 返回的是正常的 Parcel(0)
#        （void 方法），看起来调用成功了。
#        -> 脚本里必须传 "mtp"，applyAdbFunction() 会自动补回 adb。
#
#   四层都修完之后的实测结果：
#       getprop sys.usb.config          -> mtp,adb
#       cat .../idVendor                -> 18d1
#       cat .../idProduct               -> 4ee2
#       cat .../functions               -> mtp,ffs
#       cat .../state                   -> CONFIGURED
#       dumpsys usb  mCurrentFunctions  -> mtp,adb
#       logcat  MtpService              -> starting MTP server in MTP mode
#                                       -> Adding MTP storage 0x10001
#       主机侧 lsusb                    -> 18d1:4ee2 Google Inc. (MTP + debug)
#       主机侧 gvfs                     -> mtp:host=NVIDIA_Tegra-Android_...
#                                          能列出 /storage/emulated/0 全部文件
#
# 【为什么装在 /sbin 而不是 /system/bin】
#   init.tegra.rc 里的服务定义写的是 /sbin/usb_mtp_default.sh。
#   放 /sbin（ramdisk）的好处是不依赖 /system 挂载，即使 system 分区
#   有问题也能跑；而且脚本本身只用到 toybox 的 service/getprop/sleep，
#   这些在 /system 挂载后一定可用。
#
# 【为什么用 EXECUTABLES 而不是 ETC】
#   build 会自动给 0755，否则装出来是 0644，init 起服务时会报
#   "cannot execute"。
# ============================================================================
include $(CLEAR_VARS)
LOCAL_MODULE       := usb_mtp_default.sh
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := EXECUTABLES
LOCAL_SRC_FILES    := usb_mtp_default.sh
LOCAL_MODULE_PATH  := $(TARGET_ROOT_OUT)/sbin
include $(BUILD_PREBUILT)

# ============================================================================
# ---- 8) U 盘插上后自动「可见化」守护（2026-11-06 新增）----
#
# 【为什么需要这个服务】
#   用户报的现象：「设备插上 U 盘无法识别」。
#   但实测 dmesg 里一切正常：
#       usb 1-1: new high-speed USB device number 3 using tegra-ehci
#       scsi0 : usb-storage 1-1:1.0
#       sd 0:0:0:0: [sda] Attached SCSI removable disk
#       /dev/block/sda1 存在，vfat，LABEL=U，UUID=94B5-BDEB
#   手动 mount -t vfat 能挂能读写 —— 说明内核、USB、文件系统全都没问题。
#
#   问题出在「谁去挂、挂到哪、给谁看」这三步，共四层，每层独立致命：
#
#     ① fstab 层：initfiles/fstab.ardbeg 里写的是
#           /devices/platform/tegra-ehci.2
#        但 U 盘实际插在 tegra-ehci.1（DEVPATH 实测），而且
#        tegra-ehci.2 这个设备在本机上**根本不存在**
#        （只有 tegra-ehci.1 和 tegra-xhci）。
#        -> 已改成 /devices/platform/tegra-ehci*
#
#     ② 匹配层（最阴的一层）：system/vold/VolumeManager.h:108-110 的
#           bool DiskSource::matches(const std::string& sysPath) {
#               return !fnmatch(mSysPattern.c_str(), sysPath.c_str(), 0);
#           }
#        用的是 fnmatch()，是 shell 通配符的**整串完全匹配**，不是
#        strncmp 前缀匹配。不带 '*' 就要求整串完全相等，永远命中不了。
#        而且命中不了时 vold **一条日志都不打**（不是报错，是压根没进
#        handleBlockEvent 的匹配分支），只能靠 dumpsys mount 里
#        "Disks:" 永远是空的来判断。
#        -> 和 ① 一起改成了带 '*' 的通配符形式。
#
#     ③ vold 层：改完 ①② 之后 dumpsys mount 里出现 DiskInfo 了，
#        但 volume 卡在 CHECKING，logcat 是
#            E vold: Failed to setexeccon
#            --------- beginning of crash
#        tombstone 里 signal 6 (SIGABRT)，栈顶是 vold 自己的 abort()。
#        根因在 system/vold/Utils.cpp 的 ForkExecvp()：
#            if (setexeccon(context)) { LOG(ERROR) << "Failed to setexeccon"; abort(); }
#            ... android_fork_execvp(...) ...
#            if (setexeccon(nullptr)) { LOG(ERROR) << "Failed to setexeccon"; abort(); }
#        本机 SELinux 是 Disabled（getenforce -> Disabled），
#        setexeccon() 必然失败，于是 vold 每次调 blkid / sgdisk /
#        fsck_msdos 都自杀一次，init 再拉起，无限循环。
#        附带问题：/sepolicy（policyvers=28）和 file_contexts.bin 不是
#        同一次构建产物，dmesg 里有
#            SELinux: Context u:object_r:system_lib_file:s0 is not valid
#        缺了一批 type，所以即便把 SELinux 打开也会立刻出问题。
#        当前权宜解：LD_PRELOAD 一个空的 setexeccon 垫片。
#        长期正解：patches/system/vold/Utils.cpp.patch 把 abort() 去掉。
#
#     ④ framework 层（本小节要解决的）：③ 修完之后
#            VolumeInfo{public:8_1}: type=PUBLIC state=MOUNTED fsType=vfat
#                                    path=/mnt/media_rw/94B5-BDEB
#        vold 确实挂上了，但挂在 /mnt/media_rw/<UUID>（0700 root:root），
#        普通应用进不去，/storage/ 下空空如也，界面里完全看不到 U 盘。
#        根因在 frameworks/base/services/core/java/com/android/server/
#        MountService.java 的 onVolumeCreated()，对 TYPE_PUBLIC 只有
#        两种情况才给 MOUNT_FLAG_VISIBLE：
#            a) mPrimaryStorageUuid == "primary_physical" 且 isDefaultPrimary()
#            b) disk.isAdoptable()（fstab 里带 encryptable=userdata）
#        本机 "Primary storage UUID: null"，U 盘也不是 adoptable，
#        两个条件都不成立 -> mountFlags=0 -> framework 发
#            {6 volume mount public:8_1 0 0}
#        vold 的 PublicVolume::doMount() 拿到 flags=0 就：
#            if (!(getMountFlags() & MountFlags::kVisible)) {
#                // Not visible to apps, so no need to spin up FUSE
#                return OK;
#            }
#        直接 return，不 fork /system/bin/sdcard，不建 /storage/<UUID>。
#
#   本小节的服务就是绕过 ④：轮询 /proc/mounts，发现
#   /mnt/media_rw/<UUID> 挂上了但 /storage/<UUID> 不存在时，用
#       vdc volume unmount public:8_1
#       vdc volume mount   public:8_1 2 0
#   重新挂一次，第二个参数 2 = MountFlags::kVisible
#   （system/vold/VolumeManager.h:62，kVisible = 1 << 1）。
#   vold 收到带 VISIBLE 的请求才会 fork sdcard，建出：
#       /dev/fuse on /storage/<UUID>
#       /dev/fuse on /mnt/runtime/{default,read,write}/<UUID>
#
# 【为什么装 /system/bin 而不是 /sbin】
#   本服务和 usb_mtp_default.sh 不同：它要调用 vdc，而 vdc 在
#   /system/bin/vdc（system 分区）。虽然脚本内部已经轮询等
#   init.svc.vold == running（vold 也依赖 /system），但放 /system/bin
#   语义上更一致，且 class late_start 时 /system 早已挂载。
#
# 【为什么 rc 装 /system/etc/init】
#   7.1 的 init 在 LoadBootScripts() 里会自动扫描
#   /system/etc/init/、/vendor/etc/init/、/odm/etc/init/ 三个目录下
#   所有 *.rc，不需要在 init.rc 里显式 import。
#   设备上实测 ls /system/etc/init/ 已经有 zz-persist-log.rc 等同类
#   文件在跑，路径确认可用。
#
# 【为什么用 LOCAL_MODULE_CLASS := ETC + LOCAL_MODULE_PATH】
#   rc 文件是普通文本，用 ETC 类会自动给 0644（init 要求 rc 是 0644，
#   可写反而会警告）；而 .sh 必须用 EXECUTABLES 才会拿到 0755，
#   否则 init 起服务时报 "cannot execute"。
#
# 【坑：7.1 的 init 服务名最长 16 个字符，超了会静默丢弃】
#   rc 里的服务名是 usb_storage_mnt（15 字符），不是 usb_storage_mount。
#   最初写的是 usb_storage_mount（17 字符），现象是：
#       dmesg: init: (Parsing /system/etc/init/zz-usb-storage-mount.rc took 0.01s.)
#       getprop init.svc.usb_storage_mount  -> 空
#       setprop ctl.start usb_storage_mount -> init: no such service '...'
#   没有任何 ERROR 日志。根因在 system/core/init/service.cpp:856-868
#   的 ServiceParser::IsValidName()：
#       if (name.size() > 16) return false;
#   ParseSection 拿到 false 就 return，service_ 仍为空，
#   EndSection 的 if (service_) 不成立，服务压根没进 ServiceManager。
#   文件名（zz-usb-storage-mount.rc）不受此限，只有 service 名受限。
# ============================================================================

# ---- 8.1) U 盘可见化守护脚本本体 ----
include $(CLEAR_VARS)
LOCAL_MODULE       := usb_storage_mount.sh
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := EXECUTABLES
LOCAL_SRC_FILES    := usb_storage_mount.sh
LOCAL_MODULE_PATH  := $(TARGET_OUT)/bin
include $(BUILD_PREBUILT)

# ---- 8.2) U 盘可见化守护的 rc（服务定义）----
include $(CLEAR_VARS)
LOCAL_MODULE       := zz-usb-storage-mount.rc
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := ETC
LOCAL_SRC_FILES    := zz-usb-storage-mount.rc
LOCAL_MODULE_PATH  := $(TARGET_OUT)/etc/init
include $(BUILD_PREBUILT)

# ============================================================================
# 9) SELinux 旁路垫片 libselinux_bypass.so
#
# 【它解决什么】
#   本机沿用原厂 4.4.4 的 /sepolicy（dmesg 实测 307 types / 84 classes），
#   而 7.1 用户空间需要一批那个年代不存在的 type 和 class。结果：
#
#     zygote fork system_server  -> security_check_context("u:r:system_server:s0")
#                                   失败 -> "selinux_android_setcontext failed"
#                                   -> system_server SIGABRT，无限重启
#     servicemanager 注册服务    -> selinux_check_access(..., "service_manager", ...)
#                                   失败（class 不存在）-> PERMISSION DENIED
#                                   -> AMS 抛 SecurityException，FATAL
#     installd 建应用目录        -> selinux_android_restorecon_pkgdir() 在
#                                   libselinux 里 SIGSEGV（file_contexts 格式不配套）
#                                   -> /data/user_de/0/<pkg> 建不出来
#                                   -> SettingsProvider 打不开 settings.db
#                                   -> InputMethodManagerService 构造失败，FATAL
#     init 启动 audioserver      -> security_compute_create() 失败（没有 audioserver 域）
#                                   -> 服务不启动 -> AudioPolicyService 永不注册
#                                   -> boot_completed 卡死
#
#   垫片把这些 libselinux 函数统一覆盖成「直接返回成功」，让 7.1 用户空间
#   能在老策略上跑起来。完整推导见 prebuilt/lib/libselinux_bypass.c 头部。
#
# 【为什么不能关掉 SELinux 更省事】
#   内核配置是
#       # CONFIG_SECURITY_SELINUX_BOOTPARAM is not set   -> selinux=0 无效
#       # CONFIG_SECURITY_SELINUX_DISABLE is not set     -> 运行时也关不掉
#   试过 cmdline 加 lsm=capability，这个 4.4 内核的 security_module_enable()
#   不认，策略照旧加载。所以只能从用户空间旁路。
#
# 【为什么不能换成 7.1 的 sepolicy】
#   7.1 的策略是 policydb version 30，本机内核只支持 15-28：
#       SELinux: policydb version 30 does not match my version range 15-28
#       init: failed to load policy: Invalid argument
#       init: Security failure; rebooting into recovery mode...
#   一加载就重启进 recovery。
#
# 【长期正解】
#   换自编内核（支持 policydb 30）+ 7.1 完整 sepolicy 后，这个 .so 和所有
#   setenv LD_PRELOAD 都可以整体删掉。
#
# 【安装位置】
#   /system/lib/ —— 7.1 的 32 位 linker 搜索路径之一。所有需要它的进程
#   （servicemanager / zygote / installd / vold）都在自己的 rc 里显式
#   setenv LD_PRELOAD 指向它，不做全局预加载。
# ============================================================================
include $(CLEAR_VARS)
LOCAL_MODULE       := libselinux_bypass.so
LOCAL_MODULE_TAGS  := optional eng
LOCAL_MODULE_CLASS := SHARED_LIBRARIES
LOCAL_SRC_FILES    := ../prebuilt/lib/libselinux_bypass.so
LOCAL_MODULE_PATH  := $(TARGET_OUT)/lib
include $(BUILD_PREBUILT)

# ============================================================================
# [CM14.1-on-ardbeg 说明 2026-11-07] initfiles/mediacodec.rc 为什么不注册
#
# 本目录里放着一份 mediacodec.rc，但**故意不在 Android.mk 里注册成模块**，
# 它只是 AOSP 侧 patch 应用后产物的镜像副本，用途有二：
#   1) 六层字节一致性矩阵（tools/verify_six_layers.py）的 L3「设备树真源」；
#   2) adb 调试 / 文件级重打包时可以直接取用的现成字节。
#
# 【为什么不能再注册一次】
#   Android 7.1 的 frameworks/av/services/mediacodec/mediacodec.rc 由 AOSP
#   构建系统自己安装到 /system/etc/init/mediacodec.rc。如果这里再用
#   BUILD_PREBUILT / PRODUCT_COPY_FILES 往同一个目标塞一份，build/core 会
#   以「该输出路径已有模块产出」为由静默 ignored —— 和 libEGL.so 那次
#   「补丁全绿、ROM 里还是原版」是同一类坑，而且没有任何报错。
#
# 【三处真源必须逐字节一致】
#   AOSP : frameworks/av/services/mediacodec/mediacodec.rc
#          由 patches/frameworks/av/services/mediacodec/mediacodec.rc.patch
#          应用后得到（全量编译路径的唯一来源）
#   设备树: device/nvidia/ardbeg/initfiles/mediacodec.rc（本文件同目录）
#   重打包: repack/overlay/system/etc/init/mediacodec.rc（apply_overlay.py 的
#          FILES 写入，文件级重打包路径）
#   期望 md5 e5dfd2d55c04eb72cbb89ff2327ce4f1 / 4290 字节。
#
# 【这份 rc 修的两件事】
#   seclabel u:r:mediaserver:s0
#       4.4.4 /sepolicy 没有 7.1 的 mediacodec 域，init 在
#       service.cpp 的 security_compute_create() 失败会直接 return false，
#       连 fork 都到不了，媒体编解码服务一次都起不来。
#   group camera drmrpc mediadrm audio media
#       补 media(1013)。原厂 ueventd 把 /dev/tegra_avpchannel 设成
#       media:media 0660，而 7.1 的 mediacodec 是 uid 1046 / gid 1006，
#       不带 media 组时 NvAvpOpen() 失败，H.264 播放报
#       "NvxNvMMTransformOpen failed" / ACodec ERROR(0x80001000)。
#       注意 AVP handle 在首次失败后被 NvMM 缓存在进程内，事后 chmod 666
#       节点对已启动进程无效，必须改 rc 后冷启动。
#
# 详见 tools/verify_hwdec.sh 头部与 patches/README.md 硬件解码章节。
# ============================================================================
