# 这个目录已停用（改名加 `.unused-4.4` 后缀）

## 原来是什么
从原厂 Android 4.4.4 内核源码里抠出来的**部分** uapi 头：
`asm/`、`asm-generic/`、`linux/`、`sound/`。

## 为什么停用
1. `build/core/config.mk:232` 有这么一行：

   ```make
   TARGET_DEVICE_KERNEL_HEADERS := $(strip $(wildcard $(TARGET_DEVICE_DIR)/kernel-headers))
   ```

   也就是说，**只要设备树里存在名为 `kernel-headers` 的目录，它就会被自动
   加进 `TARGET_PROJECT_INCLUDES`**，最终出现在每条 target 编译命令的
   `-isystem device/nvidia/ardbeg/kernel-headers` 里，而且排在
   `-isystem bionic/libc/include` **前面**。

2. 这份头是残缺的（只抠了几个子目录）。结果它把 bionic 自带的完整 uapi
   头挡住了，7.1 编译 libc 时直接炸：

   ```
   bionic/libc/kernel/uapi/linux/resource.h:32:3: error: unknown type name '__kernel_long_t'
   device/nvidia/ardbeg/kernel-headers/asm/posix_types.h:54:19: note:
       '__kernel_loff_t' declared here
   ```

   原因是 `linux/resource.h` 需要 `asm/posix_types.h` 里定义的
   `__kernel_long_t` / `__kernel_ulong_t`，而 4.4 那份 `asm/posix_types.h`
   里根本没有这两个 typedef（它们在内核 3.4 之后才加进来）。

3. 7.1 的 bionic 已经在 `bionic/libc/kernel/uapi/` 里提供了完整的
   `asm/`、`asm-generic/`、`linux/`、`sound/` 等头（含
   `sound/asound.h`、`sound/compress_offload.h`、`sound/compress_params.h`，
   也就是这份目录里仅有的那三个音频头），音频 HAL 编译并不缺东西。

4. 本设备用原厂 4.4.4 **预编译** kernel，本来就不需要从内核源码
   headers_install 出来的那套头。

## 结论
删掉（或像现在这样改名）即可，不需要替换成别的东西。
如果以后改成从 `kernel/nvidia/ardbeg` 源码编译内核，kernel.mk 会自己
生成 `$(TARGET_OUT_INTERMEDIATES)/KERNEL_OBJ/usr/include` 并加进
include 路径，也不需要这个目录。
