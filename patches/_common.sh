#!/bin/sh
# =============================================================================
# _common.sh —— check.sh / install.sh / uninstall.sh 的公共函数
#
# 不要直接执行这个文件，它是被另外三个脚本 source 的。
#
# 这里集中放了三件容易写歪的事：
#   1) 怎么找到源码树根目录
#   2) 怎么判断一个补丁当前处于什么状态（未应用 / 已应用 / 冲突 / 缺失）
#   3) 怎么应用 / 反向应用
# 三个脚本共用同一套逻辑，避免"check 说能打、install 却打不上"这种自相矛盾。
# =============================================================================

# -----------------------------------------------------------------------------
# 定位源码树根目录
#   本文件在 device/nvidia/ardbeg/patches/ 下，往上四层就是源码树根。
#   优先用环境变量 ANDROID_BUILD_TOP（在源码树里执行过 envsetup.sh/lunch 后
#   这个变量就有值），没有再按相对路径推。
# -----------------------------------------------------------------------------
detect_top() {
    if [ -n "${ANDROID_BUILD_TOP:-}" ] && [ -d "${ANDROID_BUILD_TOP}/build/core" ]; then
        echo "${ANDROID_BUILD_TOP}"
        return 0
    fi

    _here=$(cd "$(dirname "$0")" && pwd)
    _top=$(cd "${_here}/../../../.." && pwd)

    if [ ! -d "${_top}/build/core" ]; then
        echo "错误：推算出来的源码树根目录不对：${_top}" >&2
        echo "      那里没有 build/core 目录。" >&2
        echo "      可以手动指定：ANDROID_BUILD_TOP=/path/to/lineage $0" >&2
        return 1
    fi

    echo "${_top}"
}

# -----------------------------------------------------------------------------
# 选一个打补丁的工具
#   优先用 patch(1)：它是 POSIX 工具，编译机上一定有，而且默认会生成
#   .orig 备份、把失败的 hunk 存成 .rej，排查方便。
#   没有 patch 才退回 git apply。
#   两个都没有就用本目录下的 _udiff.py（纯 Python 实现）。
#
#   [新增 2026-10-28] 加 python 兜底的原因：
#   本机是 Flatpak 打包的最小环境，`command -v patch git` 两个都是空，
#   连 /usr/bin/patch 都没有。原来的实现到 detect_tool 就返回 none，
#   三个脚本直接罢工。源码树自带 python 2.7.5，系统也有 python3，
#   所以补一条 Python 路线，保证这套脚本在任何机器上都可用。
# -----------------------------------------------------------------------------
# [2026-11-12 固化修复] 候选解释器必须「真的能跑」，不能只看 -x。
#
#   踩过的坑：prebuilts/python/linux-x86/2.7.5/bin/python2.7 文件存在、
#   有可执行位（-x 为真），但它缺动态 loader，实际执行报
#       bash: ...: 无法执行：找不到需要的文件
#   旧版 find_python() 只看 -x 就把它返回；check.sh 用这个解释器跑
#   py_compile 得到 rc=127，于是把两个本来语法完全正确的 .py
#   （tools/gen_flash_blocks.py、tools/verify_six_layers.py）误报成
#   「语法检查失败」。这类「装了但跑不了」的解释器必须用一次真实执行筛掉。
#   注意：宿主构建环境里不一定有容器专属的 managed python 路径，所以下面
#   每一档都要过 _py_can_run，失败就继续找下一档。
_py_can_run() {
    [ -x "$1" ] || return 1
    "$1" -c 'pass' >/dev/null 2>&1
}

find_python() {
    # 1) 首选 managed python3（容器内路径；宿主上不存在会自动跳过）
    _c="/home/dy/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3"
    if _py_can_run "${_c}"; then
        echo "${_c}"
        return 0
    fi
    # 2) 系统 python3 优先于 python2：本目录的 .py 都是 py2/py3 兼容，
    #    而 check.sh 里读 zip / build.prop 的片段用 python3 最稳。
    #    command -v 只保证「有这个名字」，仍要过 _py_can_run 才算数。
    for c in python3 python2 python python2.7; do
        _p=$(command -v "$c" 2>/dev/null) || continue
        if _py_can_run "${_p}"; then
            echo "${_p}"
            return 0
        fi
    done
    # 3) 最后才轮到源码树自带的 python2.7.5，且同样要过可执行性探测。
    _top="${1:-}"
    if [ -n "${_top}" ]; then
        _p="${_top}/prebuilts/python/linux-x86/2.7.5/bin/python2.7"
        if _py_can_run "${_p}"; then
            echo "${_p}"
            return 0
        fi
    fi
    echo ""
}

detect_tool() {
    if command -v patch >/dev/null 2>&1; then
        echo "patch"
    elif command -v git >/dev/null 2>&1; then
        echo "git"
    else
        # 兜底：_udiff.py 在 patches/ 目录下，和本文件同级
        _here=$(cd "$(dirname "$0")" && pwd)
        if [ -f "${_here}/_udiff.py" ]; then
            echo "python"
        else
            echo "none"
        fi
    fi
}

# 调用 _udiff.py 的封装。$1=mode(apply|check) $2=top $3=patch $4=--forward|--reverse
udiff_run() {
    _here=$(cd "$(dirname "$0")" && pwd)
    _py=$(find_python "${2}")
    if [ -z "${_py}" ]; then
        echo "_common.sh: 找不到 python，无法使用 _udiff.py 兜底" >&2
        return 1
    fi
    "${_py}" "${_here}/_udiff.py" "$1" "$2" "$3" "$4"
}

# -----------------------------------------------------------------------------
# 列出所有补丁（相对 patches/ 的路径，按字典序 = 稳定的应用顺序）
#
# 【2026-11-04 改动】排除 legacy-cm11/
#   patches/ 下这批补丁最初是为 cm-11（Android 4.4.4）那棵树生成的。
#   移植到 cm-14.1 后，源码版本变了（比如 system/vold、frameworks/rs、
#   external/v8 都换了实现），这些补丁的上下文全部对不上，
#   check.sh 会刷 18 条"冲突/缺失"，掩盖真正需要注意的东西。
#   它们作为历史资料移到 legacy-cm11/ 保留，不再参与自动打补丁。
# -----------------------------------------------------------------------------
list_patches() {
    _dir="$1"
    # shellcheck disable=SC2012
    ( cd "${_dir}" && find . -type f -name '*.patch' \
        | sed 's|^\./||' \
        | grep -v '^legacy-cm11/' \
        | sort )
}

# -----------------------------------------------------------------------------
# 补丁 -> 目标文件在源码树里的相对路径
#   patches/frameworks/av/foo/bar.cpp.patch  ->  frameworks/av/foo/bar.cpp
#
# 注意：三个脚本内部传给 patch_status / patch_do 的是**绝对路径**
# （${HERE}/${p}），所以这里必须先把 patches 目录前缀剥掉，否则会拼出
# /top//top/device/... 这种路径，导致所有补丁都被误判成"缺失"。
# 两种形式都支持，调用方不用关心。
# -----------------------------------------------------------------------------
target_of() {
    _p="$1"

    # 绝对路径形式：去掉 ${HERE}/ 前缀（HERE 由调用脚本在 source 之前设好）
    if [ -n "${HERE:-}" ]; then
        case "$_p" in
            "${HERE}/"*) _p=${_p#"${HERE}/"} ;;
        esac
    fi
    # 万一有人传了 "patches/xxx" 这种形式
    _p=${_p#patches/}

    # 去掉 .patch 后缀
    echo "${_p%.patch}"
}

# -----------------------------------------------------------------------------
# 判断补丁状态，输出：not_applied / applied / conflict / missing
#
#   missing      目标文件不存在（路径写错，或对应仓库没同步下来）
#   applied      反向 dry-run 能过 -> 说明源码里已经是"改后"的样子
#   not_applied  正向 dry-run 能过 -> 可以正常打
#   conflict     两边都过不了 -> 上下文对不上，需要人工看
# -----------------------------------------------------------------------------
patch_status() {
    _top="$1"; _patch="$2"; _tool="$3"

    _target=$(target_of "$_patch")
    if [ ! -f "${_top}/${_target}" ]; then
        echo "missing"
        return
    fi

    if [ "$_tool" = "patch" ]; then
        if patch -p1 -d "${_top}" --dry-run --reverse -i "$_patch" >/dev/null 2>&1; then
            echo "applied"; return
        fi
        if patch -p1 -d "${_top}" --dry-run --forward -i "$_patch" >/dev/null 2>&1; then
            echo "not_applied"; return
        fi
    elif [ "$_tool" = "git" ]; then
        if git -C "${_top}" apply --reverse --check -p1 "$_patch" >/dev/null 2>&1; then
            echo "applied"; return
        fi
        if git -C "${_top}" apply --check -p1 "$_patch" >/dev/null 2>&1; then
            echo "not_applied"; return
        fi
    else
        # python 兜底：check 模式只读不写
        if udiff_run check "${_top}" "$_patch" --reverse >/dev/null 2>&1; then
            echo "applied"; return
        fi
        if udiff_run check "${_top}" "$_patch" --forward >/dev/null 2>&1; then
            echo "not_applied"; return
        fi
    fi

    echo "conflict"
}

# -----------------------------------------------------------------------------
# 应用 / 反向应用
#   $3 = forward | reverse
#   返回 0 成功，非 0 失败
# -----------------------------------------------------------------------------
patch_do() {
    _top="$1"; _patch="$2"; _dir="$3"; _tool="$4"

    if [ "$_tool" = "patch" ]; then
        if [ "$_dir" = "forward" ]; then
            # --forward：已经打过的 hunk 跳过而不是反问，保证脚本非交互
            patch -p1 -d "${_top}" --forward -i "$_patch"
        else
            patch -p1 -d "${_top}" --reverse -i "$_patch"
        fi
    elif [ "$_tool" = "git" ]; then
        if [ "$_dir" = "forward" ]; then
            git -C "${_top}" apply -p1 "$_patch"
        else
            git -C "${_top}" apply --reverse -p1 "$_patch"
        fi
    else
        if [ "$_dir" = "forward" ]; then
            udiff_run apply "${_top}" "$_patch" --forward
        else
            udiff_run apply "${_top}" "$_patch" --reverse
        fi
    fi
}

# 把状态码翻译成给人看的中文
status_cn() {
    case "$1" in
        not_applied) echo "未应用" ;;
        applied)     echo "已应用" ;;
        conflict)    echo "冲突  " ;;
        missing)     echo "缺失  " ;;
        *)           echo "$1" ;;
    esac
}

# -----------------------------------------------------------------------------
# 文件权限修复（file-modes.txt）
#
# 【为什么不能用 patch 做】
#   unified diff 表达不了 mode 变更。git diff 里的
#   `old mode 100644 / new mode 100755` 是 git 的扩展，patch(1) 直接忽略，
#   _udiff.py 也不处理。所以权限类修复走单独一条通道。
#
# 【为什么会有这个问题】
#   本工程的 cm-14.1 源码树是从归档解出来的，整棵树的可执行位全丢了。
#   绝大多数不影响（AOSP 自己的模块由 LOCAL_MODULE_CLASS := EXECUTABLES
#   设权限），只有用 PRODUCT_COPY_FILES 裸拷进镜像的脚本会中招 ——
#   那条路径是 `cp -f`，权限原样带过去。
#   已确认的受害者是 system/bin/sysinit（详见 file-modes.txt）。
# -----------------------------------------------------------------------------

# 列出所有权限修复条目，输出 "path<TAB>mode"（已去掉注释和空行）
list_mode_fixes() {
    _f="$1/file-modes.txt"
    [ -f "$_f" ] || return 0
    # 去掉行尾注释，再过滤空行
    sed 's/#.*//' "$_f" | grep -v '^[[:space:]]*$'
}

# 状态：applied / not_applied / missing
#   $1=top  $2=相对路径  $3=期望权限（八进制字符串，如 0755）
mode_status() {
    _top="$1"; _rel="$2"; _want="$3"

    if [ ! -e "${_top}/${_rel}" ]; then
        echo "missing"; return
    fi

    # stat -c '%a' 在 GNU coreutils 上给 "755" / "644"；
    # 加 0 前缀转成八进制数再比，避免 0755 vs 755 这种字符串差异。
    _cur=$(stat -c '%a' "${_top}/${_rel}" 2>/dev/null)
    if [ -z "${_cur}" ]; then
        echo "missing"; return
    fi

    if [ "$((0${_cur}))" -eq "$((0${_want}))" ]; then
        echo "applied"
    else
        echo "not_applied"
    fi
}

# 当前权限（给人看）
mode_current() {
    stat -c '%a' "$1/$2" 2>/dev/null || echo "?"
}

# 应用 / 反向应用
#   $4 = forward  -> chmod 到期望值
#   $4 = reverse  -> chmod 回 0644（这棵树 checkout 出来的原始值）
mode_do() {
    _top="$1"; _rel="$2"; _want="$3"; _dir="$4"

    if [ ! -e "${_top}/${_rel}" ]; then
        return 1
    fi

    if [ "$_dir" = "forward" ]; then
        chmod "$_want" "${_top}/${_rel}"
    else
        chmod 0644 "${_top}/${_rel}"
    fi

    # 【关键】chmod 只改 ctime，不改 mtime。
    #   而 PRODUCT_COPY_FILES 的规则靠**源文件 mtime** 判断要不要重拷，
    #   所以只 chmod 不 touch 的话，ninja 认为拷贝结果还是最新的，
    #   不会重新 cp，镜像里的权限也就不会更新 —— 看起来"改了没生效"。
    touch "${_top}/${_rel}" 2>/dev/null || true

    return 0
}
