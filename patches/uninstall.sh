#!/bin/sh
# =============================================================================
# uninstall.sh —— 反向应用补丁，把 CM11 源码恢复成干净状态
#
# 行为：
#   * 只处理当前处于"已应用"状态的补丁，未应用的自动跳过
#   * 按**倒序**处理（和安装顺序相反），避免同一文件被多个补丁改过时上下文错位
#   * 用 patch(1) 时，如果源码树里还留着 .orig 备份，反向成功后一并清掉
#
# 用法：
#   ./uninstall.sh            # 正常卸载
#   ./uninstall.sh -n         # 只演练，不落盘
#   ./uninstall.sh -f         # 遇到失败也继续
#   ./uninstall.sh -v         # 打印每条命令
# =============================================================================

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
. "${HERE}/_common.sh"

DRYRUN=0
FORCE=0
VERBOSE=0

for arg in "$@"; do
    case "$arg" in
        -n|--dry-run) DRYRUN=1 ;;
        -f|--force)   FORCE=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "未知参数: $arg（用 -h 看用法）" >&2
            exit 2
            ;;
    esac
done

TOP=$(detect_top) || exit 1
TOOL=$(detect_tool)

if [ "$TOOL" = "none" ]; then
    echo "错误：patch / git / python 三者都不可用，没法卸载补丁。" >&2
    echo "      正常情况不该走到这里：没有 patch 和 git 时会自动退回" >&2
    echo "      同目录的 _udiff.py（需要 python）。" >&2
    exit 1
fi

PATCHES=$(list_patches "${HERE}")
MODES=$(list_mode_fixes "${HERE}")
if [ -z "${PATCHES}" ] && [ -z "${MODES}" ]; then
    echo "没有找到任何 .patch 文件，也没有权限修复条目，不需要卸载。"
    exit 0
fi

echo "======================================================================"
echo "源码树根目录 : ${TOP}"
echo "补丁工具     : ${TOOL}"
[ "${DRYRUN}" -eq 1 ] && echo "模式         : 演练（不会改文件）"
echo "======================================================================"

# 倒序：安装是正序，卸载必须反序
REVERSED=$(echo "${PATCHES}" | sed '1!G;h;$!d')

OK=0
SKIP=0
FAIL=0
STOPPED=0

for p in ${REVERSED}; do
    st=$(patch_status "${TOP}" "${HERE}/${p}" "${TOOL}")

    if [ "${st}" != "applied" ]; then
        printf "  [跳过] %s（当前状态：%s）\n" "${p}" "$(status_cn "${st}")"
        SKIP=$((SKIP + 1))
        continue
    fi

    if [ "${DRYRUN}" -eq 1 ]; then
        printf "  [可以] %s（演练，未落盘）\n" "${p}"
        OK=$((OK + 1))
        continue
    fi

    if [ "${VERBOSE}" -eq 1 ]; then
        echo "        执行: patch_do ${TOP} ${HERE}/${p} reverse ${TOOL}"
    fi

    if patch_do "${TOP}" "${HERE}/${p}" reverse "${TOOL}" >/dev/null 2>&1; then
        printf "  [还原] %s\n" "${p}"
        OK=$((OK + 1))

        # patch(1) 留下的 .orig 备份，反向成功就没用了，顺手清掉。
        # 只删 .orig，绝不碰源码本身。
        if [ "${TOOL}" = "patch" ]; then
            t="${TOP}/$(target_of "${p}")"
            [ -f "${t}.orig" ] && rm -f "${t}.orig"
            [ -f "${t}.rej" ] && rm -f "${t}.rej"
        fi
    else
        printf "  [失败] %s —— 反向应用失败，源码可能被手工改过\n" "${p}"
        FAIL=$((FAIL + 1))
        if [ "${FORCE}" -eq 0 ]; then STOPPED=1; break; fi
    fi
done

echo
echo "----------------------------------------------------------------------"
echo "还原 ${OK} / 跳过 ${SKIP} / 失败 ${FAIL}"
echo "----------------------------------------------------------------------"

# ---------------------------------------------------------------------------
# 反向处理文件权限修复
#   file-modes.txt 里记的是「期望权限」，反向就是改回 0644
#   （这棵树从归档解出来时的原始值）。
# ---------------------------------------------------------------------------
if [ -n "${MODES}" ]; then
    echo
    echo "文件权限修复（反向）："
    _tmp=$(mktemp 2>/dev/null || echo "/tmp/ardbeg-modes-un.$$")
    echo "${MODES}" | while read -r rel want rest; do
        [ -z "${rel}" ] && continue
        cur=$(mode_current "${TOP}" "${rel}")
        if [ ! -e "${TOP}/${rel}" ]; then
            printf "  [跳过] %-48s 文件不存在\n" "${rel}"
            echo "skip" >> "${_tmp}"
            continue
        fi
        if [ "${DRYRUN}" -eq 1 ]; then
            printf "  [可以] %-48s %s -> 0644（演练，未落盘）\n" "${rel}" "${cur}"
            echo "ok" >> "${_tmp}"
        elif mode_do "${TOP}" "${rel}" "${want}" reverse; then
            printf "  [还原] %-48s %s -> 0644\n" "${rel}" "${cur}"
            echo "ok" >> "${_tmp}"
        else
            printf "  [失败] %-48s chmod 失败\n" "${rel}"
            echo "fail" >> "${_tmp}"
        fi
    done
    # grep -c 无匹配时也打印 0，所以不要加 `|| echo 0`
    M_OK=$(grep -c '^ok$'   "${_tmp}" 2>/dev/null)
    M_SK=$(grep -c '^skip$' "${_tmp}" 2>/dev/null)
    M_NG=$(grep -c '^fail$' "${_tmp}" 2>/dev/null)
    : "${M_OK:=0}"; : "${M_SK:=0}"; : "${M_NG:=0}"
    rm -f "${_tmp}"
    echo
    echo "  权限还原：成功 ${M_OK} / 跳过 ${M_SK} / 失败 ${M_NG}"
    FAIL=$((FAIL + M_NG))
fi

if [ "${STOPPED}" -eq 1 ]; then
    echo
    echo "遇到失败已中止。反向失败通常是源码被手工改过，"
    echo "可以用 repo forall -c 'git checkout -- .' 或 repo sync 强制回干净状态。"
fi

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi

exit 0
