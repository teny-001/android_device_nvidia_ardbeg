#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_webview_gpu.py —— 给 libwebviewchromium.so 打「禁用 EGL 同步栅栏」补丁

【为什么要打这个补丁】
  Tegra K1 (T124 / TN8) 这套设备的 GPU 厂商库是从原厂 Android 4.4.4 里抽出来的
  (libEGL_tegra.so / libGLESv2_tegra.so)。它的 EGL_KHR_wait_sync 实现有缺陷:
  Chromium 的 RenderThread 里 eglWaitSyncKHR() 返回 EGL_BAD_MATCH, 紧接着
  Chromium 的合成器状态机就 abort() -> 进程 SIGABRT -> 浏览器"一打开就退出"。

  实测日志:
    E chromium: [ERROR:gl_fence_egl.cc(62)] Failed to wait for EGLSync. error:EGL_BAD_MATCH
    F libc    : Fatal signal 6 (SIGABRT), code -6 in tid xxxx (RenderThread)

【怎么修的】
  Chromium 自带一张「GPU 驱动 bug 规避表」(gpu/config/gpu_driver_bug_list_json.cc),
  编译时以纯文本 JSON 的形式嵌在 .so 的只读数据段里。表里本来就有这么几条:

    { "id": 74, ... "os": { "type": "android", "version": { "op": "<=", "value": "4.4.4" } },
      "gl_vendor": "Qualcomm.*", "disabled_extensions": [ "EGL_KHR_fence_sync" ] }
    { "id": 76, ... "gl_vendor": "Imagination Technologies.*", ... }
    { "id": 78, ... "gl_vendor": "Broadcom.*", ... }
    { "id": 94, ... "gl_vendor": "NVIDIA.*", "gl_version": {"op":"=","value":"3.1"},
      "disabled_extensions": [ "EGL_KHR_wait_sync" ] }

  也就是说 Chromium 早就知道「Android 4.4.4 的厂商驱动测 EGL 栅栏是坏的」,
  只不过它用 os.version <= 4.4.4 当条件。我们是 7.1.2 的 framework + 4.4.4 的厂商库,
  这个条件正好匹配不上, 于是 Chromium 放心地去用坏掉的 EGL_KHR_wait_sync。

  于是把 74 号条目原地改写成「所有 Android 设备都禁用 EGL_KHR_fence_sync 和
  EGL_KHR_wait_sync」。JSON 对空白不敏感, 改写后长度不够就用空格补齐,
  保证 .so 里其它所有偏移、重定位、符号表全部不动 —— 这是最安全的二进制补丁方式。

  副作用: Chromium 会退回 GLFenceGL (也就是 glFinish) 来同步, 每帧多一次
  glFinish, 性能略降, 但换来的是「不崩」。

【用法】
  python3 patch_webview_gpu.py <原始 so> <输出 so>
"""

import sys

# 被改写的那段原始区间: 从 74 号条目开头, 到 76 号条目开头
MARK_A = b'{ "id": 74, '
MARK_B = b'{ "id": 76, '

# 改写后的新条目 (注意末尾保留 ", " 以衔接后面的 76 号条目)
NEW_ENTRY = (
    b'{ "id": 74, "cr_bugs": [278606, 382686], '
    b'"description": "ardbeg: EGL sync fences are broken on Tegra K1 4.4.4 vendor blobs", '
    b'"os": { "type": "android" }, '
    b'"gl_vendor": ".*", '
    b'"disabled_extensions": [ "EGL_KHR_fence_sync", "EGL_KHR_wait_sync" ] }, '
)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    data = bytearray(open(src, 'rb').read())

    a = data.find(MARK_A)
    if a < 0:
        print('找不到 74 号条目, 这个 so 可能不是 Chromium 52 的')
        return 2
    b = data.find(MARK_B, a)
    if b < 0:
        print('找不到 76 号条目')
        return 2

    old_len = b - a
    if len(NEW_ENTRY) > old_len:
        print('新条目太长 (%d > %d), 无法原地替换' % (len(NEW_ENTRY), old_len))
        return 2

    # 用空格补齐, 保证区间总长度不变
    block = NEW_ENTRY + b' ' * (old_len - len(NEW_ENTRY))
    data[a:b] = block

    open(dst, 'wb').write(bytes(data))
    print('原条目区间 0x%x..0x%x  长度 %d' % (a, b, old_len))
    print('新条目长度 %d  补空格 %d' % (len(NEW_ENTRY), old_len - len(NEW_ENTRY)))
    print('已写出 %s' % dst)
    return 0


if __name__ == '__main__':
    sys.exit(main())
