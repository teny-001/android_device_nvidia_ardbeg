#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mkzip.py —— 用改好的 system.new.dat / transfer.list / boot.img 重新打 OTA 包

要点:
  1. 条目顺序、压缩方式都跟原包保持一致。
  2. 新写出来的 zip 不能带 archive comment —— 因为接下来 signapk -w
     会往 comment 里塞整包签名, 有 comment 它会直接报
     "zip data already has an archive comment"。
  3. 不引入 zip64。7.1 的 libziparchive 对 zip64 支持很有限,
     而且整包 < 4GB 根本用不上。所以:
        - 小文件(原包里保留的那些)直接 writestr;
        - 大文件(替换进去的)用 ZipFile.write(), 它会在写 local header
          之前就把 file_size 填好, 因此不会触发 zip64。
     最后还会检查一遍有没有 zip64 的 EOCD locator。
  4. META-INF/CERT.SF、CERT.RSA、MANIFEST.MF 保留原样。
     它们里面的摘要已经过期, 但 recovery 的 verify_file() 只认文件尾部
     那段 PKCS#7 整包签名(verifier.cpp 先检查 footer 的 $ff $ff 标记,
     不匹配就直接 VERIFY_FAILURE, 根本走不到 JAR 签名那条路),
     所以不影响刷机。
"""

import os
import struct
import sys
import zipfile

SRC = os.environ.get(
    'OTA_SRC',
    '/home/dy/WorkBuddy AI/ardbeg-cm-14.1/dist/tv-1104-1728/cm_ardbeg_tv-ota-eng.dy.zip')
BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.environ.get('OTA_OUT', os.path.join(BASE, 'work', 'out'))

# 【2026-11-06】加 OTA_SRC / OTA_OUT 两个环境变量，避免每次都手改常量。
#   SRC 是"模板包"：条目顺序、压缩方式、META-INF 都从它照抄，
#       默认用最早那份完整的 tv-1104-1728，不要换成打过补丁的包，
#       否则模板里会带着上一次的 system.new.dat（虽然会被 REPLACE 覆盖，
#       但包根目录的 system/build.prop 之类容易越滚越乱）。
#   OUT 是 system.new.dat / system.transfer.list 所在目录，
#       otablocks.py pack 的输出前缀就指这里。

REPLACE = {
    'system.new.dat': os.path.join(OUT, 'system.new.dat'),
    'system.transfer.list': os.path.join(OUT, 'system.transfer.list'),
    'boot.img': os.path.join(BASE, 'work', 'boot.img'),
    # 包根目录下那份 system/build.prop 只是给工具看构建指纹用的, 不参与刷机,
    # 但既然 build.prop 变了就一起换掉, 免得包里出现两个不一致的版本。
    'system/build.prop': os.path.join(BASE, 'overlay', 'system', 'build.prop'),
}

ZIP64_LOCATOR = b'PK\x06\x07'


def main():
    dst = sys.argv[1] if len(sys.argv) > 1 else os.path.join(OUT, 'unsigned.zip')
    zin = zipfile.ZipFile(SRC)
    zout = zipfile.ZipFile(dst, 'w', allowZip64=False)
    for info in zin.infolist():
        name = info.filename
        if name in REPLACE:
            src = REPLACE[name]
            print('替换 %-26s <- %s (%.1f MB)' %
                  (name, os.path.basename(src), os.path.getsize(src) / 1048576.0))
            zout.write(src, arcname=name, compress_type=info.compress_type)
        else:
            data = zin.read(info)
            zi = zipfile.ZipInfo(name, date_time=info.date_time)
            zi.compress_type = info.compress_type
            zi.external_attr = info.external_attr
            zi.internal_attr = info.internal_attr
            zi.create_system = info.create_system
            zout.writestr(zi, data)
            print('保留 %-26s (%d 字节)' % (name, len(data)))
    zout.close()
    zin.close()

    size = os.path.getsize(dst)
    with open(dst, 'rb') as f:
        f.seek(size - 22)
        eocd = f.read(22)
        # zip64 的 EOCD locator 紧挨在 EOCD 之前(20 字节), 只需看这一小段;
        # 不能全文件搜 "PK\x06\x07", 压缩数据里撞上会误报。
        f.seek(size - 22 - 20)
        before = f.read(20)
    if before[:4] == ZIP64_LOCATOR:
        raise SystemExit('警告: 输出里有 zip64 EOCD locator, recovery 可能不认')
    if eocd[:4] != b'PK\x05\x06':
        raise SystemExit('警告: 找不到 EOCD')
    if struct.unpack('<H', eocd[20:22])[0] != 0:
        raise SystemExit('警告: 输出带了 archive comment')
    print('已写出 %s (%.1f MB), 无 zip64 / 无 comment' % (dst, size / 1048576.0))


if __name__ == '__main__':
    main()
