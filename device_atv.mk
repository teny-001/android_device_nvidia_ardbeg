# A separate ALTERNATE_BUILD eng target presents Android's TV characteristics.
#
# ---------------------------------------------------------------------------
# 【2026-11-06 修复】补上 core hardware 特性声明
#
# 原来这个文件只有一行 PRODUCT_CHARACTERISTICS := tv，什么权限文件都不拷。
# 而平板分支 device_tablet.mk 是拷 handheld_core_hardware.xml +
# tablet_core_hardware.xml 的。结果 TV 版的 /system/etc/permissions/ 里
# 一个 core hardware 文件都没有，开机后 `pm list features` 只有 36 条。
#
# 直接后果（实测）：
#   1. 没有 android.software.backup  -> SystemServer 不启动
#      BackupManagerService -> ServiceManager 里没有 "backup" ->
#      「设置 → 备份和重置」进 PrivacySettingsActivity 时空指针闪退
#   2. 没有 android.hardware.bluetooth -> 不启动 BluetoothService ->
#      蓝牙开关无效（HAL 其实齐全，纯粹是特性位没声明）
#   3. 没有 android.software.print -> 不启动 PrintManagerService
#   4. 没有 android.software.device_admin -> 「安全 → 设备管理器」空指针
#
# 为什么不直接把 device_tablet.mk 那两行抄过来：
#   handheld_core_hardware.xml 声明了 camera / touchscreen / compass /
#   accelerometer / location，本机这些硬件要么没有要么驱动没通；
#   而且 leanback 要求设备无触摸屏，两边特性位互相打架。
#   所以单独写了 permissions/ardbeg_core_hardware.xml，只声明
#   「确实有」的硬件 + 「框架服务需要」的软件特性，逐条都带注释说明理由。
#
# 维护提醒：往 ardbeg_core_hardware.xml 里加/删特性后，必须重新编译
# system.img（或手动推到 /system/etc/permissions/ 再重启），
# PackageManager 只在开机时扫一次该目录。
# ---------------------------------------------------------------------------

PRODUCT_CHARACTERISTICS := tv

PRODUCT_COPY_FILES += \
    device/nvidia/ardbeg/permissions/ardbeg_core_hardware.xml:system/etc/permissions/ardbeg_core_hardware.xml
