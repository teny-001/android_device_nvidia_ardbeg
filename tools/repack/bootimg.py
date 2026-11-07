#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bootimg.py —— Android boot.img (header v0) 拆包 / 重打包

用法:
    bootimg.py unpack <boot.img> <输出目录>
    bootimg.py pack   <输出目录> <boot.img>

为什么自己写而不用 abootimg:
    本机(容器)里没有 abootimg / mkbootimg, 而 boot.img 的结构非常简单:
        [header 2048B] [kernel] [pad] [ramdisk] [pad] [second] [pad]
    page_size 从头部读出(本机 2048)。自己写能精确控制每一段的大小和填充,
    也能保证重打包后除 ramdisk 外的所有字节与原镜像完全一致。

ramdisk 格式:
    gzip 压缩的 cpio "newc" 归档。newc 每条记录 110 字节 ASCII 头 + 文件名 +
    数据, 全部 4 字节对齐。这里按原顺序、原 uid/gid/mode 原样重建。
"""

import os
import struct
import sys
import gzip
import io
import hashlib

BOOT_MAGIC = b'ANDROID!'


# ---------------------------------------------------------------- boot.img
def read_header(data):
    if data[:8] != BOOT_MAGIC:
        raise SystemExit('不是 Android boot image (magic 不符)')
    f = struct.unpack('<10I', data[8:48])
    keys = ['kernel_size', 'kernel_addr', 'ramdisk_size', 'ramdisk_addr',
            'second_size', 'second_addr', 'tags_addr', 'page_size',
            'header_version', 'os_version']
    hdr = dict(zip(keys, f))
    hdr['name'] = data[48:64]
    hdr['cmdline'] = data[64:64 + 512]
    hdr['id'] = data[576:576 + 32]
    hdr['extra_cmdline'] = data[608:608 + 1024]
    hdr['raw'] = data[:2048]
    return hdr


def page_align(n, page):
    return (n + page - 1) // page * page


def unpack(img, outdir):
    data = open(img, 'rb').read()
    h = read_header(data)
    page = h['page_size']
    off = page
    kernel = data[off:off + h['kernel_size']]
    off = page_align(off + h['kernel_size'], page)
    ramdisk = data[off:off + h['ramdisk_size']]
    off = page_align(off + h['ramdisk_size'], page)
    second = data[off:off + h['second_size']]

    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, 'kernel'), 'wb').write(kernel)
    open(os.path.join(outdir, 'ramdisk.cpio.gz'), 'wb').write(ramdisk)
    if second:
        open(os.path.join(outdir, 'second'), 'wb').write(second)
    # 保存头部原始字节, 重打包时直接复用 -> cmdline / 地址 / id 全部不变
    open(os.path.join(outdir, 'header.bin'), 'wb').write(h['raw'])
    print('kernel   %d 字节' % len(kernel))
    print('ramdisk  %d 字节' % len(ramdisk))
    print('second   %d 字节' % len(second))
    print('page     %d' % page)
    print('cmdline  %s' % h['cmdline'].rstrip(b'\0').decode('utf-8', 'replace'))
    return outdir


def pack(srcdir, img):
    hdr = open(os.path.join(srcdir, 'header.bin'), 'rb').read()
    h = read_header(hdr)
    page = h['page_size']
    kernel = open(os.path.join(srcdir, 'kernel'), 'rb').read()
    ramdisk = open(os.path.join(srcdir, 'ramdisk.cpio.gz'), 'rb').read()
    second = b''
    p2 = os.path.join(srcdir, 'second')
    if os.path.exists(p2):
        second = open(p2, 'rb').read()

    # 重写头部里的 size 字段, 其余字节原样保留
    hb = bytearray(hdr)
    struct.pack_into('<I', hb, 8, len(kernel))
    struct.pack_into('<I', hb, 16, len(ramdisk))
    struct.pack_into('<I', hb, 24, len(second))

    # ------------------------------------------------------------------
    # 重算 id[8] —— 这是"刷完重启直接掉进 TWRP recovery"的元凶
    #
    # Android boot header 的 id[8]（offset 576, 32 字节）是 mkbootimg
    # 用 SHA1 算出来的「kernel + ramdisk + second」摘要：
    #
    #     sha = sha1()
    #     sha.update(kernel); sha.update(pack('<I', len(kernel)))
    #     sha.update(ramdisk); sha.update(pack('<I', len(ramdisk)))
    #     sha.update(second); sha.update(pack('<I', len(second)))
    #     id[0:20] = sha.digest()
    #
    # 注意顺序是**先 update 内容、再 update 长度**（mkbootimg 的
    # update_sha() 就是这么写的）。
    #
    # 原厂 u-boot 会校验这个字段（Tegra 的 bootloader 比较严）。
    # 只要 ramdisk 一变、id 没跟着变，bootloader 就判定镜像损坏，
    # **静默回落到 recovery 分区** —— 表现是"刷完 reboot 直接进 TWRP"，
    # 而且 misc 分区是干净的（不是 boot-recovery 命令触发的），
    # 内核 dmesg 也看不到任何错误，极难往这个方向想。
    #
    # 实测对照：
    #   设备上能正常启动的 boot.img  -> id 与重算值一字不差
    #   只改 size 不改 id 的镜像     -> 两者对不上，进 recovery
    #
    # id[8] 后面的 12 字节（offset 596..608）是保留区，原厂镜像里也是 0，
    # 保持原值不动。
    # ------------------------------------------------------------------
    h = hashlib.sha1()
    h.update(kernel)
    h.update(struct.pack('<I', len(kernel)))
    h.update(ramdisk)
    h.update(struct.pack('<I', len(ramdisk)))
    h.update(second)
    h.update(struct.pack('<I', len(second)))
    hb[576:596] = h.digest()

    out = bytearray()
    out += bytes(hb) + b'\0' * (page - len(hb))
    out += kernel + b'\0' * (page_align(len(kernel), page) - len(kernel))
    out += ramdisk + b'\0' * (page_align(len(ramdisk), page) - len(ramdisk))
    if second:
        out += second + b'\0' * (page_align(len(second), page) - len(second))
    open(img, 'wb').write(bytes(out))
    print('已写出 %s (%d 字节)' % (img, len(out)))


# ---------------------------------------------------------------- cpio newc
def cpio_extract(gz_path, outdir):
    raw = gzip.open(gz_path, 'rb').read()
    os.makedirs(outdir, exist_ok=True)
    pos = 0
    entries = []
    while True:
        if raw[pos:pos + 6] not in (b'070701', b'070702'):
            raise SystemExit('cpio 魔数不对, offset=%d' % pos)
        hdr = raw[pos:pos + 110]
        fields = [int(hdr[6 + i * 8:6 + (i + 1) * 8], 16) for i in range(13)]
        (ino, mode, uid, gid, nlink, mtime, filesize,
         devmajor, devminor, rdevmajor, rdevminor, namesize, check) = fields
        pos += 110
        name = raw[pos:pos + namesize - 1].decode('utf-8', 'replace')
        pos += namesize
        pos = (pos + 3) // 4 * 4
        fdata = raw[pos:pos + filesize]
        pos += filesize
        pos = (pos + 3) // 4 * 4
        if name == 'TRAILER!!!':
            break
        entries.append(dict(name=name, mode=mode, uid=uid, gid=gid,
                            mtime=mtime, data=fdata, devmajor=devmajor,
                            devminor=devminor, rdevmajor=rdevmajor,
                            rdevminor=rdevminor, nlink=nlink))
        target = os.path.join(outdir, name.lstrip('/'))
        if mode & 0o170000 == 0o040000:      # 目录
            os.makedirs(target, exist_ok=True)
        elif mode & 0o170000 == 0o120000:    # 符号链接
            if os.path.lexists(target):
                os.unlink(target)
            os.symlink(fdata.decode(), target)
        else:
            os.makedirs(os.path.dirname(target) or outdir, exist_ok=True)
            with open(target, 'wb') as f:
                f.write(fdata)
            os.chmod(target, mode & 0o7777)
    open(os.path.join(outdir, '.cpio_order'), 'w').write(
        '\n'.join(e['name'] for e in entries))
    print('cpio 解出 %d 个条目' % len(entries))
    return entries


def cpio_pack(srcdir, gz_path):
    """按 .cpio_order 里记录的顺序重建 cpio, 保证 init 里的目录顺序不变"""
    order_file = os.path.join(srcdir, '.cpio_order')
    names = [n for n in open(order_file).read().split('\n') if n]

    # ---------------------------------------------------------------------
    # 兜底：.cpio_order 是解包时记录的原始条目清单，之后往 ramdisk 目录里
    # 新加的文件不在里面，按它打包会**静默丢掉**新文件。
    # 这个坑踩过一次：新增 /sbin/usb_mtp_default.sh 后打包，
    # 打印的还是"60 个条目"，刷进设备才发现脚本根本不存在。
    # 所以这里扫一遍目录，把漏掉的补到末尾（目录条目会自然排在文件前面
    # 因为 sorted 是字典序，'sbin' < 'sbin/xxx'）。
    # ---------------------------------------------------------------------
    listed = set(names)
    extra = []
    for root, dirs, files in os.walk(srcdir):
        rel_root = os.path.relpath(root, srcdir)
        for nm in list(dirs) + list(files):
            rel = nm if rel_root == '.' else os.path.join(rel_root, nm)
            if rel == '.cpio_order':
                continue
            if rel not in listed:
                extra.append(rel)
    if extra:
        print('警告: .cpio_order 漏了 %d 项, 自动追加: %s'
              % (len(extra), ', '.join(sorted(extra))))
        names = names + sorted(extra)

    def emit(name, mode, uid, gid, mtime, data, devmajor=0, devminor=0,
             rdevmajor=0, rdevminor=0, nlink=1):
        nb = name.encode() + b'\0'
        hdr = b'070701'
        for v in (0, mode, uid, gid, nlink, mtime, len(data),
                  devmajor, devminor, rdevmajor, rdevminor, len(nb), 0):
            hdr += b'%08X' % v
        out = hdr + nb
        out += b'\0' * ((4 - len(out) % 4) % 4)
        out += data
        out += b'\0' * ((4 - len(out) % 4) % 4)
        return out

    out = bytearray()
    for name in names:
        p = os.path.join(srcdir, name.lstrip('/'))
        st = os.lstat(p)
        if os.path.islink(p):
            mode = 0o120000 | 0o777
            data = os.readlink(p).encode()
        elif os.path.isdir(p):
            mode = 0o040000 | (st.st_mode & 0o7777)
            data = b''
        else:
            mode = 0o100000 | (st.st_mode & 0o7777)
            data = open(p, 'rb').read()
        out += emit(name, mode, 0, 0, 0, data)
    out += emit('TRAILER!!!', 0, 0, 0, 0, b'')

    # mtime 固定成 0, 让重打包结果可复现
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode='wb', mtime=0) as g:
        g.write(bytes(out))
    open(gz_path, 'wb').write(buf.getvalue())
    print('cpio 打包 %d 个条目 -> %d 字节 (gz)' % (len(names), len(buf.getvalue())))


if __name__ == '__main__':
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == 'unpack':
        unpack(sys.argv[2], sys.argv[3])
    elif cmd == 'pack':
        pack(sys.argv[2], sys.argv[3])
    elif cmd == 'ramdisk-unpack':
        cpio_extract(sys.argv[2], sys.argv[3])
    elif cmd == 'ramdisk-pack':
        cpio_pack(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(1)
