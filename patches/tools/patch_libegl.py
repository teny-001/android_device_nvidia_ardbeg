#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_libegl.py —— 修补 7.1 的 /system/lib/libEGL.so, 修掉
                  「多线程下 eglInitialize 报 EGL_BAD_DISPLAY」的根因

【问题现象】
  所有 zygote fork 出来的应用进程都崩溃:
      W/libEGL : eglInitialize(0x1) failed (EGL_BAD_DISPLAY)
      I/OpenGLRenderer: Initialized EGL, version 1.4
      F/OpenGLRenderer: Failed to choose config, error = EGL_BAD_DISPLAY
  但 SurfaceFlinger(全新 exec) 和手写的 egltest(全新 exec) 都正常。

【根因】
  7.1 的 frameworks/native/opengl/libs/EGL/egl_display.cpp 里:

      EGLDisplay egl_display_t::getDisplay(EGLNativeDisplayType display) {
          ...
          egl_connection_t* const cnx = &gEGLImpl;
          if (cnx->dso && disp.dpy == EGL_NO_DISPLAY) {   // <-- 问题在这
              EGLDisplay dpy = cnx->egl.eglGetDisplay(display);
              disp.dpy = dpy;
              ...
          }
          return EGLDisplay(uintptr_t(display) + 1U);
      }

  disp.dpy 是「进程级」缓存。NVIDIA 这颗 4.4.4 的 tegra EGL 驱动
  (libEGL_tegra_impl.so) 依赖 eglGetDisplay 在「当前线程」建立线程局部
  状态(它导入了 NvOsTlsGet / NvOsTlsAlloc / NvOsTlsAddTerminator)。

  于是:
    - 线程1 调 eglGetDisplay -> 驱动被真正调用, 线程1 的 TLS 建立,
      disp.dpy 被缓存成 0x1。
    - 线程2(hwui 的 RenderThread) 调 eglGetDisplay -> 因为 disp.dpy
      已经非 0, loader **直接跳过**, 根本没往驱动里传, 线程2 的 TLS 是空的。
    - 线程2 调 eglInitialize -> 驱动找不到 display -> EGL_BAD_DISPLAY。
    - 而 loader 的 initialize() 失败只打 ALOGW 不返回 false, 所以
      对外仍报 "Initialized EGL, version 1.4", 直到 eglChooseConfig
      才真正炸掉。

  4.4.4 时代 hwui 是单线程(没有 RenderThread), 所以老 ROM 不会触发;
  7.1 引入 RenderThread 后才暴露。

【修法】
  把 getDisplay() 里 disp.dpy == EGL_NO_DISPLAY 这个缓存条件去掉,
  让每个线程的 eglGetDisplay 都真实透传给驱动。

  对应源码改动(已记录到 device/nvidia/ardbeg/patches):
      -    if (cnx->dso && disp.dpy == EGL_NO_DISPLAY) {
      +    if (cnx->dso) {

  二进制层面只需要把这条 cbnz 变成 nop。

【2026-11-06 集成说明 —— 这个工具现在属于设备树的一部分】
  正式出 ROM 有两条路径，二者必须产出**等价**的结果：

  1) 全量编译（lunch cm_ardbeg_tv-eng）
     源码补丁 patches/frameworks/native/opengl/libs/EGL/egl_display.cpp.patch
     已经被 install.sh 应用（check.sh 显示 [已应用]），AOSP 自己会把
     libEGL 编译成带修复的版本。此时**不需要**本脚本，
     本目录下的 libEGL.orig.so 只作为对照基准。
     注意不要用 PRODUCT_COPY_FILES 把 prebuilt/lib/libEGL.so 拷到
     system/lib/libEGL.so —— 该路径已由 AOSP 的 libEGL 模块产出，
     build/core 会以 "PRODUCT_COPY_FILES ... ignored" 静默丢弃，
     结果「以为打了补丁其实没有」。

  2) 文件级重打包（out/ 被清空、只改 system.img 的场景，当前使用）
     源码补丁的编译产物不存在，于是用本脚本生成的等价二进制补丁：
         python3 tools/patch_libegl.py tools/libEGL.orig.so
     把产物落到设备树 prebuilt/lib/libEGL.so，再由
         repack/tools/apply_overlay.py 的 FILES 表
     写进 system.img 的 /system/lib/libEGL.so。
     校验：md5 必须是 4ac10584321c81f8dcddd21a025bced6（原版
     3cd50337aeb9aa2220b5007f786cf8bc），
     或对本文件执行 `python3 tools/patch_libegl.py <path> --check`
     看到「已经是打过补丁的状态」。

  原调试副本在 /home/dy/WorkBuddy AI/ardbeg-cm-14.1/egl-fix/，
  原始分析记录见 patches/README.md 的 egl_display.cpp.patch 专章。

【反汇编依据】(libEGL.so, _ZN7android13egl_display_t10getDisplayEPv @ 0xa378)
    a3c2: 6820        ldr  r0, [r4, #0]     ; r4 = &gEGLImpl, [r4] = cnx->dso
    a3c4: b190        cbz  r0, a3ec         ; dso == NULL 就跳过整块
    a3c6: 6870        ldr  r0, [r6, #4]     ; r6 = this, [r6+4] = disp.dpy
    a3c8: b980        cbnz r0, a3ec         ; <== 要改成 nop (00 bf)
    a3ca: ...                               ; cnx->egl.eglGetDisplay(display)
    a3d6: 6070        str  r0, [r6, #4]     ; disp.dpy = dpy

  结构体偏移已核对:
    egl_display_t::magic @ 0x00
    egl_display_t::disp  @ 0x04  (DisplayImpl::dpy)
    egl_display_t::lock  @ 0x28  (a382 的 add.w r5, r6, #40 印证)
    egl_connection_t::dso @ 0x00
    egl_connection_t::egl @ 0x14  (dso 0, hooks[2] 4/8, major 12, minor 16)
"""

import hashlib
import os
import struct
import sys

# ---------------------------------------------------------------------------
# 补丁定义
# ---------------------------------------------------------------------------
TARGET_VA = 0xA3C8                 # cbnz r0, a3ec
ORIG_BYTES = bytes.fromhex("80b9")  # cbnz r0, a3ec  (Thumb-2 T1, 小端)
NEW_BYTES = bytes.fromhex("00bf")  # nop

# 用来确认补丁位置没打错: 紧邻的上下文必须完全一致
#   a3c2: 20 68   (ldr r0, [r4, #0])
#   a3c4: 90 b1   (cbz r0, a3ec)
#   a3c6: 70 68   (ldr r0, [r6, #4])
#   a3c8: 80 b9   (cbnz r0, a3ec)
#   a3ca: 2a 48   (ldr r0, [pc, #168])
CONTEXT_VA = 0xA3C2
CONTEXT_ORIG = bytes.fromhex("206890b1706880b92a48")


def vaddr_to_off(elf, vaddr):
    """ELF32 小端: 用 PT_LOAD 段把虚拟地址换算成文件偏移"""
    e_phoff = struct.unpack_from("<I", elf, 0x1C)[0]
    e_phentsize = struct.unpack_from("<H", elf, 0x2A)[0]
    e_phnum = struct.unpack_from("<H", elf, 0x2C)[0]
    for i in range(e_phnum):
        base = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", elf, base)[0]
        if p_type != 1:  # PT_LOAD
            continue
        p_offset = struct.unpack_from("<I", elf, base + 0x04)[0]
        p_vaddr = struct.unpack_from("<I", elf, base + 0x08)[0]
        p_filesz = struct.unpack_from("<I", elf, base + 0x10)[0]
        if p_vaddr <= vaddr < p_vaddr + p_filesz:
            return p_offset + (vaddr - p_vaddr)
    return None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("用法: patch_libegl.py <libEGL.so> [--check]")
        return 2

    path = sys.argv[1]
    check_only = "--check" in sys.argv

    data = bytearray(open(path, "rb").read())
    print("文件      : %s (%d 字节)" % (path, len(data)))
    print("原始 md5  : %s" % hashlib.md5(data).hexdigest())

    off = vaddr_to_off(data, TARGET_VA)
    if off is None:
        print("!! 0x%08x 不在任何 PT_LOAD 段里, 文件不对" % TARGET_VA)
        return 1

    coff = vaddr_to_off(data, CONTEXT_VA)
    if coff is None:
        print("!! 上下文地址 0x%08x 换算失败" % CONTEXT_VA)
        return 1

    cur_ctx = bytes(data[coff:coff + len(CONTEXT_ORIG)])
    print("上下文    : 0x%08x -> 文件偏移 0x%x" % (CONTEXT_VA, coff))
    print("  期望    : %s" % CONTEXT_ORIG.hex())
    print("  实际    : %s" % cur_ctx.hex())

    cur = bytes(data[off:off + len(ORIG_BYTES)])
    print("补丁点    : 0x%08x -> 文件偏移 0x%x" % (TARGET_VA, off))
    print("  当前    : %s" % cur.hex())

    if cur == NEW_BYTES:
        print("\n== 已经是打过补丁的状态, 无需重复修改 ==")
        print("md5       : %s" % hashlib.md5(data).hexdigest())
        return 0

    if cur_ctx != CONTEXT_ORIG:
        print("\n!! 上下文不匹配, 拒绝修改 (说明这不是我们分析的那份 libEGL.so)")
        return 1

    if cur != ORIG_BYTES:
        print("\n!! 目标字节不是预期的 %s, 拒绝修改" % ORIG_BYTES.hex())
        return 1

    print("\n== 校验通过 ==")
    if check_only:
        print("(--check 模式, 不做修改)")
        return 0

    # cbnz r0, a3ec  ->  nop
    # 效果: 去掉 disp.dpy == EGL_NO_DISPLAY 这个进程级缓存条件,
    #       让每个线程的 eglGetDisplay 都真实透传给 tegra 驱动。
    data[off:off + len(NEW_BYTES)] = NEW_BYTES
    print("已写入    : %s" % NEW_BYTES.hex())

    # 回读校验
    back = bytes(data[off:off + len(NEW_BYTES)])
    if back != NEW_BYTES:
        print("!! 回读校验失败: %s" % back.hex())
        return 1
    print("回读校验  : OK (%s)" % back.hex())

    out = path
    open(out, "wb").write(data)
    print("新 md5    : %s" % hashlib.md5(data).hexdigest())
    print("已写入    : %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
