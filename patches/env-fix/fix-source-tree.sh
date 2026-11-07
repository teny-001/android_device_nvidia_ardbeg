#!/bin/sh
# =============================================================================
# fix-source-tree.sh —— cm-14.1 源码树里「不属于代码补丁」的环境性修复
#
# 为什么单独一个脚本，而不是做成 .patch：
#   本目录的 *.patch 都是「改源码内容」的补丁（由 check/install/uninstall.sh
#   统一管理）。但下面这两件事不是改代码，patch 表达不了：
#
#     1) external/chromium-webview 的 webview.apk 是 Git LFS 指针文件
#        （133 字节），真实 apk 83.6MB 要从 LFS 服务器拉。
#        同时这个仓库在本地被解压错位了：仓库根文件（Android.mk /
#        CleanSpec.mk / README / *.patch）全落在 patches/ 子目录里，
#        导致 Android.mk 的 $(call my-dir) 指向 patches/，
#        预编译 apk 的路径被解析成 patches/prebuilt/arm/webview.apk，
#        ninja 直接报 "missing and no known rule to make it"。
#
#     2) prebuilts/misc/linux-x86/bison/bison 是 32 位 ELF，
#        本机没有 32 位动态链接器，执行时报
#            cannot execute: required file not found
#        需要换成转调宿主 bison 的包装脚本。
#
# 用法：
#   ./fix-source-tree.sh check      只检查，不改任何文件
#   ./fix-source-tree.sh install    执行修复（幂等，可重复跑）
#   ./fix-source-tree.sh uninstall  还原（webview 只还原目录布局，
#                                   apk 不删，因为重新下载要 83MB）
#
# 依赖：curl；解析 LFS JSON 用 python3（没有 python3 时会退化成
#       “只修目录布局、不下载 apk”，并明确提示）。
# =============================================================================

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PATCHES_DIR=$(cd "${HERE}/.." && pwd)

# ---- 定位源码树根：从 patches 目录往上找，直到看见 build/core/main.mk ----
detect_top() {
    _d="${PATCHES_DIR}"
    while [ "${_d}" != "/" ]; do
        if [ -f "${_d}/build/core/main.mk" ]; then
            echo "${_d}"
            return 0
        fi
        _d=$(dirname "${_d}")
    done
    echo "错误：从 ${PATCHES_DIR} 往上找不到源码树根（缺 build/core/main.mk）" >&2
    return 1
}

TOP=$(detect_top) || exit 1

WEBVIEW_DIR="${TOP}/external/chromium-webview"
BISON_DIR="${TOP}/prebuilts/misc/linux-x86/bison"

MODE="${1:-check}"

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
ok()   { printf '  [正常] %s\n' "$*"; }
todo() { printf '  [需修] %s\n' "$*"; }
bad()  { printf '  [错误] %s\n' "$*"; }

# 判断一个文件是不是 32 位 ELF（不依赖 file 命令，读 ELF header 第 4/5 字节）
is_elf32() {
    [ -f "$1" ] || return 1
    # e_ident: 7f 45 4c 46 EI_CLASS(1=32bit) EI_DATA(1=LSB)
    _hdr=$(od -An -tx1 -N6 "$1" 2>/dev/null | tr -d ' \n')
    [ "${_hdr}" = "7f454c460101" ]
}

# 文件是不是 Git LFS 指针（开头是 "version https://git-lfs.github.com/spec/"）
# 注意：真 apk 是二进制，直接 head 会让 shell 报 "忽略输入中的 null 字节"，
# 所以先用大小粗筛（指针文件一定 <1KB），再取头部并滤掉 NUL。
is_lfs_pointer() {
    [ -f "$1" ] || return 1
    [ "$(wc -c <"$1" | tr -d ' ')" -lt 1024 ] || return 1
    head -c 40 "$1" 2>/dev/null | tr -d '\000' | grep -q '^version https://git-lfs'
}

# 读 LFS 指针里的 oid / size
lfs_oid()  { sed -n 's/^oid sha256:\(.*\)$/\1/p'  "$1" | head -1; }
lfs_size() { sed -n 's/^size \(.*\)$/\1/p'        "$1" | head -1; }

# ---------------------------------------------------------------------------
# 检查项
# ---------------------------------------------------------------------------
check_webview() {
    say "── external/chromium-webview ──"

    if [ ! -d "${WEBVIEW_DIR}" ]; then
        bad "${WEBVIEW_DIR} 不存在"
        return 1
    fi

    # 1) 目录布局：Android.mk 必须在仓库根
    if [ -f "${WEBVIEW_DIR}/Android.mk" ]; then
        ok "Android.mk 在仓库根"
    elif [ -f "${WEBVIEW_DIR}/patches/Android.mk" ]; then
        todo "Android.mk 错位在 patches/ 下（会让预编译 apk 路径变成 patches/prebuilt/...）"
    else
        bad "找不到 Android.mk"
    fi

    # 2) 预编译 apk 必须是真文件
    _apk="${WEBVIEW_DIR}/prebuilt/arm/webview.apk"
    if [ ! -f "${_apk}" ]; then
        bad "${_apk} 不存在"
    elif is_lfs_pointer "${_apk}"; then
        todo "${_apk} 是 Git LFS 指针（$(wc -c <"${_apk}" | tr -d ' ') 字节），需要下载 $(lfs_size "${_apk}") 字节的真实 apk"
    else
        ok "${_apk} 是真文件（$(wc -c <"${_apk}" | tr -d ' ') 字节）"
    fi

    # 3) patches/external 是给 chromium 源码打补丁用的相对符号链接，
    #    一旦 Android.mk 被移动就会变成悬空链接，导致 all-subdir-makefiles 报错
    if [ -d "${WEBVIEW_DIR}/patches/external" ]; then
        if find "${WEBVIEW_DIR}/patches/external" -xtype l 2>/dev/null | grep -q .; then
            todo "patches/external 里有悬空符号链接（Android.mk 移动后失效）"
        else
            ok "patches/external 无悬空链接"
        fi
    else
        ok "patches/external 已清理"
    fi
}

check_bison() {
    say "── prebuilts/misc/linux-x86/bison ──"
    _b="${BISON_DIR}/bison"
    if [ ! -e "${_b}" ]; then
        bad "${_b} 不存在"
        return 1
    fi
    if is_elf32 "${_b}"; then
        todo "bison 是 32 位 ELF，本机无法执行（缺 ld-linux.so.2）"
    elif head -1 "${_b}" 2>/dev/null | grep -q '^#!/bin/sh'; then
        if [ -x "${BISON_DIR}/bison.orig-32bit" ]; then
            ok "bison 已是包装脚本（原 32 位二进制保留为 bison.orig-32bit）"
        else
            ok "bison 已是包装脚本"
        fi
    else
        ok "bison 可执行（非 32 位）"
    fi
}

# ---------------------------------------------------------------------------
# 修复动作
# ---------------------------------------------------------------------------
fix_webview_layout() {
    if [ -f "${WEBVIEW_DIR}/patches/Android.mk" ] && [ ! -f "${WEBVIEW_DIR}/Android.mk" ]; then
        mv "${WEBVIEW_DIR}/patches/Android.mk"   "${WEBVIEW_DIR}/Android.mk"
        say "  已把 Android.mk 从 patches/ 移到仓库根"
    fi
    if [ -f "${WEBVIEW_DIR}/patches/CleanSpec.mk" ] && [ ! -f "${WEBVIEW_DIR}/CleanSpec.mk" ]; then
        mv "${WEBVIEW_DIR}/patches/CleanSpec.mk" "${WEBVIEW_DIR}/CleanSpec.mk"
        say "  已把 CleanSpec.mk 从 patches/ 移到仓库根"
    fi
    if [ -f "${WEBVIEW_DIR}/patches/README" ] && [ ! -f "${WEBVIEW_DIR}/README" ]; then
        mv "${WEBVIEW_DIR}/patches/README"       "${WEBVIEW_DIR}/README"
        say "  已把 README 从 patches/ 移到仓库根"
    fi
    # patches/external 里的符号链接指向 ../../Android.mk，移动后必然悬空。
    # 这个目录只是为了让 patches/ 能整体覆盖到 chromium 源码树，
    # 对 AOSP 编译没有任何作用，直接删。
    if [ -d "${WEBVIEW_DIR}/patches/external" ]; then
        rm -rf "${WEBVIEW_DIR}/patches/external"
        say "  已删除 patches/external（悬空符号链接）"
    fi
}

download_webview_apk() {
    _apk="${WEBVIEW_DIR}/prebuilt/arm/webview.apk"
    if ! is_lfs_pointer "${_apk}"; then
        return 0
    fi

    _oid=$(lfs_oid "${_apk}")
    _size=$(lfs_size "${_apk}")
    if [ -z "${_oid}" ] || [ -z "${_size}" ]; then
        bad "解析 LFS 指针失败，跳过下载"
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        bad "没有 curl，无法下载 webview.apk（需要手工从 LFS 取 ${_oid}）"
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        bad "没有 python3，无法解析 LFS 返回的 JSON（可手工下载 oid=${_oid} size=${_size}）"
        return 1
    fi

    say "  正在向 LineageOS LFS 申请 ${_oid}（${_size} 字节）的下载地址…"
    _json=$(curl -s -X POST \
        "https://review.lineageos.org/LineageOS/android_external_chromium-webview_prebuilt_arm.git/info/lfs/objects/batch" \
        -H "Content-Type: application/vnd.git-lfs+json" \
        -H "Accept: application/vnd.git-lfs+json" \
        -d "{\"operation\":\"download\",\"transfers\":[\"basic\"],\"objects\":[{\"oid\":\"${_oid}\",\"size\":${_size}}]}")

    _href=$(printf '%s' "${_json}" | python3 -c \
        'import json,sys
try:
    print(json.load(sys.stdin)["objects"][0]["actions"]["download"]["href"])
except Exception:
    pass')

    if [ -z "${_href}" ]; then
        bad "LFS 没有返回下载地址（可能该 oid 已被服务端清理）"
        return 1
    fi

    # LFS 返回的是 S3 预签名地址，有效期只有 60 秒，必须立刻下
    _tmp="${_apk}.download"
    say "  正在下载…"
    if ! curl -sL "${_href}" -o "${_tmp}"; then
        bad "下载失败"
        rm -f "${_tmp}"
        return 1
    fi

    _got=$(wc -c <"${_tmp}" | tr -d ' ')
    if [ "${_got}" != "${_size}" ]; then
        bad "大小不符：期望 ${_size}，实得 ${_got}"
        rm -f "${_tmp}"
        return 1
    fi

    mv "${_apk}" "${_apk}.lfs-pointer.bak"
    mv "${_tmp}" "${_apk}"
    say "  已替换为真实 apk（$(wc -c <"${_apk}" | tr -d ' ') 字节），LFS 指针备份为 webview.apk.lfs-pointer.bak"
}

fix_bison() {
    _b="${BISON_DIR}/bison"
    if ! is_elf32 "${_b}"; then
        return 0
    fi
    if [ ! -x /home/dy/hostbin/bison ]; then
        bad "/home/dy/hostbin/bison 不存在，无法建立包装脚本"
        bad "先确认 /home/dy/hostbin/bison -> toolchain/host64/bin/bison 的软链接在"
        return 1
    fi
    mv "${_b}" "${BISON_DIR}/bison.orig-32bit"
    cat > "${_b}" <<'WRAP'
#!/bin/sh
# 本机环境适配：转调宿主自编的 bison。
# 原 AOSP 预编译 bison 是 32 位 ELF（interpreter /lib/ld-linux.so.2），
# 本机 Flatpak 运行时没有 32 位动态链接器，执行报
#     cannot execute: required file not found
# 原二进制已保留为同目录下的 bison.orig-32bit。
# 详见 device/nvidia/ardbeg/patches/env-fix/fix-source-tree.sh 头部说明。
unset BISON_PKGDATADIR
exec /home/dy/hostbin/bison "$@"
WRAP
    chmod +x "${_b}"
    say "  已把 bison 换成包装脚本（原文件保留为 bison.orig-32bit）"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
say "======================================================================"
say "源码树根目录 : ${TOP}"
say "模式         : ${MODE}"
say "======================================================================"

case "${MODE}" in
    check)
        rc=0
        check_webview || rc=1
        check_bison   || rc=1
        say ""
        say "（check 模式不改任何文件；确认无误后跑 ./fix-source-tree.sh install）"
        exit "${rc}"
        ;;
    install)
        fix_webview_layout
        download_webview_apk || true
        fix_bison
        say ""
        say "── 修复后复查 ──"
        check_webview || true
        check_bison   || true
        ;;
    uninstall)
        if [ -f "${BISON_DIR}/bison.orig-32bit" ]; then
            mv "${BISON_DIR}/bison.orig-32bit" "${BISON_DIR}/bison"
            say "  已还原 bison 为原 32 位二进制"
        fi
        say "  webview.apk 不还原（真实文件保留；如需回退，"
        say "  把 prebuilt/arm/webview.apk.lfs-pointer.bak 改名回 webview.apk）"
        ;;
    -h|--help|help)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "未知模式：${MODE}（可选 check / install / uninstall）" >&2
        exit 2
        ;;
esac
