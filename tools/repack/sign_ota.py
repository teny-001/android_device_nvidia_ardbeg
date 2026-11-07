#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sign_ota.py —— 给 OTA zip 做「整包签名」(whole-file signature)

为什么不用 signapk.jar:
    源码树里只有 prebuilts/sdk/tools/lib/signapk.jar, 它是给 Android 构建
    环境用的, 内部依赖 org.conscrypt(Android 的 JCA provider) 和 BouncyCastle,
    在桌面 JDK 上直接跑会挂在 OpenSSLProvider 的静态初始化里。
    从源码重编又需要 BouncyCastle 的 jar。

    其实整包签名格式非常简单, 用 openssl + 几十行 Python 就能精确复刻。
    格式来自 build/tools/signapk/src/.../SignApk.java 的 signWholeFile():

        最终文件 = 原zip[0 : L-2] + (comment_len 2字节) + comment
        comment  = "signed by SignApk"(17) + 0x00 + PKCS7_DER
                   + signature_start(2,LE) + 0xFF 0xFF + total_size(2,LE)

        total_size      = 18 + len(DER) + 6
        signature_start = total_size - 18 = len(DER) + 6
        签名覆盖的数据  = 原zip[0 : L-2]   (即去掉最后 2 字节 comment_len 字段)

    recovery 侧对应 bootable/recovery/verifier.cpp:
        comment_size = footer[4] | footer[5]<<8
        eocd_size    = comment_size + 22
        signed_len   = length - eocd_size + 22 - 2   == 原zip长度 - 2
        signature    = 从文件末尾往回 signature_start 字节处, 长度 signature_start-6
        然后 read_pkcs7() 从 PKCS#7 里抠出 SignerInfo 的 signature OCTET STRING,
        再 RSA_verify(hash_nid, digest, digest_len, sig, sig_len, rsa)
        (BoringSSL 版 RSA_verify 收的是裸摘要, 不是 DigestInfo)

    摘要算法: recovery 按证书自身的签名算法决定 hash_len
        (Certificate 解析: sha1WithRSA -> 20 字节, sha256WithRSA -> 32 字节)
    本机 testkey.x509.pem 是 sha1WithRSA, 所以这里必须用 -md sha1。

    PKCS#7 必须**不带 authenticatedAttributes**, 因为 read_pkcs7() 的
    解析路径是: SignerInfo 里连续 sequence_next 4 次之后直接取 OCTET STRING,
    这个偏移只有在没有 signedAttrs 时才成立。对应 openssl 的 -noattr。
"""

import os
import struct
import subprocess
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYDIR = '/home/dy/aosp14/build/target/product/security'
MSG = b'signed by SignApk'


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, **kw)
    if r.returncode != 0:
        sys.stderr.write(r.stdout.decode('utf-8', 'replace'))
        sys.stderr.write(r.stderr.decode('utf-8', 'replace'))
        raise SystemExit('命令失败: %s' % ' '.join(cmd))
    return r.stdout


def main():
    src = sys.argv[1]
    dst = sys.argv[2]
    work = os.path.join(BASE, 'work')
    data_bin = os.path.join(work, 'signed_data.bin')
    der_bin = os.path.join(work, 'signature.der')
    key_pem = os.path.join(work, 'testkey.pem')

    L = os.path.getsize(src)
    print('输入 %s (%.1f MB)' % (src, L / 1048576.0))

    # 1) 把被签名的数据(去掉最后 2 字节)单独落盘
    signed_len = L - 2
    with open(src, 'rb') as f, open(data_bin, 'wb') as o:
        left = signed_len
        while left > 0:
            buf = f.read(min(left, 1 << 22))
            if not buf:
                raise SystemExit('读文件出错')
            o.write(buf)
            left -= len(buf)

    # 2) pk8(PKCS#8 DER) -> PEM, 供 openssl 使用
    if not os.path.exists(key_pem):
        run(['openssl', 'pkcs8', '-inform', 'DER', '-nocrypt',
             '-in', os.path.join(KEYDIR, 'testkey.pk8'),
             '-out', key_pem])

    # 3) 生成 detached PKCS#7 (SHA1, 无 signedAttrs)
    run(['openssl', 'smime', '-sign', '-binary', '-noattr', '-md', 'sha1',
         '-in', data_bin,
         '-signer', os.path.join(KEYDIR, 'testkey.x509.pem'),
         '-inkey', key_pem,
         '-outform', 'DER', '-out', der_bin])
    der = open(der_bin, 'rb').read()
    print('PKCS#7 DER %d 字节' % len(der))

    # 4) 自检: 用 openssl 验一遍这份 detached 签名
    run(['openssl', 'smime', '-verify', '-binary', '-inform', 'DER',
         '-in', der_bin, '-content', data_bin, '-noverify',
         '-out', os.devnull])
    print('openssl 自检签名 OK')

    # 5) 拼最终文件
    total_size = 18 + len(der) + 6
    signature_start = total_size - 18
    if total_size > 0xffff:
        raise SystemExit('签名太大, 塞不进 zip comment')

    with open(src, 'rb') as f, open(dst, 'wb') as o:
        left = signed_len
        while left > 0:
            buf = f.read(min(left, 1 << 22))
            if not buf:
                raise SystemExit('读文件出错')
            o.write(buf)
            left -= len(buf)
        o.write(struct.pack('<H', total_size))      # EOCD 的 comment_len 字段
        o.write(MSG)
        o.write(b'\x00')
        o.write(der)
        o.write(struct.pack('<H', signature_start))
        o.write(b'\xff\xff')
        o.write(struct.pack('<H', total_size))

    size = os.path.getsize(dst)
    print('已写出 %s (%.1f MB)' % (dst, size / 1048576.0))
    print('  comment_size=%d  signature_start=%d  signed_len=%d'
          % (total_size, signature_start, signed_len))


if __name__ == '__main__':
    main()
