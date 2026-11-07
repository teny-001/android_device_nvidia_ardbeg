#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mk_ramdisk4.py —— 以「设备上实际能启动的 ramdisk」为基底，只叠加本次 USB 修复

【为什么不能直接复用 work/ramdisk】
work/ramdisk 是从构建产物 dist/tv-1104-1728/boot.img 解出来的，而设备上
实际运行的是另一套 ramdisk（更早的构建）。两者除了我们关心的几个 rc 文件，
还有一批**关键二进制/策略文件不同**：

    init                  <- 二进制！版本不同
    sepolicy              <- 230437 字节(version 30) vs 96881 字节(version ≤28)
    file_contexts.bin     <- 147504 字节二进制 vs 11273 字节文本
    property_contexts
    init.environ.rc
    sbin/ueventd
    sbin/watchdogd

上一版直接用 work/ramdisk 打包，结果刷完重启直接进 TWRP，ramoops 里写着：

    SELinux:  policydb version 30 does not match my version range 15-28
    init: SELinux:  Could not load policy:  Invalid argument
    init: failed to load policy: Invalid argument
    init: Security failure; rebooting into recovery mode...

也就是 init 加载 sepolicy 失败后**主动**重启进 recovery。
所以必须以设备基线为基底，只改我们真正需要改的文件。
"""

import os
import shutil
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(BASE, 'work', 'ramdisk2')    # 设备实际运行的 ramdisk
DST = os.path.join(BASE, 'work', 'ramdisk4')    # 输出
REF = os.path.join(BASE, 'work', 'ramdisk')     # 已写好注释的那份（只取 MTP 规则段）

if not os.path.isdir(SRC):
    sys.exit('找不到 %s（先用 bootimg.py ramdisk-unpack 解设备基底的 boot）' % SRC)

if os.path.exists(DST):
    shutil.rmtree(DST)
shutil.copytree(SRC, DST, symlinks=True)
print('已复制基底 -> %s' % DST)


def read(p):
    return open(p, 'r', encoding='utf-8', errors='replace').read()


def write(p, s):
    open(p, 'w', encoding='utf-8').write(s)


# =============================================================================
# 1) init.usb.rc —— 插入 MTP / PTP 的 legacy 规则
#
# 规则文本直接从 work/ramdisk/init.usb.rc 里截取（那份已经写好了完整注释），
# 从 "[CM14.1-on-ardbeg 新增 2026-11-06] MTP / PTP" 那行开始，
# 到 "# USB accessory configuration" 之前结束。
# =============================================================================
ref_usb = read(os.path.join(REF, 'init.usb.rc'))
start_mark = '# [CM14.1-on-ardbeg 新增 2026-11-06] MTP / PTP 的 legacy(android_usb) 规则'
end_mark = '# USB accessory configuration'

i = ref_usb.index(start_mark)
j = ref_usb.index(end_mark, i)
# start_mark 所在行的上一行是 "# ====..." 分隔线，从那里开始截
line_start = ref_usb.rindex('\n', 0, i) + 1
block_start = ref_usb.rindex('\n', 0, line_start - 1) + 1
mtp_block = ref_usb[block_start:j].rstrip('\n')

p = os.path.join(DST, 'init.usb.rc')
s = read(p)
anchor = end_mark + '\non property:sys.usb.config=accessory && property:sys.usb.configfs=0'
if anchor not in s:
    sys.exit('init.usb.rc 里找不到 accessory 段锚点')
if start_mark in s:
    sys.exit('init.usb.rc 里已经有 MTP 段了，别重复插')
s = s.replace(anchor, mtp_block + '\n\n' + anchor, 1)
write(p, s)
print('init.usb.rc  : 已插入 MTP/PTP 规则 (%d 字节)' % len(mtp_block))


# =============================================================================
# 2) init.tegra.rc —— 三处改动
# =============================================================================
p = os.path.join(DST, 'init.tegra.rc')
s = read(p)

# ---- 2a) 停用 4.4.4 遗留的 service sdcard ----
old = ('service sdcard /system/bin/sdcard -u 1023 -g 1023 -l /data/media /mnt/shell/emulated\n'
       '    class late_start\n')
new = (
"""# =============================================================================
# [CM14.1-on-ardbeg 修复 2026-11-06] 停用 4.4.4 遗留的 sdcard 服务
#
# 原厂 4.4.4 的写法是:
#     service sdcard /system/bin/sdcard -u 1023 -g 1023 -l /data/media /mnt/shell/emulated
#
# 但 7.1 的 /system/bin/sdcard 已经换成了 FUSE 版本, 参数表完全不同:
#     usage: sdcard [OPTIONS] <source_path> <label>
#         -u: specify UID to run as
#         -g: specify GID to run as
#         -U: specify user ID that owns device
#         -m: source_path is multi-user
#         -w: runtime write mount has full write access
# 老的 -l 选项在新实现里根本不存在 (它已经被 -m 取代),
# 于是进程一启动就打印 usage 然后退出 -> init 判定服务退出 -> 5 秒后重启
# -> 再退 -> 无限循环。实测 dmesg:
#     init: Service 'sdcard' (pid xxxx) exited with status 1
#     每 5 秒一条, 每次开机白烧 CPU 和日志, 还会把 /cache 里的日志冲掉。
#
# 7.1 里 /storage/emulated 这套 FUSE 挂载是 **vold 自己 fork 出来的**,
# 跟这个 init 服务无关 (源码: system/vold/EmulatedVolume.cpp doMount() 里
# 直接 forkExecvp("/system/bin/sdcard", {-u 1023 -g 1023 -m -w 1023 ...}))。
# 所以直接注释掉这一整段即可, 不影响 /sdcard 访问。
# =============================================================================
#service sdcard /system/bin/sdcard -u 1023 -g 1023 -l /data/media /mnt/shell/emulated
#    class late_start
""")
if old not in s:
    sys.exit('init.tegra.rc 里找不到 service sdcard 段')
s = s.replace(old, new, 1)

# ---- 2b) boot_completed 里启动 usb_mtp_default ----
old2 = """on property:sys.boot_completed=1
    # 系统起来了，停掉 logcat，避免长期占用 /cache
    stop bootlog_logcat
    # 再打一份"完全启动后"的快照：此时音频 HAL 已加载，
    # tinymix 能列出真实控件值，dumpsys audio 能拿到 AudioFlinger 状态
    start bootlog_booted"""
new2 = old2 + """
    # [2026-11-06] 把 USB 切到 MTP+ADB。必须等 system_server 的 usb 服务
    # publish 之后才能调 binder，脚本内部会轮询等待。
    # 详见 /sbin/usb_mtp_default.sh 头部注释。
    start usb_mtp_default"""
if old2 not in s:
    sys.exit('init.tegra.rc 里找不到 boot_completed 段')
s = s.replace(old2, new2, 1)

# ---- 2c) 把末尾 "on boot / setprop sys.usb.config mtp,adb" 换成服务定义 ----
old3 = "on boot\n    setprop sys.usb.config mtp,adb\n"
new3 = (
"""#
# [2026-11-06 修订] 上面那个 "on boot / setprop sys.usb.config mtp,adb"
# 已经删除，改成「boot_completed 之后由 usb_mtp_default 服务通过 binder 切换」。
#
# 【为什么不再在 on boot 里 setprop】
# 1) 那个 setprop 本身是有效的（init.usb.rc 里已经补了 mtp,adb 的 legacy
#    规则，gadget 会被正确配成 MTP），但 system_server 起来后
#    UsbDeviceManager 构造时会把 persist.sys.usb.config 里的 mtp 强行删掉
#    （详见 /sbin/usb_mtp_default.sh 头部的注释，对应
#     UsbDeviceManager.java:358-367 那段 b/31814300 的临时补丁），
#    紧接着 setEnabledFunctions(null) 又把它打回 adb-only。
#    结果是开机过程中 USB 要重配两次（MTP -> adb -> 稍后再 MTP），
#    adb 通道会断两次，bringup 阶段很容易误判成"设备挂了"。
# 2) 只 setprop 的话 framework 的 mCurrentFunctions 还是 "adb"，
#    MtpService 不会启动，电脑上能看到 MTP 设备但点进去是空的
#    （MtpServer 没打开 /dev/mtp_usb）。
#
# 【现在的流程】
#   开机 -> on init 配 adb（状态稳定，framework 不会来重配）
#        -> sys.boot_completed=1 -> start usb_mtp_default
#        -> 脚本调 IUsbManager.setCurrentFunction("mtp,adb", true)
#        -> framework 自己走完状态机，MtpService 启动，MTP 可用
# ============================================================================

service usb_mtp_default /sbin/usb_mtp_default.sh
    class late_start
    user root
    group root system
    oneshot
    disabled
""")
if old3 not in s:
    sys.exit('init.tegra.rc 里找不到末尾的 on boot / setprop 段')
s = s.replace(old3, new3, 1)

write(p, s)
print('init.tegra.rc: sdcard 停用 / boot_completed 启动服务 / 服务定义 均已写入')


# =============================================================================
# 3) default.prop —— 加大 logd 环形缓冲
# =============================================================================
p = os.path.join(DST, 'default.prop')
s = read(p)
if 'ro.logd.size' in s:
    print('default.prop : 已有 ro.logd.size，跳过')
else:
    s = s.rstrip('\n') + """

#
# [CM14.1-on-ardbeg 新增 2026-11-06] 加大 logd 环形缓冲区
#
# 7.1 的 logd 默认每个 buffer 只有 256KB (security buffer 64KB),
# 而本机最需要抓的正是"崩溃前几十秒"的日志:
#     * SurfaceFlinger 每 40~100 秒 SIGSEGV 一次
#     * system_server 起来后 DeadSystemException 秒退
#     * WebView RenderThread 在 gl_fence 失败后 abort
# 256KB 在开机刷屏阶段几秒就被冲掉了, 抓不到现场。
#
# 这里设成 4MB/ buffer (main/system/crash/events 各 4MB, 合计 16MB 内存),
# 配合 /system/etc/init/zz-persist-log.rc 的落盘服务,
# 可以保证 crash 前后的完整上下文都留在 /cache/persist_log.txt 里。
#
# 属性名规则 (system/core/logd/LogBuffer.cpp GetBufferSize):
#     ro.logd.size.<buffer>  优先
#     ro.logd.size           其次   <- 这里用这个, 对所有 buffer 生效
#     都没有则回落到 256KB / 64KB
# 放在 default.prop 而不是 /system/build.prop, 是因为 logd 属于 class core,
# 在 on init 阶段就被拉起, 那时 /system 还没挂载, build.prop 还没被读进来。
ro.logd.size=4194304
"""
    write(p, s)
    print('default.prop : 已加 ro.logd.size=4194304')


# =============================================================================
# 5) init.nv_dev_board.usb.rc —— 注释掉原厂的 mtp/ptp/rndis property 段
#
# 【为什么必须注释】
# 这个文件是 init.tegra.rc:9 import 进来的，而 init.tegra.rc 又是
# init.rc:9 import 的；init.usb.rc 在 init.rc:8，**排在前面**。
# init 的 property 触发是"所有匹配的 action 都执行"，按 action 的加载顺序
# 依次跑 —— 也就是原厂这几段**排在我们的后面、最后执行、最后覆盖**。
#
# 原厂这几段写的是：
#     write .../idVendor  ${ro.nv.usb.vid}        # 值是字符串 "0x0955"
#     write .../idProduct ${ro.nv.usb.pid.mtp.adb} # 值是字符串 "0x701b"
# 而内核 DESCRIPTOR_ATTR(idVendor, "%04x\n") 的字段宽度是 4，
# sscanf 只吃掉 "0x70" 这种前 4 个字符：
#     0x0955 -> 0x09 -> 读回 "0009"
#     0x701b -> 0x70 -> 读回 "0070"
#
# 结果就是：我们的 init.usb.rc 明明写了 18d1:4ee2，
# 最终枚举出来的却是 **0009:0070** —— 一个根本不存在的 Vendor ID。
# Windows 不会给它加载标准 MTP 驱动，设备管理器里显示成未知设备，
# 用户看到的现象仍然是"插上没反应 / 没有盘符"。
#
# 实测（重启后）：
#     cat idVendor  -> 0009
#     cat idProduct -> 0070
#     cat iProduct  -> Tegra-Android
#
# 所以把原厂这 6 段（mtp / mtp,adb / rndis / rndis,adb / ptp / ptp,adb）
# 整体注释掉，让 init.usb.rc 里那套 18d1:4ee1/4ee2/4ee5/4ee6 成为唯一来源。
# 保留文件里 on boot 的描述符字符串（iSerial/iManufacturer/iProduct）。
# =============================================================================
p = os.path.join(DST, 'init.nv_dev_board.usb.rc')
s = read(p)

# ---- 5a) on boot 里的 "enable 0" 也要注释掉 ----
# 原厂依赖后面 setprop 触发再 enable 1；我们在 on init 就已经配好并 enable 1 了，
# 这里再 enable 0 会让开机后 USB 静默断开，直到 boot_completed 才恢复。
old_e = ("    # USB gadget\n"
         "    write /sys/class/android_usb/android0/enable 0\n")
new_e = (
"""    # USB gadget
    # [2026-11-06] 注释掉下面这行。这里 enable 0 会把 on init 已经配好并
    # enable 1 的 adb gadget 断开，而原厂是依赖后面的 setprop sys.usb.config
    # 再 enable 1 的。我们的流程里 on init 就配好了，这里再断开只会让
    # 开机后 USB 静默失联几十秒，直到 boot_completed 的 usb_mtp_default 才恢复。
    #write /sys/class/android_usb/android0/enable 0
""")
if old_e in s:
    s = s.replace(old_e, new_e, 1)
    print('init.nv_dev_board.usb.rc : 已注释 on boot 里的 enable 0')
else:
    print('init.nv_dev_board.usb.rc : 没找到 on boot 的 enable 0（可能已处理）')

# ---- 5b) 注释掉 6 个 property 段 ----
import re

BLOCK_HDR = (
"""# =============================================================================
# [CM14.1-on-ardbeg 修改 2026-11-06] 以下 6 段原厂 USB 配置已全部注释
#
# 原因见 tools/mk_ramdisk4.py 第 5 步的长注释，简单说：
#   1) 这个文件由 init.tegra.rc import，加载顺序排在 init.usb.rc **之后**，
#      同名的 property 触发会最后执行、最后覆盖我们写的 18d1:4ee2。
#   2) 原厂写的是 ${ro.nv.usb.vid}="0x0955" / ${ro.nv.usb.pid.*}="0x70xx"，
#      内核 sscanf("%04x") 只取前 4 字符，VID 被截成 0009、PID 被截成 0070，
#      枚举出来是个不存在的 Vendor ID，Windows 不会加载 MTP 驱动。
#   3) 统一改用 init.usb.rc 里那套 AOSP 标准 PID（18d1:4ee1/4ee2/4ee5/4ee6）。
#
# 保留的是本文件 on boot 段的描述符字符串（iSerial / iManufacturer / iProduct）
# 和 on post-fs 段的 functionfs 挂载（幂等，与 init.usb.rc 的 on init 重复也无害）。
# =============================================================================
""")

pat = re.compile(
    r'^on property:sys\.usb\.config=(?:mtp|mtp,adb|rndis|rndis,adb|ptp|ptp,adb)\n'
    r'(?:(?:[ \t].*)?\n)*',
    re.M)

found = pat.findall(s)
if not found:
    print('init.nv_dev_board.usb.rc : 没找到需要注释的 property 段')
else:
    def _comment(m):
        body = m.group(0).rstrip('\n')
        return ''.join('#' + ln if ln.strip() else ln for ln in body.splitlines(True)) + '\n'

    s = pat.sub(_comment, s)
    # 在第一个被注释的段前插入说明
    first = s.find('#on property:sys.usb.config=')
    if first > 0:
        s = s[:first] + BLOCK_HDR + '\n' + s[first:]
    write(p, s)
    print('init.nv_dev_board.usb.rc : 已注释 %d 个 property 段' % len(found))


# =============================================================================
# 6) /sbin/usb_mtp_default.sh
# =============================================================================
src_sh = os.path.join(REF, 'sbin', 'usb_mtp_default.sh')
dst_sh = os.path.join(DST, 'sbin', 'usb_mtp_default.sh')
shutil.copy2(src_sh, dst_sh)
os.chmod(dst_sh, 0o755)
print('sbin/usb_mtp_default.sh : 已复制并设为 0755')

# =============================================================================
# 7) fstab.ardbeg —— USB 存储（U 盘）的 vold 匹配路径
#
# 【原来写的是 /devices/platform/tegra-ehci.2，这个设备根本不存在】
#
# 本机实际控制器（ls /sys/devices/platform/）：
#     tegra-ehci.1  -> usb1        <- OTG / USB2.0 口，U 盘插这里
#     tegra-xhci    -> usb2, usb3  <- USB3.0 口
#     tegra-ehci.2  -> 不存在
#
# .2 这个条目是从 NVIDIA shield-common / CM11 设备树抄来的，那份设备树
# 对应另一块板子（有 3 个 EHCI 控制器）。g100 上只有 1 个。
#
# 【为什么写错就完全不工作 —— 这里和 AOSP 老版本不一样】
#
# system/vold/VolumeManager.h 的 DiskSource::matches()：
#     bool matches(const std::string& sysPath) {
#         return !fnmatch(mSysPattern.c_str(), sysPath.c_str(), 0);
#     }
#
# 用的是 fnmatch()，也就是 shell 通配符的**完整匹配**，不是 strncmp 前缀匹配。
# 实测 U 盘插入后内核给的 DEVPATH 是：
#     /devices/platform/tegra-ehci.1/usb1/1-1/1-1:1.0/host0/target0:0:0/0:0:0:0
#
# 不带 '*' 时 fnmatch 要求整串完全相等，永远不命中 ->
# mDiskSources 里没有一条匹配 -> 连日志都不打（不是报错，是压根没进分支）->
# dumpsys mount 里 Disks: 永远空的 -> /storage/usbdrive0 永远不出现。
#
# 所以必须写成带 '*' 的通配符形式。这也是 AOSP 所有设备 fstab 的写法：
#     hammerhead: /devices/platform/xhci-hcd.0.auto/usb1*
#     flo:        /devices/platform/xhci-hcd.0.auto*
# =============================================================================
p = os.path.join(DST, 'fstab.ardbeg')
if not os.path.exists(p):
    print('fstab.ardbeg : 不存在，跳过')
else:
    # ------------------------------------------------------------------
    # 【2026-11-06 改】优先直接用设备树里那份 fstab.ardbeg 覆盖 ramdisk。
    #
    # 原来的做法是"在 ramdisk 原有的 fstab 上做一次字符串替换"，
    # 问题有两个：
    #   1) 设备树那份（initfiles/fstab.ardbeg）带 55 行注释说明 fnmatch
    #      的坑，而 ramdisk 里的是无注释版，两边会长期漂移，
    #      以后谁改了设备树、忘了改 ramdisk，行为就对不上；
    #   2) 替换是字面匹配，fstab 一旦被重新排版（对齐空格变了）就失效，
    #      只能靠正则兜底，兜底失败还不报错。
    #
    # 改成"设备树是唯一真相源"：直接把设备树那份拷进 ramdisk。
    # 安全性已确认：system/core/fs_mgr/fs_mgr_fstab.c:283 和 314 都显式
    #     /* ignore comments or empty lines */
    #     if (*p == '#' || *p == '\0') continue;
    # 所以带 '#' 注释行和空行完全没问题。
    # ------------------------------------------------------------------
    DEV_FSTAB = ('/home/dy/aosp14/device/nvidia/ardbeg/initfiles/'
                 'fstab.ardbeg')
    if os.path.exists(DEV_FSTAB):
        src = read(DEV_FSTAB)
        write(p, src)
        print('fstab.ardbeg : 已用设备树版本覆盖（%d 字节，%d 行，含注释）'
              % (len(src.encode('utf-8')), src.count('\n')))
    else:
        print('fstab.ardbeg : 未找到设备树版本 %s，退回字符串替换' % DEV_FSTAB)
        s = read(p)
        OLD_LINE = ('/devices/platform/tegra-ehci.2                          '
                    'auto                auto      defaults'
                    '                                               voldmanaged=usbdrive:auto')
        NEW_LINE = ('/devices/platform/tegra-ehci*                          '
                    'auto                auto      defaults'
                    '                                               voldmanaged=usbdrive:auto')

        if NEW_LINE in s:
            print('fstab.ardbeg : 已经是通配符形式，跳过')
        elif OLD_LINE in s:
            s = s.replace(OLD_LINE, NEW_LINE, 1)
            write(p, s)
            print('fstab.ardbeg : tegra-ehci.2 -> tegra-ehci* （vold 用 fnmatch 匹配）')
        else:
            # 兜底：按前缀替换，容忍空白差异
            import re as _re
            new_s, n = _re.subn(r'/devices/platform/tegra-ehci(\.\d+)?(\s+)',
                                r'/devices/platform/tegra-ehci*\2', s, count=1)
            if n:
                write(p, new_s)
                print('fstab.ardbeg : 已按正则替换 tegra-ehci -> tegra-ehci*')
            else:
                print('fstab.ardbeg : 没找到 tegra-ehci 条目，请手工检查')


print('\n完成。下一步:')
print('  python3 tools/bootimg.py ramdisk-pack work/ramdisk4 work/boot/ramdisk.cpio.gz')
print('  python3 tools/bootimg.py pack work/boot work/boot.img')
