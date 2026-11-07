#!/usr/bin/env python3
"""
patch_hwc.py —— 二进制修补 4.4.4 原厂 hwcomposer.tegra.so 的二次释放崩溃

【背景 / 症状】
  CM14.1 上 SurfaceFlinger 周期性地（约每 16 秒）SIGSEGV：
      Fatal signal 11 (SIGSEGV), code 1, fault addr 0xc in tid N (surfaceflinger)
      #00 libutils.so         android::RefBase::decStrong(void const*) const+37
      #01 hwcomposer.tegra.so android::sp<android::GraphicBuffer>::operator=(GraphicBuffer*)+22
      #02 hwcomposer.tegra.so destroy_graphic_buffer+8
      #03 hwcomposer.tegra.so
      #04 hwcomposer.tegra.so glc_set+250 / glc_set+1096
      #05 hwcomposer.tegra.so hwc_composite_set+252
      #07 libsurfaceflinger.so   (SF 调 HWC set())
      #12 libutils.so         android::Looper::pollInner(int)+496

【根因】
  destroy_graphic_buffer(sp<GraphicBuffer>* p) 的原始实现：
      10194: push {r4, lr}
      10196: mov  r4, r0
      10198: cbz  r0, 101b4          ; if (!p) return;
      1019a: movs r1, #0
      1019c: bl   sp<GraphicBuffer>::operator=(GraphicBuffer*)   ; *p = NULL
      101a0: ldr  r0, [r4, #0]
      101a2: cbz  r0, 101aa
      101a4: mov  r1, r4
      101a6: blx  RefBase::decStrong(void const*)
      101aa: ...  tail call

  其中 `*p = NULL` 会走到 sp::operator= 里对【旧指针】做 decStrong。
  而 4.4.4 的 HAL 把一个【它自己没加过引用】的 GraphicBuffer 裸指针塞进了 sp<>，
  在 4.4.4 里 SF 释放 buffer 的时机比 7.1 晚，所以那个对象那时还活着，不炸；
  到了 7.1，SF 提前释放，HAL 手里的 sp<> 变成悬空指针 ——
  decStrong 取 mBase->vptr 得到 NULL，再取 [vptr+12] 就正好踩在 0xc 上。

  这跟 egl_display.cpp 那个补丁没有因果关系，但我们的 EGL 补丁让 SF 的
  GPU 合成路径跑得更频繁，于是从「偶发」变成「每 16 秒必炸」。

【修法】
  把 `bl sp::operator=`（4 字节）替换成 `str r1, [r4, #0]` + `nop`（4 字节），
  即直接把 sp 的 m_ptr 清成 NULL，不再对那个可能已死的对象做 decStrong。

      1019a: movs r1, #0
      1019c: str  r1, [r4, #0]       ; 21 60
      1019e: nop                     ; 00 bf
      101a0: ldr  r0, [r4, #0]       ; 读到 0
      101a2: cbz  r0, 101aa          ; 跳过后面的 decStrong
      ...

  代价：如果指针那一刻【还活着】，就少减一次引用（该 GraphicBuffer 泄漏一次）。
  实测这条路径只在合成配置变化时走，不是每帧，泄漏量可以接受；
  而且崩溃的前提恰恰就是「指针已死」，那种情况下跳过 decStrong 不丢任何东西。

用法：
    ./patch_hwc.py --check   hwcomposer.tegra.so
    ./patch_hwc.py --apply   hwcomposer.tegra.so -o hwcomposer.tegra.patched.so
    ./patch_hwc.py --restore hwcomposer.tegra.patched.so -o hwcomposer.tegra.so
"""
import argparse
import struct
import sys

# 注意：objdump 打印的是 Thumb halfword 的「值」（如 0xb510），
# 而文件里按小端存放，实际字节是 10 b5。下面所有常量都用文件字节序。
TARGET_VA = 0x1019C
# bl 0x1010c <sp<GraphicBuffer>::operator=>  = f7ff ffb6 -> ff f7 b6 ff
ORIG = bytes.fromhex("fff7b6ff")
# str r1,[r4,#0] (0x6021) + nop (0xbf00) -> 21 60 00 bf
NEW = bytes.fromhex("216000bf")

# 上下文校验：确认打补丁的位置没跑偏
#   b510 push {r4,lr} / 4604 mov r4,r0 / b160 cbz r0 / 2100 movs r1,#0
CTX_VA = 0x10194
CTX_ORIG = bytes.fromhex("10b5044660b10021")


def vaddr_to_off(data: bytes, va: int) -> int:
    """把虚拟地址按 ELF32 的 PT_LOAD 段映射成文件偏移"""
    if data[:4] != b"\x7fELF" or data[4] != 1:
        raise SystemExit("不是 ELF32 文件")
    e_phoff, = struct.unpack_from("<I", data, 0x1C)
    e_phentsize, = struct.unpack_from("<H", data, 0x2A)
    e_phnum, = struct.unpack_from("<H", data, 0x2C)
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, = struct.unpack_from("<I", data, off)
        if p_type != 1:            # PT_LOAD
            continue
        p_offset, p_vaddr, p_paddr, p_filesz = struct.unpack_from("<IIII", data, off + 4)
        if p_vaddr <= va < p_vaddr + p_filesz:
            return p_offset + (va - p_vaddr)
    raise SystemExit("0x%x 不在任何 PT_LOAD 段里" % va)


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--apply", action="store_true")
    g.add_argument("--restore", action="store_true")
    ap.add_argument("src")
    ap.add_argument("-o", "--out")
    a = ap.parse_args()

    data = bytearray(open(a.src, "rb").read())

    ctx_off = vaddr_to_off(data, CTX_VA)
    tgt_off = vaddr_to_off(data, TARGET_VA)

    ctx = bytes(data[ctx_off:ctx_off + len(CTX_ORIG)])
    cur = bytes(data[tgt_off:tgt_off + 4])

    print("文件      : %s (%d 字节)" % (a.src, len(data)))
    print("上下文 VA : 0x%x -> off 0x%x" % (CTX_VA, ctx_off))
    print("  期望 : %s" % CTX_ORIG.hex())
    print("  实际 : %s  %s" % (ctx.hex(), "✓ 匹配" if ctx == CTX_ORIG else "✗ 不匹配"))
    print("目标   VA : 0x%x -> off 0x%x" % (TARGET_VA, tgt_off))
    print("  当前 : %s  (%s)" % (
        cur.hex(),
        "原始 bl" if cur == ORIG else ("已打补丁" if cur == NEW else "未知")))
    print("  改为 : %s" % NEW.hex())

    if ctx != CTX_ORIG:
        raise SystemExit("上下文不匹配，拒绝操作")

    if a.check:
        if cur == NEW:
            print("\n[结果] 补丁已应用")
        elif cur == ORIG:
            print("\n[结果] 补丁未应用")
        else:
            print("\n[结果] 目标字节既不是原始也不是补丁状态，需人工确认")
            return 1
        return 0

    want = ORIG if a.restore else NEW
    if cur == want:
        print("\n[跳过] 已经是目标状态")
        if a.out:
            open(a.out, "wb").write(data)
        return 0

    data[tgt_off:tgt_off + 4] = want
    # 回读校验
    back = bytes(data[tgt_off:tgt_off + 4])
    assert back == want, "回读校验失败"
    print("\n回读校验: %s ✓" % back.hex())

    out = a.out or a.src
    open(out, "wb").write(data)
    print("已写出  : %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
