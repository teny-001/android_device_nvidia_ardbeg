#!/usr/bin/env python3
"""
patch_minijail.py —— 二进制修补 7.1 的 libminijail.so，让 seccomp 软失败生效

【背景 / 症状】
  CM14.1 上 media 相关的服务开机即崩，无限重启（实测 mediacodec 每次开机
  崩十几次，mediaextractor 同样）：

      F libc: Fatal signal 6 (SIGABRT) in tid (mediacodec)
      #00 libc.so        tgkill+12
      #01 libc.so        pthread_kill+34
      #02 libc.so        raise+10
      #03 libc.so        __libc_android_abort+34
      #04 libc.so        abort+4
      #05 libminijail.so set_seccomp_filter+132      ← 就是这里
      #06 libminijail.so minijail_enter+404
      #07 mediacodec
      #09 libc.so        __libc_init+48

  mediaextractor、mediadrm 一模一样 —— 它们共用同一份 minijail 胶水代码：
  frameworks/av/services/{mediacodec,mediaextractor,mediadrm}/minijail/minijail.cpp

  崩溃前 logcat 里能看到这几行，是最直接的证据：
      W libminijail: allowing syscall: clock_gettime
      W libminijail: logging seccomp filter failures
      E libminijail: prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER): Invalid argument
      F libc: Fatal signal 6 (SIGABRT) in tid (mediacodec)

【根因】
  本机是 4.4.4 的原厂**预编译内核**，没有编 CONFIG_SECCOMP_FILTER，
  所以 prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER) 必然返回 EINVAL。

  external/minijail/libminijail.c 里本来就有"软失败"分支（编译时
  Android.mk:35 加了 -DUSE_SECCOMP_SOFTFAIL，代码是有的）：

      if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, j->filter_prog)) {
          if ((errno == EINVAL) && can_softfail()) {
              warn("seccomp not supported");
              return;                       // 软失败：不装过滤器，继续跑
          }
          pdie("prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER)");   // abort
      }

  但 can_softfail() 被一个版本启发式挡住了：

      int seccomp_kernel_support_not_required()          // libminijail.c:183
      {
          int major, minor;
          struct utsname uts;
          return (uname(&uts) != -1 &&
                  sscanf(uts.release, "%d.%d", &major, &minor) == 2 &&
                  ((major < 3) || ((major == 3) && (minor < 8))));
      }

  它的假设是"只有内核 < 3.8 才可能没有 seccomp filter"。
  本机内核 4.4.x → 判断"应该有" → 返回 0 → 软失败被关掉 → abort。
  "版本新"和"功能有"在这台机器上恰好不成立。

【修法】
  反汇编 libminijail.so 的 set_seccomp_filter()（0x5d2c，大小 0x9c）：

      5d6a: f410 4f00   tst.w  r0, #32768        ; j->flags.seccomp_filter ?
      5d6e: d012        beq.n  5d96              ; 没设就返回
      5d70: 6ca2        ldr    r2, [r4, #72]     ; r2 = j->filter_prog
      5d72: 2016        movs   r0, #22            ; PR_SET_SECCOMP
      5d74: 2102        movs   r1, #2             ; SECCOMP_MODE_FILTER
      5d76: f7fe ea04   blx    prctl@plt
      5d7a: b160        cbz    r0, 5d96          ; 成功 -> 返回
      5d7c: f7fe ea06   blx    __errno@plt
      5d80: 6800        ldr    r0, [r0, #0]      ; errno
      5d82: 2816        cmp    r0, #22           ; == EINVAL ?
      5d84: d109        bne.n  5d9a              ; 否 -> pdie
      5d86: f7fe e9a2   blx    seccomp_kernel_support_not_required@plt
      5d8a: b130        cbz    r0, 5d9a          ; ← 返回 0 -> pdie（本机走这条）
      5d8c: 490c        ldr    r1, [pc, #48]
      5d8e: 2004        movs   r0, #4
      5d90: 4479        add    r1, pc
      5d92: f7fe e9a2   blx    syslog@plt        ; warn("seccomp not supported")
      5d96: b002        add    sp, #8
      5d98: bd10        pop    {r4, pc}          ; 正常返回
      5d9a: ...         pdie -> abort

  把 `5d8a: b130 cbz r0, 5d9a` 改成 `00 bf`（Thumb nop）。
  这样 blx 之后不再判断返回值，直接落到 5d8c 打一条警告、然后正常返回。

      5d8a: bf00        nop                      ; ← 补丁
      5d8c: 490c        ldr    r1, [pc, #48]     ; warn("seccomp not supported")
      ...

  【为什么改这里而不是改 can_softfail 函数本体】
  第一次尝试是把导出符号 can_softfail（0x4a6c，14 字节）整个换成
  "movs r0,#1; bx lr"。改完推上去仍然崩在同一个地方 ——
  因为 can_softfail() 和 set_seccomp_filter() 在同一个编译单元
  （libminijail.c），-O2 下被**内联**了，set_seccomp_filter 里根本没有对
  can_softfail 的调用，只有对 seccomp_kernel_support_not_required 的 PLT 调用。
  改那个独立符号等于改了一段没人执行的代码。
  （这类"改了没效果"的坑，判断依据就是反汇编里找不到对 can_softfail@plt
    的调用，只有 seccomp_kernel_support_not_required@plt。）

【代价 / 安全性】
  seccomp 过滤器在本机上本来就装不上（内核不支持），所以跳过它
  不降低任何实际安全性 —— 真正的隔离边界（uid/gid 降权、capabilities、
  mount namespace）由 minijail 的其它部分负责，那些仍然照常生效。
  软失败后每个 media 服务会在 logcat 里留一条
      E libminijail: prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER): Invalid argument
  以及
      W libminijail: seccomp not supported
  然后继续正常启动。

  注意 set_seccomp_filter() 里还有一条同样的软失败分支（在
  minijail_parse_seccomp_filters()，libminijail.c:610 附近，解析策略文件时
  会先探测一次）。那一处也是同样的版本判断，但因为它只影响"要不要继续
  解析策略文件"，不会 abort，所以本脚本不改它 —— 少改一处少一份风险。

用法：
    ./patch_minijail.py --check   libminijail.so
    ./patch_minijail.py --apply   libminijail.so -o libminijail.patched.so
    ./patch_minijail.py --restore libminijail.patched.so -o libminijail.so
"""
import argparse
import struct
import sys

# ---------------------------------------------------------------------------
# 补丁点：set_seccomp_filter + 0x5e
#   objdump 打印  5d8a: b130  cbz r0, 5d9a
#   文件里小端存放 -> 30 b1
#   改成 Thumb nop（0xbf00）-> 00 bf
# ---------------------------------------------------------------------------
TARGET_VA = 0x5D8A
TARGET_ORIG = bytes.fromhex("30b1")
TARGET_NEW = bytes.fromhex("00bf")

# ---------------------------------------------------------------------------
# 上下文校验：确认没打偏
#   0x5d86  f7fe e9a2   blx seccomp_kernel_support_not_required@plt
#   0x5d8a  b130        cbz r0, 5d9a          ← 目标
#   0x5d8c  490c        ldr r1, [pc, #48]
#   0x5d8e  2004        movs r0, #4
#
# objdump 打印的是 Thumb halfword 的「值」，文件里按小端存放：
#   f7fe e9a2 -> fe f7 a2 e9
#   490c      -> 0c 49
#   2004      -> 04 20
# （patch_hwc.py 里踩过同一个坑，见那个文件的注释）
# ---------------------------------------------------------------------------
CTX_VA = 0x5D86
CTX_ORIG = bytes.fromhex("fef7a2e9" "30b1" "0c49" "0420")
CTX_TARGET_OFF = 4          # 目标在上下文里的偏移


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

    # 把补丁后的样子也算出来做对比，这样 --check 能区分三种状态
    ctx_patched = bytearray(CTX_ORIG)
    ctx_patched[CTX_TARGET_OFF:CTX_TARGET_OFF + len(TARGET_NEW)] = TARGET_NEW
    ctx_patched = bytes(ctx_patched)

    cur = ctx[CTX_TARGET_OFF:CTX_TARGET_OFF + len(TARGET_ORIG)]

    print("文件          : %s (%d 字节)" % (a.src, len(data)))
    print("set_seccomp_filter+0x5e")
    print("  上下文 VA   : 0x%x -> off 0x%x" % (CTX_VA, ctx_off))
    print("    期望原始  : %s" % CTX_ORIG.hex())
    print("    实际      : %s  %s" % (ctx.hex(),
                                      "✓ 匹配" if ctx == CTX_ORIG else
                                      ("✓ 已打补丁" if ctx == ctx_patched else "✗ 不匹配")))
    print("  目标 VA     : 0x%x" % TARGET_VA)
    print("    当前      : %s  (%s)" % (cur.hex(),
                                        "原始 cbz r0" if cur == TARGET_ORIG else
                                        ("已打补丁 nop" if cur == TARGET_NEW else "未知")))
    print("    改为      : %s  (nop)" % TARGET_NEW.hex())

    if ctx not in (CTX_ORIG, ctx_patched):
        raise SystemExit("上下文不匹配，拒绝操作 —— 可能 libminijail.so 版本不对")

    if a.check:
        if ctx == ctx_patched:
            print("\n[结果] 补丁已应用")
        else:
            print("\n[结果] 补丁未应用")
        return 0

    want_ctx = CTX_ORIG if a.restore else ctx_patched
    if ctx == want_ctx:
        print("\n[跳过] 已经是目标状态")
        if a.out:
            open(a.out, "wb").write(data)
        return 0

    data[ctx_off:ctx_off + len(CTX_ORIG)] = want_ctx

    # 回读校验
    back = bytes(data[ctx_off:ctx_off + len(CTX_ORIG)])
    assert back == want_ctx, "回读校验失败"
    print("\n回读校验      : %s ✓" % back.hex())

    out = a.out or a.src
    open(out, "wb").write(data)
    print("已写出        : %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
