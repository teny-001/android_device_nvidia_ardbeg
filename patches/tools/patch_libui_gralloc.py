#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_libui_gralloc.py —— 二进制修补 libui.so，跳过 Gralloc1On0Adapter 的 acquire fence 死等

════════════════════════════════════════════════════════════════════════════
【为什么会有这个补丁】

  上一个补丁 patch_inputservice.py 为了救活 system_server，把
  SpriteController::doUpdateSprites() 整个打成了 `bx lr`（什么都不做）。
  这确实止住了 Watchdog 杀 system_server，但代价是：

      ★ 鼠标指针（sprite）永远画不出来 ★

  于是"USB 鼠标不工作"—— 事件其实一直是好的，只是屏幕上没有箭头。

  本补丁是 patch_inputservice.py 的**正确替代**：
  不动 SpriteController，改为在更底层掐掉那个永不返回的 fence 等待。
  两个补丁必须成对使用（先打本补丁，再回滚 inputservice 补丁）。

════════════════════════════════════════════════════════════════════════════
【死等的真实现场】（traces_SystemServer_WDT05_11月_22_26_02.826.txt 第 1128 行）

  "android.display" prio=5 tid=18 Native
    native: #00 pc 00049424  /system/lib/libc.so    (__ioctl+8)
    native: #01 pc 0001af3b  /system/lib/libc.so    (ioctl+38)
    native: #02 pc 0000093f  /system/lib/libsync.so (sync_wait+26)
    native: #03 pc 0000a6a1  /system/lib/libui.so   (Fence::waitForever+116)
    native: #04 pc 0000ce7d  /system/lib/libui.so   (Gralloc1On0Adapter::lock+88)  ← 就这里
    native: #05 pc 0000c437  /system/lib/libui.so   (???)
    native: #06 pc 0000b4eb  /system/lib/libui.so   (Gralloc::Device::lock+50)
    native: #07 pc 0000f7b7  /system/lib/libui.so   (GraphicBufferMapper::lockAsync+142)
    native: #08 pc 0000e5bb  /system/lib/libui.so   (GraphicBuffer::lockAsync+98)
    native: #09 pc 000543b7  /system/lib/libgui.so  (Surface::lock+490)
    native: #10 pc 00008a0b  /system/lib/libinputservice.so
                              (SpriteController::doUpdateSprites+878)

  调用链翻译：

      SpriteController 想把鼠标指针画到自己的 Surface 上
        → Surface::lock() 想用 CPU 直接写 buffer
          → GraphicBuffer::lockAsync() 要等这块 buffer 的 acquire fence
            → gralloc1→gralloc0 适配层 Gralloc1On0Adapter::lock()
              → Fence::waitForever()  ← sync_wait(fd, INT_MAX)，永远等
                → 而这块 fence 永远不会 signal

════════════════════════════════════════════════════════════════════════════
【为什么 fence 永远不 signal —— 以及为什么只有鼠标受影响】

  本机 HWC 是 4.4.4 时代编的 hwcomposer.tegra.so，跑在 7.1 的 SF 里，
  hwc_layer_1_t 布局错位（见 patches/README.md 的 HWC 专章），
  导致 SF 交给 client layer 的 release fence 是一条永远不会被 signal 的 fence。

  关键点：**普通 App 渲染完全不受影响**。因为生产者侧
  （BufferQueueProducer::dequeueBuffer）判断"这块 buffer 能不能用"
  靠的是 slot 状态 + waitForFreeSlotThenRelock，**不等 acquire fence**；
  GPU 侧靠 EGL 的隐式同步。

  全系统里唯一显式"等 acquire fence"再 CPU 写内存的路径，就是
  Surface::lock() → GraphicBuffer::lockAsync()。而 7.1 里走这条路的
  主要就是 SpriteController（鼠标指针），少数走软件 Canvas
  （lockCanvas）的 App 也会走。

  所以症状表现为："系统一切正常，只有鼠标指针出不来"。

════════════════════════════════════════════════════════════════════════════
【为什么可以安全地掐掉这次等待】

  看 frameworks/native/libs/ui/Gralloc1On0Adapter.cpp:398-403 的源码：

      } else {
          acquireFence->waitForever("Gralloc1On0Adapter::lock");   // ← 返回值被丢弃
          int result = mModule->lock(mModule, buffer->getHandle(), ...);
          ...
      }

  ★ waitForever() 的返回值**完全没有被使用**（没赋值给任何变量）。
    后面只检查 mModule->lock() 的 result。

  再看反汇编，blx 之后紧接着的两条指令会**重新加载 r0 和 r1**：

      ce7c: f7fc ee86   blx  9b8c <Fence::waitForever@plt>
      ce80: 6831        ldr  r1, [r6, #0]     ; r1 被覆盖
      ce82: 6d68        ldr  r0, [r5, #84]    ; r0 被覆盖

  所以把这个 blx 换成两条 nop，**不破坏任何寄存器语义、不改变控制流**，
  纯粹就是"不再等待"。

  为什么"不等"是安全的：
    SpriteController 每次都用 SkXfermode::kSrc_Mode 把整个 buffer 重画一遍
    （图标 + 透明填充剩余区域，见 SpriteController.cpp:218-231），
    不存在"基于旧内容做增量"的情况。所以即使 buffer 还在被扫描输出，
    写进去的内容也是完整正确的，最多出现一帧撕裂 —— 对一个 20x20 的
    鼠标箭头来说完全不可感知。

════════════════════════════════════════════════════════════════════════════
【补丁点】（两个，都是 Gralloc1On0Adapter 里的 gralloc0 回退分支）

  1) Gralloc1On0Adapter::lock        @ 0xce24，等待点在 +0x58 = 0xce7c
  2) Gralloc1On0Adapter::lockYCbCr   @ 0xceb4，等待点在 +0x62 = 0xcf16

  反汇编（Thumb-2，objdump 打印的是 halfword 值）：

      ce76: 490d        ldr  r1, [pc, #52]     ; logname 字符串
      ce78: 6800        ldr  r0, [r0, #0]      ; r0 = Fence*
      ce7a: 4479        add  r1, pc
      ce7c: f7fc ee86   blx  9b8c <Fence::waitForever@plt>   ← 改成 nop; nop
      ce80: 6831        ldr  r1, [r6, #0]

      cf10: 490d        ldr  r1, [pc, #52]
      cf12: 6800        ldr  r0, [r0, #0]
      cf14: 4479        add  r1, pc
      cf16: f7fc ee3a   blx  9b8c <Fence::waitForever@plt>   ← 改成 nop; nop
      cf1a: 6831        ldr  r1, [r6, #0]

  注意两个 blx 的编码不同（ee86 / ee3a，因为相对偏移不同），
  正好可以用来区分两个补丁点。

════════════════════════════════════════════════════════════════════════════
【用法】

    python3 patch_libui_gralloc.py --check   libui.so
    python3 patch_libui_gralloc.py --apply   libui.so -o libui.patched.so
    python3 patch_libui_gralloc.py --restore libui.patched.so -o libui.orig.so

  设备侧落地（libui.so 被 system_server / surfaceflinger / 所有 App 加载，
  改完必须整机重启）：

    adb root
    adb remount
    adb push libui.patched.so /system/lib/libui.so
    adb shell chmod 644 /system/lib/libui.so
    adb shell chcon u:object_r:system_lib_file:s0 /system/lib/libui.so
    adb reboot

  ⚠ 不能 `stop zygote; start zygote` 手工重启 —— servicemanager 里会残留
    123 个指向旧 system_server 的死服务条目，新 system_server 启动时
    在 ActivityThread.hasCodec() 里拿死 handle → DeadSystemException → 崩溃循环。
    （上一轮已实测，见 patches/README.md）

════════════════════════════════════════════════════════════════════════════
【字节序提醒】（本项目已经踩过四次，务必记住）

  objdump 打印的是 halfword 的**值**（如 `f7fc ee86`），
  文件里是按小端存的（`fc f7 86 ee`）。
  写常量必须用**文件里的字节序**，不是 objdump 的打印顺序。
"""

import argparse
import struct
import sys

# ── 补丁点定义 ────────────────────────────────────────────────────────────
# 每项：虚拟地址 / 名字 / 原始 4 字节（文件字节序）/ 替换成什么
#
#   f7fc ee86  →  fc f7 86 ee   (blx Fence::waitForever@plt)
#   f7fc ee3a  →  fc f7 3a ee   (blx Fence::waitForever@plt，另一个相对偏移)
#   00bf 00bf  →  00 bf 00 bf   (nop; nop)
PATCHES = [
    {
        "va": 0xCE7C,
        "name": "Gralloc1On0Adapter::lock",
        "orig": bytes.fromhex("fcf786ee"),
        "new": bytes.fromhex("00bf00bf"),
        # 前面 8 字节上下文，用来确认版本对得上：6800 4479 -> 00 68 79 44
        "ctx_before": bytes.fromhex("00687944"),
    },
    {
        "va": 0xCF16,
        "name": "Gralloc1On0Adapter::lockYCbCr",
        "orig": bytes.fromhex("fcf73aee"),
        "new": bytes.fromhex("00bf00bf"),
        "ctx_before": bytes.fromhex("00687944"),
    },
]


def vaddr_to_off(data, va):
    """把 ELF 虚拟地址翻译成文件偏移，遍历 PT_LOAD 段。"""
    if data[:4] != b"\x7fELF":
        raise SystemExit("不是 ELF 文件")
    if data[4] != 1:
        raise SystemExit("不是 32 位 ELF（EI_CLASS=%d）" % data[4])

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
    ap = argparse.ArgumentParser(
        description="修补 libui.so，跳过 Gralloc1On0Adapter 的 acquire fence 死等")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true", help="只检查状态，不写文件")
    g.add_argument("--apply", action="store_true", help="应用补丁")
    g.add_argument("--restore", action="store_true", help="撤销补丁")
    ap.add_argument("src", help="输入 .so 路径")
    ap.add_argument("-o", "--out", help="输出路径（默认覆盖输入文件）")
    a = ap.parse_args()

    data = bytearray(open(a.src, "rb").read())
    print("文件            : %s (%d 字节)" % (a.src, len(data)))

    # ── 第一遍：全部校验，任何一个不对就整体拒绝，避免打一半 ──────────
    sites = []
    all_orig = True
    all_patched = True

    for p in PATCHES:
        off = vaddr_to_off(data, p["va"])
        cur = bytes(data[off:off + 4])
        before = bytes(data[off - len(p["ctx_before"]):off])

        print("\n  %s @ 0x%x" % (p["name"], p["va"]))
        print("    VA -> 文件偏移 : 0x%x" % off)
        print("    前置上下文     : %s  期望 %s  %s"
              % (before.hex(), p["ctx_before"].hex(),
                 "✓" if before == p["ctx_before"] else "✗ 不匹配"))
        print("    当前 4 字节    : %s" % cur.hex())

        if before != p["ctx_before"]:
            raise SystemExit("\n前置上下文不匹配，拒绝操作 —— 可能 libui.so 版本不对")

        if cur == p["orig"]:
            print("    状态           : 原始（blx Fence::waitForever）")
            all_patched = False
        elif cur == p["new"]:
            print("    状态           : 已打补丁（nop; nop）")
            all_orig = False
        else:
            raise SystemExit("\n目标字节既不是原始值也不是补丁值，拒绝操作")

        sites.append((off, cur, p))

    if a.check:
        if all_patched:
            print("\n[结果] 补丁已应用（全部 %d 处）" % len(sites))
        elif all_orig:
            print("\n[结果] 补丁未应用（全部 %d 处是原始值）" % len(sites))
        else:
            print("\n[结果] 半套状态！部分已打、部分未打 —— 建议用原始库重新 apply")
        return 0

    want = None
    if a.apply:
        want = "new"
    elif a.restore:
        want = "orig"

    changed = 0
    for off, cur, p in sites:
        target = p[want]
        if cur == target:
            continue
        data[off:off + 4] = target
        changed += 1

    # ── 第二遍：回读校验 ────────────────────────────────────────────
    print("\n回读校验：")
    ok = True
    for off, cur, p in sites:
        back = bytes(data[off:off + 4])
        good = back == p[want]
        ok = ok and good
        print("  0x%x: %s  %s" % (p["va"], back.hex(), "✓" if good else "✗"))
    if not ok:
        raise SystemExit("回读校验失败，文件未写出")

    print("\n改动处数        : %d" % changed)
    out = a.out or a.src
    open(out, "wb").write(data)
    print("已写出          : %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
