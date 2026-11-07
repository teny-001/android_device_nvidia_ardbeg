#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
otablocks.py —— 块级 OTA 镜像数据(system.new.dat + system.transfer.list) 的拆/合

背景:
    cm-14.1 生成的 OTA 不是文件级的, 而是块级:
        system.transfer.list   文本, 描述"往分区哪些块写什么"
        system.new.dat         二进制, 所有 new 命令的数据按顺序拼接
        system.patch.dat       增量包才有, 全量包是空文件
    恢复 recovery 里的 block_image_update() 就是按 transfer.list 逐条执行,
    new 命令从 new.dat 里顺序读对应块数的数据。

    所以想改镜像, 只要能把 new.dat 还原成 raw ext4, 改完再按同样的规则
    重新生成这一对文件即可, 完全不需要重新编译。

transfer.list 格式(version 4):
    第1行  版本号 4
    第2行  分区总块数
    第3行  next_stash_id       (全量包恒为 0)
    第4行  max_stashed_blocks  (全量包恒为 0)
    之后每行一条命令:
        erase <N>,<start>,<end>,...   把区间清零(区间是 左闭右开)
        new   <N>,<start>,<end>,...   从 new.dat 顺序取数据写入
        zero  <N>,<start>,<end>,...   把区间清零(但数据不占 new.dat)
    其中 N 是后面数字的**个数**(2 × 区间数), 不是区间数。
    对应源码: build/tools/releasetools/blockimgdiff.py
              RangeSet.to_string_raw() / WriteTransfers()
    注意 new/zero 每条最多 1024 块(blockimgdiff.py WriteSplitTransfers),
    拆成多条是为了避免单条 fsync 数据量过大。

用法:
    otablocks.py unpack <transfer.list> <new.dat> <输出 raw.img>
    otablocks.py pack   <raw.img> <输出前缀>
        产出 <前缀>.transfer.list 与 <前缀>.new.dat
"""

import os
import sys
import struct

BLOCK = 4096


def parse_ranges(nums):
    """[start,end,start,end...] -> [(start,end), ...]  (end 不含)"""
    return [(nums[i], nums[i + 1]) for i in range(0, len(nums), 2)]


def parse_transfer_list(path):
    lines = [l for l in open(path).read().split('\n')]
    ver = int(lines[0])
    total_blocks = int(lines[1])
    next_stash = int(lines[2]) if len(lines) > 2 and lines[2].strip() else 0
    max_stash = int(lines[3]) if len(lines) > 3 and lines[3].strip() else 0
    cmds = []
    for l in lines[4:]:
        l = l.strip()
        if not l:
            continue
        op, rest = l.split(' ', 1)
        nums = [int(x) for x in rest.split(',')]
        cnt = nums[0]
        rng = nums[1:]
        assert cnt == len(rng), '区间数字个数不符: %s' % l[:60]
        cmds.append((op, parse_ranges(rng)))
    return dict(ver=ver, total_blocks=total_blocks, next_stash=next_stash,
                max_stash=max_stash, cmds=cmds)


def unpack(tl_path, dat_path, out_img):
    t = parse_transfer_list(tl_path)
    print('版本 %d  分区 %d 块 (%.1f MB)' %
          (t['ver'], t['total_blocks'], t['total_blocks'] * BLOCK / 1048576.0))
    max_end = max(e for op, rng in t['cmds'] for s_, e in rng)
    print('实际分区末尾 = %d 块 (%.1f MB)' % (max_end, max_end * BLOCK / 1048576.0))
    stat = {}
    dat = open(dat_path, 'rb')
    out = open(out_img, 'wb')
    out.truncate(max_end * BLOCK)   # 先撑到分区大小
    zero = b'\0' * (1024 * BLOCK)
    for op, ranges in t['cmds']:
        stat[op] = stat.get(op, 0) + sum(e - s for s, e in ranges)
        if op in ('erase', 'zero'):
            for s, e in ranges:
                out.seek(s * BLOCK)
                left = (e - s) * BLOCK
                while left > 0:
                    n = min(left, len(zero))
                    out.write(zero[:n])
                    left -= n
        elif op == 'new':
            for s, e in ranges:
                out.seek(s * BLOCK)
                left = (e - s) * BLOCK
                while left > 0:
                    chunk = dat.read(min(left, 1 << 20))
                    if not chunk:
                        raise SystemExit('new.dat 数据不够了')
                    out.write(chunk)
                    left -= len(chunk)
        else:
            raise SystemExit('未知命令 %s' % op)
    left = dat.read(1)
    if left:
        print('警告: new.dat 还有剩余数据未使用')
    out.close()
    dat.close()
    for k, v in sorted(stat.items()):
        print('  %-6s %d 块 (%.1f MB)' % (k, v, v * BLOCK / 1048576.0))
    print('已还原 %s' % out_img)


def pack(img_path, prefix):
    """raw 镜像 -> transfer.list + new.dat

    全零的 1024 块段用 erase 命令(不占 new.dat, recovery 侧走 BLKDISCARD/写零,
    比一条条 new 写零快得多), 有数据的段用 new。
    相邻的全零段会合并成大区间, 但每条 erase 命令最多带 64 个区间,
    避免单行过长(原包是 19 个区间一条)。
    """
    size = os.path.getsize(img_path)
    blocks = (size + BLOCK - 1) // BLOCK
    f = open(img_path, 'rb')

    erase_ranges = []
    new_cmds = []
    n_new = 0
    n_erase = 0

    CHUNK = 1024
    for start in range(0, blocks, CHUNK):
        end = min(start + CHUNK, blocks)
        f.seek(start * BLOCK)
        data = f.read((end - start) * BLOCK)
        if not data:
            break
        if data.count(0) == len(data):
            # 与上一个全零区间相邻就合并
            if erase_ranges and erase_ranges[-1][1] == start:
                erase_ranges[-1] = (erase_ranges[-1][0], end)
            else:
                erase_ranges.append((start, end))
            n_erase += end - start
        else:
            new_cmds.append((start, end, data))
            n_new += end - start
    f.close()

    dat = open(prefix + '.new.dat', 'wb')
    for _, _, data in new_cmds:
        dat.write(data)
    dat.close()

    out = []
    MAXR = 64
    for i in range(0, len(erase_ranges), MAXR):
        part = erase_ranges[i:i + MAXR]
        flat = []
        for s_, e_ in part:
            flat += [s_, e_]
        out.append('erase %d,%s\n' % (len(flat), ','.join(str(x) for x in flat)))
    for s_, e_, _ in new_cmds:
        out.append('new 2,%d,%d\n' % (s_, e_))

    with open(prefix + '.transfer.list', 'w') as tl:
        tl.write('4\n')
        # 第 2 行是"预期写入的块数"(recovery 只拿它判 ==0), 用 new 的块数
        tl.write('%d\n' % n_new)
        tl.write('0\n')
        tl.write('0\n')
        tl.write(''.join(out))

    print('镜像 %d 块 (%.1f MB)' % (blocks, blocks * BLOCK / 1048576.0))
    print('  new   %d 块 (%.1f MB) -> new.dat' % (n_new, n_new * BLOCK / 1048576.0))
    print('  erase %d 块 (%.1f MB) 不占体积' % (n_erase, n_erase * BLOCK / 1048576.0))
    print('  命令 %d 条 (erase %d / new %d)' % (len(out), (len(erase_ranges) + MAXR - 1) // MAXR, len(new_cmds)))
    print('已写出 %s.transfer.list / %s.new.dat' % (prefix, prefix))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == 'unpack':
        unpack(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == 'pack':
        pack(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(1)
