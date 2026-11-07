# ardbeg 内核配置（ardbeg_defconfig）

## 这是什么

`ardbeg_defconfig` 是从 **原厂 boot.img 里提取的 .config** 固化下来的内核配置，
对应 `arch/arm/configs/ardbeg_defconfig`。

已经用 `arm-eabi-gcc 4.8` 在这棵内核树上完整编译通过：

```
arch/arm/boot/Image    17,612,944 字节
arch/arm/boot/zImage    5,802,264 字节
编译时间               2026-10-27 15:30
```

所以这份配置不是"推测"出来的，是**实际编过、能出 Image 的**那份。

## 出处

| 项 | 值 |
|---|---|
| 内核版本 | Linux 3.10.96（Tegra K1 / T124） |
| 内核树 | `/home/dy/kbuild` |
| 源文件 | `/home/dy/kbuild/.config`（125,076 字节） |
| 板级配置 | `CONFIG_MACH_ARDBEG=y` |
| 平台 | `CONFIG_ARCH_TEGRA_12x_SOC=y` |

> 说明：`/home/dy/下载/build_defconfig` 在沙箱里看不到（只有
> `/home/dy/WorkBuddy AI` 是挂载点），所以改用 `/home/dy/kbuild/.config`。
> 这份 `.config` 的特征（`CONFIG_CMDLINE="console=tty0"`、
> `CONFIG_FRAMEBUFFER_CONSOLE`、`CONFIG_VT`、`CONFIG_PSTORE_CONSOLE`）
> 正是"从 boot.img 提取"留下的痕迹，和内核树自带的
> `tegra_ardbeg_defconfig` 差 16 项，差异方向全部指向"原厂配置"。
> 如果两者不是同一份，把真正的 `build_defconfig` 发过来，重新生成一次即可。

## 怎么用

### 在 `/home/dy/kbuild` 里直接用（已就位）

```sh
cd /home/dy/kbuild
export ARCH=arm
export SUBARCH=arm
export CROSS_COMPILE=/home/dy/tc-arm/bin/arm-eabi-

make ardbeg_defconfig
make -j$(nproc) Image zImage
```

产物在 `arch/arm/boot/`。`zImage` 直接替换
`device/nvidia/ardbeg/prebuilt/kernel` 就是新内核。

### 在 CM11 源码树里编（in-tree）

设备树当前是**预编译内核**模式（`BoardConfig.mk` 里
`TARGET_FORCE_PREBUILT_KERNEL ?= true`），所以源码树里的
`kernel/nvidia/ardbeg/` 是空的。要切成 in-tree 编译：

```sh
# 1) 把内核源码放进源码树（排除编译产物，省 ~1.5GB）
rsync -a --exclude='*.o' --exclude='*.o.cmd' --exclude='*.ko' \
         --exclude='*.mod.c' --exclude='.tmp*' --exclude='.*.cmd' \
         --exclude='arch/arm/boot/compressed' \
      /home/dy/kbuild/ kernel/nvidia/ardbeg/

# 2) 确认 defconfig 在位
cp device/nvidia/ardbeg/kernel-config/ardbeg_defconfig \
   kernel/nvidia/ardbeg/arch/arm/configs/

# 3) 关掉预编译模式
#    编辑 device/nvidia/ardbeg/BoardConfig.mk，把
#        TARGET_FORCE_PREBUILT_KERNEL ?= true
#    改成
#        TARGET_FORCE_PREBUILT_KERNEL := false
```

`BoardConfig.mk` 里两条分支已经写好了：

```make
ifeq ($(TARGET_FORCE_PREBUILT_KERNEL),true)
    TARGET_PREBUILT_KERNEL := device/nvidia/ardbeg/prebuilt/kernel
    # 故意指向一个不存在的路径：kernel.mk 用 $(wildcard $(KERNEL_SRC)) 判断
    # 有没有内核源码，只看目录存不存在。不这么写的话它照样会去编源码然后失败。
    TARGET_KERNEL_SOURCE := kernel/nvidia/ardbeg__disabled_by_prebuilt
    TARGET_KERNEL_CONFIG :=
else
    TARGET_KERNEL_SOURCE := kernel/nvidia/ardbeg
    TARGET_KERNEL_CONFIG := ardbeg_defconfig
endif
```

## 关键选项（本次音频修复依赖）

| 选项 | 值 | 作用 |
|---|---|---|
| `CONFIG_MACH_ARDBEG` | y | `board-ardbeg.c`，ASoC 声卡在这里注册 |
| `CONFIG_ARCH_TEGRA_12x_SOC` | y | T124 平台 |
| `CONFIG_SND_SOC_TEGRA` | y | Tegra ASoC 框架 |
| `CONFIG_SND_SOC_TEGRA_RT5639` | y | machine driver `tegra_rt5639.c` |
| `CONFIG_SND_SOC_RT5639` | y | codec driver `rt5639.c` |
| `CONFIG_SND_SOC_TEGRA30_I2S` | y | I2S 后端，codec 挂在上面 |
| `CONFIG_SND_SOC_TEGRA30_DAM` | y | DAM，音频路由 |
| `CONFIG_SND_SOC_TEGRA_OFFLOAD` | y | 提供 `Codec VMixer Codec Switch` |
| `CONFIG_SND_SOC_TEGRA30_SPDIF` | y | HDMI 音频 |

日志落 `/cache` 依赖：

| 选项 | 值 | 作用 |
|---|---|---|
| `CONFIG_PSTORE` | y | pstore 框架 |
| `CONFIG_PSTORE_RAM` | y | ramoops，掉电后保留 |
| `CONFIG_PSTORE_CONSOLE` | y | → `/sys/fs/pstore/console-ramoops` |

> `CONFIG_ANDROID_RAM_CONSOLE` **没有**，所以 `/proc/last_kmsg` 不存在。
> `bootlog.sh` 里抓 last_kmsg 那一步已经加了存在性判断，会跳过而不是报错。

USB / adb：

| 选项 | 值 | 作用 |
|---|---|---|
| `CONFIG_USB_G_ANDROID` | y | `android.c` 里 `#include "f_fs.c"` / `"f_mtp.c"`，functionfs(adb) 和 MTP 都编进内核 |

`ffs` 的别名 `adb` 由 `init.nv_dev_board.usb.rc` 写
`/sys/class/android_usb/android0/f_ffs/aliases`，
`functions_store()` 里靠这个别名把 `sys.usb.config=mtp,adb` 里的 `adb`
映射到 `ffs` 功能上（`drivers/usb/gadget/android.c:1569`）。
