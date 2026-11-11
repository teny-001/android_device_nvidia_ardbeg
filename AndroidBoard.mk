LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

ALL_PREBUILT += $(INSTALLED_KERNEL_TARGET)

# ===========================================================================
# [ardbeg 移植补丁] 预编译内核模式下补一条 KERNEL_OBJ/usr 的空目录规则
#
# ---- 问题现象 ----
#   使用原厂 Android 4.4.4 预编译 kernel（TARGET_PREBUILT_KERNEL）编译时，
#   ninja 在很靠后的阶段报：
#       ninja: error: '/home/dy/out/.../obj/KERNEL_OBJ/usr', needed by
#       '.../obj/SHARED_LIBRARIES/libtinyalsa_intermediates/mixer.o',
#       missing and no known rule to make it
#
# ---- 根因 ----
#   1) AOSP 里有一批模块在自己的 Android.mk 中写死了：
#          LOCAL_ADDITIONAL_DEPENDENCIES := $(TARGET_OUT_INTERMEDIATES)/KERNEL_OBJ/usr
#      并且把 $(TARGET_OUT_INTERMEDIATES)/KERNEL_OBJ/usr/include 加进
#      LOCAL_C_INCLUDES，用来拿内核 uapi 头（linux/*、asm/*）。
#      典型模块：external/tinyalsa（libtinyalsa、tinymix、tinyplay、tinycap、
#      tinypcminfo）、hardware/libhardware/modules/usbaudio、
#      hardware/libhardware_legacy/audio、libaudioroute、libalsautils 等。
#      这些模块即使在 ardbeg 上用不到，也会被 bootanimation
#      （CM 的 bootanimation 链接 libtinyalsa 播开机音）和 systemimage 拖进来。
#
#   2) 这个目录的创建规则原本写在 AOSP 的 build/core/tasks/kernel.mk 里。
#      CM-14.1 把那个文件换成了 vendor/cm/build/tasks/kernel.mk，而新版只在
#          ifeq ($(FULL_KERNEL_BUILD),true)
#      分支里才定义 KERNEL_HEADERS_INSTALL := $(KERNEL_OUT)/usr 的生成规则
#      （见 vendor/cm/build/tasks/kernel.mk 中 KERNEL_HEADERS_INSTALL /
#      KERNEL_HEADERS_INSTALL_STAMP 两行）。
#      ardbeg 走的是 TARGET_PREBUILT_KERNEL 分支 → FULL_KERNEL_BUILD=false
#      → 这条规则根本没被定义 → ninja 认为该文件“无规则可生成”。
#
# ---- 处理方式 ----
#   显式给出一条“只建空目录”的规则。因为：
#     * 7.1 的 bionic 已经在 bionic/libc/kernel/uapi 提供了完整的
#       linux/*、asm/*、asm-generic/* 头文件，这些模块编译时并不需要
#       从内核源码 headers_install 出来的那份；
#     * 空目录存在即可让 ninja 的依赖满足，-I 指向不存在的子目录
#       gcc 也只是忽略，不会报错。
#   所以不需要真的跑 headers_install（那还需要完整内核源码，而 ardbeg 只有
#   原厂预编译内核镜像）。
#
#   注意：这里用 ifeq 把它限制在“有预编译内核”的情况下。将来如果改成
#   kernel/nvidia/ardbeg 源码编译，vendor/cm/build/tasks/kernel.mk 会自己
#   定义同名目标的规则，两处同时定义会触发 make 的
#   "overriding recipe for target" 警告，故必须互斥。
# ===========================================================================
ifneq ($(TARGET_PREBUILT_KERNEL),)
ARDBEG_KERNEL_HEADERS_STUB := $(TARGET_OUT_INTERMEDIATES)/KERNEL_OBJ/usr
$(ARDBEG_KERNEL_HEADERS_STUB):
	@echo "  [ardbeg] 预编译内核模式：创建空的内核头目录 $@"
	@mkdir -p $(ARDBEG_KERNEL_HEADERS_STUB)/include
endif

# ---------------------------------------------------------------------------
# [ardbeg 移植补丁] 原 cm-11 设备树在这里写的是：
#     -include vendor/nvidia/ardbeg/ardbge-vendor.mk
#   注意 ardbge 是拼写错误（应为 ardbeg），所以这一行在 cm-11 上其实一直是
#   个空操作（-include 找不到文件也不报错）。
#   cm-14.1 上 vendor 闭源包清单已经由 device.mk 的"产品继承"段统一继承：
#     $(call inherit-product, vendor/nvidia/ardbeg/ardbeg-vendor.mk)
#   如果在 AndroidBoard.mk 里再把拼写修正后 include 一次，同一个产品 mk 会被
#   继承两遍，PRODUCT_COPY_FILES 里每条 blob 都会重复一份，构建时刷出大量
#   "overriding commands for target ..." / "ignoring old commands" 警告，
#   严重的还会让 install 阶段互相覆盖。
#   所以这里直接删掉这行，只保留说明，避免后人“顺手把 typo 改对”踩坑。
# ---------------------------------------------------------------------------
