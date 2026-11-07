#!/bin/sh
# =============================================================================
# install.sh —— 把 device/nvidia/ardbeg/patches/ 下的补丁打到 CM11 源码树上
#
# 行为：
#   * 已经应用的补丁自动跳过（可重复执行）
#   * 默认遇到冲突就停下，后面的补丁不再处理（避免半套状态）
#   * 用 patch(1) 时会在源码树里留 .orig 备份，卸载脚本会用到
#
# 用法：
#   ./install.sh              # 正常安装
#   ./install.sh -n           # 只演练，不落盘（等价于 check.sh）
#   ./install.sh -f           # 遇到冲突也继续装后面的
#   ./install.sh -v           # 打印每条命令
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
            sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
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
    echo "错误：patch / git / python 三者都不可用，没法打补丁。" >&2
    echo "      正常情况不该走到这里：没有 patch 和 git 时会自动退回" >&2
    echo "      同目录的 _udiff.py（需要 python）。" >&2
    exit 1
fi

PATCHES=$(list_patches "${HERE}")
MODES=$(list_mode_fixes "${HERE}")
if [ -z "${PATCHES}" ] && [ -z "${MODES}" ]; then
    echo "没有找到任何 .patch 文件，也没有权限修复条目，不需要安装。"
    echo "（当前所有改动都在设备树内部，没有修改 cm14.1 源码）"
    exit 0
fi

echo "======================================================================"
echo "源码树根目录 : ${TOP}"
echo "补丁工具     : ${TOOL}"
[ "${DRYRUN}" -eq 1 ] && echo "模式         : 演练（不会改文件）"
echo "======================================================================"

OK=0
SKIP=0
FAIL=0
STOPPED=0

for p in ${PATCHES}; do
    st=$(patch_status "${TOP}" "${HERE}/${p}" "${TOOL}")

    case "${st}" in
        applied)
            printf "  [跳过] %s（已经打过了）\n" "${p}"
            SKIP=$((SKIP + 1))
            continue
            ;;
        missing)
            printf "  [失败] %s —— 目标文件不存在\n" "${p}"
            FAIL=$((FAIL + 1))
            if [ "${FORCE}" -eq 0 ]; then STOPPED=1; break; fi
            continue
            ;;
        conflict)
            printf "  [失败] %s —— 上下文对不上，打不上\n" "${p}"
            FAIL=$((FAIL + 1))
            if [ "${FORCE}" -eq 0 ]; then STOPPED=1; break; fi
            continue
            ;;
    esac

    if [ "${DRYRUN}" -eq 1 ]; then
        printf "  [可以] %s（演练，未落盘）\n" "${p}"
        OK=$((OK + 1))
        continue
    fi

    if [ "${VERBOSE}" -eq 1 ]; then
        echo "        执行: patch_do ${TOP} ${HERE}/${p} forward ${TOOL}"
    fi

    if patch_do "${TOP}" "${HERE}/${p}" forward "${TOOL}" >/dev/null 2>&1; then
        printf "  [完成] %s\n" "${p}"
        OK=$((OK + 1))
    else
        printf "  [失败] %s —— patch 返回非 0，看源码树里的 .rej\n" "${p}"
        FAIL=$((FAIL + 1))
        if [ "${FORCE}" -eq 0 ]; then STOPPED=1; break; fi
    fi
done

echo
echo "----------------------------------------------------------------------"
echo "成功 ${OK} / 跳过 ${SKIP} / 失败 ${FAIL}"
echo "----------------------------------------------------------------------"

# ---------------------------------------------------------------------------
# 文件权限修复
#   patch(1) 表达不了 mode 变更，所以单独处理。
#   详见 _common.sh 里的 list_mode_fixes / mode_do 和 file-modes.txt 头部说明。
# ---------------------------------------------------------------------------
MODE_OK=0
MODE_SKIP=0
MODE_FAIL=0

if [ -n "${MODES}" ]; then
    echo
    echo "文件权限修复："
    # 用临时文件收集结果：`echo | while` 的循环体在子 shell 里，
    # 直接改计数器会丢，所以把每条结果写文件再统计。
    _tmp=$(mktemp 2>/dev/null || echo "/tmp/ardbeg-modes.$$")
    echo "${MODES}" | while read -r rel want rest; do
        [ -z "${rel}" ] && continue
        st=$(mode_status "${TOP}" "${rel}" "${want}")
        cur=$(mode_current "${TOP}" "${rel}")
        case "${st}" in
            applied)
                printf "  [跳过] %-48s 已经是 %s\n" "${rel}" "${want}"
                echo "skip" >> "${_tmp}"
                ;;
            missing)
                printf "  [失败] %-48s 文件不存在\n" "${rel}"
                echo "fail" >> "${_tmp}"
                ;;
            not_applied)
                if [ "${DRYRUN}" -eq 1 ]; then
                    printf "  [可以] %-48s %s -> %s（演练，未落盘）\n" \
                           "${rel}" "${cur}" "${want}"
                    echo "ok" >> "${_tmp}"
                elif mode_do "${TOP}" "${rel}" "${want}" forward; then
                    printf "  [完成] %-48s %s -> %s\n" "${rel}" "${cur}" "${want}"
                    echo "ok" >> "${_tmp}"
                else
                    printf "  [失败] %-48s chmod 失败\n" "${rel}"
                    echo "fail" >> "${_tmp}"
                fi
                ;;
        esac
    done
    # 注意：grep -c 在「无匹配」时也会打印 0（只是退出码为 1），
    # 所以这里不能写 `|| echo 0` —— 那会得到 "0\n0"，后面算术展开直接报错。
    MODE_OK=$(grep -c '^ok$'   "${_tmp}" 2>/dev/null)
    MODE_SKIP=$(grep -c '^skip$' "${_tmp}" 2>/dev/null)
    MODE_FAIL=$(grep -c '^fail$' "${_tmp}" 2>/dev/null)
    : "${MODE_OK:=0}"; : "${MODE_SKIP:=0}"; : "${MODE_FAIL:=0}"
    rm -f "${_tmp}"
    echo
    echo "  权限修复：成功 ${MODE_OK} / 跳过 ${MODE_SKIP} / 失败 ${MODE_FAIL}"
    FAIL=$((FAIL + MODE_FAIL))
fi

if [ "${STOPPED}" -eq 1 ]; then
    echo
    echo "因为遇到失败已经中止。已成功的补丁保持已应用状态，"
    echo "可以先用 ./check.sh 看清全貌，再决定是 --force 继续还是回滚。"
fi

if [ "${FAIL}" -gt 0 ]; then
    echo
    echo "排查提示："
    echo "  * 失败时 patch 会把打不上的 hunk 存成 <目标文件>.rej，"
    echo "    原始文件备份在 <目标文件>.orig。"
    echo "  * 用 ./uninstall.sh 可以整体回滚已经打上的补丁。"
    exit 1
fi

exit 0
