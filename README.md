# android_device_nvidia_ardbeg — 分支 `cm-14.1`

NVIDIA Tegra K1 T124 / TN8 P1761，代号 **ardbeg**（商品名 G100）。
本分支是 **LineageOS 14.1 / Android 7.1.2** 的实机编译设备树，
即生成 `cm_ardbeg_tv-ota-eng.dy.zip` 所用的那一棵。

```
Copyright (C) 2026 The Android Open Source Project
Copyright (C) 2026 SebaUbuntu's TWRP device tree generator
SPDX-License-Identifier: Apache-2.0
```

---

## 一、硬件

| 项目 | 规格 |
| :--- | :--- |
| SoC | NVIDIA Tegra K1 T124（4× Cortex-A15 @2.2GHz） |
| GPU | NVIDIA GK20A（Kepler） |
| 内存 / 存储 | 2GB RAM / 32GB eMMC，支持 microSD |
| 屏幕 | 1200 × 1920 |
| 电池 | 10000 mAh |
| 出厂系统 | Android 4.4.2（本移植的内核与 blob 均来自此版本线刷包） |
| 尺寸 | 27.41 × 14.36 × 5.33 cm |

---

## 二、仓库组成

本设备由**两个独立仓库**组成，落地路径各就各位，**不需要任何展开脚本**：

| 仓库 | 落地路径 | 内容 |
| :--- | :--- | :--- |
| `teny-001/android_device_nvidia_ardbeg`（本仓库） | `device/nvidia/ardbeg` | 设备树 + `shield-common/` 快照 + 原厂预编译内核 |
| `teny-001/android_vendor_nvidia_ardbeg` | `vendor/nvidia/ardbeg` | 原厂 4.4.4 预编译 blob（324 文件 / 约 114 MiB） |
| `teny-001/android_kernel_nvidia_ardbeg` | **不使用** | 本 ROM 走预编译内核，见 `DEPENDENCIES.md` 第 2 节 |

用 `repo` 同步时，把 `local_manifest.xml` 放进 `.repo/local_manifests/ardbeg.xml`；
手工 clone 则是：

```sh
git clone -b cm-14.1 https://github.com/teny-001/android_device_nvidia_ardbeg device/nvidia/ardbeg
git clone -b cm-14.1 https://github.com/teny-001/android_vendor_nvidia_ardbeg vendor/nvidia/ardbeg
```

> `shield-common/` 是 LineageOS 官方 `android_device_nvidia_shield-common` 的
> `cm-14.1` 快照，**只挑了本板真正引用的 93 个文件**（sepolicy/common 84 个、
> sepolicy/lineage-common 7 个、seccomp 2 个）。之所以并进本仓库而不是再挂一个
> 第三方仓库，是因为它只有这三处被 `BoardConfig.mk` 引用，单独拉一份代价太大。

---

## 三、目录结构

```
device/nvidia/ardbeg/
├── AndroidProducts.mk          # 产品入口注册（lineage.mk / lineage_tv.mk）
├── BoardConfig.mk              # 板级配置（分区、图形、音频、SELinux、内核路径…）
├── device.mk                   # 产品配置主体（829 行，含全部 blob 与 init 注册）
├── device_atv.mk               # TV 形态的差异项，由 PRODUCT_IS_ATV 分流
├── device_tablet.mk            # 平板形态的差异项
├── lineage.mk                  # 产品 cm_ardbeg（平板）
├── lineage_tv.mk               # 产品 cm_ardbeg_tv（Android TV，最终交付形态）
├── system.prop                 # 系统属性
├── vendorsetup.sh              # lunch 目标 + 本机编译环境（被 envsetup.sh 自动 source）
├── local_manifest.xml          # repo 片段（两个仓库）
├── lineage.dependencies        # roomservice / breakfast 依赖
│
├── prebuilt/
│   ├── kernel                  # 原厂 3.10.24 zImage（7,220,312 字节），非源码
│   └── lib/                    # libstagefrighthw.so、libEGL.so、libselinux_bypass.so …
├── initfiles/                  # 7.1 init rc 与首启 / 守护脚本
├── media/media_codecs.xml      # 7.1 兼容 codec 表
├── overlay/                    # RRO overlay（frameworks / packages / SettingsProvider…）
├── sepolicy/                   # 本板 sepolicy（device 侧）
├── sepolicy_aosp/              # 来自 AOSP 的基础 sepolicy 补充
├── shield-common/              # 并入的 shield-common 快照（sepolicy + seccomp）
├── permissions/ audio/ power/ wifi/ bluetooth/ thermal/ camera/ …
├── tools/                      # 真机验收 / OTA 往返校验 / 六层矩阵 / 刷机块表
│   └── hostbin/                # 宿主工具替身：flex / curl / xmllint（见 4.3）
├── patches/                    # AOSP 源码补丁 + check/install/uninstall + 全量文档
└── DEPENDENCIES.md             # 完整依赖清单
```

---

## 四、编译

### 4.1 环境要求

| 依赖 | 要求 | 说明 |
| :--- | :--- | :--- |
| 源码树 | LineageOS `cm-14.1` | 依赖 `vendor/cm/config/*` 与 `vendor/cm/build/tasks/kernel.mk`，AOSP 原生 7.1 不够 |
| JDK | OpenJDK **8** | 9+ 会在 jack / desugar 阶段报 `Unsupported class file major version` |
| Python | **python2** | 7.1 的 `build/tools/*.py` 全是 python2 语法 |
| 磁盘 | ≥ 120 GiB 空闲 | `out/` 约 60~80 GiB |

### 4.2 步骤

```sh
# 1) 打 AOSP 源码补丁 —— 不打能编译，但编出来的 ROM 开不了机
cd device/nvidia/ardbeg/patches
./check.sh && ./install.sh && ./check.sh

# 2) 初始化构建环境（vendorsetup.sh 会自动被 source）
cd <源码树根>
. build/envsetup.sh

# 3) 选产品并编译
lunch cm_ardbeg_tv-eng        # TV 形态（交付形态）
make -j16                     # 或 mka bacon
```

平板形态调试用 `lunch cm_ardbeg-eng`。两个产品共用 `device.mk`，靠
`PRODUCT_IS_ATV` 分流，`out/target/product/` 天然隔离。

### 4.3 本机构建环境适配

`vendorsetup.sh` 除了注册 lunch 目标，还负责把本机特有的工具链塞进 `PATH`，
**全部改动收敛在设备树内，源码树（`build/`、`prebuilts/`、`external/`）一个字节都不动**：

| 问题 | 处理方式 |
| :--- | :--- |
| 预编译 flex 2.5.39 在 UTF-8 locale 下必崩（`loadlocale.c:130` 断言） | `BoardConfig.mk` 置 `USE_HOST_LEX := yes`，让 build 从 `PATH` 找 flex；`tools/hostbin/flex` 是一个强制 `LC_ALL=C` 的包装脚本 |
| 预编译 bison 是 32 位 ELF，本机无 `/lib/ld-linux.so.2` | 只能替换 `prebuilts/misc/linux-x86/bison/bison`（由 `patches/env-fix/fix-source-tree.sh` 生成包装脚本）—— 这是本项目**唯一**需要碰源码树的地方 |
| 系统无 python2 | 由 `ARDBEG_TOOLCHAIN` 提供 |
| 老预编译 host 工具需要 `libncurses.so.5` / `libtinfo.so.5` | 由 `ARDBEG_COMPAT_LIBS` 补 `LD_LIBRARY_PATH` |
| jack server 1.3-a8 与本机 JDK 的 TLS 握手失败（服务端日志 `No available cipher suite for TLS13/TLS12`） | `vendorsetup.sh` 导出 `JACK_SERVER=false` + `JACK_REPOSITORY`，让 jack 走 **无 server 模式**：直接起 JVM 跑编译器 jar，不监听任何端口。编译器仍是 Jack，desugar 正常，不必退回 javac + dx（dx 只认 class 51，编不了 7.1 的框架代码） |
| `vendor/cm/vendorsetup.sh` 在 source 阶段 `curl` 拉 LineageOS 构建目标列表，本机连不通 `raw.githubusercontent.com` | `. build/envsetup.sh` 会卡约 **2 分钟**且无任何输出。`tools/hostbin/curl` 是一个只拦这一个域名的包装脚本，命中即返回「连不上」，其余参数原样转交 `/usr/bin/curl` |
| 构建到 58% 时 `xmllint` 报「未找到命令」（`build/core/definitions.mk:2614` 用它校验 XML） | 系统没装 libxml2-utils 且装包要 sudo 密码，`tools/hostbin/xmllint` 用 python3 的 ElementTree 顶上：合法静默退出 0，不合法把文件名和解析错误写到 stderr 并退出 1 |
| jack 无 server 模式下每个 Java 模块冷启一个 JVM，默认堆是物理内存的 1/4；同时 `make -jN` 的 N **不会**被 `makeparallel` 传给 ninja（ninja 退回 `nproc+2`），十几个 JVM 并发直接触发内核 OOM killer，日志里只留一行 `已终止` | `vendorsetup.sh` 导出 `JACK_MAIN_COMMAND`（限 `-Xmx3g`）与 `NINJA_ARGS=-j6`。真正的死因只在 `journalctl --user -u <unit>` 里写着 `oom-kill` |
| 手动 `make`（默认目标 `droid_targets`）会把树里所有 `tests` 标签的模块都编一遍，而 LineageOS 14.1 的测试目录被 backport 了 Android 8+ 的代码——`@AsbSecurityTest` 注解、`AccountManagerServiceTestFixtures` 全树没有，`String.join(CharSequence, Iterable)` 是 API 26 才有的，上游本来就编不过 | `vendorsetup.sh` 导出 `ANDROID_NO_TEST_CHECK=true`，用的是 `build/core/main.mk` **自带的官方开关**（`droidcore : target-tests host-tests` 那段有 `ifneq ($(ANDROID_NO_TEST_CHECK),true)` 守卫），源码树一行都不用改。测试模块不进 ROM，`make otapackage` 也从不编它们。要编测试：`ANDROID_NO_TEST_CHECK= make tests` |

三个路径都可用环境变量覆盖，默认值见 `vendorsetup.sh` 第 51~53 行：

```sh
ARDBEG_TOOLCHAIN=/home/dy/ardbeg-tc       # 宿主自编 bison / m4 / python2
ARDBEG_COMPAT_LIBS=/home/dy/tc-libs       # ncurses5 / tinfo5
JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
```

> 换机器编译时，只需要改这三个变量，设备树不用动。

### 4.4 内核

**不编内核源码。** `BoardConfig.mk` 用 `TARGET_PREBUILT_KERNEL` 指向
`prebuilt/kernel`，并把 `TARGET_KERNEL_SOURCE` 故意设成不存在的
`kernel/nvidia/ardbeg__prebuilt_only` —— CM14.1 的 `kernel.mk` 用
`ifeq "$(wildcard $(KERNEL_SRC))" ""` 判断，路径存在就会转去编源码并**忽略**
预编译内核，所以那个名字不是笔误。详见 `DEPENDENCIES.md` 第 2 节。

---

## 五、已固化的主要修复

完整推导在 `patches/README.md`（约 6400 行），这里只做索引。

| 领域 | 结论 |
| :--- | :--- |
| SELinux | **策略降到 v28**。内核 `POLICYDB_VERSION_MAX=28`（xperms 之前），7.1 默认的 v30 一加载就 `rebooting into recovery mode`；`POLICYVERS=28` + 剥离 xperm 语句后策略可完整加载（`policyvers=28`），`libselinux_bypass.so` 只作为标签兜底 |
| 存储 | `init.tegra.rc` 遗留导出 `EMULATED_STORAGE_TARGET`，ART `InitZygote()` 会往 `/storage/emulated` 挂 tmpfs，而 7.1 下那里是 vold 的 fuse 挂载点 → ENOENT → `JNI_CreateJavaVM failed` → zygote 无限重启 |
| init | `setenv` 一行只能一个值；`lmkd` 缺 `lmkd_exec` 域导致 Watchdog 杀 `system_server`；`wifiloader` 缺 `oneshot` 会无限重启 |
| 黑屏 | `KeyguardScrim` 遮挡 + `persist.sys.ui.hw=1` 触发旧 Tegra EGL `EGL_BAD_DISPLAY`；靠 `libEGL.so` 二进制补丁 + `egl_display.cpp.patch` |
| SetupWizard | 四清后 `Unknown package: com.google.android.tungsten.setupwraith` 崩溃 |
| 浏览器「闪退」 | 首启脚本 / 常驻守护的 `launcher_visible()` 恒 false，每 90 秒把用户踢回 HOME；补 `foreground_is_home()` 守卫 |
| 硬件解码 | 三条独立根因：`libstagefrighthw.so` / 7.1 兼容 `media_codecs.xml` / `mediacodec.rc` 的 `group media` |
| WiFi / 蓝牙 | 开机自启、自动连接；7.1 `svc` 无 bluetooth 子命令，需 `service call bluetooth_manager 6` |
| 日志 | `persist_logcat` 落盘 `/cache`；`seclabel u:r:init:s0` 解决 `logcat_exec` 缺域 |
| 内核日志可观测性 | `restorecon_recursive /sys/kernel/debug` 在 debugfs 上必然失败（不支持 `security.*` xattr），**每个文件一行**，一次冷启动 5460 行、占 ramoops 的 88%，把内核 ring buffer 冲得只剩 780 行；去掉后 `dmesg` 恢复可用 |
| 蓝牙 MAC | `init.comms.rc` 重复 `setprop ro.bt.bdaddr_path`（`ro.*` 只能写一次，`system.prop` 已给出同值并先于它生效），每次开机固定报 `property_set failed`；注释掉即可。**本机 FCT 分区为空**（只有 `lost+found`），`bt_mac.txt` 本来就不存在，MAC 拿不到工厂值属数据缺失，非软件问题 |
| WiFi「断网」 | 状态栏 WiFi 带断网标记但实际能上网。`NetworkMonitor.java:293` 的 `mUseHttps` 默认 **1**，强制走 `https://www.google.com/generate_204`，国内不可达 → 即使 HTTP 探测返回 204 也判 `VALIDATION_FAILED`。修法：`settings put global captive_portal_use_https 0` + **WiFi 重连一次**（`mUseHttps` 只在 NetworkMonitor 构造时读）。已固化进 `zz-ardbeg-firstboot-fix.sh` 第 4c 节（写在开 WiFi 之前）与第 10 节（复查 `lastValidated`，必要时重连兜底） |
| 桌面黑屏（壁纸被删） | 按导航栏「最近任务」后桌面只剩时钟和 Dock，背景纯黑，**重启也不恢复**。链条：本机声明了 `android.software.leanback` 却没有 `android.software.picture_in_picture` → `UiModeManagerService` 把 UI 模式判成 `UI_MODE_TYPE_TELEVISION` → `Recents.start()` 选 `RecentsTvImpl`；而 `PipUI.start()` 原先在 `!mSupportPip` 时直接 return，`PipManager.initialize()` 从不执行 → `RecentsTvActivity.onCreate` 取 `getRecentsFocusedPipBounds()` 得 null → NPE（第 321 行）→ 连崩两次后 `Process com.android.systemui has crashed too many times: killing!` → `ImageWallpaper` 与 SystemUI 同进程一起死 → `Reverting to built-in wallpaper!` → `clearWallpaperLocked()` 删掉 `/data/system/users/0/wallpaper`；此后每次开机 `systemReady()` 都因「无源图 → 无裁剪图」再清一次，所以**重启救不回来**。修法见 `patches/frameworks/base/packages/SystemUI/src/com/android/systemui/tv/pip/PipUI.java.patch`（把 `initialize()` 提到 return 之前，PIP 功能仍由 `mSupportPip` 关掉）。已经黑掉的机器要手工补回 `/data/system/users/0/wallpaper`（1920×1280 PNG，`system:system 600`）并把 `wallpaper_info.xml` 的 width/height/crop 改成 1920/1280/0,0,1920,1280，再重启 |

---

## 六、验收工具

`tools/` 下是随设备树分发的真机验收脚本：

| 脚本 | 用途 |
| :--- | :--- |
| `full_function_test.sh` | 108 项真机功能测试 |
| `verify_hwdec.sh` | OMX 组件 / `NvMMLiteOpen` / `EOS detected` 硬解专项 |
| `verify_app_video.sh` | Gallery3d / Jelly HTML5 / 第三方在线 HLS 的 app 级播放 |
| `verify_after_boot.sh` | 冷启动后的运行时证据（属性 / md5 / 抢前台计数） |
| `verify_ota_contents.sh` | zip → `system.new.dat` → raw ext4 → debugfs dump → md5 往返校验 |
| `verify_six_layers.py` | 六层字节一致性矩阵（补丁 / 真源 / 注册 / overlay / 包内 / 真机） |
| `gen_flash_blocks.py` | 把 `system.transfer.list` 展开成 recovery 侧 `dd` 脚本 |

---

## 七、交付基准

最终 OTA：`dist/appvideo-1107-2005/cm_ardbeg_tv-ota-eng.dy.zip`
（在工作目录，不在本仓库内）。`patches/check.sh` 与
`tools/verify_six_layers.py` 中锚定的 md5 均以此为基准。

---

## 八、维护提醒

* **md5 锚定的是二进制与 rc 文件，不是注释。** 六层矩阵与 `EXPECT_MD5` 表锁的是
  `libEGL.so`、`libstagefrighthw.so`、`media_codecs.xml`、`lmkd.rc` 等 12 个
  产物文件；改 `.mk` / `.md` 里的注释不影响校验，但**不要改这些产物文件的字节**。
* 新增文件必须同时注册 `device.mk`（全量编译）与宿主侧
  `repack/tools/apply_overlay.py` 的 `FILES`（文件级重打包）；zip 条目还要注册
  `mkzip.py`。只改一处会出现「补丁应用了但没进 ROM」。
* `PRODUCT_COPY_FILES` 不能覆盖 AOSP 已产出的模块（`system/lib/libEGL.so` 是
  典型坑，`build/core` 会静默忽略），这类文件只能靠源码补丁 + overlay。
* **构建被中断（Ctrl-C / OOM / 超时）后，`out/` 里可能留下写了一半的产物**，ninja 只看时间戳，不会自动重建它们，后续就会出现很难懂的下游报错。本项目实测过一次：`framework-res` 的 `package-export.apk` 被截断，导致 `packages/apps/Bluetooth` 的 aapt 报`No resource found that matches the given name: attr 'android:layout_width'`——连最基本的属性都找不到，说明 `-I` 指向的框架包根本没读进来。遇到这类「不可能缺的资源」报错，先把对应 intermediates 删掉重编，或直接 `make clean`。
* **`make` 和 `make otapackage` 编的不是同一批模块。** 全量 `make` 会走
  `droidcore : target-tests host-tests`，把 295 个 `tests` 标签模块（CTS 各包、
  `external/deqp`、`skia_dm`、`FrameworksCoreTests` …）全编一遍；`otapackage`
  完全不碰它们。本树用 `ANDROID_NO_TEST_CHECK=true` 关掉了这部分，所以「`make`
  能过」现在等价于「ROM 能出」。如果哪天要验证测试模块，先去掉这个变量，
  再准备面对上游那些来自 Android 8+ 的测试代码。
* **`POLICYVERS` 必须是 28，不能跟着上游走 30。** 本机内核停在
  `POLICYDB_VERSION_DEFAULT_TYPE(28)`，v30 策略加载即
  `policydb version 30 does not match my version range 15-28`，随后
  `Security failure; rebooting into recovery mode`。降到 28 后 `checkpolicy`
  拒绝写 xperm 规则，`system/sepolicy/Android.mk` 里那三处 awk 过滤就是干这个的：
  它剥掉 `allowxperm` / `neverallowxperm` / `dontauditxperm`，这些只约束 ioctl
  白名单，permissive 下没有实际约束力。**不要**为了「策略更完整」把它们改回去。
* 设备树注释里保留了本机绝对路径（`/home/dy/...`），是调试留档；换机器编译
  请改 `vendorsetup.sh` 里的三个变量，不要全局替换注释。
* 许可：`shield-common/` 为 Apache-2.0，仅因本板引用而随本仓库分发；
  其余内容为本移植工作产物，`prebuilt/` 与原厂 blob 版权归 NVIDIA 及原厂所有。
