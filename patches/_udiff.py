#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
_udiff.py —— 纯 Python 的 unified diff 应用器，给 check.sh / install.sh /
uninstall.sh 当兜底工具。

为什么需要它
------------
_common.sh 里原本只认两种打补丁的工具：patch(1) 和 git apply。
但本机（Flatpak 沙箱内外都一样）这两个都没有：
    $ command -v patch git
    （空）
于是 detect_tool 返回 none，三个脚本全部失效。而源码树里自带 python 2.7.5
（prebuilts/python/linux-x86/2.7.5/bin/python2.7），系统也有 python3，
所以这里用 Python 实现一份等价能力，作为第三种工具。

支持的能力（刻意做小，够用就行）
------------------------------
    apply <top> <patch> --forward   正向应用
    apply <top> <patch> --reverse   反向应用（卸载）
    check <top> <patch> --forward   只检查能否正向应用
    check <top> <patch> --reverse   只检查能否反向应用

行为对齐 patch(1) 的关键点
-------------------------
1. 目标文件路径取自 diff 头的 `+++ b/<path>`，去掉 `b/` 前缀（等价 patch -p1）。
2. 每个 hunk 按 `@@ -old_start,old_count +new_start,new_count @@` 定位。
   真实源码树的上下文常有几行漂移，所以找不到精确位置时会在附近
   ±FUZZ 行内搜索；搜索半径用完还找不到就报冲突。
3. 应用成功后保留原文件的换行风格（不做换行符转换）。
4. `check` 模式不写盘，只判断可行性——这样 check.sh 能给出
   「未应用 / 已应用 / 冲突 / 缺失」四种状态，和 patch 版逻辑一致。

退出码
------
    0  成功（check 模式表示"可行"）
    1  失败（check 模式表示"不可行"）
    2  用法错误
"""

from __future__ import print_function

import os
import re
import sys

# hunk 定位失败时，在期望位置附近上下搜索多少行
FUZZ = 200

HUNK_RE = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')


def die(msg, code=1):
    sys.stderr.write("_udiff: %s\n" % msg)
    sys.exit(code)


def read_lines(path):
    """按行读取，保留行尾换行符，避免破坏文件格式。"""
    with open(path, 'rb') as f:
        data = f.read()
    if not data:
        return []
    # 按 \n 切分但保留 \n；最后一段若无换行也要保留
    parts = data.split(b'\n')
    lines = []
    for i, p in enumerate(parts):
        if i == len(parts) - 1:
            if p:
                lines.append(p)
        else:
            lines.append(p + b'\n')
    return lines


def write_lines(path, lines):
    with open(path, 'wb') as f:
        f.write(b''.join(lines))


def parse_patch(patch_path):
    """把补丁解析成 [(target_rel_path, [hunk, ...]), ...]

    hunk = (old_start, old_lines, new_start, new_lines)
    其中 old_lines / new_lines 是 bytes 列表（不含行首标记）。
    """
    lines = read_lines(patch_path)
    files = []
    i = 0
    n = len(lines)

    cur_target = None
    cur_hunks = None

    while i < n:
        line = lines[i]

        if line.startswith(b'--- '):
            # 新文件段的开始。下一个应该是 +++ 行。
            if i + 1 >= n or not lines[i + 1].startswith(b'+++ '):
                die("第 %d 行：--- 之后不是 +++，补丁格式不认识" % (i + 1))
            plus = lines[i + 1][4:].strip()
            # 去掉 a/ b/ 前缀；/dev/null 表示新建或删除文件，本工具不支持
            name = plus.split(b'\t')[0]
            if name == b'/dev/null':
                die("补丁涉及新增/删除整个文件，本工具不支持（请用 patch(1)）")
            if name.startswith(b'b/'):
                name = name[2:]
            cur_target = name.decode('utf-8', 'replace')
            cur_hunks = []
            files.append((cur_target, cur_hunks))
            i += 2
            continue

        m = HUNK_RE.match(line.decode('utf-8', 'replace'))
        if m:
            old_start = int(m.group(1))
            old_count = int(m.group(2)) if m.group(2) is not None else 1
            new_start = int(m.group(3))
            new_count = int(m.group(4)) if m.group(4) is not None else 1

            old_lines = []
            new_lines = []
            i += 1
            # 收集本 hunk 的行，直到下一个 @@ 或下一个 --- 或文件结束
            while i < n:
                hl = lines[i]
                if hl.startswith(b'@@') or hl.startswith(b'--- '):
                    break
                if hl[:1] == b' ':
                    body = hl[1:]
                    old_lines.append(body)
                    new_lines.append(body)
                elif hl[:1] == b'-':
                    old_lines.append(hl[1:])
                elif hl[:1] == b'+':
                    new_lines.append(hl[1:])
                elif hl[:1] == b'\\':
                    # "\ No newline at end of file"，忽略
                    pass
                elif hl in (b'', b'\n'):
                    # 某些工具会在这里塞空行，跳过
                    pass
                else:
                    die("第 %d 行：hunk 内出现无法识别的行首 %r" % (i + 1, hl[:1]))
                i += 1

            # 数量校验：允许 -0,0 这种删除文件的写法带来的差异
            if old_count not in (0, len(old_lines)) or new_count not in (0, len(new_lines)):
                die("hunk 行数与头部声明不符（@@ -%d,%d +%d,%d）："
                    "实际 old=%d new=%d"
                    % (old_start, old_count, new_start, new_count,
                       len(old_lines), len(new_lines)))

            cur_hunks.append((old_start, old_lines, new_start, new_lines))
            continue

        i += 1

    if not files:
        die("补丁里没有找到任何文件段")
    return files


def find_hunk(lines, old_lines, expect):
    """在 lines 里找 old_lines 出现的位置。

    expect 是 0-based 的期望起始行号（由 @@ -old_start 换算而来）。
    先试 expect，再从近到远在 ±FUZZ 内搜索。
    """
    if not old_lines:
        # 纯插入：直接落在 expect 处
        return max(0, min(expect, len(lines)))

    total = len(lines)
    cand = max(0, min(expect, total))

    def matches(pos):
        if pos < 0 or pos + len(old_lines) > total:
            return False
        return lines[pos:pos + len(old_lines)] == old_lines

    if matches(cand):
        return cand

    for d in range(1, FUZZ + 1):
        if matches(cand - d):
            return cand - d
        if matches(cand + d):
            return cand + d

    return -1


def apply_one(top, rel, hunks, reverse, dry_run):
    """把 hunks 应用到 top/rel。返回 True/False。"""
    path = os.path.join(top, rel)
    if not os.path.isfile(path):
        return False, "目标文件不存在: %s" % rel

    lines = read_lines(path)

    for idx, (old_start, old_lines, new_start, new_lines) in enumerate(hunks):
        if reverse:
            src, dst, start = new_lines, old_lines, new_start
        else:
            src, dst, start = old_lines, new_lines, old_start

        # @@ -1,3 表示从第 1 行开始 -> 0-based 索引 0
        expect = start - 1
        pos = find_hunk(lines, src, expect)
        if pos < 0:
            return False, "%s 第 %d 个 hunk 上下文对不上（期望附近第 %d 行）" % (
                rel, idx + 1, start)

        lines[pos:pos + len(src)] = dst

    if not dry_run:
        write_lines(path, lines)
    return True, ""


def main(argv):
    if len(argv) < 5:
        sys.stderr.write(__doc__)
        return 2

    mode = argv[1]
    top = argv[2]
    patch = argv[3]
    direction = argv[4]

    if mode not in ('apply', 'check'):
        die("mode 只能是 apply 或 check", 2)
    if direction not in ('--forward', '--reverse'):
        die("方向只能是 --forward 或 --reverse", 2)

    if not os.path.isdir(top):
        die("源码树根目录不存在: %s" % top)
    if not os.path.isfile(patch):
        die("补丁文件不存在: %s" % patch)

    reverse = (direction == '--reverse')
    dry_run = (mode == 'check')

    files = parse_patch(patch)
    for rel, hunks in files:
        ok, why = apply_one(top, rel, hunks, reverse, dry_run)
        if not ok:
            sys.stderr.write("_udiff: %s\n" % why)
            return 1

    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
