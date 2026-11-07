#
# lineage_tv.mk — cm_ardbeg_tv 产品（Android TV 形态）
#
# 【为什么要单独一个产品文件，而不是在 lineage.mk 里加 if】
#   7.1 的 lunch 是按"产品"来选构建参数的，一个产品对应一个 PRODUCT_NAME。
#   用同一个产品名 + 环境变量切换形态，会导致 ccache/out 目录里
#   两种形态的中间产物互相污染（尤其是 PRODUCT_PACKAGES 不同的情况下，
#   system.img 会缺包但编译不报错）。
#   所以 TV 形态做成独立产品，out 目录天然隔离（out/target/product/ardbeg_tv）。
#
# 【和 cm-11 的 ardbeg_tv 目录的区别】
#   cm-11 时代为了绕开 build 系统的产品发现逻辑，额外建了
#   device/nvidia/ardbeg_tv/ 目录，里面只有一个 lineage.mk 转发到这里。
#   7.1 的 product_config.mk 会扫描 device/*/*/AndroidProducts.mk，
#   两个目录里如果都定义了 cm_ardbeg_tv，会报
#       Product "cm_ardbeg_tv" already defined
#   所以 7.1 版本删掉了 ardbeg_tv 目录，只保留这一个文件。
#

# TV 形态开关：device.mk 用它选择 device_atv.mk / device_tablet.mk
PRODUCT_IS_ATV := true
ALTERNATE_BUILD := true

# ---- 1) AOSP 基础 ----
$(call inherit-product, $(SRC_TARGET_DIR)/product/languages_full.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base.mk)

# ---- 2) LineageOS TV 公共部分 ----
# common_full_tv 会带上 TV 版 overlay（大焦点、无状态栏时钟等）和 AppDrawer。
# 【注意】完整的 Android TV 还需要 TvSettings / LeanbackLauncher，
#   它们在 device/google/atv 里，本源码树没有同步那个仓库。
#   所以这个 TV 版本是"TV 特性 + TV 外观"，不是 Google 认证的 ATV。
#   要变成真 ATV，需要把 device/google/atv 和 vendor/google/atv 加进本地 manifest。
$(call inherit-product, vendor/cm/config/common_full_tv.mk)

# ---- 3) 设备配置 ----
$(call inherit-product, device/nvidia/ardbeg/device.mk)

# ---- 4) 产品标识 ----
# PRODUCT_DEVICE 保持 ardbeg：out 目录会变成 out/target/product/ardbeg_tv，
# 但设备侧 ro.product.device 必须是 ardbeg，否则 HAL 和 init 找不到对应文件。
PRODUCT_DEVICE := ardbeg
PRODUCT_NAME := cm_ardbeg_tv
PRODUCT_BRAND := nvidia
PRODUCT_MODEL := ardbeg TV
PRODUCT_MANUFACTURER := NVIDIA
PRODUCT_CHARACTERISTICS := tv

# TV 形态的屏幕参数：1080p 电视，密度 320
PRODUCT_PROPERTY_OVERRIDES += \
    ro.sf.lcd_density=320 \
    persist.sys.ui.hw=0

# ============================================================================
# 【2026-11-06 深夜黑屏修复】为什么 persist.sys.ui.hw 必须从 1 改成 0
#
# 这个属性原先是 1，本意是「TV 盒子性能好，把所有 app 都开硬件加速」，
# 但在本机（g100 / ardbeg，预编译 4.4.4 Tegra K1 内核 + 原厂 NVIDIA GL 驱动）
# 上是致命的：
#
#   frameworks/base/core/java/android/view/Window.java:755
#       mHardwareAccelerated = hardwareAccelerated
#               || SystemProperties.getBoolean(PROPERTY_HARDWARE_UI, false);
#
#   它让**每一个** app 窗口都强制走 HWUI / RenderThread。而原厂 4.4.4 的
#   /system/vendor/lib/libEGL_tegra_impl.so 把 EGL display 状态放在线程局部
#   存储里（NvOsTlsGet / NvOsTlsAlloc），7.1 的 RenderThread 在另一个线程上
#   eglGetDisplay / eglInitialize，于是 eglChooseConfig 返回 EGL_BAD_DISPLAY。
#   实测 tombstone（tombstone_02）：
#       pid 9669 tid 10722 name RenderThread >>> com.cyanogenmod.trebuchet
#       Abort message: 'Failed to choose config, error = EGL_BAD_DISPLAY'
#       #06 libhwui.so ... #13 RenderThread::threadLoop
#   SystemUI / Trebuchet / Settings / Email 全部这样反复 SIGABRT。
#
# 连带后果（这才是用户看到的「黑屏」）：
#   SystemUI 一死 -> PhoneWindowManager.removeWindowLw()(3409-3435) 在状态栏
#   窗口被移除时调 mKeyguardDelegate.showScrim()；
#   KeyguardServiceDelegate.onScreenTurningOn()(290-303) 也会因为
#   mKeyguardService == null 打 "no keyguard service!" 并 showScrim()。
#   而 hideScrim() 只有两个入口：KeyguardShowDelegate.onDrawn()(100) 和
#   bindService() 返回 false 的分支(149)。keyguard 画不出来 -> onDrawn 永不
#   回调 -> KeyguardScrim 常驻，WMS 把 Launcher 判成 mViewVisibility=0x4 /
#   mObscured=true，logcat 刷 "Screen frozen ... due to KeyguardScrim"。
#
# 设成 0 之后 app 走 Skia CPU 渲染，不再创建 RenderThread；SurfaceFlinger
# 仍由 sf_hwc_off.sh 用 GLES 合成，画面正常。实测重启后：
#   KeyguardScrim mViewVisibility=0x8 (GONE)
#   dumpsys window policy: deviceHasKeyguard=false / showing=false
#   SystemUI 与 Trebuchet 不再崩
#
# 配套（在 zz-ardbeg-firstboot-fix.sh 里）：三个 animation_scale=0，
# 否则窗口淡入 layer 的 alpha 会卡在 0x00（SurfaceFlinger 里看不到内容）。
#
# 注：patches/frameworks/native/opengl/libs/EGL/egl_display.cpp.patch 是
# 这个 EGL TLS 问题的「正解」，源码已应用，但编译产物 libEGL.so 还没进
# 文件级重打包的 system.img（见 repack/tools/apply_overlay.py 的说明）。
# 在产物补上之前，必须用本属性绕开；将来恢复全量编译后可考虑改回 1。
# ============================================================================

# Leanback 特性声明（TV 应用靠它识别运行环境）
PRODUCT_COPY_FILES += \
    device/nvidia/ardbeg/permissions/android.software.leanback.xml:system/etc/permissions/android.software.leanback.xml

# 【TV 形态去电信用应用】
# 7.1 的 TV 配置本身不含电话应用，这里只是显式声明"不要电话特性"，
# 避免某些应用通过 PackageManager 探测到 FEATURE_TELEPHONY。
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.software.app_widgets.xml:system/etc/permissions/android.software.app_widgets.xml
