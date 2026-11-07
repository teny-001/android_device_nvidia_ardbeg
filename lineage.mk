#
# lineage.mk — cm_ardbeg 产品（平板/盒子通用形态）
#
# 继承顺序很重要（PRODUCT_* 变量是"后写覆盖先写"）：
#   1) AOSP 基础：languages_full + full_base
#   2) LineageOS 公共部分：common_full_tablet_wifionly
#   3) 设备配置：device/nvidia/ardbeg/device.mk
#   4) 产品标识（必须放在所有 inherit 之后，否则会被继承进来的值覆盖）
#

# ---- 1) AOSP 基础 ----
$(call inherit-product, $(SRC_TARGET_DIR)/product/languages_full.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base.mk)

# ---- 2) LineageOS 公共部分 ----
# 本机 WiFi-only、无基带，所以用 tablet_wifionly 而不是 full_phone。
# 【为什么不用 full_base_telephony】cm-11 版本继承的是 telephony 版本，
#   会拉进 RIL/Phone 全套。本机 ro.radio.noril、无 Modem，7.1 上
#   Phone 进程会因为找不到 RIL 而反复崩溃（com.android.phone 停止运行），
#   所以换成非 telephony 的 full_base。
$(call inherit-product, vendor/cm/config/common_full_tablet_wifionly.mk)

# ---- 3) 设备配置 ----
$(call inherit-product, device/nvidia/ardbeg/device.mk)

# ---- 4) 产品标识 ----
# PRODUCT_DEVICE 必须与以下三处一致，否则会出现"能开机但服务全无"：
#   - BoardConfig 的 TARGET_OTA_ASSERT_DEVICE
#   - init 的 androidboot.hardware=ardbeg（决定加载 /init.ardbeg.rc）
#   - HAL 加载器的 ro.hardware（决定加载 audio.primary.ardbeg.so）
PRODUCT_DEVICE := ardbeg
PRODUCT_NAME := cm_ardbeg
PRODUCT_BRAND := nvidia
PRODUCT_MODEL := ardbeg
PRODUCT_MANUFACTURER := NVIDIA
PRODUCT_CHARACTERISTICS := tablet

# 机型指纹。7.1 的 build/tools/buildinfo.sh 会拼出 ro.build.fingerprint，
# 这里显式指定 eng 指纹，方便在设备上确认刷的是自己编的包。
PRODUCT_BUILD_PROP_OVERRIDES += \
    PRODUCT_NAME=ardbeg \
    TARGET_DEVICE=ardbeg

# 声明 Leanback（部分 TV 应用会读），但产品特性仍是 tablet
PRODUCT_COPY_FILES += \
    device/nvidia/ardbeg/permissions/android.software.leanback.xml:system/etc/permissions/android.software.leanback.xml

# ============================================================================
# 【7.1 移除】cm-11 里的 filter-out 电话应用那段
# ============================================================================
# cm-11 的 lineage.mk 用
#     PRODUCT_PACKAGES := $(filter-out Dialer InCallUI Mms Stk ...,$(PRODUCT_PACKAGES))
# 把电话类应用剔掉。这段在 7.1 上**不能照搬**：
#   1) 7.1 的 common_full_tablet_wifionly.mk 本身就不含 Dialer/InCallUI/Mms
#      （那是 phone 产品才有的），filter-out 是空操作；
#   2) 更关键的是 `PRODUCT_PACKAGES := ...` 这种**赋值**会打断继承链。
#      7.1 的 inherit-product 在解析时把父产品的 PRODUCT_PACKAGES 展开，
#      这里用 := 重新赋值会把这些继承结果整体丢弃，
#      表现是 system.img 少一堆库、编译不报错、开机直接崩。
# 需要精简包时请用 overlay 或 PRODUCT_PACKAGES 增量控制，不要用 :=。
