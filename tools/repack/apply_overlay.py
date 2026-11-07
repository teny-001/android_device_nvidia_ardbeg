#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apply_overlay.py —— 把 overlay/ 目录里的改动写进 raw ext4 的 system 镜像

做法:
    不用 mount(容器里没有 CAP_SYS_ADMIN), 而是用 e2fsprogs 的 debugfs
    直接改镜像文件。debugfs 能在不挂载的前提下:
        rm / write / mkdir / sif(改 inode 字段) / ea_set(改扩展属性)
    正好覆盖我们的需求, 而且改完跑一遍 e2fsck -f 就能保证 fs 一致。

    SELinux 标签必须用 ea_set 单独补, 因为 debugfs 的 write 不带 xattr。
    本机是 androidboot.selinux=permissive, 标签错了不至于起不来,
    但打包出去还是要写对: 统一 u:object_r:system_file:s0
    (实测设备上这些文件的实际标签也都是它)。

注意路径: system 分区的根就是 /system, 所以 debugfs 里要写 /app/xxx,
        不能写 /system/app/xxx。
"""

import os
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OVL = os.path.join(BASE, 'overlay', 'system')

# 需要新建的目录(镜像里原本没有)
DIRS = [
    '/app/ArdbegIME',
    '/app/webview/lib',
    '/app/webview/lib/arm',
    '/lib/BaiduInput',
]

# (镜像内路径, overlay 下的相对路径, inode mode)
FILES = [
    # --- WebView: 119 -> 52, 并带一个打过 GPU 规避补丁的 .so ---
    ('/app/webview/webview.apk',
     'app/webview/webview.apk', 0o100644),
    ('/app/webview/lib/arm/libwebviewchromium.so',
     'app/webview/lib/arm/libwebviewchromium.so', 0o100644),

    # --- 输入法 ---
    ('/app/BaiduInput.apk', 'app/BaiduInput.apk', 0o100644),
    ('/lib/BaiduInput/libchiperencoder_v1_2.so',
     'lib/BaiduInput/BaiduInput/libchiperencoder_v1_2.so', 0o100644),
    ('/lib/BaiduInput/librabjni-1.so',
     'lib/BaiduInput/BaiduInput/librabjni-1.so', 0o100644),
    ('/lib/BaiduInput/libshare_v2.so',
     'lib/BaiduInput/BaiduInput/libshare_v2.so', 0o100644),
    ('/lib/BaiduInput/libtmfe30.so',
     'lib/BaiduInput/BaiduInput/libtmfe30.so', 0o100644),
    ('/app/ArdbegIME/ArdbegIME.apk',
     'app/ArdbegIME/ArdbegIME.apk', 0o100644),

    # --- 属性 / 音频策略 / 硬件声明 ---
    ('/build.prop', 'build.prop', 0o100644),
    ('/etc/audio_policy.conf', 'etc/audio_policy.conf', 0o100644),
    ('/etc/permissions/ardbeg_core_hardware.xml',
     'etc/permissions/ardbeg_core_hardware.xml', 0o100644),

    # --- init 服务定义 ---
    ('/etc/init/logd.rc', 'etc/init/logd.rc', 0o100644),
    ('/etc/init/surfaceflinger.rc', 'etc/init/surfaceflinger.rc', 0o100644),
    ('/etc/init/zz-persist-log.rc', 'etc/init/zz-persist-log.rc', 0o100644),
    ('/etc/init/zz-bootanim-fix.rc', 'etc/init/zz-bootanim-fix.rc', 0o100644),
    ('/etc/init/zz-sf-hwc-off.rc', 'etc/init/zz-sf-hwc-off.rc', 0o100644),
    ('/etc/init/zz-ardbeg-media-watchdog.rc',
     'etc/init/zz-ardbeg-media-watchdog.rc', 0o100644),

    # --- [2026-11-06 新增] U 盘可见化 + vold setexeccon 垫片 ---
    # zz-usb-storage-mount.rc : 服务名 usb_storage_mnt（15 字符，7.1 的 init
    #                           限制服务名 ≤16 字符，超了会静默丢弃）
    # usb_storage_mount.sh    : 轮询 /proc/mounts，发现 /mnt/media_rw/<UUID>
    #                           已挂但 /storage/<UUID> 缺失时，用
    #                           vdc volume mount <id> 2 0 带 VISIBLE 重挂
    # vold.rc                 : 原版 + setenv LD_PRELOAD libsetexeccon_shim.so
    #                           （SELinux Disabled 时 vold 调 blkid 会 abort，
    #                             垫片让它返回 0，绕开无限重启）
    # libsetexeccon_shim.so   : 上面那个垫片本体，只导出 setexeccon()->0
    ('/etc/init/zz-usb-storage-mount.rc',
     'etc/init/zz-usb-storage-mount.rc', 0o100644),
    ('/etc/init/vold.rc', 'etc/init/vold.rc', 0o100644),
    ('/lib/libsetexeccon_shim.so', 'lib/libsetexeccon_shim.so', 0o100644),

    # --- 运行时守护脚本 ---
    ('/bin/bootanim_killer.sh', 'bin/bootanim_killer.sh', 0o100755),
    ('/bin/sf_hwc_off.sh', 'bin/sf_hwc_off.sh', 0o100755),
    ('/bin/ardbeg_media_watchdog.sh', 'bin/ardbeg_media_watchdog.sh', 0o100755),
    ('/bin/usb_storage_mount.sh', 'bin/usb_storage_mount.sh', 0o100755),
    ('/bin/surfaceflinger.real', 'bin/surfaceflinger.real', 0o100755),
    ('/vendor/bin/powerservice', 'vendor/bin/powerservice', 0o100755),
    ('/vendor/bin/powerservice.real', 'vendor/bin/powerservice.real', 0o100755),

    # --- Settings: 二级菜单闪退修复(dex 补丁版) ---
    ('/priv-app/Settings/Settings.apk',
     'priv-app/Settings/Settings.apk', 0o100644),
]

LABEL = 'u:object_r:system_file:s0'


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(BASE, 'work', 'overlay.cmds')
    host_root = '/home/dy/wbrp'      # 宿主侧指向 repack 的无空格软链
    lines = []
    total = 0
    for d in DIRS:
        lines.append('mkdir %s' % d)
        lines.append('sif %s mode 040755' % d)
        lines.append('sif %s uid 0' % d)
        lines.append('sif %s gid 0' % d)
        lines.append('ea_set %s security.selinux %s' % (d, LABEL))
    for dest, rel, mode in FILES:
        src = os.path.join(OVL, rel)
        if not os.path.exists(src):
            raise SystemExit('缺文件: %s' % src)
        size = os.path.getsize(src)
        total += size
        lines.append('# %s  (%d 字节)' % (dest, size))
        lines.append('rm %s' % dest)
        lines.append('write %s/overlay/system/%s %s' % (host_root, rel, dest))
        lines.append('sif %s mode 0%o' % (dest, mode))
        lines.append('sif %s uid 0' % dest)
        lines.append('sif %s gid 0' % dest)
        lines.append('ea_set %s security.selinux %s' % (dest, LABEL))
    with open(out, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print('生成 debugfs 命令脚本 %s' % out)
    print('  目录 %d 个, 文件 %d 个, 合计 %.1f MB' %
          (len(DIRS), len(FILES), total / 1048576.0))


if __name__ == '__main__':
    main()
