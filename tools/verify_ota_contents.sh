#!/bin/bash
# =============================================================================
# verify_ota_contents.sh —— 刷机前「包内文件级」往返校验
#
# 用法:
#     ./verify_ota_contents.sh                       # 自动取 dist/ 下最新 OTA
#     ./verify_ota_contents.sh /path/to/xxx.zip      # 指定包
#
# 【为什么需要这个脚本】
#   patches/check.sh 只能证明「设备树 / overlay / 打包工具都对了」，以及
#   「zip 有 17 个条目、能打开、build.prop 有 persist.sys.ui.hw=0」。
#   但项目里踩过最痛的一次坑是：egl_display.cpp.patch 明明显示「已应用」，
#   设备上的 /system/lib/libEGL.so 却还是原版 —— 因为 out/ 被清空、
#   根本没重编 libEGL，「补丁应用了」和「补丁进 ROM 了」长期脱节。
#   本脚本不看源码树，只从**最终 zip 本身**出发：
#       zip -> system.new.dat + system.transfer.list
#           -> otablocks.py unpack 还原成 raw ext4
#           -> debugfs 逐个 dump 出关键文件 -> 算 md5
#   这样得到的是「刷进设备后 /system 里到底是什么」的硬证据。
#
# 【与 verify_after_boot.sh 的分工】
#   verify_ota_contents.sh : 刷机前，在宿主侧验「包」；
#   verify_after_boot.sh   : 刷机后，在设备侧验「分区」。
#   两者的 EXPECT_MD5 表必须一致，任何一侧对不上都说明重打包或刷入脱节。
#
# 【环境铁律】
#   1) /tmp 在本机只有 2.3G tmpfs，system.new.dat 780MB + raw.img 3GB
#      放进去会写爆，临时目录一律放 repack/work/ 下。
#   2) debugfs 的 write/dump 参数按空格切分，含空格路径会被切碎，
#      所以宿主侧命令里一律走无空格软链 /home/dy/wbrp。
#   3) 容器里没有 debugfs，必须 flatpak-spawn --host。
#   4) debugfs 操作的是 system.img 的**根**，所以 /system/lib/libEGL.so
#      在这里写成 /lib/libEGL.so。
# =============================================================================

set -euo pipefail

ROOT="/home/dy/WorkBuddy AI/ardbeg-cm-14.1"
REPACK="$ROOT/repack"
DIST_ROOT="$ROOT/dist"
PY=/home/dy/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3
[ -x "$PY" ] || PY=$(command -v python3)

PKG=${1:-$(ls -t "$DIST_ROOT"/*/cm_ardbeg_tv-ota-eng.dy.zip 2>/dev/null | head -1)}
if [ -z "$PKG" ] || [ ! -f "$PKG" ]; then
    echo "找不到 OTA 包，用法: $0 [xxx.zip]" >&2
    exit 1
fi

# 期望值基准：dist/appvideo-1107-2005/cm_ardbeg_tv-ota-eng.dy.zip
#   395989155 字节 / md5 f23add70d0e028e5602d0d85824ad1df
#   （2026-11-07 app 视频播放验收固化重打包；包内 14 项 md5 与
#    homeguard-1107-1705 完全一致，仅 zip 重新签名、ext4 运行时字段重写。
#    首启脚本 md5 仍是 231f397b...）
# 与 tools/verify_after_boot.sh 的 EXPECT_MD5 表逐项一致。
# 恢复全量编译或重做二进制补丁后，两张表必须一起更新。
EXPECT_MD5=(
    "lib/libEGL.so|4ac10584321c81f8dcddd21a025bced6"
    "etc/init/lmkd.rc|4635029e48b1ef36190332742188bf65"
    "bin/sf_hwc_off.sh|f1223c35f9d7ea3706d74cbe83a4a24b"
    "lib/libselinux_bypass.so|8652d544f226ee8de7127f30dca2fff1"
    "lib/libminijail.so|29f2b8bb047cac7473cb1b77e3a21a14"
    "bin/zz-ardbeg-firstboot-fix.sh|231f397b82a71d94f16c9846140ed9a1"
    "bin/zz-ardbeg-home-watchdog.sh|977e12d55141bebe1e6964c36bc6bfa3"
    "etc/wifi/ardbeg_default_network.conf|d2e8dd68fab0df7e80b5373b372ba720"
    # 2026-11-07 全面功能测试查出 persist_logcat 一次都没起来：
    # /system/bin/logcat 是 7.1 的 logcat_exec 标签，4.4.4 sepolicy 无此 type，
    # init 在 security_compute_create() 失败。rc 加 seclabel u:r:init:s0 后
    # 实机 init.svc.persist_logcat=running、/cache/persist_log.txt 持续增长。
    # 这里必须比 md5，不能只「存在」，否则又会出现「rc 在包里但是旧版」。
    "etc/init/zz-persist-log.rc|6500a2babf94cec94c50e4e160517b2b"
    # ---- 2026-11-07 硬件解码专项：三条独立根因的实物，必须比 md5 ----
    # 1) OMX 插件桥。缺失时 OMXMaster::addVendorPlugin() 静默失败，
    #    mPluginByComponentName 里没有任何 OMX.Nvidia.*，全部退软解。
    "lib/libstagefrighthw.so|7221cb3656b33b54846e34b5e406163c"
    # 2) 7.1 兼容 codec 表。4.4 版的同名组件重复声明会让
    #    MediaCodecList.cpp:737 返回 -EINVAL 并清空 mCodecInfos。
    "etc/media_codecs.xml|9c884d66a4e7d44a0b7227cc2ec8ddb5"
    # 3) mediacodec 服务 group 补 media(1013)，否则打不开
    #    media:media 0660 的 /dev/tegra_avpchannel，播放报 0x80001000。
    "etc/init/mediacodec.rc|e5dfd2d55c04eb72cbb89ff2327ce4f1"
)
# 只需存在、不需要比 md5 的 init rc（内容由 initfiles/Android.mk 保证）
EXPECT_EXIST=(
    "etc/init/zz-ardbeg-firstboot-fix.rc"
    "etc/init/zz-ardbeg-home-watchdog.rc"
)

# 无空格软链：debugfs 命令里只能用这个路径
WBRP=/home/dy/wbrp
if [ ! -L "$WBRP" ] || [ "$(readlink -f "$WBRP")" != "$REPACK" ]; then
    rm -f "$WBRP"
    ln -s "$REPACK" "$WBRP"
fi

TAG=$(basename "$(dirname "$PKG")")
W="$REPACK/work/ota-verify-$TAG"
mkdir -p "$W/extracted"
W_HOST="$WBRP/work/ota-verify-$TAG"      # 给宿主侧 debugfs 用的路径

echo "======================================================================"
echo "OTA 包内文件级往返校验"
echo "  包   : $PKG"
echo "  大小 : $(wc -c < "$PKG") 字节"
echo "  md5  : $(md5sum "$PKG" | cut -d' ' -f1)"
echo "  临时 : $W"
echo "======================================================================"

# ---------------------------------------------------------------------------
# 1) zip 结构 + build.prop（不还原镜像就能先判一遍）
# ---------------------------------------------------------------------------
echo
echo "========== 1. zip 结构与签名件 =========="
"$PY" - "$PKG" <<'PYEOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
bad = z.testzip()
need = [
    'META-INF/com/google/android/updater-script',
    'META-INF/com/android/otacert',
    'META-INF/CERT.RSA', 'META-INF/CERT.SF', 'META-INF/MANIFEST.MF',
    'system.new.dat', 'system.transfer.list', 'system/build.prop',
    'boot.img',
    'install/bin/backuptool.sh',
    'install/bin/backuptool.functions',
    'install/bin/otasigcheck.sh',
]
print('  条目数 : %d' % len(names))
print('  testzip: %s' % ('干净' if bad is None else '损坏 -> ' + bad))
missing = [n for n in need if n not in names]
print('  必备条目: %s' % ('齐全' if not missing else '缺 ' + ', '.join(missing)))
bp = z.read('system/build.prop').decode('utf-8', 'replace')
print('  build.prop persist.sys.ui.hw=0 : %s' % ('是' if 'persist.sys.ui.hw=0' in bp else '否 <<< 黑屏根因'))
if missing or bad is not None or 'persist.sys.ui.hw=0' not in bp:
    sys.exit(1)
PYEOF

# ---------------------------------------------------------------------------
# 2) 解出块数据（只解这两个，不解整包，省时间省空间）
# ---------------------------------------------------------------------------
echo
echo "========== 2. 解出 system.new.dat / transfer.list =========="
"$PY" - "$PKG" "$W" <<'PYEOF'
import sys, zipfile
z, w = zipfile.ZipFile(sys.argv[1]), sys.argv[2]
for n, out in [('system.new.dat', w + '/system.new.dat'),
               ('system.transfer.list', w + '/system.transfer.list')]:
    with z.open(n) as src, open(out, 'wb') as dst:
        while True:
            b = src.read(4 << 20)
            if not b:
                break
            dst.write(b)
    print('  %s -> %s' % (n, out))
PYEOF

# ---------------------------------------------------------------------------
# 3) 还原 raw ext4
# ---------------------------------------------------------------------------
echo
echo "========== 3. otablocks.py unpack 还原 raw ext4 =========="
rm -f "$W/raw.img"
"$PY" "$REPACK/tools/otablocks.py" unpack \
    "$W/system.transfer.list" "$W/system.new.dat" "$W/raw.img"

# ---------------------------------------------------------------------------
# 4) debugfs 把关键文件 dump 到宿主侧
# ---------------------------------------------------------------------------
echo
echo "========== 4. debugfs dump 关键文件 =========="
CMDS="$W/dump.cmds"
: > "$CMDS"
for item in "${EXPECT_MD5[@]}" "${EXPECT_EXIST[@]}"; do
    # EXPECT_EXIST 元素是裸路径，EXPECT_MD5 是 "路径|md5"
    p=${item%%|*}
    base=$(basename "$p")
    echo "dump /$p $W_HOST/extracted/$base" >> "$CMDS"
done
flatpak-spawn --host debugfs -f "$CMDS" "$W/raw.img" 2>&1 \
    | grep -Ev '^\s*$|debugfs 1\.' | tail -25 || true

# ---------------------------------------------------------------------------
# 5) md5 逐项判定
# ---------------------------------------------------------------------------
echo
echo "========== 5. 包内文件 md5 判定 =========="
PASS=0
FAIL=0
for item in "${EXPECT_MD5[@]}"; do
    p=${item%%|*}
    want=${item##*|}
    base=$(basename "$p")
    f="$W/extracted/$base"
    if [ ! -f "$f" ]; then
        printf '  FAIL  %-46s dump 失败（文件不存在）\n' "/$p"
        FAIL=$((FAIL + 1))
        continue
    fi
    got=$(md5sum "$f" | cut -d' ' -f1)
    if [ "$got" = "$want" ]; then
        printf '  PASS  %-46s %s\n' "/$p" "$got"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %-46s got %s want %s\n' "/$p" "$got" "$want"
        FAIL=$((FAIL + 1))
    fi
done
for p in "${EXPECT_EXIST[@]}"; do
    base=$(basename "$p")
    if [ -s "$W/extracted/$base" ]; then
        printf '  PASS  %-46s 存在 (%s 字节)\n' "/$p" "$(wc -c < "$W/extracted/$base")"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %-46s 不存在或为空\n' "/$p"
        FAIL=$((FAIL + 1))
    fi
done

echo
echo "======================================================================"
echo "  PASS = $PASS   FAIL = $FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "  结论：最终 OTA 包内确实包含全部已验证修复，可以刷入。"
else
    echo "  结论：包内文件与设备树真源不一致，禁止刷入，先查 apply_overlay.py 的 FILES。"
fi
echo "======================================================================"
[ "$FAIL" -eq 0 ]
