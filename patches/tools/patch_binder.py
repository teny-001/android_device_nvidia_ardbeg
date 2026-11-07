#!/usr/bin/env python3
"""
patch_binder.py —— 二进制修补 7.1 的 libbinder.so，让 binder 池线程遇错不 abort

【背景 / 症状】
  SurfaceFlinger 在开机约 33 秒时 SIGABRT，之后 init 重启 SF。
  新 SF 起来了，但**屏幕上什么都没有（纯黑）**，Launcher / SystemUI
  的窗口在 WMS 里都存在，就是画不出来。

  崩溃日志：
      E IPCThreadState: getAndExecuteCommand(fd=3) returned unexpected error -2147483648, aborting
      F libc    : Fatal signal 6 (SIGABRT), code -6 in tid 1547 (Binder:221_3)
      #04 libc.so    abort+4
      #05 libbinder.so IPCThreadState::joinThreadPool(bool)+132
      #06 libbinder.so
      #07 libutils.so Thread::_threadLoop(void*)+144

  注意 tid 名字是 `Binder:221_3` —— 这是 SF 的**线程池线程**，不是主线程。

【为什么黑屏】
  SF 一死，所有客户端（Launcher、SystemUI、Wallpaper）手里的 Surface 就全废了：
  Surface 背后的 BufferQueue 是通过 binder 连到 SF 的，SF 进程没了，
  这些队列就成了孤儿。框架层**没有**"SF 重启了"这个通知 —— 客户端只会
  在下次 dequeueBuffer 时拿到 DEAD_OBJECT，而 WMS 不会主动让所有窗口重建 Surface。
  结果就是：窗口层级完好、`dumpsys window` 一切正常、`mCurrentFocus` 有值，
  但每一个 Layer 都没有 buffer，屏幕上永远黑着。
  KeyguardScrim 还会一直盖在最上面（SystemUI 画不出解锁界面，scrim 就撤不掉），
  连按键都进不去。

  实测：`screencap` 本身是好的（能抓到开机动画），所以黑屏是真的没画东西。

【根因】
  `-2147483648` = `0x80000000` = `INT_MIN` = `UNKNOWN_ERROR`（见 utils/Errors.h）。

  来源是 IPCThreadState::executeCommand() 的 default 分支：

      default:
          printf("*** BAD COMMAND %d received from Binder driver\\n", cmd);
          result = UNKNOWN_ERROR;
          break;

  （注意是 `printf` 不是 `ALOGE` —— 所以 logcat 里**看不到**这行，
    init 服务的 stdout 默认丢弃。这也是为什么一开始完全没头绪。）

  也就是：**4.4.4 的内核 binder 驱动发来了一条 7.1 的 libbinder 不认识的命令**。
  两代的 BR_* 枚举值是一样的，所以更可能是某个结构体布局/长度不一致导致
  读命令流时错位，后面读到的就是垃圾值。

  然后 joinThreadPool() 把这个 UNKNOWN_ERROR 当成致命错误：

      result = getAndExecuteCommand();
      if (result < NO_ERROR && result != TIMED_OUT
              && result != -ECONNREFUSED && result != -EBADF) {
          ALOGE("getAndExecuteCommand(fd=%d) returned unexpected error %d, aborting", ...);
          abort();          /* ← 整个 SF 进程陪葬 */
      }

  一个**池线程**收到一条异常命令，把整个显示服务 abort 掉 —— 这个代价明显不成比例。

【修法】
  反汇编 IPCThreadState::joinThreadPool（0x3d3ec，大小 0x90）：

      3d410: 4620        mov    r0, r4
      3d412: f7f5 ed2a   blx    getAndExecuteCommand@plt
      3d416: f110 0f6e   cmn.w  r0, #110        ; r0 == -ETIMEDOUT ?
      3d41a: d008        beq.n  3d42e
      3d41c: f1b0 3fff   cmp.w  r0, #0xffffffff  ; r0 >= 0 ?
      3d420: dc05        bgt.n  3d42e
      3d422: f110 0f6f   cmn.w  r0, #111        ; r0 == -ECONNREFUSED ?
      3d426: bf18        it     ne
      3d428: f110 0f09   cmnne.w r0, #9         ; r0 == -EBADF ?
      3d42c: d116        bne.n  3d45c            ; ← 都不是 -> 报错 + abort
      3d42e: f110 0f6e   cmn.w  r0, #110        ; 正常路径从这里继续
      ...
      3d444: 4630        mov    r0, r6            ; ← 正常退出循环的入口
      3d446: f246 310d   movw   r1, #25357        ; BC_EXIT_LOOPER
      ...
      3d45c: ...         __android_log_print(6, ...) ; ALOGE
      3d470: f7f4 eccc   blx    abort@plt          ; ← 就是这里（+0x84 = 132）

  把 `3d42c: d116 bne.n 3d45c` 改成 `d10b bne.n 3d444`：

      3d42c: d10b        bne.n  3d444   ; 遇错 -> 走正常退出循环的路径

  效果：池线程收到不认识的命令时，干净地写一条 BC_EXIT_LOOPER 然后退出，
  **SF 进程继续活着**，所有 Surface 保持有效，屏幕不会黑。

  【为什么不"重试"（把 bne 改成 nop 让它落回 3d42e）】
  落回 3d42e 之后会走到 `while (result != -ECONNREFUSED && result != -EBADF)`
  的循环条件，条件为真 → 回到 3d40a 重试。
  如果那条异常命令是**持续**出现的（协议错位通常就是持续的），
  这个线程会 100% 占满一个核空转，比让它退出糟得多。
  退出线程是唯一"不放大问题"的选择：SF 还有主线程和别的池线程，
  binder 需要更多线程时会通过 BR_SPAWN_LOOPER 再拉起。

【代价】
  每发生一次协议错位就少一个池线程。实测一次开机只发生一次，可以接受。
  如果以后发现池线程被大量消耗（`dumpsys SurfaceFlinger` 里 binder 线程数变少），
  说明错位是持续性的，那就得从内核 binder 驱动或 userspace 协议版本上解决，
  不是这个补丁能兜住的。

【安全性】
  只影响"出错时的处理方式"，不改变任何正常路径。
  正常命令、正常返回值全部走原来的代码。

用法：
    ./patch_binder.py --check   libbinder.so
    ./patch_binder.py --apply   libbinder.so -o libbinder.patched.so
    ./patch_binder.py --restore libbinder.patched.so -o libbinder.so
"""
import argparse
import struct
import sys

# ---------------------------------------------------------------------------
# 补丁点：joinThreadPool + 0x40
#   objdump 打印  3d42c: d116  bne.n 3d45c   -> 文件字节 16 d1
#   改成          3d42c: d10a  bne.n 3d444   -> 文件字节 0a d1
#
#   Thumb T1 条件分支编码：1101 cond imm8，目标 = (本条地址 + 4) + (imm8 << 1)
#     原值 0x16：3d42c + 4 = 3d430，3d430 + (0x16<<1) = 3d430 + 0x2c = 3d45c  ✓
#     新值 0x0a：3d430 + (0x0a<<1) = 3d430 + 0x14 = 3d444                     ✓
#   （不要用"下一条指令 + 2*imm8"去算，Thumb 的 PC 是当前指令 + 4）
# ---------------------------------------------------------------------------
TARGET_VA = 0x3D42C
TARGET_ORIG = bytes.fromhex("16d1")
TARGET_NEW = bytes.fromhex("0ad1")

# ---------------------------------------------------------------------------
# 上下文校验（18 字节，覆盖整段 if 判断）：
#   3d420  dc05        bgt.n 3d42e        -> 05 dc
#   3d422  f110 0f6f   cmn.w r0, #111     -> 10 f1 6f 0f
#   3d426  bf18        it ne              -> 18 bf
#   3d428  f110 0f09   cmnne.w r0, #9     -> 10 f1 09 0f
#   3d42c  d116        bne.n 3d45c        -> 16 d1   ← 目标（偏移 12）
#   3d42e  f110 0f6e   cmn.w r0, #110     -> 10 f1 6e 0f
#
# 再次强调字节序：objdump 打印的是 Thumb halfword 的「值」，
# 文件里按小端存放（patch_hwc.py / patch_minijail.py 里都踩过）。
# ---------------------------------------------------------------------------
CTX_VA = 0x3D420
CTX_ORIG = bytes.fromhex("05dc" "10f16f0f" "18bf" "10f1090f" "16d1" "10f16e0f")
CTX_TARGET_OFF = 12


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
    ctx = bytes(data[ctx_off:ctx_off + len(CTX_ORIG)])

    ctx_patched = bytearray(CTX_ORIG)
    ctx_patched[CTX_TARGET_OFF:CTX_TARGET_OFF + len(TARGET_NEW)] = TARGET_NEW
    ctx_patched = bytes(ctx_patched)

    print("文件          : %s (%d 字节)" % (a.src, len(data)))
    print("joinThreadPool+0x40")
    print("  上下文 VA   : 0x%x -> off 0x%x（%d 字节）" % (CTX_VA, ctx_off, len(CTX_ORIG)))
    print("    期望原始  : %s" % CTX_ORIG.hex())
    print("    实际      : %s  %s" % (ctx.hex(),
                                      "✓ 匹配" if ctx == CTX_ORIG else
                                      ("✓ 已打补丁" if ctx == ctx_patched else "✗ 不匹配")))
    print("  目标 VA     : 0x%x" % TARGET_VA)
    print("    改为      : %s  (bne.n 3d444，遇错走正常退出)" % TARGET_NEW.hex())

    if ctx not in (CTX_ORIG, ctx_patched):
        raise SystemExit("上下文不匹配，拒绝操作 —— 可能 libbinder.so 版本不对")

    if a.check:
        print("\n[结果] %s" % ("补丁已应用" if ctx == ctx_patched else "补丁未应用"))
        return 0

    want_ctx = CTX_ORIG if a.restore else ctx_patched
    if ctx == want_ctx:
        print("\n[跳过] 已经是目标状态")
        if a.out:
            open(a.out, "wb").write(data)
        return 0

    data[ctx_off:ctx_off + len(CTX_ORIG)] = want_ctx

    back = bytes(data[ctx_off:ctx_off + len(CTX_ORIG)])
    assert back == want_ctx, "回读校验失败"
    print("\n回读校验      : %s ✓" % back.hex())

    out = a.out or a.src
    open(out, "wb").write(data)
    print("已写出        : %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
