#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_flash_blocks.py —— 把全量 OTA 的 system.transfer.list 展开成设备侧 dd 脚本

【为什么要这个工具】

  本机的 TWRP 3.1.1 在 4.4.4 内核上 `framebuffer: 3 (0 x 0)`，UI 每 5 秒
  崩溃重启一次，两阶段 OpenRecoveryScript 的 `install /cache/xxx.zip` 常常
  根本走不到（wipe data 也会被截断）。但 recovery 的 kernel 与 adbd 是稳定的，
  所以「真机干净刷机实验」需要绕开 TWRP UI，直接在 recovery shell 里把
  system 分区按 OTA 块表写好。

  recovery 的 `block_image_update()` 就是逐条执行 transfer.list：
      new   <N>,<start>,<end>,... 从 system.new.dat **顺序**取数据写到目标块
      erase <N>,<start>,<end>,... 把目标块区间清零（不占 new.dat）
      zero  同 erase
  本脚本把这份块表翻译成 215 条设备侧 toybox `dd`，语义与之严格等价。

【最容易踩的坑：不能把 system.new.dat 直接 dd 到分区开头】

  otablocks.py pack 把 3 GiB raw ext4 镜像按 1024 块(4 MiB)分组：全零组用
  erase，非零组才进 new.dat。所以 new.dat 是**非零组的紧凑拼接**，目标块号
  是分散的（实测 0、12288、13312 … 753664），并不是「前 199680 块连续」。
  直接 `dd if=system.new.dat of=/dev/block/mmcblk0p10` 会把数据写到错误的
  块位置，ext4 的 group descriptor / inode table 全部对不上，必挂。
  早期 README 16.6 记过「连续写前 780MB」的绕行做法（当时那个包的底图
  恰好数据连续），**不能推广到所有包**。本工具按块表逐条写，不依赖这种巧合。

【为什么脚本放在 /tmp、数据从 /data 读】

  recovery 的 /tmp 是 1.9 GiB tmpfs，kernel 不重启就一直在（TWRP 只是主进程
  反复重启）；而 /data 有时需要手工 `mount -t ext4 /dev/block/mmcblk0p21 /data`
  才可见。所以脚本自己带挂载兜底，执行体放 /tmp，780 MiB 的 new.dat 留在
  /data 不必重复 push。

【2026-11-07 真机实测踩坑，四条都写在这里免得重犯】

  1. **必须前台执行**：`adb shell 'sh /tmp/flash_blocks.sh &'` 看着能返回，
     实际上 adb shell 会话一结束就把后台进程 SIGHUP 掉了，日志文件根本
     不会创建（实测空转 300 秒轮询全空）。正确写法：
         adb shell 'sh /tmp/flash_blocks.sh; echo SCRIPT_RC=$?'
     TWRP UI 因 `framebuffer 0x0` 反复重启，但 kernel / adbd 稳定，
     215 条 dd 前台跑完约 1 分钟，长会话撑得住。

  2. **toybox dd 的 skip 有 2^31 边界**：`bs=4096 skip=524288` 正好是
     2147483648 字节，读回来是**空数据**（md5 变成 d41d8cd9... 空串 md5），
     而且错误被 `2>/dev/null` 吞掉，看起来像「分区后半段全零」。
     所以校验分区一律用「不带 skip 的全量读取」，或把镜像落到文件再算。

  3. **recovery 没有 wc / grep / cut / head / md5sum**：PATH 只有
     /sbin:/system/bin 且 /system 未挂载；`/sbin/md5` 存在但**不接受 stdin**。
     完整性检查用 `set -- $(md5 "$DAT")` + shell 内建分词，全不依赖外部命令。

  4. **判「是否在 recovery」看 sys.boot_completed 是否为空**，不能看
     /system 是否 rw 挂载 —— TWRP 刷包也会 rw 挂 /system，会误拦。

【静态自检】

  生成后会把自己产出的 dd 命令反解析回来，与原始 transfer.list 逐条比对：
  区间覆盖 0..覆盖终点无重叠、new 的 skip 严格连续且总字节等于 new.dat
  大小、erase 的 seek/count 与块表一致。任何一条不符直接退出非零，
  绝不产出可疑脚本。`--verify` 可对已生成的脚本独立复验。

用法:
    gen_flash_blocks.py <system.transfer.list> <system.new.dat> <输出 .sh> \
                        [设备侧 new.dat 路径]
    gen_flash_blocks.py --verify <system.transfer.list> <待校验 .sh> <system.new.dat>

  第 4 个参数是**设备侧**路径（默认 /data/local/tmp/flash-exp/system.new.dat）。
  【坑】千万别把宿主路径写进 DAT：工作目录含空格，且设备上根本没有这个路径。
"""

import hashlib
import os
import sys

BLOCK = 4096


def file_md5(path):
    h = hashlib.md5()
    with open(path, 'rb') as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def parse_transfer_list(path):
    """返回 (version, total_blocks, [(op, [(start,end), ...]), ...])"""
    with open(path, 'r', encoding='utf-8') as f:
        lines = f.read().split('\n')
    ver = int(lines[0])
    total = int(lines[1])
    cmds = []
    for ln in lines[4:]:
        ln = ln.strip()
        if not ln:
            continue
        op, rest = ln.split(' ', 1)
        nums = [int(x) for x in rest.split(',')]
        # nums[0] 是后面数字的个数(2 × 区间数)，不是区间数
        assert nums[0] == len(nums) - 1, '区间数字个数不符: %s' % ln[:60]
        rng = [(nums[i], nums[i + 1]) for i in range(1, len(nums), 2)]
        cmds.append((op, rng))
    return ver, total, cmds


def build_commands(cmds):
    """把块表翻译成 dd 参数列表。每条 (kind, seek, count, skip)

    kind = 'zero' 写 /dev/zero；kind = 'new' 从 new.dat 的 skip 块取数据。
    """
    out = []
    dat_off = 0            # new.dat 内已消耗的块数
    n_new = n_zero = 0
    for op, rngs in cmds:
        for s, e in rngs:
            count = e - s
            if op in ('erase', 'zero'):
                out.append(('zero', s, count, 0))
                n_zero += count
            elif op == 'new':
                out.append(('new', s, count, dat_off))
                dat_off += count
                n_new += count
            else:
                raise SystemExit('未知命令 %s' % op)
    return out, n_new, n_zero


def self_check(cmds, ddcmds, dat_size):
    """反解析生成的 dd 命令，与原始块表逐条比对

    【坑】transfer.list 第 2 行不是分区块数。otablocks.py pack 写的是
    "预期写入的 new 块数"(199680)，recovery 只拿它判是否为 0。
    真正的覆盖终点必须取所有命令区间的 max(end)，本包是 786432 块
    = 3 GiB，正好是 ext4 文件系统大小（分区本身有 5.5 GiB）。
    """
    err = []
    expected_end = max(e for _op, rngs in cmds for _s, e in rngs)
    # 1) 顺序与数量：dd 命令必须严格等于块表展开后的区间序列
    expect, n_new, n_zero = build_commands(cmds)
    if len(ddcmds) != len(expect):
        err.append('命令条数 %d != 期望 %d' % (len(ddcmds), len(expect)))
    else:
        for i, (a, b) in enumerate(zip(ddcmds, expect)):
            if a != b:
                err.append('第 %d 条不符: %s != %s' % (i, a, b))
                break

    # 2) new 的 skip 必须严格连续，且总字节 == new.dat 实际大小
    off = 0
    for kind, seek, count, skip in ddcmds:
        if kind == 'new':
            if skip != off:
                err.append('new skip 不连续: %d != %d' % (skip, off))
                break
            off += count
    if off * BLOCK != dat_size:
        err.append('new.dat 消耗 %d 字节 != 实际 %d 字节'
                   % (off * BLOCK, dat_size))

    # 3) 所有区间必须落在 [0,total) 且互不重叠、无空洞
    spans = sorted((seek, seek + count) for _, seek, count, _ in ddcmds)
    cur = 0
    for s, e in spans:
        if s != cur:
            err.append('区间不连续/重叠: 期望起点 %d，实际 %d' % (cur, s))
            break
        cur = e
    if cur != expected_end:
        err.append('覆盖终点 %d != 块表最大区间端 %d' % (cur, expected_end))

    return err, len(ddcmds), n_new, n_zero, expected_end


def parse_generated(path):
    """从生成的 .sh 里读回 dd 行，做静态自检用"""
    res = []
    for ln in open(path, 'r', encoding='utf-8'):
        ln = ln.strip()
        if not ln.startswith('run_dd '):
            continue
        kv = dict(x.split('=', 1) for x in ln.split()[1:] if '=' in x)
        if kv.get('if', '').endswith('/dev/zero'):
            kind = 'zero'
        elif kv.get('if') == '$DAT':
            kind = 'new'
        else:
            raise SystemExit('无法识别的 dd 行: %s' % ln)
        res.append((kind, int(kv['seek']), int(kv['count']),
                    int(kv.get('skip', 0))))
    return res


HEADER = '''#!/system/bin/sh
# =====================================================================
# flash_blocks.sh —— 由 device/nvidia/ardbeg/tools/gen_flash_blocks.py 生成
#
# 语义等价于 recovery 的 block_image_update()：按 system.transfer.list
# 把 system.new.dat 的非零块写到 mmcblk0p10 的**指定块号**，并把块表
# 标为 erase/zero 的区间清零。**绝对不要**把 system.new.dat 直接 dd 到
# 分区开头 —— 它是非零 4 MiB 组的紧凑拼接，目标块号是分散的。
#
# 使用环境：recovery shell（TWRP UI 崩溃也能用，只要 adbd 活着）
#   执行体：/tmp/flash_blocks.sh（tmpfs，kernel 不重启就一直在）
#   数据：  %s
#   日志：  /tmp/flash_blocks.log
#
# 生成前已做静态自检：区间覆盖 0..%d 无重叠、new skip 严格连续、
# new.dat 消耗字节数与实际大小一致。
# =====================================================================

DEV=/dev/block/mmcblk0p10
DAT=%s
LOG=/tmp/flash_blocks.log

# 【坑】recovery 里 TWRP 不一定自动挂 /data；没挂就手工挂一次。
# 脚本本身放 /tmp，所以即使 /data 一开始不可见也能跑到这里。
if [ ! -f "$DAT" ]; then
    echo "mount /data ..." >> "$LOG"
    mount -t ext4 /dev/block/mmcblk0p21 /data 2>>"$LOG"
fi
if [ ! -f "$DAT" ]; then
    echo "FATAL: $DAT 不存在，/data 挂载失败" >> "$LOG"
    exit 1
fi
# 【坑】TWRP recovery 的 PATH 只有 /sbin:/system/bin，/system 又没挂载，
# 所以 wc / grep / cut / head / md5sum 全都不存在；只有 /sbin/md5，且它
# **只接受文件参数、不读 stdin**。用 shell 内建 set -- 分词取第一个字段，
# 整段校验不依赖任何外部命令，顺便把 780 MiB 数据的完整性也验了。
set -- $(md5 "$DAT")
DAT_MD5=$1
if [ "$DAT_MD5" != "%s" ]; then
    echo "FATAL: system.new.dat md5 $DAT_MD5 != %s" >> "$LOG"
    exit 1
fi
# 【坑】不能用「/system 是不是 rw 挂载」判断是否在 recovery：TWRP 刷包时
# 也会 rw 挂 /system。真正的区别是已启动的 Android 有 sys.boot_completed=1，
# 而 recovery 里为空。在跑着的 Android 里改写挂载中的 ext4 会让 page cache
# 与磁盘不一致，必须拒绝。
if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
    echo "FATAL: 当前是已启动的 Android 系统，拒绝刷写 system 分区" >> "$LOG"
    exit 1
fi

: > "$LOG"
echo "BLOCK-FLASH-START md5=$DAT_MD5 dev=$DEV" >> "$LOG"

# 统一封装：任何一条 dd 失败立刻停，避免半写状态被误判为刷完
run_dd() {
    dd "$@" 2>>"$LOG" || {
        echo "FATAL: dd 失败: $*" >> "$LOG"
        exit 1
    }
}

'''

FOOTER = '''
sync
echo "BLOCK-FLASH-DONE" >> "$LOG"
exit 0
'''


def main():
    args = sys.argv[1:]
    tl_path = args[0] if args[0] != '--verify' else args[1]

    ver, total, cmds = parse_transfer_list(tl_path)
    ddcmds, n_new, n_zero = build_commands(cmds)

    if args[0] == '--verify':
        if len(args) != 4:
            print(__doc__)
            return 2
        target = args[2]
        dat_size = os.path.getsize(args[3])
        got = parse_generated(target)
        err, n, nn, nz, cov = self_check(cmds, got, dat_size)
        print('静态自检（--verify）：transfer.list=%s  待校验=%s' %
              (tl_path, target))
        print('  dd 命令 %d 条 / new %d 块 / zero %d 块 / 覆盖终点 %d'
              % (n, nn, nz, cov))
        if err:
            for e in err:
                print('  [FAIL] %s' % e)
            return 1
        print('  全部一致：区间覆盖、new skip 连续性、new.dat 消耗字节')
        return 0

    if len(args) not in (3, 4):
        print(__doc__)
        return 2
    dat_path, out_path = args[1], args[2]
    dev_dat = (args[3] if len(args) == 4
               else '/data/local/tmp/flash-exp/system.new.dat')
    dat_size = os.path.getsize(dat_path)
    dat_md5 = file_md5(dat_path)

    err, n, nn, nz, cov = self_check(cmds, ddcmds, dat_size)
    if err:
        for e in err:
            print('[FAIL] %s' % e)
        return 1

    lines = [HEADER % (dev_dat, cov, dev_dat, dat_md5, dat_md5)]
    for i, (kind, seek, count, skip) in enumerate(ddcmds):
        if kind == 'zero':
            lines.append('run_dd if=/dev/zero of=$DEV bs=4096 seek=%d count=%d\n'
                         % (seek, count))
        else:
            lines.append('run_dd if=$DAT of=$DEV bs=4096 skip=%d seek=%d count=%d\n'
                         % (skip, seek, count))
        # 每 50 条打一次进度，便于宿主侧在 TWRP UI 反复重启时确认没卡死
        if (i + 1) % 50 == 0:
            lines.append('echo "progress %d/%d" >> "$LOG"\n' % (i + 1, n))
    lines.append(FOOTER)

    with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(''.join(lines))
    os.chmod(out_path, 0o755)

    got = parse_generated(out_path)
    err2, _, _, _, _ = self_check(cmds, got, dat_size)
    if err2:
        for e in err2:
            print('[FAIL] 产出脚本反解析不一致: %s' % e)
        return 1

    print('生成 %s' % out_path)
    print('  transfer.list version=%d  第2行(new 块数)=%d'
          % (ver, total))
    print('  覆盖终点 %d 块 (%.2f GiB) = ext4 文件系统大小'
          % (cov, cov * BLOCK / 1073741824.0))
    print('  dd 命令 %d 条：new %d 块 / zero %d 块' % (n, nn, nz))
    print('  new.dat %d 字节 / md5 %s，消耗 %d 字节，完全吻合'
          % (dat_size, dat_md5, nn * BLOCK))
    print('  脚本内完整性检查用 /sbin/md5 + shell 内建 set --（不依赖 wc/cut）')
    print('  静态自检（含产出脚本反解析）：全部一致')
    return 0


if __name__ == '__main__':
    sys.exit(main())
