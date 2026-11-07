#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_audio_policy.py —— 修正 NVIDIA 预编译 audio_policy.tegra.so 的 ABI 错位

【问题】
  g100/ardbeg 的 CM11 用的是厂商预编译的 audio_policy.tegra.so
  （vendor/nvidia/ardbeg/proprietary/lib/hw/audio_policy.tegra.so，83516 字节，
   里面是 NVIDIA 的 NvAudioPolicyManager）。它是按 Android 4.3 时代的
  hardware/libhardware/include/hardware/audio_policy.h 编译的，而 CM11 是 4.4.4，
  这个头文件里的 struct audio_policy_service_ops 少了一个成员：

      4.3（NVIDIA 编译时）              4.4.4（CM11 现在）
      -----------------------------     -----------------------------
      [0]  open_output                  [0]  open_output
      [1]  open_duplicate_output        [1]  open_duplicate_output
      [2]  close_output                 [2]  close_output
      [3]  suspend_output               [3]  suspend_output
      [4]  restore_output               [4]  restore_output
      [5]  open_input                   [5]  open_input
      [6]  close_input                  [6]  close_input
      [7]  set_stream_volume            [7]  set_stream_volume
      [8]  set_stream_output            [8]  set_stream_output
      [9]  invalidate_input      <--删   [9]  set_parameters
      [10] set_parameters               [10] get_parameters
      [11] get_parameters               [11] start_tone
      [12] start_tone                   [12] stop_tone
      [13] stop_tone                    [13] set_voice_volume
      [14] set_voice_volume             [14] move_effects
      [15] move_effects                 [15] load_hw_module
      [16] load_hw_module               [16] open_output_on_module
                                        [17] open_input_on_module

  也就是说：4.3 的 invalidate_input 在 4.4.4 被删掉了，导致从第 9 项开始
  **后面所有函数指针整体前移一格（4 字节）**。

  后果（这就是「能开机但音频全坏」的真正原因）：
    - 预编译 blob 调 load_hw_module（偏移 64），实际打到我们的
      aps_open_output_on_module 上，模块句柄参数其实是字符串指针，
      AudioFlinger 查不到这个句柄，**静默返回 0**。
    - 于是 AudioPolicyManagerBase 打出 "could not open HW module primary"，
      而且**一条别的日志都没有**（因为根本没走到 load_audio_interface）。
    - 最终 dumpsys media.audio_policy 里 Output devices 恒为 00000000。

【本脚本做什么】
  直接改预编译 .so 里 AudioPolicyCompatClient 那几个转发函数的机器码，
  把读 ops 结构体的偏移从「4.3 的槽位」改成「4.4.4 的槽位」，即 offset-4。
  这样不用重新编译整个 AOSP（本机 out/ 目录不存在，全量编译要几小时+60G）。

  需要改的 7 个偏移（>= 36 的都要减 4）：
      64 -> 60  loadHwModule      打到 aps_load_hw_module        ← 关键
      60 -> 56  moveEffects       打到 aps_move_effects
      56 -> 52  setVoiceVolume    打到 aps_set_voice_volume
      52 -> 48  stopTone          打到 aps_stop_tone
      48 -> 44  startTone         打到 aps_start_tone
      44 -> 40  getParameters     打到 aps_get_parameters
      40 -> 36  setParameters     打到 aps_set_parameters

  另外 invalidateInput（偏移 36）在 4.4.4 里没有对应实现，
  直接改成「立刻返回 1（错误）」，避免它去调 aps_set_parameters 而崩掉。

【为什么改机器码是安全的】
  - ARM Thumb 的 LDR(immediate) 是 16 位定长指令，改 imm5 只动这 2 个字节，
    不影响其它指令、不影响地址、不影响重定位。
  - 改完立刻重新反汇编逐条核对。
  - 原文件保留备份，随时可回滚。
"""
import re
import shutil
import subprocess
import sys

OBJDUMP = "/home/dy/WorkBuddy AI/lineage/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.7/bin/arm-linux-androideabi-objdump"

# Thumb LDR (immediate) T1 编码：0110 1 imm5 Rn Rt
LDR_IMM_BASE = 0x6800
NOP = 0xBF00
MOVS_R0_1 = 0x2001  # movs r0, #1


def enc_ldr_imm(rt, rn, offset):
    """把 (Rt, Rn, 字节偏移) 编码成 Thumb LDR(imm) 的 16 位机器码。"""
    assert offset % 4 == 0, "偏移必须是 4 的倍数"
    imm5 = offset // 4
    assert 0 <= imm5 < 32, "imm5 超出范围"
    return LDR_IMM_BASE | (imm5 << 6) | (rn << 3) | rt


def disasm(path):
    """反汇编，返回 {函数名: [(地址, 机器码字节hex, 汇编文本), ...]}"""
    out = subprocess.run([OBJDUMP, "-d", "--demangle", path],
                         capture_output=True, text=True).stdout
    funcs = {}
    cur = None
    for line in out.splitlines():
        m = re.match(r"^([0-9a-f]+) <(.+)>:$", line)
        if m:
            cur = m.group(2)
            funcs[cur] = []
            continue
        if cur is None:
            continue
        m = re.match(r"^\s+([0-9a-f]+):\t([0-9a-f ]+)\t(.*)$", line)
        if m:
            asm = m.group(3).strip()
            # objdump 对大立即数会在后面补注释，例如
            #     ldr\tr2, [r3, #64]\t; 0x40
            # 这里把注释去掉，否则带 $ 的正则会匹配失败
            asm = re.sub(r"\s*;.*$", "", asm)
            funcs[cur].append((int(m.group(1), 16), m.group(2).strip(), asm))
    return funcs


def find_ops_dispatch(instrs):
    """
    在一个 AudioPolicyCompatClient 转发函数里，找出「从 ops 表取函数指针并跳过去」的那条指令。

    典型形态（loadHwModule）：
        ldr r3, [r0, #4]      ; r3 = this->mServiceOps
        ldr r0, [r0, #8]      ; r0 = this->mService
        ldr r2, [r3, #64]     ; r2 = mServiceOps->load_hw_module
        blx r2

    但不同函数的形态不完全一样，例如：
      - setParameters 中间插了 ldr r2, [r2, #0]
      - getParameters 的 ops 基址在 r0 而不是 r3，且 ldr 和 blx 之间还夹了一条
      - openInput     读的是偏移 72（NVIDIA 的 open_input_on_module）

    所以这里改成：
      1) 先收集「从 [rX, #4] 取出来的寄存器」，那就是 mServiceOps 的候选
      2) 再找 `ldr rT, [rB, #off]`，要求 rB 是候选、off >= 36、且后面 4 条内有 blx rT
    返回 [(ldr索引, blx索引, 基址寄存器, 目标寄存器, 偏移), ...]
    """
    hits = []
    ops_regs = set()
    for i, (addr, code, asm) in enumerate(instrs):
        m = re.match(r"ldr\s+r(\d+),\s*\[r\d+, #4\]$", asm)
        if m:
            ops_regs.add(int(m.group(1)))
            continue
        m = re.match(r"ldr\s+r(\d+),\s*\[r(\d+), #(\d+)\]$", asm)
        if not m:
            continue
        rt, rb, off = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if rb not in ops_regs:
            continue
        if off < 36:
            # 36 之前的成员在 4.3 和 4.4.4 里位置相同，不用动
            continue
        for j in range(i + 1, min(i + 5, len(instrs))):
            if re.match(r"blx\s+r%d$" % rt, instrs[j][2]):
                hits.append((i, j, rb, rt, off))
                break
    return hits


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "audio_policy.tegra.so"
    dst = sys.argv[2] if len(sys.argv) > 2 else "audio_policy.tegra.patched.so"

    shutil.copyfile(src, dst)
    data = bytearray(open(dst, "rb").read())

    funcs = disasm(dst)
    targets = [n for n in funcs if "AudioPolicyCompatClient::" in n]
    print("找到 %d 个 AudioPolicyCompatClient 转发函数\n" % len(targets))

    changed = 0
    for name in sorted(targets, key=lambda n: funcs[n][0][0]):
        short = name.split("::")[-1]
        hits = find_ops_dispatch(funcs[name])
        if not hits:
            continue
        for li, bi, base_reg, rt, off in hits:
            addr_ldr = funcs[name][li][0]

            if "invalidateInput" in name:
                # 4.4.4 没有 invalidate_input，改成「直接返回 1」，别让它调到 set_parameters
                data[addr_ldr:addr_ldr + 2] = MOVS_R0_1.to_bytes(2, "little")
                addr_blx = funcs[name][bi][0]
                data[addr_blx:addr_blx + 2] = NOP.to_bytes(2, "little")
                print("  %-22s offset=%-3d -> 停用（4.4.4 无此成员，改为直接返回错误）"
                      % (short, off))
                changed += 1
                continue

            new_off = off - 4
            old_code = int.from_bytes(data[addr_ldr:addr_ldr + 2], "little")
            # 先确认原机器码和我们算出来的完全一致，不一致就跳过（防止误伤）
            if old_code != enc_ldr_imm(rt, base_reg, off):
                print("  %-22s offset=%-3d 编码校验失败(实际0x%04X)，跳过"
                      % (short, off, old_code))
                continue
            new_code = enc_ldr_imm(rt, base_reg, new_off)
            data[addr_ldr:addr_ldr + 2] = new_code.to_bytes(2, "little")
            print("  %-22s offset %3d -> %3d   (0x%04X -> 0x%04X)  @0x%05X"
                  % (short, off, new_off, old_code, new_code, addr_ldr))
            changed += 1

    open(dst, "wb").write(data)
    print("\n共修改 %d 处，输出 %s" % (changed, dst))

    # ---- 改完立刻重新反汇编核对 ----
    print("\n===== 修改后复核 =====")
    funcs2 = disasm(dst)
    for name in sorted(targets, key=lambda n: funcs2[n][0][0]):
        short = name.split("::")[-1]
        hits = find_ops_dispatch(funcs2[name])
        if hits:
            for _, _, _, rt, off in hits:
                print("  %-30s 现在读偏移 %d" % (short, off))
        elif "invalidateInput" in name:
            print("  %-30s 已停用" % short)


if __name__ == "__main__":
    main()
