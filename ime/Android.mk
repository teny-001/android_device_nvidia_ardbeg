# ============================================================================
# ime/Android.mk —— ArdbegIME（轻量输入法）预编译模块
# ============================================================================
# 【为什么这个目录存在】
#   cm_ardbeg_tv 这个产品 inherit 的是 vendor/cm/config/common_full_tv.mk，
#   而 LineageOS 只把 LatinIME 放进下面四个配置：
#       common_full_phone.mk
#       common_mini_phone.mk
#       common_full_tablet_wifionly.mk
#       common_mini_tablet_wifionly.mk
#   TV 配置**没有**。所以整个 TV 版 ROM 一个输入法都没有：
#       # ime list -a -s
#       （空）
#   表现是「设置 → WLAN → 选热点 → 输入密码」时点输入框弹不出键盘，
#   WiFi 密码根本没法输。
#
# 【两条修法，这里两条都做了】
#   1. device.mk 第二十一节把 LatinIME 加回 PRODUCT_PACKAGES（正规、功能全）。
#   2. 本目录的 ArdbegIME 是一个手工打包的轻量键盘（10 KB），
#      不依赖构建系统就能产 APK，用来保证「即使 LatinIME 编不出来，
#      系统里也一定有能打字的输入法」。
#
#      如果确认 LatinIME 能正常编出来，把 device.mk 里
#      PRODUCT_PACKAGES 的 ArdbegIME 一行注释掉即可。
#
# 【为什么不直接 PRODUCT_COPY_FILES】
#   用 BUILD_PREBUILT 才能进 PRODUCT_PACKAGES，从而参与
#   dexpreopt / 安装清单校验；PRODUCT_COPY_FILES 只是裸拷贝，
#   PackageManager 扫到之前没有任何检查，出问题只能开机后看 logcat。
#
# 【LOCAL_CERTIFICATE := PRESIGNED 是必须的】
#   ArdbegIME.apk 已经用 build/target/product/security/platform.*
#   手工签过名。如果这里不写 PRESIGNED，构建系统会再签一次，
#   结果是双重签名 / 与手工签名不一致，安装时报
#       INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES
#
# 【LOCAL_DEX_PREOPT := false 的理由】
#   这个 APK 的 classes.dex 是手工用 prebuilts/sdk/tools/lib/dx.jar
#   生成的（Java 7 字节码）。dexpreopt 会在构建期再跑一次 dex2oat，
#   对这么小的模块没有收益，反而多一个可能出错的环节，
#   所以直接关掉，运行时靠 JIT。
#
# 【怎么重新生成 ArdbegIME.apk】
#   改完 src/ 或 res/ 后，在**宿主机**执行（容器里没有 java）：
#       flatpak-spawn --host bash \
#           "/home/dy/WorkBuddy AI/2026-10-23-16-34-21/aosp-src/device/nvidia/ardbeg/ime/build.sh"
#   build.sh 会输出到 ime/out/ArdbegIME.apk，把它拷回本目录覆盖即可。
#   注意 build.sh 里的路径变量是按本机目录写的，换机器要改。
# ============================================================================

LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

LOCAL_MODULE        := ArdbegIME
LOCAL_MODULE_TAGS   := optional
LOCAL_MODULE_CLASS  := APPS
LOCAL_MODULE_SUFFIX := $(COMMON_ANDROID_PACKAGE_SUFFIX)
LOCAL_SRC_FILES     := ArdbegIME.apk
LOCAL_CERTIFICATE   := PRESIGNED
LOCAL_DEX_PREOPT    := false

# 装到 /system/app/ArdbegIME/ArdbegIME.apk。
# 不用 LOCAL_PRIVILEGED_MODULE —— 输入法不需要 priv-app 的权限，
# 放在普通 app 目录更符合最小权限原则（它只申请 BIND_INPUT_METHOD，
# 那是由系统在绑定服务时校验的，与 priv-app 无关）。
LOCAL_MODULE_PATH   := $(TARGET_OUT_APPS)

include $(BUILD_PREBUILT)

# ============================================================================
# 【2026-11-06 新增】原厂百度输入法 com.baidu.input_baidutv
# ============================================================================
# 上面那个 ArdbegIME 是纯 ASCII 的应急键盘，没有中文。用户要求用原厂
# 4.4.4 线刷包里的那个输入法（带拼音全键/拼音九键/笔画键盘 + 中英切换）。
#
# 该包是加固包，在 ART 7.1 上会因 RegisterNatives 注册了一个 dex 里不存在
# 的方法（nativeChiperGetVersion）而触发 CheckJNI 致命中止，必须配合
# system.prop 里的 dalvik.vm.checkjni=false 才能跑起来。
# 完整的排查链、原生库路径（lib/arm 而不是 lib/armeabi）等细节，
# 全部写在 BaiduInput/Android.mk 的头部注释里，这里不重复。
#
# 两个输入法都装进 ROM 是刻意的：
#   - BaiduInput 是主力，中文输入靠它；
#   - ArdbegIME 是兜底，万一百度那个哪天因为某个系统改动又崩了，
#     还能在 设置 -> 语言和输入法 里切到 ArdbegIME 打字，不至于完全没法输入。
include $(ARDBEG_PATH)/ime/BaiduInput/Android.mk
