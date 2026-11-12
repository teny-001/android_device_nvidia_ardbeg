#
# BoardConfig.mk — ardbeg (NVIDIA Tegra K1 T124 / TN8 P1761 / 商品名 g100)
#
# 目标平台：LineageOS 14.1 (Android 7.1.2)
#
# 本文件由 cm-11.0 版本的 BoardConfig 改写而来。改写原则：
#   1) 只保留 7.1 构建系统真正会读的变量。cm-11 里那些 NVIDIA 私有变量
#      （BOARD_SUPPORT_PARAGON_FUSE_UFSD / TARGET_KERNEL_VCM_BUILD /
#      TARGET_QUICKBOOT / BOARD_HAVE_LBH_SUPPORT / SECURE_OS_BUILD …）
#      在 7.1 的 build/core 里**没有任何代码读取**，留着只会误导后来人，
#      所以全部删除，并在本文档末尾统一记录删了什么、为什么。
#   2) 所有与硬件相关的数值都标注来源，方便和原厂线刷包对照。
#   3) 每一处"和 cm-11 不一样"的地方都写清原因，避免以后又改回去。
#

# ============================================================================
# 一、架构与板型
# ============================================================================
# T124 是 32 位 Cortex-A15（无 armv8），实机 /proc/cpuinfo 已确认。
TARGET_CPU_ABI := armeabi-v7a
TARGET_CPU_ABI2 := armeabi
TARGET_ARCH := arm
TARGET_ARCH_VARIANT := armv7-a-neon
TARGET_CPU_VARIANT := cortex-a15
TARGET_CPU_SMP := true
ARCH_ARM_HAVE_TLS_REGISTER := true

TARGET_BOARD_PLATFORM := tegra
TARGET_TEGRA_VERSION := t124
TARGET_BOOTLOADER_BOARD_NAME := ardbeg
TARGET_NO_BOOTLOADER := true
TARGET_NO_RADIOIMAGE := true

# 设备树私有头文件目录（include/tinyhal/audio_config.h 等）
TARGET_SPECIFIC_HEADER_PATH := device/nvidia/ardbeg/include

# ============================================================================
# 二、内核：使用原厂 4.4.4 预编译内核
# ============================================================================
# 【为什么必须是预编译】
#   本设备没有可用的 7.1 内核源码分支：
#     - 原厂线刷包只给 zImage（3.10.24-g1fc624e，2016-03-15 构建，gcc 4.7）；
#     - 树内 kernel/nvidia/shield 是 3.10.96（LineageOS 的 shieldtablet 分支），
#       和本板的 DTB / NCT 配置不是一套，且之前实测自编内核起不来
#       （见 Kernel编译与boot镜像报告.md 第五节：console 走 ttyS0、
#        DTB 里 linux,initrd-start 陈旧导致静默挂死）。
#   因此默认走预编译，把"能编译出 ROM"这件事和"内核能不能起来"解耦。
#
# 【7.1 的 kernel.mk 行为（和 cm-11 完全不同，这是移植时最大的坑）】
#   Android 7.1 的 AOSP build/core 里**已经没有 tasks/kernel.mk**，
#   内核改由 vendor/cm/build/tasks/kernel.mk 处理，判断逻辑是：
#       ifeq "$(wildcard $(KERNEL_SRC))" ""
#           -> 用 TARGET_PREBUILT_KERNEL（预编译）
#       else
#           -> FULL_KERNEL_BUILD := true（从源码编）
#   也就是说：只要 TARGET_KERNEL_SOURCE 指向的目录**存在**，就会去编源码，
#   TARGET_PREBUILT_KERNEL 被完全忽略。cm-11 时代用
#   "kernel/nvidia/ardbeg__disabled_by_prebuilt" 这种不存在的路径来绕，
#   这里沿用同样的手法，但路径名改成更能自解释的 prebuilt_only。
TARGET_PREBUILT_KERNEL := device/nvidia/ardbeg/prebuilt/kernel

# 故意指向一个不存在的目录：让上面那条 wildcard 判断为空，从而走预编译分支。
# 【注意】不要把这个路径改成 kernel/nvidia/shield，否则会转而编译树内内核，
#        而且因为缺少 ardbeg 的 DTB/defconfig 组合，编出来的内核起不来。
TARGET_KERNEL_SOURCE := kernel/nvidia/ardbeg__prebuilt_only
TARGET_KERNEL_CONFIG :=

# boot.img 头部参数：全部取自原厂 boot.img 实测值（porting 目录下的
# unpack 结果），逐字段与原厂一致才能被 nvflash 的 bootloader 接受。
#   kernel_addr   = 0x10008000  -> BASE 0x10000000 + OFFSET 0x8000
#   ramdisk_addr  = 0x11000000  -> BASE + RAMDISK_OFFSET 0x01000000
#   tags_addr     = 0x10000100  -> BASE + TAGS_OFFSET 0x100
#   page_size     = 2048
#   dt_size       = 0           -> DTB 不在 boot.img 里，走独立的 DTB 分区
BOARD_KERNEL_BASE := 0x10000000
BOARD_KERNEL_OFFSET := 0x00008000
BOARD_KERNEL_PAGESIZE := 2048
BOARD_RAMDISK_OFFSET := 0x01000000
BOARD_KERNEL_TAGS_OFFSET := 0x00000100
BOARD_MKBOOTIMG_ARGS += --ramdisk_offset $(BOARD_RAMDISK_OFFSET)
BOARD_MKBOOTIMG_ARGS += --tags_offset $(BOARD_KERNEL_TAGS_OFFSET)

# cmdline 只有 69 字节，和原厂一致。
# 【不要在这里加 mem= / vpr= / tegra_fbmem=】
#   这些由 bootloader 读 NCT/DTB 后拼进来，写死会覆盖内存映射导致起不来。
# androidboot.hardware=ardbeg 决定 init 去加载 /init.ardbeg.rc，缺了系统没有服务。
# androidboot.selinux=permissive：本板没有可用的 7.1 sepolicy 全集，
#   先用宽容模式把系统跑起来，再逐条补策略（见 sepolicy/README.md）。
# ---------------------------------------------------------------------------
# 【2026-11-12 长日志内核：在内核 cmdline 追加 log_buf_len=1M】
# 目的：把内核 printk 的环形缓冲（dmesg 读的就是它）由默认 128KB 扩到 1MB，
#       让 `adb shell dmesg` 在开机后能直接看到接近 0 秒的内核日志。
# 背景：本机 3.10.24 内核默认 log_buf 约 128KB（实测上限 904 行 / 128586 字节），
#       开机前 ~13s 的密集驱动日志就会写满并覆盖最早的 0~6s；而 adbd 要
#       uptime≈16s 才可用，所以 adb 侧 dmesg 最早只能抓到 5.2~6.7s。
#       此前只能靠 /sys/fs/pstore/console-ramoops 拿「上一次启动」从
#       0.000000s 开始的 console 日志（ramoops 1MB @0xf2300000），但它是
#       read-once 且必须再重启一次才落盘，无法用于当前启动的实时诊断。
# 依据：设备 /proc/kallsyms 存在 log_buf_len_setup / setup_log_buf 两个符号，
#       证明该内核注册了 early_param("log_buf_len") 并支持运行时用 bootmem
#       分配更大的 log_buf；1M 是 3.10 时代 Android 设备的通用取值。
# 安全性：log_buf_len 只影响 printk 缓冲大小，不参与内存映射，不会覆盖
#       bootloader 从 NCT/DTB 追加的 mem= / vpr= / tegra_fbmem= / gpt /
#       board_info 等参数，因此不触发上方第 84~85 行「写死会覆盖内存映射
#       导致起不来」的警告。完整 /proc/cmdline = 本行 + buildvariant=
#       （build/core/Makefile:553 自动追加）+ bootloader 段；实测原 799 字节，
#       加完约 815 字节，远低于 ATAG/DT cmdline 的 1024/2048 上限。
# 构建链路：BOARD_KERNEL_CMDLINE 会同时传给 boot.img / recovery.img 与
#       OTA 包里的 cmdline 文件（build/core/Makefile:555 / 1017 / 1461 /
#       1922 / 1963），所以改这一行即可让今后所有编译产物自带长日志。
# 落地边界：本行只影响「未来编译产物」，不影响已刷入的 5002791a80 系统。
#       立即可用的成品是 wb_tmp/boot_longlog.img：在现成 boot.img 头部
#       cmdline 字段追加同样 15 字节，kernel/ramdisk/全部地址/img_id
#       逐字节不变（详见 wb_tmp/report_longlog_boot.txt）。
#       刷 LNX 前必须 dump + md5 备份 + af.py verify + 用户单独授权。
# 回退：把本行末尾的 " log_buf_len=1M" 删掉，或还原
#       wb_tmp/BoardConfig.mk.bak_before_longlog。
# 规范：本次只改设备树 mk，未改 cm14.1 源码，按项目约定无需新增 patch。
# ---------------------------------------------------------------------------
BOARD_KERNEL_CMDLINE := vpr_resize androidboot.selinux=permissive androidboot.hardware=ardbeg log_buf_len=1M

# ============================================================================
# 三、分区尺寸
# ============================================================================
# 来源：实机 /proc/partitions + 原厂 partitiontable.txt
#   LNX(mmclk0p9) 40MB / SOS(p7) 40MB / APP(p10) 3GB / CAC(p11) 768MB / UDA(p21) 25.2GB
# 【注意】cm-11 里写的是 24432320(23MB) / 1.28GB / 370MB，那是 Shield Tablet
#   8 英寸版的布局，和本机 3GB system 分区不一致；分区写小了会导致
#   system.img 放不下（7.1 的 system 比 4.4 大很多，1.28GB 绝对不够）。
BOARD_BOOTIMAGE_PARTITION_SIZE := 41943040
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 41943040
BOARD_SYSTEMIMAGE_PARTITION_SIZE := 3221225472
BOARD_CACHEIMAGE_PARTITION_SIZE := 805306368
BOARD_USERDATAIMAGE_PARTITION_SIZE := 27042478080
BOARD_FLASH_BLOCK_SIZE := 131072

TARGET_USERIMAGES_USE_EXT4 := true
BOARD_SYSTEMIMAGE_PARTITION_TYPE := ext4
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := ext4
# 7.1 默认会尝试给 userdata 加 file-based encryption 需要的元数据，
# 本板老 bootloader 不支持，关掉以保证 data 分区能正常挂载。
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_USERIMAGES_USE_F2FS := false

# ============================================================================
# 四、图形
# ============================================================================
# 7.1 仍然使用 HWC1 + gralloc0，Tegra K1 的闭源 blob（gralloc.tegra.so /
# hwcomposer.tegra.so）可以原样使用，不需要 HWC2/HIDL。
USE_OPENGL_RENDERER := true
BOARD_DISABLE_TRIPLE_BUFFERED_DISPLAY_SURFACES := true
MAX_EGL_CACHE_SIZE := 4194304
MAX_EGL_CACHE_ENTRY_SIZE := 262144
OVERRIDE_RS_DRIVER := libnvRSDriver.so
BOARD_OVERRIDE_RS_CPU_VARIANT_32 := cortex-a15
EXTENDED_FONT_FOOTPRINT := true

# 本板图形内存走 nvmap（CONFIG_TEGRA_NVMAP=y），不是 ION。
# 所以**不能**设 TARGET_USES_ION / BOARD_USES_LEGACY_ION，
# 否则 frameworks/native 会去找 libion，链接直接失败。

# 显示：本机没有内置屏，只有 HDMI（实机 fb0 为 1280x720 虚拟兜底）。
BOARD_HDMI_MIRROR_MODE := Scale

# ============================================================================
# 五、音频
# ============================================================================
# 本板硬件：HDMI（HDA NVIDIA Tegra, card0/pcm3）+ 蓝牙 A2DP，无内置 codec 功放。
# 使用设备树自带的 tinyhal（ALSA/XML 配置驱动），不用 NVIDIA 的
# audio.primary.tegra.so 闭源 HAL —— 那个 blob 在 4.4 上就已经加载失败
# （见 音频故障诊断报告.md：mediaserver 从未映射该 so），
# 7.1 的 AudioFlinger 更不可能兼容它。
BOARD_USES_GENERIC_AUDIO := false
BOARD_USES_ALSA_AUDIO := true
BOARD_USES_TINYHAL_AUDIO := true

# 生成的 HAL 模块名 = audio.$(TINYHAL_AUDIO_MODULE_NAME).$(TARGET_DEVICE)
#   = audio.primary.ardbeg.so
# 为什么不叫 audio.primary.tegra：
#   vendor 闭源包里已经有一个 audio.primary.tegra.so，两者安装路径相同会报
#   "Two files installed to the same path"。7.1 的 HAL 加载器按
#   ro.hardware(=ardbeg) 找 audio.primary.ardbeg.so，改名不影响加载。
TINYHAL_AUDIO_MODULE_NAME := primary

# ============================================================================
# 六、无线（WiFi / 蓝牙）
# ============================================================================
# 实机确认：WiFi 是 Marvell 8897（SDIO），内核模块 sd8897.ko / sd8897mlan.ko；
# 蓝牙是独立的 BCM4350C0，走 UART /dev/ttyTHS2 + libbt-vendor。
# 【和 cm-11 不同】cm-11 的 BoardConfig 写的是 bcmdhd（Broadcom WiFi），
#   那是 Shield Tablet 8 英寸版的配置，本机不是。写成 bcmdhd 会导致
#   wpa_supplicant 加载 lib_driver_cmd_bcmdhd 并去找 fw_bcmdhd.bin，
#   WiFi 永远起不来。这里改成 Marvell 的正确组合。
BOARD_WPA_SUPPLICANT_DRIVER := NL80211
WPA_SUPPLICANT_VERSION := VER_0_8_X
BOARD_HOSTAPD_DRIVER := NL80211
# Marvell 用通用 nl80211 驱动命令，不需要厂商私有 lib_driver_cmd_*
BOARD_WPA_SUPPLICANT_PRIVATE_LIB :=
BOARD_HOSTAPD_PRIVATE_LIB :=
WIFI_DRIVER_MODULE_NAME := "sd8897"
WIFI_DRIVER_MODULE_ARG := ""
# 8897 的固件由模块自己从 /system/etc/firmware 加载，不走 firmware_path 参数
WIFI_DRIVER_FW_PATH_PARAM := ""

BOARD_HAVE_BLUETOOTH := true
BOARD_HAVE_BLUETOOTH_BCM := true
BOARD_BLUETOOTH_BDROID_BUILDCFG_INCLUDE_DIR ?= device/nvidia/ardbeg/bluetooth
BOARD_BLUEDROID_VENDOR_CONF := device/nvidia/ardbeg/bluetooth/vnd_ardbeg.txt

# ============================================================================
# 七、摄像头 / 传感器 / GPS
# ============================================================================
# 本板 /dev/camera 存在但无 sensor（NvOdmImagerDeviceDetect: autodetect disabled）。
# 7.1 的相机 HAL1 是 legacy，TARGET_HAS_LEGACY_CAMERA_HAL1 在 7.1 已废弃，
# 用 USE_CAMERA_STUB 走占位实现，避免编 camera.tegra 时链接失败。
USE_CAMERA_STUB := true
BOARD_GPS_LIBRARIES := true
# 传感器：InvenSense MPL + NVIDIA NVS 框架，内核模块 inv-mpu.ko 等
# 7.1 的 SensorService 需要 HAL 1.0，走 vendor blob（sensors.tegra.so）
TARGET_TEGRA_TOUCH := raydium

# ============================================================================
# 八、SELinux
# ============================================================================
# 7.1 的 sepolicy 与 4.4 差异极大（引入 attribute、hal_* 域、vendor 分区规则），
# 直接套 cm-11 的 .te 会大面积报 "unknown type"。
# 因此：
#   - 主体策略复用 shield-common（同为 T124，且是官方 14.1 维护的策略）；
#   - 本设备只补 ardbeg 特有的 device 节点（见 sepolicy/）。

# 【关键】策略版本必须降到 28
#   本机内核是原厂 4.4.4 的 3.10.24，SELinux 停在
#   POLICYDB_VERSION_DEFAULT_TYPE(28)，也就是「xperms 之前」的版本
#   （xperms 是 Linux 3.14 才进主线）。实测 dmesg：
#       SELinux: policydb version 30 does not match my version range 15-28
#       init: failed to load policy: Invalid argument
#       init: Security failure; rebooting into recovery mode...
#   7.1 默认 POLICYVERS=30，直接刷必然进 recovery。
#   降到 28 后 checkpolicy 拒绝写 xperm 规则，Android.mk 里同步做剥离，
#   见 patches/system/sepolicy/Android.mk.patch。
POLICYVERS := 28
BOARD_SEPOLICY_DIRS += \
    device/nvidia/ardbeg/shield-common/sepolicy/common \
    device/nvidia/ardbeg/shield-common/sepolicy/lineage-common \
    device/nvidia/ardbeg/sepolicy

# 7.1 的 sepolicy 需要 seccomp 策略（shield-common 自带）
BOARD_SECCOMP_POLICY := device/nvidia/ardbeg/shield-common/seccomp

# ============================================================================
# 九、HAL 变体（shield-common 约定的变量）
# ============================================================================
TARGET_POWERHAL_VARIANT := tegra
TARGET_THERMALHAL_VARIANT := tegra

# ============================================================================
# 十、Recovery
# ============================================================================
TARGET_RECOVERY_FSTAB := device/nvidia/ardbeg/initfiles/fstab.ardbeg
TARGET_RECOVERY_PIXEL_FORMAT := "RGBX_8888"
BOARD_HAS_NO_SELECT_BUTTON := true
# 原厂 recovery 走 SOS 分区，用音量键选择，不需要触摸
TARGET_RECOVERY_LCD_BACKLIGHT_PATH := "/sys/class/backlight/pwm-backlight/brightness"

# ============================================================================
# 十一、OTA / 打包
# ============================================================================
# 让 OTA 脚本校验机型，防止刷错板子
TARGET_OTA_ASSERT_DEVICE := ardbeg,cm_ardbeg,tegra
# 本板没有 fastboot，只能 nvflash/卡刷；不生成 fastboot 专用的 bootloader 断言
TARGET_NO_RECOVERY := false

# ============================================================================
# 十二、cm-11 里有、7.1 里已删除/无意义的变量（记录在此，避免有人再加回来）
# ============================================================================
#   BOARD_SUPPORT_PARAGON_FUSE_UFSD   Paragon exFAT/NTFS 驱动，7.1 无对应实现
#   BOARD_BUILD_BOOTLOADER            4.4 时代 NVIDIA 私有 bootloader 编译
#   BOARD_HAVE_LBH_SUPPORT            LBH 分区，7.1 无
#   TARGET_QUICKBOOT / TARGET_BOOT_MEDIUM / TARGET_QB_FLASH_TOOL
#                                     Quickboot（伪关机快速启动），7.1 无
#   TARGET_KERNEL_VCM_BUILD           NVIDIA VCM 变体编译开关
#   SECURE_OS_BUILD / TARGET_USE_NCT  TLK 安全 OS 与 NCT 分区读取，
#                                     7.1 的 init 不解析 NCT（DTB 已包含板级信息）
#   BOARD_USES_CYANOGEN_HARDWARE      cm-11 的 CMHW 框架，14.1 改名 LineageHW
#   DALVIK_ENABLE_DYNAMIC_GC          ART 时代无意义
#   COMMON_GLOBAL_CFLAGS              4.4 全局 CFLAGS 机制，7.1 已移除
#   ZYGOTE_WHITELIST_PATH_EXTRA       4.4 zygote 白名单机制，7.1 已移除
#   BOARD_WIDEVINE_OEMCRYPTO_LEVEL    7.1 用 drm.service.enabled 属性控制
#   BOARD_CHARGER_STATIC_IMAGE        7.1 的 charger 用 healthd 默认实现
#   BOARD_HAS_NVDPS / BOARD_HAS_3DV_SUPPORT / BOARD_HDMI_MIRROR_MODE
#                                     显示相关，7.1 的 HWC1 blob 自己处理，
#                                     只有 HDMI_MIRROR_MODE 保留（见上）

# ============================================================================
# 十三、ramdisk 的 default.prop 追加项（2026-11-06 新增）
# ============================================================================
#
# 【这个变量是什么】
#   system/core/rootdir/Android.mk 里有一条规则：
#       $(TARGET_ROOT_OUT)/default.prop:
#           echo "#" > $@
#           echo "# ADDITIONAL_DEFAULT_PROPERTIES" >> $@
#           $(foreach line,$(ADDITIONAL_DEFAULT_PROPERTIES), echo "$(line)" >> $@;)
#   也就是说这里列出的每一行都会原样写进 **ramdisk 的 /default.prop**。
#
# 【为什么 ro.logd.size 必须放在这里，不能放 /system/build.prop】
#   7.1 的 logd 是 class core 服务，在 `on init` 阶段就被拉起来了，
#   那时 /system 还没 mount（/system 要等 on fs 的 mount_all），
#   build.prop 根本还没被读进来。属性服务此时能看到的只有：
#       /default.prop  +  /system/build.prop 之外的内置默认值
#   所以只有写进 default.prop，logd 启动时才能读到正确的 buffer 大小。
#
# 【为什么要加大到 4MB】
#   7.1 的 logd 默认每个 buffer 只有 256KB（security buffer 64KB），
#   而本机最需要抓的正是「崩溃前几十秒」的日志：
#       * SurfaceFlinger 每 40~100 秒 SIGSEGV 一次（HWC 二次释放）
#       * system_server 起来后 DeadSystemException 秒退
#       * WebView RenderThread 在 gl_fence 失败后 abort
#   256KB 在开机刷屏阶段几秒就被冲掉了，抓不到现场。
#   4MB × 4 buffer（main/system/crash/events）= 16MB 内存，换来完整的
#   crash 上下文，配合 /system/etc/init/zz-persist-log.rc 落盘到
#   /cache/persist_log.txt。
#
# 【属性名规则】（system/core/logd/LogBuffer.cpp GetBufferSize）
#       ro.logd.size.<buffer>   优先（例如 ro.logd.size.crash）
#       ro.logd.size            其次   <- 这里用这个，对所有 buffer 生效
#       都没有则回落到 256KB / security 64KB
#
# 【验证】
#   开机后 logcat -g 应该看到：
#       main: ring buffer is 4Mb ...
#       system: ring buffer is 4Mb ...
#       crash: ring buffer is 4Mb ...
#   实测已通过。
# ============================================================================
ADDITIONAL_DEFAULT_PROPERTIES += ro.logd.size=4194304

# ============================================================================
# 十四、本机构建环境适配（2026-11-08 新增）
# ============================================================================
#
# 【这个开关干什么】
#   build/core/config.mk 第 527 行本来就有：
#       ifeq ($(USE_HOST_LEX),yes)
#         LEX := flex
#       else
#         LEX := prebuilts/misc/$(BUILD_OS)-$(HOST_PREBUILT_ARCH)/flex/flex-2.5.39
#       endif
#   置 yes 之后，build 系统不再用 prebuilts 里那个 2013 年的 flex 二进制，
#   改成从 PATH 里找 flex。vendorsetup.sh 把
#   device/nvidia/ardbeg/tools/hostbin 插到 PATH 最前面，里面就是包装脚本。
#
# 【为什么必须绕这一下】
#   预编译 flex 2.5.39 在本机 UTF-8 locale 下必崩：
#       loadlocale.c:130: _nl_intern_locale_data: Assertion ... failed
#       Aborted (core dumped)
#   而 prebuilts/ 属于源码树，直接换掉二进制会让 repo sync / git checkout
#   冲突。用这个开关 + 设备树内的包装脚本，源码树零改动。
#
# 【bison 为什么不能用同样的办法】
#   config.mk 里也有 USE_HOST_BISON，但它指向 $(HOST_OUT_EXECUTABLES)/bison
#   （out/ 目录下），要先由 external/bison 编出来；而 ninja 不会把这个文件
#   当依赖，首次构建直接 "No such file or directory"。所以 bison 只能沿用
#   prebuilts 内的包装脚本（由 patches/env-fix/fix-source-tree.sh 生成），
#   那是本项目唯一需要碰源码树的地方。
USE_HOST_LEX := yes

# ----------------------------------------------------------------------------
# Jack：保留编译器，只关掉常驻 server
# ----------------------------------------------------------------------------
# 【症状】
#   build/core/ninja.mk 里的 "Ensure Jack server is installed and started"
#   这一步会用 prebuilts/sdk/tools/jack-admin 起一个本地 HTTPS 服务，之后
#   jack 客户端再通过 TLS 连上去提交编译任务。本机 jack server 1.3-a8 是
#   Java 8 的 SSLEngine 实现：JackHttpServer.configureSocket() 先把可用套件
#   过滤成只剩 TLS_(DHE)|(EDH).*，再 setNeedClientAuth(true)，与较新的 JDK
#   握手时服务端直接断开。服务端日志是：
#       No available cipher suite for TLS13/TLS12
#   客户端看到的是：
#       SSL error when connecting to the Jack server. Try 'jack-diagnose'
#       Communication error with Jack server (35)
#
# 【已排除】
#   证书 CN 不符（curl -k 无效）、强制降级 TLSv1.2、删掉 ~/.jack-server 重新
#   install-server、-Djdk.tls.disabledAlgorithms=、换 Temurin 8u312 —— 全部
#   无效。说明不是证书校验问题，而是套件协商阶段就没有交集。
#
# 【做法】关掉 server，不关编译器
#   prebuilts/sdk/tools/jack 脚本第 74 行本来就有"无 server 模式"：
#       if [ "$JACK_SERVER" != "true" ]; then
#           exec $JACK_MAIN_COMMAND -jar $JACK_REPOSITORY/jack-$JACK_VERSION.jar "$@"
#   JACK_SERVER=false 时直接起一个 JVM 跑编译器 jar，全程不监听、不连接任何
#   socket，TLS 问题自然不存在。jack_server_setup.mk 里也有对应开关
#   （JACK_SERVER != true 时 jack_server_disabled=true，整条 setup-jack-server
#   配方变空），所以 "Ensure Jack server ..." 那一步会自动消失，不用改 ninja.mk。
#
#   JACK_REPOSITORY 要指向 prebuilts/sdk/tools/jacks（那里有
#   jack-3.36.CANDIDATE.jar，正好等于 jack_versions.mk 里的
#   JACK_DOGFOOD_VERSION）。这两个变量都由 vendorsetup.sh 导出到环境，
#   这里再声明一次是为了让本文件自解释、也方便单独检查。
#
# 【为什么不能退回 javac + dx】
#   两条路都试过，都不通：
#     1) 直接关 Jack 走 dx —— dx 的类文件解析器只认到 class 51，而
#        build/core/java_common.mk 在 LOCAL_SDK_VERSION 为空时默认给
#        -target 1.8（class 52），所有没写 LOCAL_SDK_VERSION 的模块都在
#        "target Dex" 这一步炸：
#            PARSE ERROR: unsupported class file version 52.0
#        （实测 BasicDreams / InputDevices / ExtShared 三个）
#     2) 把默认语言级别压到 1.7 迁就 dx —— frameworks/base 用了 Java 8 的
#        默认方法（android.media.AudioRouting.OnRoutingChangedListener），
#        javac 直接报 18 个错：
#            -source 1.7 中不支持默认方法
#   也就是说这棵树的框架代码本来就依赖 Jack 的 desugar，Jack 编译器不能丢。
#
# 【代价】没有常驻 server，每个模块编译都要冷启一次 JVM，整体比 server 模式
#   慢一些；换来的是不依赖任何本地服务、结果可复现。
JACK_SERVER := false
