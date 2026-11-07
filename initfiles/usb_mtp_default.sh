#!/system/bin/sh
# =============================================================================
# [CM14.1-on-ardbeg 新增 2026-11-06] 开机后把 USB 切到「MTP + ADB」
#
# 【为什么需要这么个脚本，而不是改个属性了事】
# AOSP 7.1 的 UsbDeviceManager$UsbHandler 构造函数里有一段"临时兼容代码"
# （frameworks/base/services/usb/java/com/android/server/usb/UsbDeviceManager.java
#   第 358-367 行）：
#
#     /**
#      * Remove MTP from persistent config, to bring usb to a good state
#      * after fixes to b/31814300. This block can be removed after the update
#      */
#     String persisted = SystemProperties.get(USB_PERSISTENT_CONFIG_PROPERTY);
#     if (UsbManager.containsFunction(persisted, UsbManager.USB_FUNCTION_MTP)) {
#         SystemProperties.set(USB_PERSISTENT_CONFIG_PROPERTY,
#                 UsbManager.removeFunction(persisted, UsbManager.USB_FUNCTION_MTP));
#     }
#     setEnabledFunctions(null, false, false);
#
# 它会把 persist.sys.usb.config 里的 mtp **强行删掉**：
#     "mtp,adb"  ->  "adb"
# 紧接着 getDefaultFunctions() 读到的就是 "adb"（getDefaultFunctions 见
# 第 989-996 行：persist 为空才回落 "mtp"），于是 setEnabledFunctions(null)
# 把 USB 配成 adb-only。
#
# 也就是说：无论我们在 build.prop / default.prop / init.rc 里怎么写
# persist.sys.usb.config=mtp,adb，开机都会被这段代码吃掉，插上电脑永远只有 adb。
# 这是 7.1 上游的已知行为（b/31814300 那个"修好了就删"的补丁一直没删）。
#
# 【为什么只改 sysfs 的 functions 也不够】
# 手工 echo mtp,adb > /sys/class/android_usb/android0/functions 之后：
#     - 内核侧 mtp_bind_config 会成功，dmesg 能打出来
#     - state 变成 CONFIGURED，主机也能枚举到一个 MTP 设备
# 但是！MtpService 是由 UsbDeviceManager 在
#     UsbManager.containsFunction(mCurrentFunctions, USB_FUNCTION_MTP)
# 为真时才 startService 起来的。framework 的 mCurrentFunctions 还是 "adb"，
# 所以 MtpServer 永远不会打开 /dev/mtp_usb。
# 电脑上表现就是：设备出现了，点进去是空的、或者直接报"无法访问"。
#
# 【所以唯一不改 framework 的办法】
# 系统起来之后，通过 binder 直接调 IUsbManager.setCurrentFunction()，
# 让 framework 自己把状态机走一遍。这样：
#     mCurrentFunctions 变成 "mtp,adb"
#     -> setUsbConfig("none") 再 setUsbConfig("mtp,adb")
#     -> init.usb.rc 里新增的 mtp,adb 规则配好 gadget
#     -> waitForState 通过
#     -> startService(MtpService) 被调用
#     -> MtpServer 打开 /dev/mtp_usb，MTP 会话真正建立
#
# 【service call usb 16 是什么】
# frameworks/base/core/java/android/hardware/usb/IUsbManager.aidl 里
# 方法的 transaction code 按声明顺序从 1 开始编号：
#      1 getDeviceList             2 openDevice
#      3 getCurrentAccessory       4 openAccessory
#      5 setDevicePackage          6 setAccessoryPackage
#      7 hasDevicePermission       8 hasAccessoryPermission
#      9 requestDevicePermission  10 requestAccessoryPermission
#     11 grantDevicePermission    12 grantAccessoryPermission
#     13 hasDefaults              14 clearDefaults
#     15 isFunctionEnabled(String)
#     16 setCurrentFunction(String function, boolean usbDataUnlocked)   <-- 这个
#     17 allowUsbDebugging        18 denyUsbDebugging
#     19 clearUsbDebuggingKeys    20 getPorts
#     21 getPortStatus            22 setPortRoles
#
# 参数签名：s16 = UTF-16 字符串，i32 = 32 位整数。
# usbDataUnlocked 传 1，让 MTP 能直接访问已解锁的存储
# （否则 updateUsbNotification 会显示"仅充电"，
#   并且 MtpService 里 mUsbDataUnlocked 为 false 时不会导出存储卷）。
# =============================================================================

# ---- 等 system_server 的 usb 服务就绪 ----
# boot_completed 广播发出时 UsbService 通常已经 publish 了，
# 但这台机器 system_server 起来得慢（Zygote 冷启动 + 一堆 native 服务），
# 保守轮询，最多 20 秒。
i=0
while [ $i -lt 20 ]; do
    if service list 2>/dev/null | grep -q "usb: \[android.hardware.usb.IUsbManager\]"; then
        break
    fi
    sleep 1
    i=$((i + 1))
done

# ---- 已经在 mtp 模式就不折腾了 ----
# 避免无谓地 enable 0 -> enable 1 断一次 adb。
CUR=$(getprop sys.usb.config)
case "$CUR" in
    *mtp*) exit 0 ;;
esac

# ---- 切换 ----
#
# 【为什么这里只能传 "mtp"，不能传 "mtp,adb"】
# UsbService.setCurrentFunction() 会先过一道白名单
# （frameworks/base/services/usb/java/com/android/server/usb/UsbService.java:306-320）：
#
#     private static boolean isSupportedCurrentFunction(String function) {
#         if (function == null) return true;
#         switch (function) {
#             case UsbManager.USB_FUNCTION_NONE:          // "none"
#             case UsbManager.USB_FUNCTION_AUDIO_SOURCE:  // "audio_source"
#             case UsbManager.USB_FUNCTION_MIDI:          // "midi"
#             case UsbManager.USB_FUNCTION_MTP:           // "mtp"
#             case UsbManager.USB_FUNCTION_PTP:           // "ptp"
#             case UsbManager.USB_FUNCTION_RNDIS:         // "rndis"
#                 return true;
#         }
#         return false;
#     }
#
# 它只认**单个功能名**，不认 "mtp,adb" 这种逗号组合。
# 传组合进去会被改写成 "none"，然后 setEnabledFunctions("none") 又回落到
# getDefaultFunctions()（= persist 里的 "adb"），结果什么都没发生，
# 只留一条 logcat 警告：
#     W UsbService: Caller of setCurrentFunction() requested unsupported USB function: mtp,adb
#
# 这个坑很隐蔽：service call 的返回值是正常的 Parcel(0)（void 方法），
# 看起来调用成功了，但 USB 一点没变。
#
# 传 "mtp" 之后，UsbDeviceManager.trySetEnabledFunctions() 里的
# applyAdbFunction() 会自动把 adb 加回去（因为 mAdbEnabled 为 true，
# 它由 persist.sys.usb.config / ADB_ENABLED 决定），
# 最终下发的仍然是 "mtp,adb"。
service call usb 16 s16 "mtp" i32 1
