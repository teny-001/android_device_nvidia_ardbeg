#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_inputservice.py —— 二进制修补 libinputservice.so，禁用鼠标指针 sprite 渲染

╔══════════════════════════════════════════════════════════════════════════╗
║ ★★★ 本补丁已被取代，不要再用 ★★★                                        ║
║                                                                          ║
║ 它把 SpriteController::doUpdateSprites() 整个打成 `bx lr`，虽然止住了     ║
║ Watchdog 杀 system_server，但代价是**鼠标指针永远画不出来** ——           ║
║ 也就是后来"USB 鼠标不工作"的真正原因。                                    ║
║                                                                          ║
║ 正确做法（2026-11-05 已实机验证）：                                       ║
║   1) 用 tools/patch_libui_gralloc.py 给 libui.so 打补丁，                 ║
║      跳过 Gralloc1On0Adapter::lock 里那条永不 signal 的 acquire fence；  ║
║   2) 把 libinputservice.so 恢复成**原始版本**（本脚本 --restore），       ║
║      让 SpriteController 正常工作。                                       ║
║                                                                          ║
║ 实测结果：Sprite 图层出现、指针 1:1 跟随、点击可打开 App、                ║
║          system_server 全程不被 Watchdog 杀。                            ║
║ 详见 patches/README.md 的「USB 鼠标」专章。                               ║
║                                                                          ║
║ 本脚本仅作为历史记录保留，供需要回滚/对照时使用。                         ║
╚══════════════════════════════════════════════════════════════════════════╝

════════════════════════════════════════════════════════════════════════════
【症状】
  开机后 2 分半左右，system_server 被 Watchdog 杀死，然后进入无限崩溃循环：

      W Watchdog: *** WATCHDOG KILLING SYSTEM PROCESS:
                  Blocked in handler on display thread (android.display)
      W Watchdog: display thread stack trace:
      W Watchdog:     at android.os.MessageQueue.nativePollOnce(Native Method)
      W Watchdog:     at android.os.Looper.loop(Looper.java:136)
      W Watchdog:     at android.os.HandlerThread.run(HandlerThread.java:61)
      W Watchdog:     at com.android.server.ServiceThread.run(ServiceThread.java:46)
      W Watchdog: *** GOODBYE!
      I Process : Sending signal. PID: 1520 SIG: 9

  之后每 6 秒崩一次：
      E AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS: main
      E AndroidRuntime: DeadSystemException: The system died

  【关键】Watchdog 打印的 Java 堆栈是 `nativePollOnce` —— 看起来是**空闲**的！
  这是 Android 7.x Watchdog 的一个"陷阱"：第一次超时时它 dump 完整线程栈
  到 /data/anr/traces_SystemServer_WDT*.txt，然后**不会重新 post monitor**，
  第二次检查直接判死。所以 logcat 里看到的堆栈是"事后"状态，
  真正的卡死现场只在 traces 文件里。

════════════════════════════════════════════════════════════════════════════
【真实现场】（来自 traces_SystemServer_WDT05_11月_22_26_02.826.txt 第 1128 行）

  "android.display" prio=5 tid=18 Native
    native: #00 pc 00049424  /system/lib/libc.so (__ioctl+8)
    native: #01 pc 0001af3b  /system/lib/libc.so (ioctl+38)
    native: #02 pc 0000093f  /system/lib/libsync.so (sync_wait+26)
    native: #03 pc 0000a6a1  /system/lib/libui.so (Fence::waitForever+116)
    native: #04 pc 0000ce7d  /system/lib/libui.so (Gralloc1On0Adapter::lock+88)
    native: #05 pc 0000c437  /system/lib/libui.so (???)
    native: #06 pc 0000b4eb  /system/lib/libui.so (Gralloc::Device::lock+50)
    native: #07 pc 0000f7b7  /system/lib/libui.so (GraphicBufferMapper::lockAsync+142)
    native: #08 pc 0000e5bb  /system/lib/libui.so (GraphicBuffer::lockAsync+98)
    native: #09 pc 000543b7  /system/lib/libgui.so (Surface::lock+490)
    native: #10 pc 00008a0b  /system/lib/libinputservice.so
                              (SpriteController::doUpdateSprites+878)
    native: #11 pc 0001177f  /system/lib/libutils.so (WeakMessageHandler::handleMessage)
    native: #12 pc 00012069  /system/lib/libutils.so (Looper::pollInner+496)
    at android.os.MessageQueue.nativePollOnce(Native method)

  翻译成人话：

      display thread 在跑 SpriteController::doUpdateSprites（渲染鼠标指针），
      它调 Surface::lock() 想用 CPU 直接往 surface 的 buffer 里画，
      Surface::lock() 需要等这块 buffer 的 acquire fence（GPU/HWC 什么时候
      把这块 buffer 用完），于是调 Fence::waitForever()，
      waitForever 里的 sync_wait() 超时参数是 INT_MAX —— 也就是**永远等下去**。
      而这块 buffer 的 fence 永远不会 signal。

════════════════════════════════════════════════════════════════════════════
【为什么 fence 永远不 signal】

  这台设备的 hwcomposer 是 CM11（Android 4.4）时代编译的
  `/system/vendor/lib/hw/hwcomposer.tegra.so`，跑在 Nougat 的
  surfaceflinger 里。两代的 `hwc_layer_1_t` 结构体布局不同（见
  patches/README.md 的 hwcomposer 专章），导致 HWC 的
  prepare/set 调用读到错位的字段，fence 的管理链路整体是错乱的：
  有时能正常 signal（上一轮那次开机就成功了，桌面都渲染出来了），
  有时永远不 signal（本次开机）。**这是个随机 bug**。

  触发条件：只要接了鼠标，InputReader 就会上报 pointer 事件，
  PointerController 就会让 sprite 可见，SpriteController 就会去 lock surface。
  实测本机输入设备：

      /dev/input/event1  name: "2.4G Mouse"     ← 就是这个
      /dev/input/event0  name: "aw9201_ts"      （触摸屏）

  所以插着 2.4G 无线鼠标 = 必踩。

════════════════════════════════════════════════════════════════════════════
【修法选择】

  A. 根治：修 hwcomposer 的 hwc_layer_1_t 布局翻译
     → 需要写一个 shim .so 把 Nougat 的 hwc_layer_1_t 翻译成 4.4 的
       hwc_layer_1_t 再喂给原厂 HWC。工作量大，但这是正解。
       （patches/README.md 里记为"路 B"）

  B. 规避：不让 SpriteController 去碰 Surface  ← 本脚本采用
     → 鼠标指针不画了。点击事件完全不受影响（事件走 InputReader/InputDispatcher，
       跟 sprite 渲染是两条独立的路），只是屏幕上看不到那个箭头。
       TV 盒子本来就是遥控器/键盘操作为主，可接受。
       **系统能起来 > 有鼠标指针**，先把系统救活，fence 问题后面再根治。

  C. 折中：给 waitForever 加超时
     → 要改 libui.so 的 Fence::waitForever，但它被全系统共用，
       改了会影响所有 fence 等待语义，风险远大于收益。

════════════════════════════════════════════════════════════════════════════
【补丁点】

  符号：_ZN7android16SpriteController15doUpdateSpritesEv  @ 0x869c

  反汇编（Thumb-2）：

      869c: e92d 4ff0   stmdb  sp!, {r4, r5, r6, r7, r8, r9, sl, fp, lr}
      86a0: f5ad 5d93   sub.w  sp, sp, #4704        ; 0x1260
      86a4: b085        sub    sp, #20
      86a6: 4680        mov    r8, r0

  函数返回类型是 void，所以直接在入口写 `bx lr` 就等价于"整个函数什么都不做"：

      869c: 7047        bx     lr          ; ← 直接返回
      869e: 00bf        nop                ; ← 占位（保持后续指令对齐）

  【为什么敢整个函数跳过，不用担心状态不一致】
    doUpdateSprites 的职责是"把 mSprites 里所有 sprite 的最新属性
    提交到 SurfaceControl 上并画出来"。它的状态全部是**输出型**：
      - mTransactionOpen / openTransaction / closeTransaction
      - mSurfaceLocked / mLockedBuffer
    跳过它，这些状态就保持"未打开/未锁定"，是自洽的空状态。
    而它唯一的调用者是 SpriteController::handleMessage 的
    MSG_UPDATE_SPRITES 分支：

        8688: 6809        ldr    r1, [r1, #0]   ; r1 = message.what
        868a: 2901        cmp    r1, #1
        868c: bf08        it     eq
        868e: f002 bf53   beq.w  b538           ; what==1 -> MSG_UPDATE_SPRITES
        8692: b909        cbnz   r1, 8698
        8694: f002 bf58   b.w    b548           ; what==0 -> MSG_DISPOSE_SURFACES
        8698: 4770        bx     lr

    handleMessage 是 void 返回的，doUpdateSprites 空转也不会让
    handleMessage 出问题。

  【会不会有别的路径也去 lock surface】
    SpriteController 里跟 Surface 打交道的只有三个函数：
      obtainSurface(0x8efc)     —— 只 new Surface / 复用，不 lock
      doUpdateSprites(0x869c)   —— 唯一 lock 点   ← 本补丁干掉
      doDisposeSurfaces(0x8e80) —— 只 destroy，不 lock
    PointerController::Spot::updateSprite(0x7328) 只调 setIcon/setPosition/
    setVisible 这些纯属性设置，然后 invalidate 一下触发 handleMessage，
    本身不碰 surface。

    所以堵住 doUpdateSprites 这一个点，display thread 就再也不会
    走到 Surface::lock。

════════════════════════════════════════════════════════════════════════════
【用法】

    python3 patch_inputservice.py --check   libinputservice.so
    python3 patch_inputservice.py --apply   libinputservice.so -o libinputservice.patched.so
    python3 patch_inputservice.py --restore libinputservice.patched.so -o libinputservice.orig.so

  设备侧落地：

    adb root
    adb remount
    adb push libinputservice.patched.so /system/lib/libinputservice.so
    adb shell chmod 644 /system/lib/libinputservice.so
    adb shell chcon u:object_r:system_lib_file:s0 /system/lib/libinputservice.so
    adb reboot

  ⚠ 注意：libinputservice.so 被 **system_server** 加载（不是独立进程）。
    改完之后必须整机重启才生效，`stop zygote; start zygote` 那种手工重启
    会因为 servicemanager 残留旧 handle 而引发 zygote 崩溃循环
    （上一轮已经踩过，17 次重启 + DeadSystemException 死循环）。

════════════════════════════════════════════════════════════════════════════
【字节序提醒】（这个坑本项目已经踩过三次，务必记住）

  objdump 打印的是 halfword 的**值**（如 `e92d 4ff0`），
  而文件里是按小端存的（`f0 4f 2d e9`）。
  写常量时必须用**文件里的字节序**，不是 objdump 的打印顺序。
"""

import argparse
import struct
import sys

# ── 补丁点定义 ────────────────────────────────────────────────────────────
# doUpdateSprites 的虚拟地址
TARGET_VA = 0x869C

# 上下文：函数入口前 12 字节，用于确认这个 .so 就是我们预期的那个版本
#   2de9f04f  stmdb sp!, {r4, r5, r6, r7, r8, r9, sl, fp, lr}
#   adf5935d  sub.w  sp, sp, #0x1260
#   85b08046  sub sp, #20  ;  mov r8, r0
CTX_VA = 0x869C
CTX_ORIG = bytes.fromhex("2de9f04f" "adf5935d" "85b08046")

# 目标：把前 4 字节改成 bx lr; nop
#   7047  bx lr
#   00bf  nop
TARGET_ORIG = bytes.fromhex("2de9f04f")
TARGET_NEW = bytes.fromhex("704700bf")

# 目标在上下文里的偏移
CTX_TARGET_OFF = 0

# 打补丁后的完整上下文（用于 --check 判断状态）
CTX_PATCHED = (TARGET_NEW
               + CTX_ORIG[CTX_TARGET_OFF + len(TARGET_NEW):])


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
        description="修补 libinputservice.so，禁用 SpriteController::doUpdateSprites")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true", help="只检查状态，不写文件")
    g.add_argument("--apply", action="store_true", help="应用补丁")
    g.add_argument("--restore", action="store_true", help="撤销补丁")
    ap.add_argument("src", help="输入 .so 路径")
    ap.add_argument("-o", "--out", help="输出路径（默认覆盖输入文件）")
    a = ap.parse_args()

    data = bytearray(open(a.src, "rb").read())

    ctx_off = vaddr_to_off(data, CTX_VA)
    ctx = bytes(data[ctx_off:ctx_off + len(CTX_ORIG)])

    print("文件            : %s (%d 字节)" % (a.src, len(data)))
    print("SpriteController::doUpdateSprites @ 0x%x" % TARGET_VA)
    print("  上下文 VA     : 0x%x -> 文件偏移 0x%x（%d 字节）"
          % (CTX_VA, ctx_off, len(CTX_ORIG)))
    print("    期望原始    : %s" % CTX_ORIG.hex())
    print("    实际        : %s  %s"
          % (ctx.hex(),
             "✓ 匹配（未打补丁）" if ctx == CTX_ORIG else
             ("✓ 已打补丁" if ctx == CTX_PATCHED else "✗ 不匹配")))
    print("  目标 VA       : 0x%x" % TARGET_VA)
    print("    原始指令    : %s  (stmdb sp!, {r4-r9, sl, fp, lr})" % TARGET_ORIG.hex())
    print("    改为        : %s  (bx lr; nop —— 函数直接返回)" % TARGET_NEW.hex())

    if ctx not in (CTX_ORIG, CTX_PATCHED):
        raise SystemExit("\n上下文不匹配，拒绝操作 —— 可能 libinputservice.so 版本不对")

    if a.check:
        print("\n[结果] %s" % ("补丁已应用" if ctx == CTX_PATCHED else "补丁未应用"))
        return 0

    want_ctx = CTX_ORIG if a.restore else CTX_PATCHED
    if ctx == want_ctx:
        print("\n[跳过] 已经是目标状态")
        if a.out:
            open(a.out, "wb").write(data)
            print("已写出          : %s" % a.out)
        return 0

    data[ctx_off:ctx_off + len(CTX_ORIG)] = want_ctx

    back = bytes(data[ctx_off:ctx_off + len(CTX_ORIG)])
    assert back == want_ctx, "回读校验失败"
    print("\n回读校验        : %s ✓" % back.hex())

    out = a.out or a.src
    open(out, "wb").write(data)
    print("已写出          : %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
