# cm-14.1 编译依赖清单 — ardbeg / NVIDIA Tegra K1 T124 / TN8 P1761

本文件回答一个问题：**拿到仓库后还需要什么，才能重新编出
`cm_ardbeg_tv-ota-eng.dy.zip`？** 所有路径均相对 LineageOS 源码树根目录。

配套文档：根目录 `README.md`（结构概览与编译步骤）、`patches/README.md`
（全部调试与修复推导，约 6400 行）、`patches/check.sh`（六层一致性静态检查）。

---

## 0. 结论速查

| 仓库 / 目录 | 是否需要 | 分支 | 落地路径 | 说明 |
| :--- | :--- | :--- | :--- | :--- |
| `teny-001/android_device_nvidia_ardbeg` | **必需** | `cm-14.1` | `device/nvidia/ardbeg` | 本仓库。设备树 + `shield-common/` 快照 + 原厂预编译内核 |
| `teny-001/android_vendor_nvidia_ardbeg` | **必需** | `cm-14.1` | `vendor/nvidia/ardbeg` | 原厂 4.4.4 预编译 blob（324 文件 / 114 MiB） |
| `teny-001/android_kernel_nvidia_ardbeg` | **不需要** | — | — | 本次移植未使用内核源码，见第 2 节 |
| `LineageOS/android_device_nvidia_shield-common` | 已内置 | `cm-14.1` 快照 | `device/nvidia/ardbeg/shield-common` | 只并入了 93 个被引用的文件，见第 4 节 |
| `LineageOS/android_device_nvidia_shieldtablet` | 不需要 | — | — | 全树 grep 无引用，见第 5 节 |
| LineageOS `cm-14.1` 全量源码 | **必需** | `cm-14.1` | 源码树根 | 提供 `build/`、`frameworks/`、`vendor/cm/` 等 |

**一句话**：内核仓库不动；device 与 vendor 是两个独立仓库，各建 `cm-14.1`
分支；编译前必须执行 `device/nvidia/ardbeg/patches/install.sh` 打 AOSP 补丁。

---

## 1. 源码基线

* **LineageOS 14.1 / Android 7.1.2**，不是 AOSP 原生 7.1，也不是 CM11。
  产品文件依赖 `vendor/cm/config/common_full_tv.mk`、
  `vendor/cm/config/common_full_tablet_wifionly.mk` 和
  `vendor/cm/build/tasks/kernel.mk`，这三者只有 CM/LineageOS 树里才有。
* 产品中用到的框架侧组件（均在 LineageOS 源码树内，无需额外仓库）：
  * `vendor/cm/config/*`：TV / 平板公共产品定义；
  * `hardware/nvidia/power`：`TARGET_POWERHAL_VARIANT := tegra` 对应的 power HAL；
  * `hardware/nvidia/libstagefrighthw`：官方 14.1 的 OMX vendor plugin 桥源码。
    注意本设备**没有**使用它编译出的模块，而是用 4.4.4 原厂预编译的
    `prebuilt/lib/libstagefrighthw.so`（见第 6.2 节）。
  * `device/google/atv`、`vendor/google/atv`：TV 形态资源。若未同步对应仓库，
    `lineage_tv.mk` 里的相关 `PRODUCT_COPY_FILES` 会找不到文件，请按本地
    LineageOS manifest 正常同步 TV 相关项目。
* `lunch` 目标：`cm_ardbeg_tv-eng`（TV，最终交付形态）与 `cm_ardbeg-eng`
  （平板形态，调试用）。二者共用 `device.mk`，靠 `PRODUCT_IS_ATV` 分流。

---

## 2. 内核：为什么不需要内核仓库

这是本次移植最关键、也最容易误解的一点。

```make
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
  来自原厂 Android 4.4.4 线刷包 `boot.img` 里的 `3.10.24-g1fc624e` zImage
  （2016-03-15 构建，gcc 4.7）。它作为二进制资源随 device 仓库上传，
  属于设备树的一部分。
* 树内虽存在 `kernel/nvidia/shield`（3.10.96，LineageOS shieldtablet 分支），
  但 DTB / NCT 配置与本板不是一套，实测自编内核起不来（console 走 ttyS0、
  DTB 里 `linux,initrd-start` 陈旧导致静默挂死），因此**没有采用**。
* 结论：`android_kernel_nvidia_ardbeg` 保持原有 `android-4.4` / `cm11-test` /
  `cm-11.0` / `rel-st8-r2.2` 四个分支不变，**不新建 `cm-14.1`**。
  若将来要切到源码编译，需要单独补齐 ardbeg 的 DTB / defconfig 组合，
  并同步修改 `TARGET_KERNEL_SOURCE`，那是另一项工作。

> 附带影响：4.4.4 内核没有 `CONFIG_SECCOMP_FILTER`，缺 `system_server`、
> `service_manager` 等 7.1 新 sepolicy 类型，也没有 pstore / 新 logd 能力。
> 本树通过 `libselinux_bypass.so`、`libminijail.so` 软失败补丁、`/sepolicy`
> permissive、逐服务 `seclabel` 等方式绕过，详见 `patches/README.md`
> 第十七、十八章。这些都随 device 树分发。

---

## 3. vendor 树依赖（独立仓库）

`android_vendor_nvidia_ardbeg` @ `cm-14.1`，落地 `vendor/nvidia/ardbeg`，
由 `device.mk` 通过 `ardbeg-vendor.mk` → `ardbeg-vendor-blobs.mk` 继承：

* `proprietary/`：原厂 4.4.4 blob（`lib/libnvomx.so`、
  `vendor/lib/libEGL_tegra_impl.so` 等）。最大单文件
  `proprietary/vendor/lib/libglcore.so` 约 20 MiB，远低于 GitHub 单文件
  100 MiB 限制，可直接 push，无需 Git LFS。
* `ardbeg-vendor-blobs.mk`：为 7.1 重写过的 `PRODUCT_COPY_FILES` 清单
  （242 条）。`ardbeg-vendor-blobs.mk.orig-4.4.4` 是原始 4.4.4 清单，
  仅作 diff 留档，**不参与构建**。
* `blobs-blacklist.txt` / `blobs-recovered.txt`：排除与找回记录。注意历史
  注释里曾写「7.1 要求 `createOMXPlugin(bool secure)`，所以排除 4.4 的
  `libstagefrighthw.so`」，这是**误判** —— 当前 CM14.1 `OMXMaster.cpp` 用的是
  无参 `CreateOMXPluginFunc` 加 `dlsym("_ZN7android15createOMXPluginEv")`
  fallback。修正结论见第 6.2 节。
* 来源：原厂线刷包手工提取，早期存在缺文件 / 路径错位，已在本分支修复。

> vendor 与 device 是**两个独立仓库**。`device.mk` 里对 vendor 的引用只有
> 一行 `$(call inherit-product, vendor/nvidia/ardbeg/ardbeg-vendor.mk)`，
> 路径固定，不需要任何展开脚本。

---

## 4. shield-common 为什么并进 device 仓库

`BoardConfig.mk` 只有三处引用它：

```make
BOARD_SEPOLICY_DIRS += \
    device/nvidia/ardbeg/shield-common/sepolicy/common \
    device/nvidia/ardbeg/shield-common/sepolicy/lineage-common \
    device/nvidia/ardbeg/sepolicy
BOARD_SECCOMP_POLICY := device/nvidia/ardbeg/shield-common/seccomp
```

而 GitHub 一个仓库只有一个根目录，无法同时占据 `device/nvidia/ardbeg` 和
`device/nvidia/shield-common`。两个选择：

| 方案 | 代价 |
| :--- | :--- |
| 再挂一个第三方仓库 + 展开脚本 | 多一个仓库、多一步 `cp -a`，且脚本幂等性要自己保证 |
| **把用到的 93 个文件快照进本仓库**（当前方案） | 仓库大 428 KiB，但一次 clone 到位 |

所以只搬了真正被引用的三块：`sepolicy/common`（84 文件）、
`sepolicy/lineage-common`（7 文件）、`seccomp`（2 文件）。官方仓库其余内容
（含 `Android.mk` 里的设备白名单分支）与本板无关，没有一并引入。

---

## 5. 为什么排除 `shieldtablet`

* 对 `device/nvidia/ardbeg` 全树 grep，没有任何 `.mk` / `.sh` / `.rc` 引用
  `device/nvidia/shieldtablet`。
* shield-common 的 `Android.mk` 里
  `ifneq ($(filter $(TARGET_DEVICE), shieldtablet foster loki hawkeye falcon roth jetson),)`
  是一份设备白名单，`ardbeg` **不在其中**，该分支不会为 ardbeg 生效。
* `kernel/nvidia/shield` 是 shieldtablet 的配套内核，同样未使用（见第 2 节）。

所以 `shieldtablet` 只是本地 LineageOS 源码树自带内容，**不属于本次交付**，
合进仓库反而会引入无关代码与许可归属问题。

---

## 6. 编译前必须做的两件事

### 6.1 打 AOSP 补丁

```sh
cd <源码树根>/device/nvidia/ardbeg/patches
./check.sh        # 期望 RC=0
./install.sh      # 把源码级修改打到 frameworks/av、system/core、system/vold 等
./check.sh        # 再跑一次，确认全部已应用
```

补丁按源码路径存放（如
`frameworks/av/services/mediacodec/mediacodec.rc.patch`），
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
`repack/tools/apply_overlay.py` 的 `FILES` 表（文件级重打包）。
**只改一处不算固化。**

---

## 7. 本机构建环境适配

见 `README.md` 第 4.3 节。要点：

* 环境变量与 `PATH` 全部由 `device/nvidia/ardbeg/vendorsetup.sh` 设置，
  它会被 `build/envsetup.sh` 自动 source，**源码树零改动**。
* 唯一的例外是 `prebuilts/misc/linux-x86/bison/bison`：原文件是 32 位 ELF，
  本机没有 `/lib/ld-linux.so.2`，只能替换成包装脚本。该脚本由
  `patches/env-fix/fix-source-tree.sh` 生成，`./uninstall.sh` 或重新
  `repo sync prebuilts/misc` 即可还原。
* jack server 1.3-a8 与本机 JDK 的 TLS 握手失败（服务端日志
  `No available cipher suite for TLS13/TLS12`，客户端是
  `Communication error with Jack server (35)`）。`vendorsetup.sh` 因此导出
  `JACK_SERVER=false` 与 `JACK_REPOSITORY`，让 jack 走无 server 模式
  （直接 `java -jar jacks/jack-3.36.CANDIDATE.jar`）。编译器还是 Jack，
  只是不再需要那个本地 HTTPS 服务。推导过程见 `BoardConfig.mk` 第十五节。
* `vendorsetup.sh` 还导出 `ANDROID_NO_TEST_CHECK=true`。`build/core/main.mk`
  在 eng / userdebug 变体下会把 `droidcore` 挂到 `target-tests host-tests` 上，
  也就是全量 `make` 要顺带编 295 个 `tests` 标签模块；而本树的测试目录被
  backport 了 Android 8+ 的代码（`@AsbSecurityTest` 注解、
  `AccountManagerServiceTestFixtures` 全树没有，`String.join(CharSequence,
  Iterable)` 是 API 26 才有的），上游本来就编不过。这些模块不进 ROM，
  `make otapackage` 也从不编它们，所以直接用上游自带的开关关掉，源码树零改动。

* 同一脚本还处理了 `external/chromium-webview` 的 Git LFS 指针问题
  （`webview.apk` 是 133 字节的 LFS 指针，真实文件 83.6 MiB）。

---

## 8. 宿主侧工具不在本仓库

`repack/`、`dist/`、`make_ota.sh` 等属于工作目录，是把已编译镜像做
**文件级重打包**（`chk.img` → debugfs 写 overlay → `otablocks.py pack` →
`mkzip.py` → `sign_ota.py`）的工具链，不是 AOSP 设备树组成部分，因此未上传。
本仓库 `tools/` 里是与设备树强绑定、需要随树分发的验收脚本：

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

## 9. 已知边界与维护提醒

* **md5 锚定的是产物文件，不是注释。** `verify_six_layers.py` 的 `FILES` 表
  锁的是 12 个产物（`libEGL.so`、`libstagefrighthw.so`、`media_codecs.xml`、
  `lmkd.rc`、`libselinux_bypass.so`、`libminijail.so`、`sf_hwc_off.sh`、
  `zz-ardbeg-firstboot-fix.sh`、`zz-ardbeg-home-watchdog.sh`、
  `ardbeg_default_network.conf`、`zz-persist-log.rc`、`mediacodec.rc`）。
  改 `.mk` / `.md` 的注释不影响校验，但**不要改这些产物文件的字节**。
* 新增文件必须注册三处：`device.mk`（全量编译）、`apply_overlay.py` 的
  `FILES`（文件级重打包）、`mkzip.py`（zip 条目，如 `install/bin/*`）。
  三处缺一，就会出现「补丁应用了但没进 ROM」。
* `PRODUCT_COPY_FILES` 不能覆盖 AOSP 已产出的模块（`system/lib/libEGL.so`
  是典型坑，`build/core` 会静默忽略），这类文件只能靠源码补丁 + overlay。
* 4.4.4 `/sepolicy` 仍缺若干 7.1 新域，logcat 里会有 14 条
  `could not get context`（bootanim / gatekeeperd / mediadrm / bootstat 等），
  属已确认的次要遗留；真机 108 项功能测试未发现功能缺失，未擅自改 ROM。
* 最终交付包基准：`dist/appvideo-1107-2005/cm_ardbeg_tv-ota-eng.dy.zip`。
