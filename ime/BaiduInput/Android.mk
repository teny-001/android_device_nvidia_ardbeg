# ============================================================================
# ime/BaiduInput/Android.mk —— 原厂百度输入法（com.baidu.input_baidutv）预编译模块
# ============================================================================
# 【想直接拿一个 APK 装，不想刷机？】
#   本目录的 BaiduInput.apk 是自包含的（4 个 armeabi 库都在包里），
#   直接 adb install 就能用，**不需要准备任何 lib 目录**，
#   系统会自动把库抽到 /data/app/<pkg>/lib/arm/。
#   已经单独导出一份，连同安装步骤放在：
#       /home/dy/WorkBuddy AI/ardbeg-cm-14.1/BaiduInput/
#           ├── BaiduInput.apk
#           └── 安装说明.md
#   唯一前提是 dalvik.vm.checkjni=false（见下面【一】）。
#
#   三种安装形态（data app / 目录式系统应用 / 扁平系统应用）都实测通过，
#   各自的原生库路径对照表见上面那份 安装说明.md。
#   本 Android.mk 用的是「目录式系统应用」，因为它是唯一能让
#   BUILD_PREBUILT 把库和 APK 一起管起来的形态。
#
# 【本目录的来历】
#   这里的 BaiduInput.apk 不是从网上下载的，是从 g100 原厂 4.4.4 线刷包里
#   直接取出来的那个：
#       /home/dy/WorkBuddy AI/20260706-G100-tegraK1/system/app/BaiduInput.apk
#   包名 com.baidu.input_baidutv，versionName 4.0.8.9，TV 版百度输入法，
#   自带拼音全键 / 拼音九键 / 笔画键盘三套中文输入方案，以及中英文切换。
#
# 【为什么不用手搓的 ArdbegIME 就够了】
#   ../ime/ 下那个 ArdbegIME 是纯 ASCII 键盘，只能应急（比如输 WiFi 密码、
#   输网址）。它没有中文。原厂这个带完整中文词库，才是真正能用的输入法。
#
# ============================================================================
# 【一、这个包是"加固包"，7.1 上会崩，必须同时关 CheckJNI】
# ============================================================================
#   APK 里的 classes.dex 是被加固壳（爱加密那一类）处理过的：真正的业务
#   dex 加密存放，运行时解密后从 /data/data/<pkg>/files/inputcore_20130808
#   加载（这是个 352 KB 的 ELF，里面 93 个 Java_com_baidu_input_PlumCore_*
#   符号，就是拼音核心）。
#
#   问题出在 4 个 armeabi 库里的 libchiperencoder_v1_2.so：
#   它的 JNI_OnLoad 会 RegisterNatives 一张表，表里有一个方法叫
#       nativeChiperGetVersion()I
#   但是 APK 的 classes.dex 里，类 Lcom/baidu/util/ChiperEncrypt; 的
#   direct methods 只有 11 个，**没有** nativeChiperGetVersion
#   （只有名字很像的 nativeB64GetVersion）。实测：
#       # 在 dex 里搜这个字符串，出现 0 次
#       nativeChiperGetVersion -> 0
#       nativeB64GetVersion    -> 1
#
#   Dalvik（4.4.4）遇到 RegisterNatives 表里有、Java 类里没有的方法，
#   是**静默跳过**的，所以原厂系统上一直没事。
#   ART 不是 —— art/runtime/jni_internal.cc:2313-2321 无条件执行：
#       LOG(ERROR) << "Failed to register native method " ...
#       ThrowNoSuchMethodError(soa, c, name, sig, "static or non-static");
#       return JNI_ERR;
#   于是留下一个 pending 的 NoSuchMethodError。
#
#   接下来 art/runtime/java_vm_ext.cc:867-880，JNI_OnLoad 返回后 ART
#   **只检查返回值，不检查 pending exception**，所以库算"加载成功"。
#   真正致命的是：库自己在 JNI_OnLoad 里继续调 NewGlobalRef，而 eng 版
#   默认开着 CheckJNI，CheckJNI 对"带 pending exception 调 JNI"是零容忍的，
#   直接 JavaVMExt::JniAbort -> LOG(FATAL)，进程 SIGABRT：
#       F art: JNI DETECTED ERROR IN APPLICATION:
#              JNI NewGlobalRef called with pending exception
#              java.lang.NoSuchMethodError: no static or non-static method
#              "Lcom/baidu/util/ChiperEncrypt;.nativeChiperGetVersion()I"
#       I ActivityManager: Process com.baidu.input_baidutv has died
#       W ActivityManager: Scheduling restart of crashed service ...ImeService
#   -> 输入法每秒死一次，永远起不来。
#
#   【修法】关掉 CheckJNI，让那个 pending exception 留在原地。
#   加固壳的入口 com.baidu.input.pub.h.s(Context) -> h.kn() 是包了
#   try/catch 的，异常被吞掉，ImeService.onCreate 继续往下走
#   （日志里能看到它紧接着走到 com.baidu.input.ime.ag.init 和 p.<init>）。
#   实测关掉后 "has died" 计数为 0，键盘正常弹出、拼音候选正常、能上屏。
#
#   具体开关在 system.prop（本设备树的 ../system.prop 末尾）：
#       dalvik.vm.checkjni=false
#   依据 art/runtime/AndroidRuntime.cpp:637-653：
#       property_get("dalvik.vm.checkjni", propBuf, "");
#       if (strcmp(propBuf, "true") == 0) {
#           checkJni = true;
#       } else if (strcmp(propBuf, "false") != 0) {
#           // 只有"既不是 true 也不是 false"才回落到内核参数
#           property_get("ro.kernel.android.checkjni", propBuf, "");
#           if (propBuf[0] == '1') checkJni = true;
#       }
#   eng 版由 build/core/main.mk:383 自动注入 ro.kernel.android.checkjni=1，
#   所以必须显式写 dalvik.vm.checkjni=false 才能盖掉它。
#
#   顺带的好处：这套 ROM 是给 2014 年的 4.4 设备跑的，很多老应用都像这个
#   加固壳一样在 JNI 上不干净，关掉 CheckJNI 对整机兼容性都有利。
#   代价是 native 层的 JNI 错误不再立刻 abort，排查 native 问题时要自己
#   手动 setprop dalvik.vm.checkjni true 再复现。
#
# ============================================================================
# 【二、原生库必须落到 <codePath>/lib/arm/，这是踩过的坑】
# ============================================================================
#   一开始只把 APK push 到 /system/app/BaiduInput/，logcat 报：
#       W System: ClassLoader referenced unknown path: /system/app/BaiduInput/lib/arm
#       E art   : No implementation found for boolean
#                 com.baidu.util.ChiperEncrypt.nativeChiperInit()
#   也就是库根本没被找到。
#
#   目录名是 lib/arm 而**不是** lib/armeabi，这点很容易搞错：
#   PackageManager 给的 legacyNativeLibraryDir 是 /system/app/BaiduInput/lib
#   （见 dumpsys package 输出），真正拼出来的 nativeLibraryDir 是
#   <codePath>/lib/<isa>，而 armeabi 这个 ABI 对应的 isa 名字就是 "arm"
#   （VMRuntime.getInstructionSet("armeabi") -> "arm"）。
#   注意区分：/data/app/<pkg>/lib/arm/ 里的 arm 也是 isa，
#   但 APK 内部的目录名是 lib/armeabi/ —— 两套命名不一样。
#
#   构建系统这边正好对得上，见
#   build/core/install_jni_libs_internal.mk:21：
#       my_app_lib_path := $(dir $(LOCAL_INSTALLED_MODULE))lib/$(TARGET_ARCH)
#   本机 TARGET_ARCH=arm，所以 LOCAL_PREBUILT_JNI_LIBS 会被装到
#   <LOCAL_MODULE_PATH>/lib/arm/。
#
#   注意**不能**用 "@lib/armeabi/xxx.so" 这种带 @ 的写法。@ 的含义是
#   "这个 .so 在 APK 里面"，构建系统只会把它在 APK 内重新压成 STORED
#   （见 build/core/definitions.mk:2540 uncompress-shared-libs），
#   **不会**额外生成 lib/arm 目录。要生成独立文件必须给源树相对路径，
#   走 install_jni_libs_internal.mk:86-97 的 copy-one-file 分支。
#
# ============================================================================
# 【三、LOCAL_MODULE_PATH 必须带目录名】
# ============================================================================
#   如果写成 LOCAL_MODULE_PATH := $(TARGET_OUT_APPS)，APK 会被装成扁平的
#   /system/app/BaiduInput.apk。这时 codePath 就是这个 .apk 文件本身，
#   PM 会把 nativeLibraryDir 设成 /system/lib，我们准备的
#   lib/arm 目录压根不会被看。
#   所以必须写成 $(TARGET_OUT_APPS)/BaiduInput，让 APK 进自己的目录：
#       /system/app/BaiduInput/BaiduInput.apk
#       /system/app/BaiduInput/lib/arm/*.so
#   这才是 PM 认的"目录式系统应用"布局。
#
# ============================================================================
# 【四、其它几个字段为什么这么写】
# ============================================================================
#   LOCAL_CERTIFICATE := PRESIGNED
#       原厂包是百度自己签的，我们**没有**也**不能**重签（加固壳会校验
#       自己的签名，重签必然启动失败）。所以必须原样保留签名。
#       附带后果：PRESIGNED 的包不能 adb install 到 /data，会报
#       INSTALL_FAILED_INVALID_INSTALL_LOCATION: Cannot install platform
#       packages to user storage! —— 只能进 /system。
#
#   LOCAL_DEX_PREOPT := false
#       加固过的 dex 交给 dex2oat 处理没意义（真正代码是运行时解密的），
#       而且 AOT 编译这个壳 dex 只会多一个出错环节。关掉，走 JIT。
#
#   LOCAL_MODULE_TAGS := optional
#       不参与 eng/userdebug 的差异打包，任何 variant 都装。
#
# ============================================================================
# 【五、怎么验证装好了】
# ============================================================================
#   刷完机后：
#       adb shell ime list -a -s
#           -> 应该能看到 com.baidu.input_baidutv/.ImeService
#       adb shell settings get secure default_input_method
#           -> com.baidu.input_baidutv/.ImeService
#       adb shell ls -l /system/app/BaiduInput/lib/arm/
#           -> 4 个 .so
#       adb shell getprop dalvik.vm.checkjni
#           -> false
#   然后进 设置 -> WLAN -> 添加网络，点 SSID 输入框，键盘应该弹出来，
#   打 nihao 应该出「你好」候选。
#
#   如果起不来，按顺序查：
#       adb logcat | grep -E "Chiper|JNI DETECTED|has died"
#           -> 有 JNI DETECTED 说明 checkjni 没关掉
#       adb shell dumpsys package com.baidu.input_baidutv | grep -iE "codePath|CpuAbi"
#           -> 确认 codePath=/system/app/BaiduInput、primaryCpuAbi=armeabi
#       adb shell ls /system/app/BaiduInput/lib/arm/
#           -> 目录名必须是 arm，不是 armeabi
# ============================================================================

LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

LOCAL_MODULE        := BaiduInput
LOCAL_MODULE_TAGS   := optional
LOCAL_MODULE_CLASS  := APPS
LOCAL_MODULE_SUFFIX := $(COMMON_ANDROID_PACKAGE_SUFFIX)
LOCAL_SRC_FILES     := BaiduInput.apk

# 原厂签名，绝不重签（加固壳会校验自己的签名）
LOCAL_CERTIFICATE   := PRESIGNED

# 加固 dex 不做 AOT
LOCAL_DEX_PREOPT    := false

# 必须带目录名，否则 APK 装成扁平文件，<codePath>/lib/arm 不存在。
# 详见上面【三】。
LOCAL_MODULE_PATH   := $(TARGET_OUT_APPS)/BaiduInput

# 4 个 armeabi 原生库。这里是**源树相对路径**（相对 LOCAL_PATH），
# 会被 build/core/install_jni_libs_internal.mk:86-97 逐个 copy 到
# <LOCAL_MODULE_PATH>/lib/arm/ 下。
# 千万不要写成 "@lib/armeabi/xxx.so"，那样只会重压 APK 内的条目，
# 不会产生独立的 lib/arm 目录。详见上面【二】。
LOCAL_PREBUILT_JNI_LIBS := \
    lib/armeabi/libchiperencoder_v1_2.so \
    lib/armeabi/librabjni-1.so \
    lib/armeabi/libshare_v2.so \
    lib/armeabi/libtmfe30.so

include $(BUILD_PREBUILT)
