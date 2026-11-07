# android_device_nvidia_ardbeg — 分支 `cm-14.1`

NVIDIA Tegra K1 T124 / TN8 P1761，代号 **ardbeg**（g100 / G100）。
本分支是 **LineageOS 14.1 / Android 7.1.2** 的实际编译设备树，即生成
`cm_ardbeg_tv-ota-eng.dy.zip` 所用那一棵树的完整快照。

```
#
# Copyright (C) 2026 The Android Open Source Project
# Copyright (C) 2026 SebaUbuntu's TWRP device tree generator
#
# SPDX-License-Identifier: Apache-2.0
#
```

## Spec Sheet

| Feature | Specification |
| :--- | :--- |
| CPU | Quad Core 2.2GHz |
| Chipset | NVIDIA® Tegra K1 T124 |
| GPU | NVIDIA® GK20A (Kepler) |
| Memory | 2GB RAM |
| Shipped Android Version | 4.4.2（原厂） |
| Storage | 32GB |
| MicroSD | Up to 128GB |
| Battery | 10000 mAh |
| Dimentions | 27,41 x 14,36 x 5,33 cm |
| Display | 1200 x 1920 pixels |

---

## 这个分支和其它分支的关系

| 分支 | 内容 |
| :--- | :--- |
| `main` | 仓库初始的 TWRP 设备树生成器骨架 |
| `cm-11` | 原厂 Android 4.4.4 / CM11 时代的 device 树 |
| **`cm-14.1`（本分支）** | 在 `cm-11` 基础上移植到 7.1.2，并固化全部真机调试修复 |

与 `cm-11` 的主要差异不是「改几个 mk」，而是把 4.4.4 的预编译内核与 blob
接到 7.1 用户空间上，涉及 SELinux、init、HWUI/EGL、媒体框架、TV 特性位等
多条根因链。完整推导在 `patches/README.md`（约 6400 行），本文件只做索引。

---

## 仓库布局（已按要求把散落的 device 树合并成一个）

本仓库根直接对应 `device/nvidia/ardbeg/`；另外两个**编译必需**的兄弟目录
以快照形式并入 `merged/`：

```
android_device_nvidia_ardbeg @ cm-14.1
├── AndroidProducts.mk / lineage.mk / lineage_tv.mk   # 产品入口
├── BoardConfig.mk / device.mk / system.prop          # 板级与产品配置
├── Android.mk / AndroidBoard.mk / Android.bp
├── prebuilt/
│   ├── kernel                    # 原厂 4.4.4 zImage（3.10.24），非源码
│   └── lib/                      # 含 libstagefrighthw.so、libEGL.so 等修复产物
├── initfiles/                    # 7.1 init rc 与服务脚本（含 mediacodec.rc）
├── media/media_codecs.xml        # 7.1 兼容 codec 表
├── patches/                      # AOSP 源码补丁 + check/install/uninstall + 全量文档
├── tools/                        # 真机验收 / OTA 往返校验 / 六层矩阵 / 刷机块表
├── overlay/ sepolicy/ permissions/ audio/ power/ ...  # 常规设备树内容
├── merged/
│   ├── ardbeg_tv/                # -> device/nvidia/ardbeg_tv（TV lunch 入口）
│   └── shield-common/            # -> device/nvidia/shield-common（sepolicy + seccomp）
├── install-layout.sh             # 展开 merged/
├── DEPENDENCIES.md               # 完整依赖清单（内核 / vendor / 官方树 / 补丁）
├── lineage.dependencies          # roomservice 依赖声明
├── local_manifest.xml            # repo 片段
└── .gitignore
```

`shieldtablet` 与 `kernel/nvidia/shield` **未合并**：全树 grep 无引用，
`shield-common/Android.mk` 的设备白名单里也不含 ardbeg。理由见
`DEPENDENCIES.md` 第 5 节。

---

## 快速开始

```sh
# 1) 取两个仓库（内核仓库不需要）
git clone -b cm-14.1 https://github.com/teny-001/android_device_nvidia_ardbeg device/nvidia/ardbeg
git clone -b cm-14.1 https://github.com/teny-001/android_vendor_nvidia_ardbeg vendor/nvidia/ardbeg

# 2) 展开合并进来的兄弟树（否则 lunch cm_ardbeg_tv 找不到产品文件）
cd device/nvidia/ardbeg && ./install-layout.sh

# 3) 打 AOSP 源码补丁 —— 不打能编译，但编出来的 ROM 开不了机
cd patches && ./check.sh && ./install.sh && ./check.sh

# 4) 编译（eng / TV）
. build/envsetup.sh
lunch cm_ardbeg_tv-eng
mka bacon
```

**内核不编译源码**：`BoardConfig.mk` 用 `TARGET_PREBUILT_KERNEL` 指向
`prebuilt/kernel`，并把 `TARGET_KERNEL_SOURCE` 故意设成不存在的
`kernel/nvidia/ardbeg__prebuilt_only`，以绕开 CM14.1 `kernel.mk` 的
`wildcard` 判断。因此 `android_kernel_nvidia_ardbeg` 保持原有 4.4 分支，
**不新建 `cm-14.1`**。详见 `DEPENDENCIES.md` 第 2 节。

---

## 已固化的主要修复（索引）

| 领域 | 结论 | 文档位置 |
| :--- | :--- | :--- |
| SELinux | 4.4.4 `/sepolicy` 只有 307 types / 84 classes，缺 7.1 新域；靠 `libselinux_bypass.so` + permissive + 逐服务 `seclabel` 绕过 | `patches/README.md` 17 章 |
| init | `setenv` 一行只能一个值；`lmkd` 缺 `lmkd_exec` 域导致 Watchdog 杀 `system_server`；`wifiloader` 缺 `oneshot` 无限重启 | 同上 |
| 黑屏 | `KeyguardScrim` 遮挡 + `persist.sys.ui.hw=1` 触发旧 Tegra EGL `EGL_BAD_DISPLAY`；`libEGL.so` 二进制补丁 + `egl_display.cpp.patch` | 同上 18 章 |
| SetupWizard | 四清后 `Unknown package: com.google.android.tungsten.setupwraith` 崩溃 | 同上 |
| 浏览器「闪退」 | 首启脚本 / 常驻守护的 `launcher_visible()` 恒 false，每 90 秒把用户踢回 HOME；补 `foreground_is_home()` 守卫 | 同上 19 章 |
| 硬件解码 | 三条独立根因：`libstagefrighthw.so` / 7.1 兼容 `media_codecs.xml` / `mediacodec.rc` 的 `group media` | 同上 19 章 |
| WiFi / 蓝牙 | 开机自启、自动连接、7.1 `svc` 无 bluetooth 子命令需 `service call bluetooth_manager 6` | 同上 |
| 日志 | `persist_logcat` 写 `/cache`；`seclabel u:r:init:s0` 解决 `logcat_exec` 缺域 | 同上 |

验收工具：`tools/full_function_test.sh`（108 项真机功能测试）、
`tools/verify_hwdec.sh`、`tools/verify_app_video.sh`（Gallery3d / Jelly HTML5 /
第三方在线 HLS）、`tools/verify_after_boot.sh`、
`tools/verify_ota_contents.sh`、`tools/verify_six_layers.py`。

---

## 交付物基准

最终 OTA：`dist/appvideo-1107-2005/cm_ardbeg_tv-ota-eng.dy.zip`
（该路径在工作目录，不在本仓库内）。`patches/check.sh` 与
`tools/verify_six_layers.py` 中锚定的 md5 均以此为基准。

---

## 维护提醒

* 设备树里的注释含大量本机绝对路径（`/home/dy/...`），是调试留档。
  **不要为「清理注释」改动文件字节**：六层一致性矩阵按 md5 锚定，改一个
  字节就会全线报红。
* 新增文件必须同时注册 `device.mk`（全量编译）与宿主侧
  `repack/tools/apply_overlay.py` 的 `FILES`（文件级重打包）；zip 条目还要
  注册 `mkzip.py`。只改一处会出现「补丁应用了但没进 ROM」。
* 许可：`merged/shield-common/` 是 LineageOS `cm-14.1` 官方
  `android_device_nvidia_shield-common` 的 2018-08-04 快照，Apache-2.0，
  仅因「合并成一个仓库」而随本仓库分发；其余内容为本移植工作产物与
  原厂 blob（后者版权归 NVIDIA 所有）。
