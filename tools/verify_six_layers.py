#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ardbeg CM14.1 —— 六层字节一致性矩阵（2026-11-07 收官补强）

【这个工具解决什么问题】
    `patches/check.sh` 核验的是「补丁在不在、注册没注册、包在不在」这类
    **存在性 / 静态**判据。历史上出现过「check.sh 22/22 全绿，但设备上
    /system/lib/libEGL.so 的 md5 始终是原版」的脱节：因为
    PRODUCT_COPY_FILES 对已由 AOSP 模块产出的 system/lib/libEGL.so 会被
    build/core 静默 ignored，全量编译路径根本不会带进二进制补丁。
    所以「补丁应用了」≠「补丁进 ROM 了」≠「补丁在真机上生效了」。

    本工具把同一个文件在**六个层**上的 md5 摆到一张表里，只有逐字节
    相等才算固化完成：

      L1 期望基准   tools/verify_ota_contents.sh + verify_after_boot.sh
                    的 EXPECT_MD5 表（两份表必须一致）
      L2 源码补丁   device/nvidia/ardbeg/patches/**/*.patch + device.mk
                    构建期断言（全量编译路径）
      L3 真源       device/nvidia/ardbeg/{initfiles,prebuilt,wifi}/
      L4 overlay    repack/overlay/system/ + apply_overlay.py 的 FILES 注册
      L5 最终包     从 zip 还原出来的 raw ext4，用 debugfs dump 后算 md5
      L6 真机       adb 到设备 /system/... 上算 md5

    L1/L2/L4(注册) 是「静态/声明」，L3/L4(文件)/L5/L6 是「字节」。
    六层全对齐，才能回答用户那句「补丁集成到设备树、固化进刷机包了吗」。

【坑位备忘（都是真机/打包过程里踩过的）】
    1) 容器里**没有 debugfs**，必须 `flatpak-spawn --host debugfs`。
       `debugfs -f cmdfile` 里的路径按空格切分，所以 dump 的目标路径
       绝对不能含空格 —— 用无空格软链 `/home/dy/wbrp` 指向 repack/。
    2) debugfs 操作的是 **system.img 的 ext4 根**，不是设备的 /system。
       `/system/lib/libEGL.so` 在镜像里是 `/lib/libEGL.so`，要去掉 system 前缀。
    3) `system.new.dat` 是**按 1024 块分组抽出的非零块紧凑拼接**，不是连续
       raw 镜像。绝不能 `dd if=system.new.dat of=/dev/block/mmcblk0p10`，
       那样 ext4 group descriptor / inode table 全对不上，必挂。必须用
       otablocks.py unpack 按 transfer.list 还原，再 debugfs dump。
    4) 本工具默认复用 `work/flash-experiment-*/new_raw.img`（3 GiB 已还原
       基准），并**强制校验它的全量 md5** 才允许复用，避免拿旧底图冒充
       当前包。磁盘只剩 20G 量级时不要重复还原第二份 3 GiB。
    5) `libminijail.so` 是 AOSP 构建产物的二进制补丁结果，设备树里**没有
       真源文件**，只有 repack/overlay 副本。缺真源是设计如此，不是漏文件。
    6) 设备侧 `adb shell` 输出带 \\r，必须 strip；md5sum 不存在时返回空串，
       要当成 FAIL 而不是「0」。
    7) **禁止 screencap -p**：FLAG_SECURE 屏上它会挂住 SurfaceFlinger
       客户端连接，导致 system_server 拿不到 SF 锁而全局 ANR。
    8) 不要用 `settings get` 逐项取值（每次都要起 ART VM，十几秒），
       也不要把 dumpsys/logcat 塞进 shell 变量（printf: Argument list too
       long，grep 拿到空输入会造成「假绿」）。本工具只读文件 md5。
    9) 【2026-11-07 实测踩到】`--offline` 时 L6 是 `SKIP` 占位符，
       **绝不能把 `SKIP` 塞进 `== expect` 的判据列表**，否则 9 个文件
       全部假 FAIL（首次离线复跑就报了 9 个 FAIL，其实前五层全对）。
       跳过的层要整体从 checks 里剔除，而不是给一个"假相等"的值。
   10) 【2026-11-07 硬解专项】静态检查扫 XML 时必须先剥掉 `<!-- ... -->`：
       AOSP 的 media_codecs.xml 头部注释里自带示例
       `<MediaCodec name="OMX.foo.bar" ...>` 且出现多次，直接 findall
       会误报「重复组件名」而拒绝打包。与 check.sh 里 grep 'screencap -p'
       被「禁止使用」的说明注释误伤是同一类错误：注释不是运行时证据。

【用法】
    python3 tools/verify_six_layers.py                     # 全六层（需 adb 在线）
    python3 tools/verify_six_layers.py --offline          # 跳过 L6（设备不在线时）
    python3 tools/verify_six_layers.py --out report.txt   # 落盘报告
    python3 tools/verify_six_layers.py --zip /path/x.zip  # 指定包
    python3 tools/verify_six_layers.py --raw /path/raw.img

    退出码 0 = 六层全部对齐；非 0 = 有 FAIL，报告里会逐条列出。
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

# ---------------------------------------------------------------------------
# 路径常量。工作目录含空格，所有 subprocess 一律用 list 形式传参，不拼 shell。
# ---------------------------------------------------------------------------
TOP = Path('/home/dy/aosp14/device/nvidia/ardbeg')
REPACK = Path('/home/dy/WorkBuddy AI/ardbeg-cm-14.1/repack')
DIST_ROOT = Path('/home/dy/WorkBuddy AI/ardbeg-cm-14.1/dist')
# 2026-11-07 app 视频播放验收固化后重打包换基准：new_raw.img 是
# dist/appvideo-1107-2005 的最终包经 otablocks unpack 还原出的 3 GiB raw
# （5488394af925e6835916cbe32630de96），用硬链复用，不额外占 3 GiB。
# 【注意】这次 A 组（进 system.img 的文件）字节一字未改，重打包只为把
# 「设备树 <-> 包 <-> 真机」再对齐一次并要求可复现交付；raw 全量 md5
# 仍会变，因为 ext4 的 s_mtime / s_wtime 等运行时字段被重写。关键文件
# 的 debugfs dump md5 才是判据，不要用 raw 全量 md5 判断「内容有没有变」。
# 上一版基准是 dist/homeguard-1107-1705（raw fdd9f6d4...），已作废。
EXP = Path('/home/dy/WorkBuddy AI/ardbeg-cm-14.1/work/'
           'appvideo-flash-1107-2005')
ADB = '/home/dy/WorkBuddy AI/k1flash/adb'
WBRP = Path('/home/dy/wbrp')          # 无空格软链，指向 REPACK

# 最终包与包内还原镜像的基准 md5；换包时用 --zip/--raw 并同步更新 --raw-md5。
PKG_MD5_DEFAULT = 'f23add70d0e028e5602d0d85824ad1df'
RAW_MD5_DEFAULT = '5488394af925e6835916cbe32630de96'

# ---------------------------------------------------------------------------
# 关键文件表：(ext4 内相对路径, 期望 md5, 设备树真源相对路径 or None, 说明)
# 期望 md5 必须与 tools/verify_ota_contents.sh 的 EXPECT_MD5 逐项一致。
# ---------------------------------------------------------------------------
FILES = [
    ('lib/libEGL.so', '4ac10584321c81f8dcddd21a025bced6',
     'prebuilt/lib/libEGL.so', 'egl_display.cpp.patch 的等价二进制补丁产物'),
    ('etc/init/lmkd.rc', '4635029e48b1ef36190332742188bf65',
     'initfiles/lmkd.rc', '全量侧另有 system/core/lmkd/lmkd.rc.patch'),
    ('bin/sf_hwc_off.sh', 'f1223c35f9d7ea3706d74cbe83a4a24b',
     'initfiles/sf_hwc_off.sh', ''),
    ('lib/libselinux_bypass.so', '8652d544f226ee8de7127f30dca2fff1',
     'prebuilt/lib/libselinux_bypass.so', 'LD_PRELOAD 垫片'),
    ('lib/libminijail.so', '29f2b8bb047cac7473cb1b77e3a21a14',
     None, 'AOSP 构建产物，设备树无真源（设计如此）'),
    ('bin/zz-ardbeg-firstboot-fix.sh', '231f397b82a71d94f16c9846140ed9a1',
     'initfiles/zz-ardbeg-firstboot-fix.sh', '四清首启 oneshot'),
    ('bin/zz-ardbeg-home-watchdog.sh', '977e12d55141bebe1e6964c36bc6bfa3',
     'initfiles/zz-ardbeg-home-watchdog.sh', '修浏览器被踢回 HOME'),
    ('etc/wifi/ardbeg_default_network.conf', 'd2e8dd68fab0df7e80b5373b372ba720',
     'wifi/ardbeg_default_network.conf', '四清后 WiFi 自动连接模板'),
    ('etc/init/zz-persist-log.rc', '6500a2babf94cec94c50e4e160517b2b',
     'initfiles/zz-persist-log.rc', 'seclabel u:r:init:s0 修 persist_logcat'),
    # ---- 2026-11-07 硬件解码专项三条独立根因 ----
    ('lib/libstagefrighthw.so', '7221cb3656b33b54846e34b5e406163c',
     'prebuilt/lib/libstagefrighthw.so',
     '原厂 4.4 OMX 桥；旧注释误判 7.1 要 bool secure 导致 ROM 里完全没有'),
    ('etc/media_codecs.xml', '9c884d66a4e7d44a0b7227cc2ec8ddb5',
     'media/media_codecs.xml',
     '7.1 兼容版，同名组件改 <Type> 子元素，避免 -EINVAL 清空 codec 表'),
    ('etc/init/mediacodec.rc', 'e5dfd2d55c04eb72cbb89ff2327ce4f1',
     'initfiles/mediacodec.rc',
     'group 含 media；设备树副本与 AOSP patch 后产物逐字节一致，'
     '由 KEY_PATCHES 的 mediacodec.rc.patch + apply_overlay.py 双向保证'),
]

# L2 源码补丁层必须存在的关键补丁（对应本表几个二进制 / rc 修复的全量侧来源）
KEY_PATCHES = [
    'frameworks/native/opengl/libs/EGL/egl_display.cpp.patch',
    'system/core/lmkd/lmkd.rc.patch',
    'system/core/init/init.cpp.patch',
    'system/core/rootdir/init.usb.rc.patch',
    'frameworks/av/media/audioserver/audioserver.rc.patch',
    'frameworks/native/cmds/installd/installd.rc.patch',
    # 硬件解码第三条：mediacodec 服务 group 补 media(1013)
    'frameworks/av/services/mediacodec/mediacodec.rc.patch',
]
MIN_PATCHES = 23

EXPECT_ENTRIES = 17


def md5(path):
    h = hashlib.md5()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def run(argv):
    """list 形式执行，绝不 shell=True（工作目录含空格）。"""
    return subprocess.run(argv, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, timeout=600)


def find_pkg(explicit):
    if explicit:
        return Path(explicit)
    candidates = sorted(DIST_ROOT.glob('*/cm_ardbeg_tv-ota-eng.dy.zip'),
                        key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0] if candidates else None


def check_zip(pkg, pkg_md5, report):
    """L0：包本身要先站得住，否则后面所有 md5 都没有意义。"""
    ok = True
    if not pkg or not pkg.is_file():
        report.append('L0 [FAIL] 找不到最终 OTA 包')
        return False, ''
    real_md5 = md5(pkg)
    if real_md5 != pkg_md5:
        report.append('L0 [FAIL] 包 md5 %s != 基准 %s（换包了？用 --pkg-md5 更新）'
                      % (real_md5, pkg_md5))
        ok = False
    else:
        report.append('L0 [PASS] 包 md5 %s / %d 字节'
                      % (real_md5, pkg.stat().st_size))
    with zipfile.ZipFile(pkg) as z:
        names = z.namelist()
        bad = z.testzip()
        bp = z.read('system/build.prop').decode('utf-8', 'replace')
    if bad is not None:
        report.append('L0 [FAIL] testzip 报损坏条目 %s' % bad)
        ok = False
    if len(names) != EXPECT_ENTRIES:
        report.append('L0 [FAIL] zip 条目 %d != %d' % (len(names), EXPECT_ENTRIES))
        ok = False
    else:
        report.append('L0 [PASS] zip 条目 %d，testzip 干净' % len(names))
    if 'persist.sys.ui.hw=0' not in bp:
        report.append('L0 [FAIL] build.prop 缺 persist.sys.ui.hw=0（黑屏根因复发）')
        ok = False
    else:
        report.append('L0 [PASS] build.prop persist.sys.ui.hw=0')
    return ok, real_md5


def check_patch_layer(report):
    """L2：全量编译侧的 AOSP 源码补丁是否存在。"""
    ok = True
    patches = list((TOP / 'patches').rglob('*.patch'))
    if len(patches) < MIN_PATCHES:
        report.append('L2 [FAIL] AOSP 补丁只有 %d 个，少于 %d'
                      % (len(patches), MIN_PATCHES))
        ok = False
    else:
        report.append('L2 [PASS] AOSP 源码补丁 %d 个' % len(patches))
    for rel in KEY_PATCHES:
        p = TOP / 'patches' / rel
        if not p.is_file():
            report.append('L2 [FAIL] 关键补丁缺失：%s' % rel)
            ok = False
            continue
        # mediacodec.rc 现在有三处真源：AOSP patch 后的源文件、设备树
        # initfiles/mediacodec.rc 副本、overlay 副本。L3 已指向设备树副本
        # 做字节比对；这里再补一条语义断言：补丁必须真的把 media 组加
        # 进去了，不能只看「文件存在」。少了它 AVP 通道打不开，
        # 硬解照样 0x80001000。
        # 【2026-11-07 实测漂移】设备树 initfiles/mediacodec.rc 一度仍是
        # 11-06 的旧 2471 字节版本（无 media 组），而 AOSP 侧和 overlay
        # 已经是 4290 字节修复版。正是六层矩阵要抓的那类「改了一边」。
        if rel.endswith('mediacodec.rc.patch'):
            body = p.read_text(encoding='utf-8', errors='replace')
            added = [ln for ln in body.splitlines()
                     if ln.startswith('+') and ln[1:].strip().startswith('group ')]
            if not any('media' in ln.split() for ln in added):
                report.append('L2 [FAIL] mediacodec.rc.patch 没有把 media 加进 group')
                ok = False
    if not (TOP / 'patches' / 'check.sh').is_file():
        report.append('L2 [FAIL] 缺 patches/check.sh')
        ok = False
    device_mk = (TOP / 'device.mk').read_text(encoding='utf-8', errors='replace')
    for kw in ('libEGL', 'lmkd.rc', 'zz-persist-log.rc',
               'zz-ardbeg-firstboot-fix.sh', 'ardbeg_default_network.conf',
               # 硬件解码：全量编译侧必须同时注册桥、codec 表
               'libstagefrighthw.so', 'media/media_codecs.xml'):
        if kw not in device_mk:
            report.append('L2 [FAIL] device.mk 少了全量编译侧注册/断言：%s' % kw)
            ok = False
    return ok


def check_registration(report):
    """L4 注册层：FILES 表才是「进不进 system.img」的唯一真清单。"""
    ok = True
    ap = (REPACK / 'tools' / 'apply_overlay.py').read_text(
        encoding='utf-8', errors='replace')
    for rel, _exp, _src, _note in FILES:
        token = "'/%s'" % rel
        if token not in ap:
            report.append('L4 [FAIL] apply_overlay.py 的 FILES 未注册 /%s' % rel)
            ok = False
    if ok:
        report.append('L4 [PASS] apply_overlay.py FILES 已注册 %d 个目标路径'
                      % len(FILES))
    return ok


def dump_from_raw(raw, raw_md5, report):
    """L5：debugfs 从包内还原的 raw ext4 里 dump 出 9 个文件。"""
    ok = True
    if not raw or not raw.is_file():
        report.append('L5 [FAIL] 找不到已还原的 raw ext4 镜像：%s' % raw)
        return False, {}
    real = md5(raw)
    if real != raw_md5:
        report.append('L5 [FAIL] raw md5 %s != 包内还原基准 %s，拒绝拿旧底图冒充'
                      % (real, raw_md5))
        return False, {}
    report.append('L5 [PASS] raw 镜像 %d 字节 / md5 %s（与包内还原基准一致）'
                  % (raw.stat().st_size, real))

    # 【坑】dump 目标路径不能含空格，且 host 侧要能写、容器侧要能读。
    # /home/dy/wbrp 是无空格软链，指向含空格的 repack/ 目录。
    outdir = WBRP / 'work' / 'six-layer-dump'
    outdir.mkdir(parents=True, exist_ok=True)
    real_outdir = REPACK / 'work' / 'six-layer-dump'
    for p in real_outdir.glob('*'):
        if p.is_file():
            p.unlink()

    cmdfile = outdir / 'dump.cmd'
    lines = []
    for rel, _exp, _src, _note in FILES:
        # debugfs 里是 ext4 根，去掉 /system 前缀
        lines.append('dump /%s %s\n' % (rel, outdir / Path(rel).name))
    cmdfile.write_text(''.join(lines), encoding='utf-8')

    r = run(['flatpak-spawn', '--host', 'debugfs', '-f', str(cmdfile), str(raw)])
    if r.returncode != 0:
        report.append('L5 [FAIL] debugfs 执行失败：%s' % r.stdout.strip()[:300])
        return False, {}
    # debugfs 即使某个 dump 失败也可能返回 0，必须逐个确认文件存在
    got = {}
    for rel, _exp, _src, _note in FILES:
        p = real_outdir / Path(rel).name
        if not p.is_file():
            report.append('L5 [FAIL] debugfs 没 dump 出 /%s' % rel)
            ok = False
            got[rel] = '-'
        else:
            got[rel] = md5(p)
    return ok, got


def device_md5s(report):
    """L6：真机运行时文件 md5。"""
    paths = ' '.join('/system/' + rel for rel, _e, _s, _n in FILES)
    script = ('for f in %s; do m=$(md5sum "$f" 2>/dev/null | cut -d" " -f1); '
              'echo "$f|$m"; done' % paths)
    r = run([ADB, 'shell', script])
    if r.returncode != 0:
        report.append('L6 [FAIL] adb shell 执行失败：%s' % r.stdout.strip()[:200])
        return False, {}
    got = {}
    for line in r.stdout.splitlines():
        line = line.strip().lstrip('\r')
        if '|' not in line:
            continue
        p, m = line.split('|', 1)
        got[p.replace('/system/', '', 1)] = m.strip()
    if len(got) != len(FILES):
        report.append('L6 [FAIL] 只拿到 %d/%d 个设备侧 md5（设备掉线或文件缺失）'
                      % (len(got), len(FILES)))
        return False, got
    return True, got


def main():
    ap = argparse.ArgumentParser(description='ardbeg 六层字节一致性矩阵')
    ap.add_argument('--zip', help='最终 OTA 包，默认取 dist 下最新的')
    ap.add_argument('--raw', help='已还原的 raw ext4，默认用真机实验留档的 new_raw.img')
    ap.add_argument('--pkg-md5', default=PKG_MD5_DEFAULT)
    ap.add_argument('--raw-md5', default=RAW_MD5_DEFAULT,
                    help='raw 镜像基准 md5，换包必须同步更新')
    ap.add_argument('--offline', action='store_true', help='跳过 L6 真机层')
    ap.add_argument('--out', help='报告落盘路径')
    args = ap.parse_args()

    report = []
    pkg = find_pkg(args.zip)
    raw = Path(args.raw) if args.raw else (EXP / 'new_raw.img')

    report.append('=' * 78)
    report.append('ardbeg CM14.1 六层字节一致性矩阵')
    report.append('  最终包 : %s' % pkg)
    report.append('  raw    : %s' % raw)
    report.append('  真机层 : %s' % ('跳过 (--offline)' if args.offline else '启用'))
    report.append('=' * 78)

    fail = 0
    ok, _ = check_zip(pkg, args.pkg_md5, report)
    fail += 0 if ok else 1
    report.append('')
    report.append('--- L2 全量编译侧：AOSP 源码补丁 + device.mk 断言 ---')
    fail += 0 if check_patch_layer(report) else 1
    report.append('')
    report.append('--- L4 注册侧：apply_overlay.py FILES ---')
    fail += 0 if check_registration(report) else 1
    report.append('')
    report.append('--- L5 最终包侧：raw ext4 + debugfs dump ---')
    ok5, pkgside = dump_from_raw(raw, args.raw_md5, report)
    fail += 0 if ok5 else 1

    deviceside = {}
    if not args.offline:
        report.append('')
        report.append('--- L6 真机侧：adb md5sum /system/... ---')
        ok6, deviceside = device_md5s(report)
        fail += 0 if ok6 else 1

    # ------------------------------------------------------------------
    # 逐文件六列对齐
    # ------------------------------------------------------------------
    report.append('')
    report.append('--- 逐文件矩阵（包内 / overlay / 真源 / 设备 都必须等于期望）---')
    hdr = ('%-40s %-34s %-8s %-8s %-8s %-8s %-6s'
           % ('文件', 'L1 期望', 'L5 包内', 'L4 ovl', 'L3 真源', 'L6 设备', '结论'))
    report.append(hdr)
    report.append('-' * len(hdr))
    per_file_fail = 0
    for rel, expect, src, _note in FILES:
        p_in = pkgside.get(rel, '-')
        ovl = REPACK / 'overlay' / 'system' / rel
        p_ovl = md5(ovl) if ovl.is_file() else '-'
        if src:
            s = TOP / src
            p_src = md5(s) if s.is_file() else '-'
        else:
            # libminijail.so 是 AOSP 构建产物，设备树没有真源，用 N/A 占位
            p_src = 'N/A'
        p_dev = deviceside.get(rel, 'SKIP' if args.offline else '-')

        # 【坑】offline 时 L6 是 SKIP 占位符，不能拿它跟 expect 比，
        # 否则 9 个文件全部假 FAIL。跳过的层要整体从判据里剔除。
        checks = [p_in == expect, p_ovl == expect]
        if not args.offline:
            checks.append(p_dev == expect)
        if src:
            checks.append(p_src == expect)
        good = all(checks)
        if not good:
            per_file_fail += 1
        def short(v):
            if v == expect:
                return 'OK'
            if v in ('N/A', 'SKIP', '-'):
                return v
            return 'DIFF'
        report.append('%-40s %-34s %-8s %-8s %-8s %-8s %-6s'
                      % (rel, expect, short(p_in), short(p_ovl),
                         short(p_src), short(p_dev),
                         'PASS' if good else 'FAIL'))
        if not good:
            report.append('    实测: 包内=%s overlay=%s 真源=%s 设备=%s'
                          % (p_in, p_ovl, p_src, p_dev))
    fail += per_file_fail

    report.append('')
    report.append('汇总：前置层 FAIL=%d，逐文件 FAIL=%d，共 %d 个 FAIL%s'
                  % (fail - per_file_fail, per_file_fail, fail,
                     '（L6 已按 --offline 跳过）' if args.offline else ''))
    report.append('结论：%s' % ('六层字节全部对齐，修复确实进了 ROM 且在真机生效。'
                               if fail == 0 else '存在脱节，按上面 FAIL 逐条排查。'))
    text = '\n'.join(report) + '\n'
    print(text, end='')
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding='utf-8')
        print('报告已落盘：%s' % out)
    return 0 if fail == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
