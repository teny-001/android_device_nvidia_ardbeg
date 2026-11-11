#
# device.mk — ardbeg (Tegra K1 T124 / TN8 P1761 / g100) 产品配置
#
# 目标平台：LineageOS 14.1 (Android 7.1.2)
#
# 【本文件相对 cm-11 版本的改动原则】
#   cm-11 的 device.mk 里有一批模块在 7.1 里**根本不存在**，直接照搬会在
#   "No rule to make target" 上卡死。这里按类别处理：
#     A. 7.1 仍然存在、且本设备需要的 -> 保留（可能改模块名）
#     B. 7.1 里改名/换实现的          -> 换成 7.1 的名字
#     C. 厂商私有、7.1 无对应实现的    -> 删除，并在下面注明
#   每一处改动都写了原因，方便对照 cm-11 版本回溯。
#

LOCAL_PATH := device/nvidia/ardbeg

# ============================================================================
# 一、屏幕与密度
# ============================================================================
# 本机无内置屏，HDMI 输出。AAPT 按 1080p 电视/显示器配置。
PRODUCT_AAPT_CONFIG += xlarge large
PRODUCT_AAPT_PREF_CONFIG := xhdpi
TARGET_SCREEN_HEIGHT := 1920
TARGET_SCREEN_WIDTH := 1200

# ============================================================================
# 二、SoC 标识（shield-common / 部分 HAL 会读）
# ============================================================================
TARGET_TEGRA_VERSION := t124

# ============================================================================
# 三、音频
# ============================================================================
# 音频架构（本板实情，见 音频故障诊断报告.md）：
#    card0 = HDA NVIDIA Tegra（HDMI，pcm3 播放）
#    card1 = tegradummy（占位，媒体默认路由到这里，实际不出声）
#   蓝牙 A2DP 走 audio.a2dp.default
#
# 【为什么用 tinyhal 而不是 NVIDIA 的 audio.primary.tegra.so】
#   后者是 4.4 时代的闭源 HAL，依赖 libnvaudioservice/libaudioavp 等一整套
#   NVIDIA 私有库，在 4.4 上就已经加载失败（AudioFlinger 从未映射该 so）。
#   7.1 的 AudioFlinger 与其 ABI 更不兼容，继续用它等于必然没有声音。
#   tinyhal 是开源的 ALSA HAL，用 audio.ardbeg.xml 描述路由，可控可调。
#
# 【模块命名】audio.primary.$(TARGET_DEVICE) = audio.primary.ardbeg.so
#   故意不用 audio.primary.tegra：vendor blob 里也有一个同名文件
#   （audio.primary.tegra.so），两者会争抢同一个安装路径导致
#   "Two files installed to the same path" 编译错误。
#   7.1 的 HAL 加载器按 ro.hardware（=ardbeg）找 audio.primary.ardbeg.so，
#   所以换名字不影响加载。
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/audio/asound.conf:system/etc/asound.conf \
    $(LOCAL_PATH)/audio/audio_policy.conf:system/etc/audio_policy.conf \
    $(LOCAL_PATH)/audio/audio.ardbeg.xml:system/etc/audio.ardbeg.xml \
    $(LOCAL_PATH)/audio/nvaudio_conf.xml:system/etc/nvaudio_conf.xml \
    $(LOCAL_PATH)/audio/nvaudio_fx.xml:system/etc/nvaudio_fx.xml

# 【不拷 audio_effects.conf】
#   AOSP 7.1 自带 frameworks/av/media/libeffects/data/audio_effects.conf，
#   并且会装到 /system/etc/audio_effects.conf。设备树里那份 4.4 的版本
#   指向 NVIDIA 私有效果库（libbundlewrapper/libdownmix 等，7.1 名字已变），
#   拷过去也会被 AOSP 的版本覆盖（实测 "PRODUCT_COPY_FILES ... ignored"），
#   索性不拷，避免"以为改的是生效的那份"。

PRODUCT_PACKAGES += \
    audio.a2dp.default \
    audio.usb.default \
    audio.r_submix.default \
    audio.primary.ardbeg \
    libaudiohalcm \
    libaudio-resampler \
    libtinycompress

# 【关于 tinyalsa 工具】
#   7.1 的 external/tinyalsa 会编出 tinymix / tinyplay / tinycap / libtinyalsa，
#   但它们依赖 KERNEL_OBJ/usr/include（内核 uapi 头）。本工程用**预编译内核**，
#   树内没有 KERNEL_OBJ，ninja 会报
#       'obj/KERNEL_OBJ/usr' needed by tinyplay.o, missing and no known rule
#   所以不用 AOSP 那套，改用设备树自带的 tinyalsa（libtinyalsa_ardbeg +
#   tinymix_ardbeg / tinyplay_ardbeg / tinycap_ardbeg）——它编译时不依赖
#   KERNEL_OBJ，而且带 NVIDIA 需要的 mixer 扩展。
PRODUCT_PACKAGES += \
    libtinyalsa_ardbeg \
    tinymix_ardbeg \
    tinyplay_ardbeg \
    tinycap_ardbeg

# 【删除】xaplay / record / recordvideo
#   NVIDIA 私有的 ALSA 调试工具，7.1 源码树里没有，也不需要。
# 【删除】libaudiospdif
#   5.0 才引入的 IEC61937 直通库，4.4 没有；7.1 有，但本板 HDMI 直通
#   由 AudioFlinger 处理，不需要显式打包（框架会自动按需编译）。
# 【删除】libstagefrighthw（设备树本地版本）
#   设备树里的 NVOMXPlugin.cpp 是 4.4 的 libstagefrighthw 接口
#   （createOMXPlugin 签名不同），7.1 编译不过。
#   改用 hardware/nvidia/libstagefrighthw（官方 14.1 版本）+ vendor 的
#   libnvomx.so，见下面 PRODUCT_PACKAGES。

# ============================================================================
# 四、蓝牙
# ============================================================================
# 蓝牙芯片 BCM4350C0，UART /dev/ttyTHS2，BlueDroid + libbt-vendor。
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/bluetooth/bt_vendor.conf:system/etc/bluetooth/bt_vendor.conf

PRODUCT_PACKAGES += \
    libbt-vendor

# ============================================================================
# 五、摄像头（无 sensor，仅保留配置以兼容相机 HAL 加载路径）
# ============================================================================
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/camera/model_frontal.xml:system/etc/model_frontal.xml \
    $(LOCAL_PATH)/camera/nvcamera.conf:system/etc/nvcamera.conf

# ============================================================================
# 六、充电器 / 电量
# ============================================================================
PRODUCT_PACKAGES += \
    charger \
    charger_res_images

# 【删除】libhealthd.tegra
#   设备树里的 healthd_board_tegra.cpp 用的是 4.4 的 healthd_board_init()
#   签名，7.1 改成了 int healthd_board_init(struct healthd_config *config)，
#   编译不过。7.1 自带的默认 healthd 已经能读 /sys/class/power_supply，
#   本板电量计走 max77663 驱动，默认实现可用。

# ============================================================================
# 七、Calibration（NVIDIA 触摸校准）
# ============================================================================
# 【删除】CalibNotifier + calib_cfg.xml
#   4.4 时代 NVIDIA 的触摸校准服务，7.1 无对应实现，本机也没有内置触摸屏。

# ============================================================================
# 八、Dalvik / ART 堆
# ============================================================================
$(call inherit-product, frameworks/native/build/phone-xhdpi-2048-dalvik-heap.mk)

# ============================================================================
# 九、GPS
# ============================================================================
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/comms/gpsconfig.xml:system/etc/gps/gpsconfig.xml \
    $(LOCAL_PATH)/comms/gps.conf:system/etc/gps.conf

# ============================================================================
# 十、灯光 HAL
# ============================================================================
# lights.c 用的是 4.4/7.1 通用的 lights.h 接口（set_light 一个函数），
# 7.1 可以直接编译，模块名 lights.tegra 与 HAL 加载器一致。
PRODUCT_PACKAGES += \
    lights.tegra

# ============================================================================
# 十一、媒体编解码
# ============================================================================
# 7.1 要求同时提供 google 的软解配置，否则部分容器/编码没有 decoder。
PRODUCT_COPY_FILES += \
    frameworks/av/media/libstagefright/data/media_codecs_google_audio.xml:system/etc/media_codecs_google_audio.xml \
    frameworks/av/media/libstagefright/data/media_codecs_google_video.xml:system/etc/media_codecs_google_video.xml \
    $(LOCAL_PATH)/media/media_codecs.xml:system/etc/media_codecs.xml \
    $(LOCAL_PATH)/media/media_profiles.xml:system/etc/media_profiles.xml

# ---- 【2026-11-07 修订】libstagefrighthw：NVIDIA 硬件编解码的桥 ----
#   【纠正历史误判】
#     旧注释（以及 vendor/nvidia/ardbeg/blobs-blacklist.txt 第 42 行）写着
#     「4.4 导出的 createOMXPlugin() 是无参，7.1 要 createOMXPlugin(bool
#     secure)，所以排除 4.4 blob、改用 hardware/nvidia/libstagefrighthw」。
#     这条判断是错的，直接导致 ROM 里**完全没有** libstagefrighthw.so。
#
#     本树 frameworks/av/media/libstagefright/omx/OMXMaster.cpp 的
#     addVendorPlugin() 实际用的是：
#         typedef OMXPluginBase *(*CreateOMXPluginFunc)();   // 无参
#         ... dlsym("createOMXPlugin") 或 fallback
#             dlsym("_ZN7android15createOMXPluginEv")       // 正是无参符号
#     hardware/nvidia/libstagefrighthw/omxplugin.cpp（官方 cm-14.1 桥）
#     里同样是无参 createOMXPlugin()。
#     原厂 4.4 blob 导出的就是 _ZN7android15createOMXPluginEv，
#     用 ELF32 .dynsym 解析 + 实机播放已验证匹配。
#
#   【为什么最终包里曾经没有它】
#     上一版这里写的是 PRODUCT_PACKAGES += libstagefrighthw（源码模块），
#     但本项目所有交付 ROM 都走「解 system.img -> 只换改动文件 ->
#     重打包签名」的**文件级重打包**链路，根本不跑编译；而
#     repack/tools/apply_overlay.py 的 FILES 表里也没注册它。
#     结果：补丁/源码都改了，ROM 里一个字节都没变 —— 又是典型的
#     「补丁应用了」≠「补丁进 ROM 了」。
#
#   【缺了它的后果（实测）】
#     OMXMaster::addVendorPlugin() 就是 dlopen("libstagefrighthw.so")，
#     文件不存在 → 厂商插件加载失败 → mPluginByComponentName 里没有任何
#     OMX.Nvidia.* 条目 → 所有解码退回软解 OMX.google.*。
#     现场判据：/proc/<media.codec pid>/maps 里只有 libstagefright_omx.so，
#     没有 libnvomx.so；dumpsys media.player 里 numFramesDropped 高。
#
#   【本次硬解专项的三条独立根因，缺一不可】
#     1) 本条：补 system/lib/libstagefrighthw.so（OMX 插件桥）
#     2) media/media_codecs.xml：4.4 的同名组件重复声明会让 7.1
#        MediaCodecList.cpp:737 返回 -EINVAL 并清空 mCodecInfos，
#        必须改写成 <Type> 子元素形式
#     3) patches/frameworks/av/services/mediacodec/mediacodec.rc.patch：
#        mediacodec 服务的 group 补 media，否则打不开
#        media:media 0660 的 /dev/tegra_avpchannel，NvAvpOpen() 失败，
#        播放时报 NvxNvMMTransformOpen failed / ERROR(0x80001000)
#
#   【真源与路径】
#     真源：  $(LOCAL_PATH)/prebuilt/lib/libstagefrighthw.so
#     原始：  vendor/nvidia/ardbeg/proprietary/vendor/lib/libstagefrighthw.so
#     期望：  md5 7221cb3656b33b54846e34b5e406163c / 5420 字节
#     目标：  system/lib/libstagefrighthw.so（不是 4.4 的 vendor/lib，
#             OMXMaster 在 /system/lib 与 /vendor/lib 都找，实测前者可用）
#     文件级重打包侧另需注册到 repack/tools/apply_overlay.py 的 FILES。
#
#   【为什么删掉 PRODUCT_PACKAGES += libstagefrighthw】
#     hardware/nvidia/libstagefrighthw 源码模块也会产出
#     system/lib/libstagefrighthw.so，与这里的 PRODUCT_COPY_FILES 撞同一
#     路径，build 会报 "Two files installed to the same path"。
#     两条路径只能留一条，本交付统一走预编译 blob（可字节校验）。
#
#   注意：这个 .so 只提供「桥」，真正的编解码实现仍是 vendor 的
#   libnvomx.so / libnvmmlite_video.so（已在 ardbeg-vendor-blobs.mk 里
#   装到 /vendor/lib，链接 /vendor -> /system/vendor 由 init 建立）。
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/prebuilt/lib/libstagefrighthw.so:system/lib/libstagefrighthw.so

# ============================================================================
# 十二、预编译内核模块（WiFi / 蓝牙）
# ============================================================================
# 内核是预编译的 3.10.24，模块必须与内核 vermagic 严格一致，
# 所以只能用原厂模块，不能用树内内核编出来的。
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/prebuilt/modules/mbt8897.ko:system/lib/modules/mbt8897.ko \
    $(LOCAL_PATH)/prebuilt/modules/sd8897.ko:system/lib/modules/sd8897.ko \
    $(LOCAL_PATH)/prebuilt/modules/sd8897mlan.ko:system/lib/modules/sd8897mlan.ko \
    $(LOCAL_PATH)/prebuilt/modules/modules.alias:system/lib/modules/modules.alias \
    $(LOCAL_PATH)/prebuilt/modules/modules.dep:system/lib/modules/modules.dep \
    $(LOCAL_PATH)/prebuilt/modules/modules.softdep:system/lib/modules/modules.softdep

# ============================================================================
# 十三、NVIDIA 特性声明
# ============================================================================
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/permissions/com.google.widevine.software.drm.xml:system/etc/permissions/com.google.widevine.software.drm.xml \
    $(LOCAL_PATH)/permissions/com.nvidia.feature.xml:system/etc/permissions/com.nvidia.feature.xml \
    $(LOCAL_PATH)/permissions/com.nvidia.feature.opengl4.xml:system/etc/permissions/com.nvidia.feature.opengl4.xml \
    $(LOCAL_PATH)/permissions/com.nvidia.shieldtech.xml:system/etc/permissions/com.nvidia.shieldtech.xml \
    $(LOCAL_PATH)/permissions/com.nvidia.nvsi.xml:system/etc/permissions/com.nvidia.nvsi.xml \
    $(LOCAL_PATH)/permissions/com.nvidia.miracast.xml:system/etc/permissions/com.nvidia.miracast.xml \
    $(LOCAL_PATH)/permissions/com.nvidia.graphics.xml:system/etc/permissions/com.nvidia.graphics.xml

# 【删除】permissions/platform.xml
#   cm-11 时代用整份 platform.xml 覆盖框架默认权限表。7.1 的
#   frameworks/base/data/etc/platform.xml 多了很多新权限（如
#   READ_PHONE_STATE 的 split、FOREGROUND_SERVICE 等），
#   用 4.4 的版本覆盖会导致大量系统应用启动即崩（SecurityException）。
#   需要额外授权请在 overlay 或 sepolicy 里做，不要整体覆盖。

# ============================================================================
# 十四、Overlay
# ============================================================================
DEVICE_PACKAGE_OVERLAYS += \
    device/nvidia/ardbeg/overlay

# ============================================================================
# 十五、Ramdisk / init 脚本
# ============================================================================
# 模块定义在 initfiles/Android.mk，这里只负责把它们装进 ramdisk。
# 【7.1 注意】init 在 7.1 里对 rc 语法更严格：
#   - service 必须有 class，否则会被丢弃并打印 "ignoring service ... no class"
#   - 同名的 service / on 段落重复定义会被忽略（不是报错，静默丢弃）
#   - 挂载同一个挂载点两次会 EBUSY，第二次失败并打印错误
#   所以 init.ardbeg.rc / init.tegra.rc 里重复的部分必须清理干净，
#   详见 initfiles/README-init-audit.md。
PRODUCT_PACKAGES += \
    fstab.ardbeg \
    init.recovery.ardbeg.rc \
    init.ardbeg.rc \
    init.comms.rc \
    init.ray_touch.rc \
    init.hdcp.rc \
    init.tegra.rc \
    init.tegra_emmc.rc \
    init.nv_dev_board.usb.rc \
    init.ussrd.rc \
    init.t124.rc \
    init.tlk.rc \
    init.cal.rc \
    power.ardbeg.rc \
    ueventd.ardbeg.rc \
    bootlog.sh \
    zz-persist-log.rc \
    zz-bootanim-fix.rc \
    bootanim_killer.sh \
    zz-sf-hwc-off.rc \
    sf_hwc_off.sh \
    ardbeg_fps_match.sh \
    zz-ardbeg-fps-match.rc \
    ardbeg_gpu_video.sh \
    zz-ardbeg-gpu-video.rc \
    zz-ardbeg-media-watchdog.rc \
    ardbeg_media_watchdog.sh

# ============================================================================
# 【新增 2026-11-11】视频播放 GPU 调频 —— 上面 PRODUCT_PACKAGES 里新增的
#   ardbeg_gpu_video.sh / zz-ardbeg-gpu-video.rc
#
#   为什么必须进 PRODUCT_PACKAGES：initfiles/Android.mk 里的 BUILD_PREBUILT
#   只是「声明有这个模块」，不被 PRODUCT_PACKAGES 引用就不会被安装进
#   /system。本项目在「四清专项」里踩过这个坑：只有定义没引用，历次
#   重打包出来的 zip 和设备上都找不到文件（见下面 5.5 节注释）。
#
#   落点：
#     ardbeg_gpu_video.sh      -> /system/bin/
#     zz-ardbeg-gpu-video.rc   -> /system/etc/init/  (oneshot)
#
#   作用：开机把 GPU devfreq 三项 debugfs 参数从原厂默认改成
#     load_target 700->300 / use_throughput_hint 0->1 /
#     gr_idle_timeout 10ms->50ms，让「关掉 HWC 后由 SF GLES 合成」
#   时 GPU 不再被压在最低档、不再每帧进 ELPG 电源门控。
#   A/B 实测（25.000fps 本地片 / 60Hz）：跳帧 14.6%->6.8%、
#   理想帧 81.6%->93.2%、上屏延迟 46.5ms->32.4ms、GPU 均频
#   75.6->102.6MHz；解码侧两轮不变 -> 瓶颈在合成/上屏而非解码能力。
#   详见 initfiles/Android.mk 5.4c 节、ardbeg_gpu_video.sh 头部、
#   zz-ardbeg-gpu-video.rc，以及 system.prop 的 GPU 开关注释。
#
#   开关 persist.ardbeg.gpu_video 默认 1，置 0 恢复原厂三项默认值。
# ============================================================================
# ============================================================================
# 【新增 2026-11-06 四清专项】首次开机收尾 + 桌面/显示常驻守护
# ============================================================================
# 模块定义在 initfiles/Android.mk 第 5.5 / 5.6 节。
#
# ★ 这四个之前只有 Android.mk 里的定义，没有进 PRODUCT_PACKAGES ★
#   Android.mk 只是「声明有这个模块」，不引用就不会被安装到 system。
#   同时 repack/tools/apply_overlay.py 的 FILES 清单里也漏了它们。
#   两处一起漏，导致历次重打包出来的 zip 和设备上都找不到这些文件，
#   四清后 SetupWizard 崩溃 + 黑屏一直没有真正被修掉。
#   这次把构建侧（此处）和重打包侧（apply_overlay.py）一并补齐。
#
# 落点：
#   zz-ardbeg-firstboot-fix.rc  -> /system/etc/init/   （oneshot，class late_start）
#   zz-ardbeg-firstboot-fix.sh  -> /system/bin/
#   zz-ardbeg-home-watchdog.rc  -> /system/etc/init/   （常驻，服务名 ardbeg_homewd）
#   zz-ardbeg-home-watchdog.sh  -> /system/bin/
#
# 为什么两个都要：
#   firstboot-fix 只在开机跑一轮 —— 禁用缺 setupwraith 的 SetupWizard、
#   标记 device_provisioned=1、设永不休眠、点亮 display、拉起 Trebuchet。
#   home-watchdog 常驻 15s 巡检 —— Trebuchet 的 RenderThread 会在运行中
#   SIGABRT（4.4.4 NVIDIA GL/HWC 与 7.1 hwui 不兼容），死后 AMS 残留
#   ActivityRecord、SF 只剩僵尸 KeyguardScrim，系统不会自恢复；
#   同时 display 会掉回 OFF，只有 brightness 变化能触发 DPC 重算。
#   完整日志推导见两个 .sh 头部注释。
PRODUCT_PACKAGES += \
    zz-ardbeg-firstboot-fix.rc \
    zz-ardbeg-firstboot-fix.sh \
    zz-ardbeg-home-watchdog.rc \
    zz-ardbeg-home-watchdog.sh

# 【修正 2026-11-05】上面第一项原来写的是 init.recovery.rc，但
#   initfiles/Android.mk 里 LOCAL_MODULE 已经改成 init.recovery.ardbeg.rc
#   （原因见那个文件里 [7.1 移植修正] 那段注释：7.1 的 recovery 只 import
#    /init.recovery.${ro.hardware}.rc，本机 ro.hardware=ardbeg）。
#   名字对不上时 make 会直接报
#       *** No rule to make target '.../init.recovery.rc', needed by ...
#   属于必须消掉的硬错误，不是警告。两处必须保持字面一致。

# 【新增 2026-11-05】五个 /system 侧运行时修复件
#   zz-persist-log.rc    -> /system/etc/init/zz-persist-log.rc（全程日志落盘）
#   zz-bootanim-fix.rc   -> /system/etc/init/zz-bootanim-fix.rc（开机动画看门狗）
#   bootanim_killer.sh   -> /system/bin/bootanim_killer.sh（看门狗脚本本体）
#   zz-sf-hwc-off.rc     -> /system/etc/init/zz-sf-hwc-off.rc（关闭 HWC 合成）
#   sf_hwc_off.sh        -> /system/bin/sf_hwc_off.sh（关闭 HWC 的看门狗本体）
#   这几个不装进 ramdisk，随 system 分区走，改完 push 单个文件即可验证，
#   不用重打包 boot.img。为什么 /system/etc/init 下的 rc 会被 init 解析，
#   见 initfiles/Android.mk 里对应的注释块（关键：mount_all 不带路径参数
#   时会 import_late() 该目录）。
#
#   zz-sf-hwc-off.rc + sf_hwc_off.sh 是本轮解决"SF 每 40~100 秒崩一次、
#   崩一次就永久黑屏"的关键修复：原厂 4.4.4 hwcomposer 的 hwc_layer_1_t
#   字段偏移与 7.1 错位 4 字节，把 jemalloc 堆写坏。SF 起来后立刻
#   service call SurfaceFlinger 1008 i32 1 切到纯 GLES 合成即可绕开。
#   详细原理见 sf_hwc_off.sh 顶部注释。

# ============================================================================
# 【新增 2026-11-06】USB 两个守护模块
# ============================================================================
# 这两组模块定义在 initfiles/Android.mk 的第 7、8 节，这里负责让它们真正
# 进入产物。**注意 usb_mtp_default.sh 之前是漏的**：
#   上一轮调试 MTP 时，为了不重编 system 分区，是用临时工具
#   （tools/repack/mk_ramdisk4.py）手工把脚本塞进 ramdisk 的，
#   所以设备上 /sbin/usb_mtp_default.sh 存在、能用，但
#   PRODUCT_PACKAGES 里从来没有它。
#   后果：一旦跑一次干净的全量编译，ramdisk 重新生成，
#   /sbin/usb_mtp_default.sh 就会消失，init.tegra.rc 里
#       service usb_mtp_default /sbin/usb_mtp_default.sh
#   会报 "cannot execute"，MTP 又回到"插上电脑只有 adb"的状态。
#   这次一并补上，以后全量编译也能自洽。
#
# 四个文件的落点：
#   usb_mtp_default.sh     -> /sbin/usb_mtp_default.sh        （ramdisk）
#   usb_storage_mount.sh   -> /system/bin/usb_storage_mount.sh
#   zz-usb-storage-mount.rc-> /system/etc/init/zz-usb-storage-mount.rc
#
# 【为什么 usb_mtp_default.sh 必须进 ramdisk（TARGET_ROOT_OUT/sbin）】
#   它做的是「等 framework 起来后把 USB 切回 mtp」这件事，本身放 /system
#   也能跑；但放 ramdisk 有个实打实的好处：脚本里的 service call 依赖
#   /system/bin/service，而 service 又依赖 /system 挂载 —— 万一 system
#   分区出问题（OTA 半途、fsck 失败），脚本至少在 ramdisk 里还在，
#   logcat 能看到它报的错，便于定位。这是排障期的刻意选择。
#
# 【为什么 usb_storage_mount.sh 放 /system/bin 而不是 /sbin】
#   它要调 vdc，vdc 在 /system/bin/vdc（system 分区），
#   class late_start 时 /system 早已挂载，放 /system 语义更一致。
#   详细根因（四层）见 initfiles/Android.mk 第 8 节的大段注释。
PRODUCT_PACKAGES += \
    usb_mtp_default.sh \
    usb_storage_mount.sh \
    zz-usb-storage-mount.rc

# ============================================================================
# 【新增 2026-11-06】SELinux 旁路垫片 —— 修「设备不启动」
# ============================================================================
# 模块定义在 initfiles/Android.mk 第 9 节，落点是 /system/lib/libselinux_bypass.so。
#
# 它和下面那个 libsetexeccon_shim.so 不一样：**这个必须装，全量编译也要装**。
# 原因：它绕的不是「预编译 vold 的 abort()」，而是「原厂 4.4.4 的 /sepolicy
# 撑不起 7.1 用户空间」这个硬伤。策略文件来自 ramdisk，不随编译改变，
# 所以重编多少次都需要这个垫片。
#
# 四个使用者，都在各自的 rc 里显式 setenv LD_PRELOAD：
#   /system/etc/init/servicemanager.rc  -> selinux_check_access（service_manager class 缺失）
#   /init.zygote32.rc（ramdisk）        -> selinux_android_setcontext（system_server type 缺失）
#   /system/etc/init/installd.rc        -> selinux_android_restorecon_pkgdir（SIGSEGV）
#   /system/etc/init/vold.rc            -> setexeccon（配合 Utils.cpp 的 abort()）
#
# 注意 servicemanager / installd / audioserver / cameraserver 这四个 rc 是
# **覆盖** AOSP 原版（它们各自在 frameworks/ 下有自己的 Android.mk），
# 所以不通过 PRODUCT_PACKAGES 装，而是走源码补丁：
#   patches/frameworks/native/cmds/servicemanager/servicemanager.rc.patch
#   patches/frameworks/native/cmds/installd/installd.rc.patch
#   patches/frameworks/av/media/audioserver/audioserver.rc.patch
#   patches/frameworks/av/camera/cameraserver/cameraserver.rc.patch
#   patches/system/core/rootdir/init.zygote32.rc.patch
# initfiles/ 下保留同名副本，只是为了「文件级重打包」流程（apply_overlay.py）
# 能直接取用，不作为全量编译的输入。
#
# 完整根因链（四层）见 initfiles/Android.mk 第 9 节和
# prebuilt/lib/libselinux_bypass.c 头部注释。
PRODUCT_PACKAGES += \
    libselinux_bypass.so

# 【故意不装 prebuilt/lib/libsetexeccon_shim.so】
#   那个 .so 是给"文件级重打包"用的权宜垫片：当前的 /system/bin/vold 是
#   预编译件，没法重编，只能靠 LD_PRELOAD 让 setexeccon() 返回 0，
#   绕开 Utils.cpp 里的 abort()。它配套的 setenv 写在
#   repack/overlay/system/etc/init/vold.rc 里（那个文件同样只进重打包流程）。
#
#   全量编译**不需要**它，因为 patches/system/vold/Utils.cpp.patch 已经把
#   abort() 降级成 LOG(WARNING)，重编出来的 vold 本身就不会自杀。
#   源码留在 prebuilt/lib/setexeccon_shim.c 只是为了留档，
#   将来若要重新生成（比如换编译器），命令是：
#       arm-linux-androideabi-gcc -shared -fPIC -O2 -Wall \
#           -nostdlib -nostartfiles \
#           -o libsetexeccon_shim.so setexeccon_shim.c
#   （-nostdlib -nostartfiles 必须加：预编译 gcc 里没有 crtbegin_so.o，
#     也没有 bionic 的 -lc，不加会链接失败；shim 本身不依赖 libc。）

# 【删除】initfiles/ueventd.ardbeg_sata.rc 的安装
#   本机没有 SATA 控制器（eMMC only），该文件只是从 Shield Tablet 的
#   SATA 底座变体继承来的残留。7.1 的 ueventd 如果读到不存在的设备节点
#   规则只会忽略，但少一个文件少一份困惑，直接不装。

# ============================================================================
# 十六、标准硬件特性声明
# ============================================================================
# 只声明本机**真实具备**的硬件。7.1 的 PackageManager 会用这些 xml 决定
# 应用兼容性；多声明（比如摄像头、GPS）会让 Play/应用以为有该硬件，
# 装上后运行即崩。
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.bluetooth_le.xml:system/etc/permissions/android.hardware.bluetooth_le.xml \
    frameworks/native/data/etc/android.hardware.usb.accessory.xml:system/etc/permissions/android.hardware.usb.accessory.xml \
    frameworks/native/data/etc/android.hardware.usb.host.xml:system/etc/permissions/android.hardware.usb.host.xml \
    frameworks/native/data/etc/android.hardware.wifi.xml:system/etc/permissions/android.hardware.wifi.xml \
    frameworks/native/data/etc/android.hardware.wifi.direct.xml:system/etc/permissions/android.hardware.wifi.direct.xml \
    frameworks/native/data/etc/android.hardware.ethernet.xml:system/etc/permissions/android.hardware.ethernet.xml \
    frameworks/native/data/etc/android.software.midi.xml:system/etc/permissions/android.software.midi.xml

# 【删除】摄像头 / GPS / 传感器 / 触摸屏 的权限 xml
#   实机确认：camera 无 sensor、无 GPS 硬件、传感器只有 MPL 但 7.1 没有
#   对应 HAL。声明了会让系统去加载不存在的 HAL，开机时 zygote 反复重启。
#   等硬件真正调通后再逐条加回来。

# ============================================================================
# 十七、TV / 平板 形态
# ============================================================================
ifeq ($(PRODUCT_IS_ATV),true)
$(call inherit-product, device/nvidia/ardbeg/device_atv.mk)
else
$(call inherit-product, device/nvidia/ardbeg/device_tablet.mk)
endif

# ============================================================================
# 十八、USB / ADB 调试
# ============================================================================
# 【关键】7.1 的 adbd 默认要求认证（ro.adb.secure=1），而 eng 版本
#   需要"插上就能 adb"。这里显式关掉认证并打开 debuggable。
# persist.sys.usb.config 必须包含 adb，否则 adbd 不会启动
#   （cm-11 上就是因为写成 mtp 导致 adb 完全连不上）。
PRODUCT_PROPERTY_OVERRIDES += \
    ro.adb.nonblocking_ffs=false \
    persist.sys.usb.config=mtp,adb \
    ro.adb.secure=0 \
    ro.secure=0 \
    ro.debuggable=1

# Widevine DRM
PRODUCT_PROPERTY_OVERRIDES += drm.service.enabled=true

# 屏幕密度：HDMI 1080p 下 320dpi 比较合适
PRODUCT_PROPERTY_OVERRIDES += ro.sf.lcd_density=320

# ============================================================================
# 十九、WiFi 用户态
# ============================================================================
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/wifi/dhcpcd.conf:system/etc/dhcpcd/dhcpcd.conf \
    $(LOCAL_PATH)/wifi/wpa_supplicant.conf:system/etc/wifi/wpa_supplicant.conf \
    $(LOCAL_PATH)/wifi/ardbeg_default_network.conf:system/etc/wifi/ardbeg_default_network.conf

# ----------------------------------------------------------------------------
# 【2026-11-06 新增】出厂预置 WiFi 网络模板
#
#   目标路径 /system/etc/wifi/ardbeg_default_network.conf 是**新增**路径，
#   不与任何 AOSP 模块冲突，所以这里用 PRODUCT_COPY_FILES 是安全的
#   （不像 libEGL.so / lmkd.rc 那样会被 build/core 静默 ignored）。
#
#   它只是模板，真正生效的是首启脚本：
#     /system/bin/zz-ardbeg-firstboot-fix.sh 第 9 节
#   该脚本在 /data/misc/wifi/wpa_supplicant.conf 里没有任何 network 块时，
#   把模板里的 network={...} 段追加进去，然后 svc wifi enable 触发连接。
#   四清后仍能自动连上，且用户后来自己配过网络时不会覆盖。
#
#   开机自动「打开」WiFi 由两处保证，与本模板分工不同：
#     overlay/packages/providers/SettingsProvider/.../defaults.xml
#         def_wifi_on=true / def_bluetooth_on=true（全量编译路径）
#     首启脚本第 9 节的 svc wifi enable + bluetooth_manager Binder 调用
#         （文件级重打包路径，因为 SettingsProvider.apk 不会被重编译）
#
#   详见 patches/README.md 第十五章。
# ----------------------------------------------------------------------------

# 【不拷 marvel_wpa.conf / marvel_p2p.conf】
#   vendor 闭源包已经把它们装到 system/etc/firmware/ 下（见
#   ardbeg-vendor-blobs.mk），这里再拷一次会报
#   "PRODUCT_COPY_FILES ... ignored"（同一个目标路径重复定义）。
#   保留 vendor 那份即可。

PRODUCT_PACKAGES += \
    hostapd \
    wpa_supplicant \
    wpa_supplicant.conf \
    libnetcmdiface

# ============================================================================
# 二十、杂项系统组件
# ============================================================================
PRODUCT_PACKAGES += \
    drmserver \
    libdrmframework_jni \
    e2fsck

# 【删除】setup_fs / overlaymon / Gallery2 / rild / libdashplayer
#   setup_fs：4.4 时代格式化 data 的小工具，7.1 用 make_f2fs/mke2fs
#   overlaymon：NVIDIA 私有 overlay 监控
#   Gallery2：TV/盒子形态不需要，平板形态由 common_full_tablet 自带
#   rild：本机无基带（ro.radio.noril），编了也起不来
#   libdashplayer：7.1 源码树里没有这个仓库

# ============================================================================
# 二十一、输入法（LatinIME / ArdbegIME / BaiduInput）
# ============================================================================
# 本节装三个输入法，职责各不相同，详见下面各小节的说明：
#   LatinIME    英文 + 多语言词典（AOSP 方案）
#   ArdbegIME   手搓兜底键盘（纯 ASCII，不依赖编译产物）
#   BaiduInput  原厂百度输入法（中文拼音/笔画，主力）
# ============================================================================
# 【为什么必须显式加 LatinIME —— 这是「设置里连 WiFi 时弹不出键盘」的根因】
#
#   现象：进「设置 → WLAN」点一个热点，弹出输入密码的对话框，
#         点输入框没有任何软键盘出来，密码根本没法输。
#
#   排查：
#       # ime list -a -s
#       （空）
#       # pm list packages | grep -i latin
#       （空）
#   说明系统里**一个输入法服务都没有**，不是"输入法被禁用"或
#   "键盘被硬件键盘抑制"，而是压根没装。
#
#   根因在构建配置，不在设备树，也不在 IME 框架：
#     LineageOS 的 IME 是按产品形态分发在 vendor/cm/config/ 下的：
#         common_full_phone.mk            -> LatinIME
#         common_mini_phone.mk            -> LatinIME
#         common_full_tablet_wifionly.mk  -> LatinIME
#         common_mini_tablet_wifionly.mk  -> LatinIME
#         common_full_tv.mk               -> **没有 LatinIME**
#     本机用的是 cm_ardbeg_tv，lineage_tv.mk 里 inherit 的是
#     vendor/cm/config/common_full_tv.mk，于是整个 TV 版 ROM 不带输入法。
#     Google 的 Android TV 官方镜像是靠 Leanback 键盘 / Gboard TV 补的，
#     本 ROM 没有 GMS，所以只能自己把 LatinIME 加回来。
#
#   顺带说明：这不是 InputMethodManagerService 的问题。
#     # service check input_method
#     Service input_method: found
#   服务一直在，只是没有任何 IME 向它注册，所以 IME 列表为空。
#
#   注意 LatinIME 需要词典数据。CM 在
#   vendor/cm/overlay/dictionaries/packages/inputmethods/LatinIME 里放了
#   多语言词典 overlay，common_full_phone.mk 通过下面这行把它挂上：
#       $(call inherit-product-if-exists, vendor/cm/config/dictionaries.mk)
#   TV 版没走那条路，这里也一并 inherit，否则英文联想/自动纠错不可用。
# ----------------------------------------------------------------------------
$(call inherit-product-if-exists, vendor/cm/config/dictionaries.mk)

PRODUCT_PACKAGES += \
    LatinIME

# ----------------------------------------------------------------------------
# 兜底输入法：ArdbegIME
#
# 为什么还要再带一个：
#   LatinIME 依赖构建系统把 packages/inputmethods/LatinIME 编出来，
#   而 LatinIME 带 JNI（原生词典压缩/解压）和大量资源，是本项目里
#   "可能编不过"的模块之一。一旦它编不过，整个 system.img 出不来。
#   为了不让"没有输入法"这种小问题拖死整个移植，这里额外带一个
#   10 KB 的手工打包键盘（device/nvidia/ardbeg/ime/），
#   它是预编译 APK，不参与任何编译，只要 PRODUCT_COPY_FILES 生效就存在。
#
# 两个输入法同时存在不会冲突：
#   - 包名不同（com.android.inputmethod.latin vs com.ardbeg.ime）
#   - 用户可在「设置 → 语言和输入法 → 当前输入法」里切换
#   - 系统默认选第一个可用的
#
# 如果确认 LatinIME 能正常编出来并且用着没问题，把下面这行 ArdbegIME
# 注释掉即可省掉 10 KB。
# ----------------------------------------------------------------------------
PRODUCT_PACKAGES += \
    ArdbegIME

# ----------------------------------------------------------------------------
# 主力中文输入法：原厂百度输入法 BaiduInput
#
# 【为什么又加第三个输入法】
#   LatinIME 只有英文（AOSP 从来没有中文拼音方案），ArdbegIME 是我手搓的
#   纯 ASCII 键盘。两个都打不出汉字。中文输入必须靠原厂那个带拼音引擎的
#   百度输入法，也就是 g100 原厂 4.4.4 线刷包里的
#       system/app/BaiduInput.apk  (com.baidu.input_baidutv 4.0.8.9)
#   已经把它连同 4 个 armeabi 原生库一起放进
#       device/nvidia/ardbeg/ime/BaiduInput/
#
# 【这个包在 7.1 上有一个必须配套的改动】
#   它是加固包，libchiperencoder_v1_2.so 的 JNI_OnLoad 会 RegisterNatives
#   一个 dex 里不存在的方法 nativeChiperGetVersion，ART 会抛
#   NoSuchMethodError 留下 pending exception；eng 版默认开 CheckJNI，
#   库接着调 NewGlobalRef 就被 CheckJNI 判死，进程 SIGABRT，输入法
#   每秒重启一次，永远起不来。
#   配套改动在 system.prop 末尾：dalvik.vm.checkjni=false
#   完整的源码级追查（jni_internal.cc / java_vm_ext.cc / AndroidRuntime.cpp
#   的具体行号）写在 ime/BaiduInput/Android.mk 头部注释里。
#
# 【三个输入法共存的顺序】
#   - BaiduInput  中文主力（用户可切拼音全键/拼音九键/笔画）
#   - LatinIME    英文备用，带多语言词典 overlay
#   - ArdbegIME   最后兜底，10 KB，不依赖任何编译产物
#   包名各不相同，互不冲突；默认输入法由用户在设置里选，或由
#   frameworks 里第一个 enabled 的 IME 决定。
# ----------------------------------------------------------------------------
PRODUCT_PACKAGES += \
    BaiduInput

# ============================================================================
# 二十二、vendor 闭源库
# ============================================================================
$(call inherit-product, vendor/nvidia/ardbeg/ardbeg-vendor.mk)

# ============================================================================
# 二十三、EGL / HWUI 兼容性 —— libEGL 补丁集成（2026-11-06 集成核查后补上）
# ============================================================================
#
# 【为什么单列一节】
#   之前 egl_display.cpp.patch 一直是「源码补丁已应用」状态，check.sh
#   22/22 全绿，但设备上 /system/lib/libEGL.so 的 md5 始终是
#   3cd50337aeb9aa2220b5007f786cf8bc（**未打补丁的原版**）。
#   原因是 out/target/product/ardbeg/ 被清空过，而后续所有 ROM 都走
#   「解 system.img → 只换改动文件 → 重新打包签名」的文件级重打包，
#   那条链路只认 repack/overlay/ 下的现成文件，不会去编译 libEGL。
#   于是「补丁应用了」和「补丁进 ROM 了」这两件事长期脱节 ——
#   这正是四清后黑屏里 `Failed to choose config, error = EGL_BAD_DISPLAY`
#   一直清不掉的根因（实测近 3000 行 logcat 仍有 5 次，Trebuchet 反复被
#   SIGABRT、mCurrentFocus=null）。本节把这条缺口正式封上。
#
# 【补丁修的是什么】
#   7.1 frameworks/native/opengl/libs/EGL/egl_display.cpp 里
#   egl_display_t::getDisplay() 有 `disp.dpy == EGL_NO_DISPLAY` 的
#   **进程级缓存**。而 g100 原厂 4.4.4 的 libEGL_tegra_impl.so 把
#   display 状态放在**线程局部存储**（导入 NvOsTlsGet/NvOsTlsAlloc）。
#   第一个线程调过 eglGetDisplay 之后，7.1 新引入的 hwui RenderThread
#   再调 eglGetDisplay 会被直接跳过，它的 TLS 是空的，
#   接着 eglInitialize / eglChooseConfig 必然 EGL_BAD_DISPLAY 并 abort。
#   4.4.4 的 hwui 是单线程，所以原厂 ROM 从不触发。
#   修法：去掉那个短路条件，改成 `if (cnx->dso) {`，让每个线程都真正
#   透传给驱动（驱动对 EGL_DEFAULT_DISPLAY 幂等，始终返回 0x1）。
#   完整推导 / egltest5 八种模式对照 / 反汇编依据见
#   patches/README.md 的 egl_display.cpp.patch 专章。
#
# 【两条出包路径，必须产出等价结果】
#   1) 全量编译（lunch cm_ardbeg_tv-eng）
#      install.sh 会把 patches/frameworks/native/opengl/libs/EGL/
#      egl_display.cpp.patch 打进源码，AOSP 自己编出带修复的 libEGL.so。
#      ★ 这里**不要**写
#          PRODUCT_COPY_FILES += .../libEGL.so:system/lib/libEGL.so
#        system/lib/libEGL.so 已由 AOSP 的 libEGL 模块产出，build/core
#        会以 "PRODUCT_COPY_FILES ... ignored" 静默丢掉这条
#        （device.mk 第 62 行 audio_effects.conf 已经踩过同一个坑），
#        结果就是「以为打了补丁、其实刷进去的还是原版」。
#      下面那条构建期断言就是防止这种静默失效。
#
#   2) 文件级重打包（out/ 为空时用，当前交付走这条）
#      prebuilt/lib/libEGL.so 是上面源码补丁的**等价二进制补丁产物**：
#        输入  patches/tools/libEGL.orig.so   md5 3cd50337...（原版基准）
#        工具  patches/tools/patch_libegl.py  （ELF PT_LOAD 换算 + 上下文校验，
#                                              只把 0xA3C8 的 cbnz 改成 nop）
#        产物  prebuilt/lib/libEGL.so         md5 4ac10584321c81f8dcddd21a025bced6
#      repack/tools/apply_overlay.py 的 FILES 表把它写进 system.img 的
#      /system/lib/libEGL.so，并强制校验 md5；repack/overlay/system/lib/
#      libEGL.so 只是它在打包侧的镜像副本，两者必须一致。
#      想重新生成：
#        cd device/nvidia/ardbeg/patches && \
#        python3 tools/patch_libegl.py tools/libEGL.orig.so && \
#        cp tools/libEGL.orig.so ../prebuilt/lib/libEGL.so
#
# 【配套修复，缺一不可】
#   - persist.sys.ui.hw=0（lineage_tv.mk + overlay build.prop + 首启脚本）：
#     关掉属性强制硬件加速。但 Window.java:755 是
#     `hardwareAccelerated || 属性`，app 自己声明硬件加速时仍会起
#     RenderThread，所以它只是缓解，不能替代本节的 libEGL 补丁。
#     实测 persist.sys.force_sw_gles=1 是错误路径（本机无 software GLES，
#     SurfaceFlinger 会 "couldn't find an OpenGL ES implementation" 崩溃），
#     已回滚废弃。
#   - sf_hwc_off.sh / zz-sf-hwc-off.rc：README 第 1359 行指出 EGL 补丁是
#     「放大器」—— 它让 GPU 合成变频繁，暴露 4.4.4 hwcomposer 与 7.1
#     hwc_layer_1_t 布局不符的越界释放。守护脚本通过
#     `service call SurfaceFlinger 1008 i32 1` 把 mDebugDisableHWC 置 1，
#     强制走 GLES 合成来规避。**不要为了压 SF 崩溃而回退 EGL 补丁**。
#   - 三个 animation_scale=0：避免窗口淡入动画把 layer alpha 卡在 0x00。
#
# 这一节不新增 PRODUCT_PACKAGES / PRODUCT_COPY_FILES，是刻意的：
# 全量编译靠源码补丁，文件级重打包靠 apply_overlay.py 的 FILES 表，
# 两处清单都登记了才会真的进包，重复登记反而会被 build 静默忽略。
# ============================================================================

# 构建期断言：源码里的进程级缓存条件必须已经被补丁去掉。
#
# 【两个坑，实测踩过】
#   a) 不能只 grep 'disp.dpy == EGL_NO_DISPLAY'：补丁自带的大段注释里
#      就写着「去掉 disp.dpy == EGL_NO_DISPLAY 这个短路条件」，朴素 grep
#      会数到 1，把「已打补丁」误判成「没打」。所以模式必须锚定到
#      ^[[:space:]]*if，只匹配**真正生效的代码行**（补丁注释那行以
#      `//` 开头，匹配不上）。用 . 通配圆括号，是因为 make 会把
#      $(shell ...) 里的 ')' 当成函数结束符。
#   b) 用 grep -c 的**输出文本**判断（0 = 已打补丁），不要用退出码：
#      grep 找不到匹配时退出码是 1，容易让 $(shell ...) 报错。
#
# LOCAL_PATH = device/nvidia/ardbeg，往上三级才是源码根：
#   ardbeg/.. -> nvidia ; /.. -> device ; /.. -> 源码根
# 写四级会指到源码树外面去，wildcard 恒为空、断言就永远不生效。
EGL_DISPLAY_CPP := $(LOCAL_PATH)/../../../frameworks/native/opengl/libs/EGL/egl_display.cpp
EGL_CACHE_STILL_THERE := $(strip $(shell grep -c '^[[:space:]]*if .cnx->dso && disp.dpy == EGL_NO_DISPLAY' $(EGL_DISPLAY_CPP) 2>/dev/null))
ifneq ($(wildcard $(EGL_DISPLAY_CPP)),)
ifneq ($(EGL_CACHE_STILL_THERE),0)
$(warning ================================================================)
$(warning [ardbeg] egl_display.cpp.patch 尚未应用！)
$(warning 全量编译出的 libEGL.so 会缺少多线程 EGL 修复，开机必现)
$(warning EGL_BAD_DISPLAY / 应用全崩 / 黑屏。请先执行：)
$(warning     cd device/nvidia/ardbeg/patches && ./install.sh)
$(warning ================================================================)
endif
endif

# ============================================================================
# 二十四、lmkd / system_server Watchdog 兼容性（2026-11-06 深夜）
#
# 【症状】开机一段时间后 framework 整体重启：Netd 重新启动、
#   `sys.boot_completed=1` 残留但 `pidof system_server` 为空，
#   桌面上表现为突然黑屏 + 重新加载。此前一直和 KeyguardScrim /
#   EGL / screencap 混在一起当成同一个「遗留项」，其实是独立根因。
#
# 【根因链】
#   /data/anr/traces_SystemServer_WDT*.txt 显示 AMS 大锁
#   <0x0eb155e3> 被 `Binder:1466_6` / `ActivityManager` 持有，卡在
#       ProcessList.writeLmkd(ProcessList.java:723) -> Thread.sleep(1000)
#   而 main / android.display / android.ui 全部 Blocked 等这把锁。
#   writeLmkd 在 /dev/socket/lmkd 连不上时会持锁睡 3 秒（for 3 次 × 1s），
#   开机阶段 app 频繁 attach/die 累积超过 Watchdog 30s+30s 判死窗口。
#
#   socket 不存在的实锤（dmesg）：
#       init: (Parsing /system/etc/init/lmkd.rc took 0.00s.)
#       SELinux: Context u:object_r:lmkd_exec:s0 is not valid (left unmapped).
#   rc 被正常解析，但 4.4.4 的 /sepolicy 里没有 lmkd_exec 域，
#   init 在 security_compute_create 就失败，连 execve 都没走到。
#   与 audioserver / cameraserver / mediacodec 是同一条「7.1 新域缺失」链。
#
# 【修法】给 lmkd 服务显式 seclabel u:r:mediaserver:s0 绕开计算，
#   去掉 readproc（7.1 android_ids 没有它，decode_uid 会给无效 gid），
#   去掉 critical（崩溃触发 reboot，而本机 recovery 是 4.4.4 ramdisk，
#   进去就再也加载不了 7.1 /system）。
#
# 【为什么不改 ProcessList.java 去掉 sleep】
#   改 Java 要重编 services.jar；本机 out/ 已清空、所有 ROM 走文件级
#   重打包，改了也落不了地，只会再制造一个「check.sh 全绿但产物没进
#   ROM」的假修复（egl_display.cpp.patch 已踩过）。lmkd 修好后
#   socket 常连，sleep 分支根本不会进。
#
# 【两条落地路径 —— 和 EGL 那一节完全同构】
#   全量编译：patches/system/core/lmkd/lmkd.rc.patch（check.sh 第 23 个）
#   文件级重打包：initfiles/lmkd.rc -> repack/overlay/system/etc/init/lmkd.rc
#                 -> apply_overlay.py 的 FILES 表写进 system.img
#   本节刻意不写 PRODUCT_PACKAGES / PRODUCT_COPY_FILES：
#   /system/etc/init/lmkd.rc 已由 AOSP 的 system/core/lmkd 模块产出，
#   再用 PRODUCT_COPY_FILES 覆盖会被 build/core 静默
#   "PRODUCT_COPY_FILES ... ignored" 丢掉（这个坑在 EGL 节记过）。
#   真正决定「进不进包」的是源码补丁 + FILES 两处清单。
#
# 真源与详细注释：
#   device/nvidia/ardbeg/initfiles/lmkd.rc
#   patches/README.md 第十二章
# ============================================================================

# 构建期断言：源码树的 lmkd.rc 必须已经被补丁改过。
# 模式锚定 ^[[:space:]]*seclabel，只匹配真正生效的服务行：
#   补丁自带的大段注释里也提到 seclabel，朴素 grep 会误判成「已修」；
#   注释行以 '#' 开头，锚定到行首空白后紧跟 seclabel 就排除了它们。
LMKD_RC := $(LOCAL_PATH)/../../../system/core/lmkd/lmkd.rc
LMKD_HAS_SECLABEL := $(strip $(shell grep -c '^[[:space:]]*seclabel u:r:mediaserver:s0' $(LMKD_RC) 2>/dev/null))
ifneq ($(wildcard $(LMKD_RC)),)
ifeq ($(LMKD_HAS_SECLABEL),0)
$(warning ================================================================)
$(warning [ardbeg] system/core/lmkd/lmkd.rc 尚未打补丁！)
$(warning 4.4.4 policy 没有 lmkd_exec 域 -> lmkd 服务起不来)
$(warning -> /dev/socket/lmkd 不存在)
$(warning -> ProcessList.writeLmkd() 持 AMS 大锁 sleep)
$(warning -> Watchdog 杀 system_server / framework 整体重启。)
$(warning 请先执行： cd device/nvidia/ardbeg/patches && ./install.sh)
$(warning ================================================================)
endif
endif
