#!/system/bin/sh
# =============================================================================
# [CM14.1-on-ardbeg 新增 2026-11-06] 让插入的 U 盘真正可见可用
#
# 【为什么需要这个脚本 —— 这是「U 盘识别不了」的最后一层根因】
#
# 前面几层修完之后，链路已经走到这一步（实测 dumpsys mount）：
#
#     DiskInfo{disk:8_0}: flags=USB size=15953035264 label=ADATA
#     VolumeInfo{public:8_1}: type=PUBLIC state=MOUNTED fsType=vfat
#                             path=/mnt/media_rw/94B5-BDEB
#
# 也就是 vold 已经把 U 盘挂上了，但挂在 /mnt/media_rw/<UUID>，
# 这个目录权限是 0700 root:root，普通应用根本进不去，
# 而且 /storage/ 下什么都没有 —— 文件管理器、设置里的存储都看不到 U 盘。
#
# 【根因在 framework，不在 vold】
#
# frameworks/base/services/core/java/com/android/server/MountService.java
# 的 onVolumeCreated() 里，对 TYPE_PUBLIC 只在这两种情况下给 VISIBLE 标志：
#
#     } else if (vol.type == VolumeInfo.TYPE_PUBLIC) {
#         // TODO: only look at first public partition
#         if (Objects.equals(StorageManager.UUID_PRIMARY_PHYSICAL, mPrimaryStorageUuid)
#                 && vol.disk.isDefaultPrimary()) {
#             vol.mountFlags |= VolumeInfo.MOUNT_FLAG_PRIMARY;
#             vol.mountFlags |= VolumeInfo.MOUNT_FLAG_VISIBLE;
#         }
#         // Adoptable public disks are visible to apps
#         if (vol.disk.isAdoptable()) {
#             vol.mountFlags |= VolumeInfo.MOUNT_FLAG_VISIBLE;
#         }
#         vol.mountUserId = mCurrentUserId;
#         mHandler.obtainMessage(H_VOLUME_MOUNT, vol).sendToTarget();
#
# 本机两个条件都不成立：
#   * dumpsys mount 里 "Primary storage UUID: null"
#     （不是 "primary_physical"，所以第一个 if 永远 false）
#   * fstab 里 U 盘没写 encryptable=userdata，isAdoptable() 也 false
#
# 于是 mountFlags=0，framework 发下去的就是：
#     {6 volume mount public:8_1 0 0}
#                              ^ 没有 VISIBLE(2)
#
# vold 的 PublicVolume::doMount() 拿到 flags=0 后：
#
#     if (!(getMountFlags() & MountFlags::kVisible)) {
#         // Not visible to apps, so no need to spin up FUSE
#         return OK;
#     }
#
# 直接 return —— 不 fork /system/bin/sdcard，不建 /storage/<UUID>，
# 不建 /mnt/runtime/{default,read,write}/<UUID>。
# 表现就是：dmesg 里 sd/scsi/usb-storage 全部正常，vold 也说 MOUNTED，
# 但用户界面上完全看不到 U 盘。
#
# 【这个脚本做什么】
# 轮询 /proc/mounts，发现 /mnt/media_rw/<UUID> 已经挂上但 /storage/<UUID>
# 还不存在时，用 vdc 重新 mount 一次，这次带上 VISIBLE(2) 标志：
#
#     vdc volume unmount public:8_1
#     vdc volume mount   public:8_1 2 0
#
# 第二条命令里的 2 就是 MountFlags::kVisible（VolumeBase.h:62  kVisible = 1 << 1）。
# 重新 mount 之后 vold 就会 fork sdcard，建出：
#     /dev/fuse on /storage/<UUID>                 type fuse
#     /dev/fuse on /mnt/runtime/default/<UUID>     type fuse
#     /dev/fuse on /mnt/runtime/read/<UUID>        type fuse
#     /dev/fuse on /mnt/runtime/write/<UUID>       type fuse
# 文件管理器里就能看到这个 U 盘了。
#
# 【为什么是轮询而不是监听 uevent】
# 用户态监听内核 block uevent 需要 NETLINK_KOBJECT_UEVENT socket，
# toybox 没有现成工具，init 也不支持 "on uevent" 触发。
# 3 秒一次的轮询代价可以忽略（一次 grep /proc/mounts + 最多一次 vdc 调用）。
#
# 【幂等性】
# 只处理「/mnt/media_rw/<UUID> 存在 且 /storage/<UUID> 不存在」的情况。
# 一旦挂好，/storage/<UUID> 出现，下一轮就跳过，不会反复 unmount/mount。
# 用户在设置里卸载 U 盘时 vold 会同时清掉两个挂载点，也不会被误 remount。
#
# 【长期正解】
# 改 MountService.onVolumeCreated()，在 TYPE_PUBLIC 分支里无条件加一行
#     vol.mountFlags |= VolumeInfo.MOUNT_FLAG_VISIBLE;
# 补丁已放在
#     device/nvidia/ardbeg/patches/frameworks/base/services/core/java/
#         com/android/server/MountService.java.patch
# 等下次全量编译（或重编 services.jar）后就可以撤掉这个脚本。
# =============================================================================

# 等 vold 起来再开始，避免开机早期空转
i=0
while [ $i -lt 60 ]; do
    if [ "$(getprop init.svc.vold)" = "running" ]; then
        break
    fi
    sleep 1
    i=$((i + 1))
done

while true; do
    # 从 /proc/mounts 里找出所有 /mnt/media_rw/<UUID> 的真实挂载
    # 只认 /dev/block/vold/public:X_Y 这种 vold 管理的 public volume
    for mnt in $(sed -n 's|^[^ ]* \(/mnt/media_rw/[^ ]*\) .*|\1|p' /proc/mounts 2>/dev/null); do
        uuid=$(basename "$mnt")

        # 已经可见了就不再折腾
        [ -e "/storage/$uuid" ] && continue

        # 取设备名，形如 /dev/block/vold/public:8_1
        dev=$(sed -n "s|^\([^ ]*\) $mnt .*|\1|p" /proc/mounts 2>/dev/null | head -1)
        case "$dev" in
            /dev/block/vold/public:*)
                vid="public:${dev##*public:}"
                ;;
            *)
                continue
                ;;
        esac

        log -t usb_storage_mount "remounting $vid ($uuid) with VISIBLE flag"

        vdc volume unmount "$vid" >/dev/null 2>&1
        sleep 1
        # 2 = MountFlags::kVisible (VolumeBase.h:62)
        vdc volume mount "$vid" 2 0 >/dev/null 2>&1

        # 等 FUSE 起来（PublicVolume::doMount 里是 50ms 一轮等设备号变化）
        j=0
        while [ $j -lt 20 ]; do
            [ -e "/storage/$uuid" ] && break
            sleep 0.2
            j=$((j + 1))
        done

        if [ -e "/storage/$uuid" ]; then
            log -t usb_storage_mount "$uuid is now visible at /storage/$uuid"
        else
            log -t usb_storage_mount "WARNING: $uuid still not visible"
        fi
    done

    sleep 3
done
