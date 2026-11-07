# cm-14.1 编译依赖清单 — ardbeg / NVIDIA Tegra K1 T124 / TN8 P1761

本文件回答一个问题：**拿到这三个 GitHub 仓库后，还需要什么，才能重新编出
`cm_ardbeg_tv-ota-eng.dy.zip`？** 所有路径均相对 AOSP / LineageOS 源码树根目录。

配套文档：根目录 `README.md`（仓库结构）、`patches/README.md`（全部调试与修复
推导，约 6400 行）、`patches/check.sh`（六层一致性静态检查）。

---

## 0. 结论速查

| 仓库 / 目录 | 是否需要 | 分支 | 落地路径 | 说明 |
| :--- | :--- | :--- | :--- | :--- |
| `teny-001/android_device_nvidia_ardbeg` | **必需** | `cm-14.1` | `device/nvidia/ardbeg` | 本仓库。主设备树 + `merged/` 两个兄弟树 |
| `teny-001/android_vendor_nvidia_ardbeg` | **必需** | `cm-14.1` | `vendor/nvidia/ardbeg` | 原厂 4.4.4 预编译 blob（324 文件 / 114 MiB） |
| `teny-001/android_kernel_nvidia_ardbeg` | **不需要** | — | — | 本次移植**未使用内核源码**，见第 2 节 |
| `LineageOS/android_device_nvidia_shield-common` | 已内置 | `cm-14.1` 快照 | `device/nvidia/shield-common` | 已合并到 `merged/shield-common`，无需另拉 |
| `LineageOS/android_device_nvidia_shieldtablet` | 不需要 | — | — | 全树 grep 无引用，见第 5 节 |
| LineageOS `cm-14.1` 全量源码 | **必需** | `cm-14.1` | 源码树根 | 提供 `build/`、`frameworks/`、`vendor/cm/` 等 |

**一句话**：内核仓库不动；device 与 vendor 两个仓库新建 `cm-14.1` 分支；编译前
还必须执行 `device/nvidia/ardbeg/patches/install.sh` 打 AOSP 补丁。

---

## 1. 源码基线

* **LineageOS 14.1 / Android 7.1.2**，不是 AOSP 原生 7.1，也不是 CM11。
  产品文件依赖 `vendor/cm/config/common_full_tv.mk`、
  `vendor/cm/config/common_full_tablet_wifionly.mk` 和
  `vendor/cm/build/tasks/kernel.mk`；这三者只有 CM/LineageOS 树里才有。
* 产品中用到的框架侧组件（均在 LineageOS 源码树内，无需额外仓库）：
  * `vendor/cm/config/*`：TV / tablet 公共产品定义；
  * `hardware/nvidia/power`：`TARGET_POWERHAL_VARIANT := tegra` 对应的 power HAL；
  * `hardware/nvidia/libstagefrighthw`：官方 14.1 的 OMX vendor plugin 桥源码。
    注意本设备**没有**使用它编译出的模块，而是用 4.4.4 原厂预编译
    `prebuilt/lib/libstagefrighthw.so`（见第 6 节硬解三条）。
  * `device/google/atv`、`vendor/google/atv`：TV 形态资源，若未同步对应仓库，
    `lineage_tv.mk` 里的相关 `PRODUCT_COPY_FILES` 会找不到文件；请按本地
    LineageOS manifest 正常同步 TV 相关项目。
* `lunch` 目标：`cm_ardbeg_tv-eng`（TV，最终交付包）与 `cm_ardbeg-eng`
  （平板形态，调试用）。二者共用 `device.mk`，靠 `PRODUCT_IS_ATV` 分流。

---

## 2. 内核：为什么第三个仓库不用上传

这是本次移植最关键、也最容易误解的一点。

```
# BoardConfig.mk
TARGET_PREBUILT_KERNEL := device/nvidia/ardbeg/prebuilt/kernel
TARGET_KERNEL_SOURCE   := kernel/nvidia/ardbeg__prebuilt_only
TARGET_KERNEL_CONFIG   :=
```

* `TARGET_KERNEL_SOURCE` **故意指向一个不存在的目录**。CM14.1 的
  `vendor/cm/build/tasks/kernel.mk` 用 `ifeq "$(wildcard $(KERNEL_SRC))" ""`
  判断：路径存在就走 `FULL_KERNEL_BUILD := true`（编源码，忽略预编译），
  路径不存在才使用 `TARGET_PREBUILT_KERNEL`。所以这个名字不是笔误。
* 使用的内核是 `device/nvidia/ardbeg/prebuilt/kernel`，7,220,312 字节，
  来自原厂 Android 4.4.4 线刷包 boot.img 的 `3.10.24-g1fc624e` zImage
  （2016-03-15 构建，gcc 4.7）。它**作为二进制资源随本 device 仓库一起上传**，
  属于设备树的一部分，不是内核源码仓库的内容。
* 树内虽存在 `kernel/nvidia/shield`（3.10.96，LineageOS shieldtablet 分支），
  但 DTB / NCT 配置与本板不是一套，实测自编内核起不来（console 走 ttyS0、
  DTB 里 `linux,initrd-start` 陈旧导致静默挂死）。因此**没有采用**。
* 结论：`android_kernel_nvidia_ardbeg` 保持原有 `android-4.4` / `cm11-test` /
  `cm-11.0` / `rel-st8-r2.2` 四个分支不变，**不新建 `cm-14.1`、不上传源码**。
  若将来要切到源码编译，需要单独补齐 ardbeg 的 DTB / defconfig 组合，
  并同步修改本文件的 `TARGET_KERNEL_SOURCE`，那是另一项工作。

> 附带影响：4.4.4 内核没有 `CONFIG_SECCOMP_FILTER`，缺 `system_server`、
> `service_manager` 等 7.1 新 sepolicy 类型，也没有 pstore/新 logd 能力。
> 本树通过 `libselinux_bypass.so`、`libminijail.so` 软失败补丁、
> `/sepolicy` permissive、逐服务 `seclabel` 等方式绕过，详见
> `patches/README.md` 第十七、十八章。这些都随 device 树上传。

---

## 3. vendor 树依赖

`android_vendor_nvidia_ardbeg` @ `cm-14.1`，落地 `vendor/nvidia/ardbeg`：

* `proprietary/`：原厂 4.4.4 blob（`lib/libnvomx.so`、`vendor/lib/libEGL_tegra_impl.so`
  等），最大单文件 `proprietary/vendor/lib/libglcore.so` 约 20 MiB，
  远低于 GitHub 单文件 100 MiB 限制。
* `ardbeg-vendor-blobs.mk`：为 7.1 重写过的 `PRODUCT_COPY_FILES` 清单。
  `ardbeg-vendor-blobs.mk.orig-4.4.4` 是原始 4.4.4 清单，仅作 diff 留档，**不参与构建**。
* `blobs-blacklist.txt` / `blobs-recovered.txt`：排除与找回记录。注意历史注释里
  曾写过「7.1 要求 `createOMXPlugin(bool secure)` 所以排除 4.4 blob」，这是**误判**——
  当前 CM14.1 `OMXMaster.cpp` 用的是无参 `CreateOMXPluginFunc` 加
  `dlsym("_ZN7android15createOMXPluginEv")` fallback。修正结论见第 6 节。
* 来源：原厂线刷包手工提取，早期存在缺文件 / 路径错位，已在本分支修复。

---

## 4. 为什么需要 `merged/`，以及怎么展开

按 Android 惯例，一个 device 仓库的内容直接对应 `device/<vendor>/<device>/`。
但本次移植在 `device/nvidia/` 下还多出两个**编译必需**的兄弟目录：

| 目录 | 作用 | 不展开的后果 |
| :--- | :--- | :--- |
| `merged/ardbeg_tv/` | `lunch cm_ardbeg_tv-eng` 时 CM_BUILD=`ardbeg_tv`，`build/core/product_config.mk` 用 `find device -path "*/ardbeg_tv/lineage.mk"` 定位产品文件，只有这个极薄转发目录能命中 | `Cannot locate config makefile for product cm_ardbeg_tv` |
| `merged/shield-common/` | `BoardConfig.mk` 的 `BOARD_SEPOLICY_DIRS` 引用其 `sepolicy/common`、`sepolicy/lineage-common`，`BOARD_SECCOMP_POLICY` 引用其 `seccomp/` | sepolicy / seccomp 编译直接失败 |

因为 GitHub 一个仓库只有一个根目录，无法同时是 `device/nvidia/ardbeg` 和
`device/nvidia/ardbeg_tv`，所以把两者以**快照**形式合并进 `merged/`，由
`./install-layout.sh` 展开：

```sh
cd <aosp-root>/device/nvidia/ardbeg
./install-layout.sh            # 自动推断源码树根
# 或显式指定
./install-layout.sh /path/to/cm-14.1
```

脚本是幂等的 `cp -a`，只覆盖 `merged/` 里存在的同名文件，不会删除源码树里
其它内容。若源码树已通过 LineageOS manifest 拉过官方 `shield-common`，
可以跳过这一步（但需保证 revision 是 cm-14.1 且 seccomp 目录存在）。

`local_manifest.xml` 给出了等价的 `repo` 写法；`lineage.dependencies` 供
`breakfast` / roomservice 使用（第三方 owner 需自行配置 remote，见文件注释）。

---

## 5. 为什么排除 `shieldtablet`

* 对 `device/nvidia/ardbeg` 全树 grep，没有任何 `.mk` / `.sh` / `.rc` 引用
  `device/nvidia/shieldtablet`。
* `merged/shield-common/Android.mk` 里的
  `ifneq ($(filter $(TARGET_DEVICE), shieldtablet foster loki hawkeye falcon roth jetson),)`
  是一份设备白名单，`ardbeg` **不在其中**，因此该分支不会为 ardbeg 生效。
* `kernel/nvidia/shield` 同为 shieldtablet 配套内核，同样未使用（见第 2 节）。

所以 `shieldtablet` 目录只是本地 LineageOS 源码树自带内容，**不属于本次交付**，
合并进仓库反而会引入无关代码与许可归属问题。

---

## 6. 编译前必须做的两件事

### 6.1 打 AOSP 补丁

```sh
cd <aosp-root>/device/nvidia/ardbeg/patches
./check.sh        # 期望 RC=0
./install.sh      # 把源码级修改打到 frameworks/av、system/core、system/vold 等
./check.sh        # 再跑一次，确认全部已应用
```

补丁按源码路径存放（如 `frameworks/av/services/mediacodec/mediacodec.rc.patch`），
`install.sh` / `uninstall.sh` 成对。**不打补丁能编译，但编出来的 ROM 开不了机**：
典型症状包括 `system_server` 反复被 Watchdog 杀、`persist_logcat` 起不来、
SELinux 缺域导致 installd / vold 崩溃、HWUI 黑屏等。

### 6.2 确认硬件解码三条文件

这三条是彼此独立、缺一不可的根因，也是「有 OMX 组件但播不了 H.264」的答案：

| 文件 | md5 | 作用 |
| :--- | :--- | :--- |
| `prebuilt/lib/libstagefrighthw.so` → `system/lib/` | `7221cb3656b33b54846e34b5e406163c` | `OMXMaster::addVendorPlugin()` 的 `dlopen` 入口，缺了就没有 `OMX.Nvidia.*` |
| `media/media_codecs.xml` → `system/etc/` | `9c884d66a4e7d44a0b7227cc2ec8ddb5` | 7.1 兼容 XML。4.4 风格同名组件重复声明会触发 `MediaCodecList.cpp:737` 返回 `-EINVAL` 并 `mCodecInfos.clear()` |
| `initfiles/mediacodec.rc` → `system/etc/init/` | `e5dfd2d55c04eb72cbb89ff2327ce4f1` | `group ... media`，让 `mediacodec` 进程能打开 `/dev/tegra_avpchannel`；缺了会报 `NvxVideoDecoderAcquireResources : NvxNvMMTransformOpen failed` |

这三条同时注册在 `device.mk`（全量编译）和宿主侧
`repack/tools/apply_overlay.py` 的 `FILES` 表（文件级重打包）。**只改一处不算固化**。

---

## 7. 宿主侧工具不在本仓库

`repack/`、`dist/`、`make_ota.sh` 等属于工作目录
`/home/dy/WorkBuddy AI/ardbeg-cm-14.1/`，是把已编译镜像做**文件级重打包**
（`chk.img` → debugfs 写 overlay → `otablocks.py pack` → `mkzip.py` →
`sign_ota.py`）的工具链，不是 AOSP 设备树组成部分，因此**未上传**。
本仓库的 `tools/` 里是与设备树强绑定、需要随树分发的验收脚本：

| 脚本 | 用途 |
| :--- | :--- |
| `tools/full_function_test.sh` | 真机 108 项全面功能测试 |
| `tools/verify_hwdec.sh` | OMX 组件 / `NvMMLiteOpen` / `EOS detected` 硬解专项 |
| `tools/verify_app_video.sh` | Gallery3d / Jelly HTML5 / 第三方在线 HLS 的 app 级播放验收 |
| `tools/verify_after_boot.sh` | 冷启动后运行时证据（属性 / md5 / 抢前台计数） |
| `tools/verify_ota_contents.sh` | zip → `system.new.dat` → raw ext4 → debugfs dump → md5 往返校验 |
| `tools/verify_six_layers.py` | 六层字节一致性矩阵（补丁 / 真源 / 注册 / overlay / 包内 / 真机） |
| `tools/gen_flash_blocks.py` | 把 `system.transfer.list` 展开成 recovery 侧 `dd` 脚本 |

---

## 8. 已知边界与维护提醒

* **不要改文件字节去"清理"注释**：设备树里有 28 个文件在注释中写有本机绝对路径
  （`/home/dy/...`），那是调试留档。`check.sh`、`verify_six_layers.py`、最终 OTA
  期望表都按 md5 锚定，改一个字节就会让六层矩阵全线报红。
* 全量编译侧新增文件必须注册 `device.mk`；文件级重打包侧必须注册
  `apply_overlay.py` 的 `FILES`；zip 条目（如 `install/bin/*`）注册在 `mkzip.py`。
  三处缺一，就会出现「补丁应用了但没进 ROM」。
* `PRODUCT_COPY_FILES` 不能覆盖 AOSP 已产出的模块（`system/lib/libEGL.so` 是
  典型坑，build/core 会静默 ignored），这类文件只能靠源码补丁 + overlay。
* 4.4.4 `/sepolicy` 仍缺若干 7.1 新域，logcat 里会有 14 条
  `could not get context`（bootanim / gatekeeperd / mediadrm / bootstat 等），
  属已确认的次要遗留，真机 108 项功能测试未发现功能缺失，未擅自改 ROM。
* 最终交付包基准：`dist/appvideo-1107-2005/cm_ardbeg_tv-ota-eng.dy.zip`。
* 当前环境无 `git` / `gh` 二进制、无凭据、Bash 侧无法直连 GitHub，
  因此 `cm-14.1` 分支是**离线生成**的；上传步骤见工作目录 `upload/README.md`。
