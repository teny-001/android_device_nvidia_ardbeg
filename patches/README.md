# 源码补丁（ardbeg / g100）

这个目录放的是**对 AOSP / LineageOS 源码本身的修改**。设备树自己的改动  
（`device/nvidia/ardbeg/` 下面的文件）不在这里，那些是直接改的。

---

## 当前状态（2026-11-05，cm-14.1）

| 子目录                 | 内容                                                    | 是否参与自动打补丁                             |
| ------------------- | ----------------------------------------------------- | ------------------------------------- |
| `env-fix/`          | 源码树里**非代码类**的环境修复（LFS 大文件、32 位宿主工具）                   | 否，用 `env-fix/fix-source-tree.sh` 单独执行 |
| `audio_policy_abi/` | 音频 HAL 的二进制 ABI 修补                                    | 否，见文末专章                               |
| `tools/`            | **对预编译 .so 的二进制补丁脚本**（hwcomposer / libminijail）+ 验证工具 | 否，逐个手动执行，见各专章                         |
| `legacy-cm11/`      | 上一轮 **cm-11（Android 4.4.4）** 的 19 个源码补丁               | **否**，仅作历史资料保留                        |

`check.sh` / `install.sh` / `uninstall.sh` 只处理**本目录下（不含上述子目录）**  
的 `*.patch`。`legacy-cm11/` 在 `_common.sh` 的 `list_patches()` 里被显式排除，  
原因见那一处注释：那批补丁的上下文是按 4.4.4 的源码写的，在 7.1 上  
18 个冲突、6 个目标文件根本不存在，混在一起会把真正的告警淹没。


### 当前 cm-14.1 补丁清单（截至 2026-11-06）

| 补丁                                                                              | 作用                                                                                                                                      |
| ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `build/core/definitions.mk.patch`                                               | 宿主工具链兼容                                                                                                                                 |
| `build/core/java.mk.patch`                                                      | JDK / javac 参数适配                                                                                                                        |
| `build/core/proguard.flags.patch`                                               | proguard 规则兼容                                                                                                                           |
| `external/icu/.../TimeZoneTest.java.patch`                                      | ICU 单测编译修正                                                                                                                              |
| `packages/apps/CMParts/Android.mk.patch`                                        | CMParts 构建修正                                                                                                                            |
| `system/core/init/init.cpp.patch`                                               | 老内核没有 `checkreqprot`，不再 `security_failure()`                                                                                            |
| `system/core/rootdir/init.rc.patch`                                             | **`symlink /system/lib/egl /egl`，让 4.4.4 的 Tegra GL 库能按相对路径 dlopen**                                                                    |
| `system/core/rootdir/init.rc.patch`（同文件第 2 个 hunk）          | **去掉 `restorecon_recursive /sys/kernel/debug`**。debugfs 不支持 `security.*` xattr，这条命令 100% 失败且逐文件打日志，一次冷启动 5456 行（占 88%），把内核 ring buffer 冲光。去掉不改变任何行为（见 README 第五章「内核日志可观测性」） |
| `system/core/rootdir/init.usb.rc.patch`                                         | **补齐 MTP/PTP 的 legacy 规则 + 把 adb 配置提前到 `on init`，修「USB 没有盘符」**（见下）                                                                      |
| `frameworks/native/opengl/libs/EGL/egl_display.cpp.patch`                       | **去掉 EGL display 的进程级缓存，修应用进程全崩**                                                                                                       |
| `frameworks/native/services/surfaceflinger/surfaceflinger.rc.patch`             | **去掉 `onrestart restart zygote`，把「SF 崩→整机死」降级为「只 SF 自己重启」**                                                                             |
| `frameworks/native/libs/ui/Gralloc1On0Adapter.cpp.patch`                        | **跳过 `Surface::lock` 路径上永不 signal 的 acquire fence，修好 USB 鼠标指针**（见文末「USB 鼠标」专章）                                                          |
| `frameworks/base/packages/SettingsLib/.../SettingsDrawerActivity.java.patch`    | 修系统设置二级菜单闪退                                                                                                                             |
| `frameworks/base/services/core/java/com/android/server/MountService.java.patch` | **public volume（U 盘/SD 卡）无条件给 `MOUNT_FLAG_VISIBLE`，修「U 盘插上识别不了」的最后一层**（见下）                                                              |
| `system/vold/Utils.cpp.patch`                                                   | **`ForkExecvp()` 里 `setexeccon` 失败不再 `abort()`，改降级 WARNING，修 vold 无限重启**（见下）                                                            |
| `system/core/rootdir/init.zygote32.rc.patch`                                    | **给 zygote 挂 `LD_PRELOAD=libselinux_bypass.so`，修 `selinux_android_setcontext failed` → system_server SIGABRT**（见文末「SELinux 旁路」专章，第 1 层） |
| `frameworks/native/cmds/servicemanager/servicemanager.rc.patch`                 | **给 servicemanager 挂同一个垫片，修 `Unknown class service_manager` → `add_service PERMISSION DENIED`**（第 2 层）                                  |
| `frameworks/native/cmds/installd/installd.rc.patch`                             | **给 installd 挂同一个垫片，修它在 `libselinux.so` 里 SIGSEGV、导致 `/data/user_de/0/` 建不出来**（第 3 层）                                                   |
| `frameworks/av/media/audioserver/audioserver.rc.patch`                          | **加 `seclabel u:r:mediaserver:s0`，修 `could not get context while starting 'audioserver'`**（第 4 层）                                       |
| `frameworks/av/camera/cameraserver/cameraserver.rc.patch`                       | **同上，相机服务**（第 4 层）                                                                                                                      |
| `system/vold/vold.rc.patch`                                                     | **给 vold 挂垫片，修 `Failed to setexeccon` → SIGABRT 无限重启 → `/data/user_de/0/` 建不出来**（第 3.5 层，见专章）                                           |
| `frameworks/av/services/mediacodec/mediacodec.rc.patch`                         | **`seclabel u:r:mediaserver:s0`，修 `could not get context while starting 'mediacodec'`**（第 5 层）                                          |
| `frameworks/av/services/mediaextractor/mediaextractor.rc.patch`                 | **同上，媒体容器解析服务**（第 5 层）                                                                                                                  |
| `system/sepolicy/Android.mk.patch`                              | **`POLICYVERS=28` 下剥离 xperm 语句**，否则 `checkpolicy` 报 `policy version 28 does not support ioctl extendedpermissions rules`（见专章） |

> **`system/core/rootdir/init.usb.rc.patch` 的补充说明**
>
> 这个补丁修的是用户报的「usb 没有盘符」。根因有四层，它只负责最外面那层：  
> AOSP 7.1 把 MTP/PTP 全搬到 `init.usb.configfs.rc` 了，自带的 `init.usb.rc`  
> 里一条 mtp/ptp 的 property 触发都没有；而本机内核是 4.4.4 的 NVIDIA gadget，  
> 没有 configfs，只能走 `android_usb` 老接口。
>
> 另外三层分别修在：
>
> - 描述符层 → `initfiles/init.nv_dev_board.usb.rc`（注释掉原厂 6 段，  
>   它写的 `"0x0955"` 会被内核 `sscanf("%04x")` 截成 `0009`）
> - framework 层 → `initfiles/usb_mtp_default.sh`（`UsbDeviceManager` 构造时  
>   会强行删掉 persist 里的 mtp，只能 boot_completed 后走 binder 改回来）
> - binder 层 → 同上（`UsbService` 白名单只认单个功能名，必须传 `"mtp"`）

> **「U 盘插上识别不了」的两个新补丁**
>
> 现象：dmesg 里 `usb-storage` / `sd 0:0:0:0: [sda]` / vfat 全部正常，  
> `mount -t vfat` 手动能挂能读，但系统界面里完全看不到 U 盘。
>
> 这是四层根因里的第 3、4 层，前两层（fstab 控制器号写错、`DiskSource::matches()`  
> 用 `fnmatch()` 必须带 `*`）修在设备树，见 `initfiles/fstab.ardbeg`。
>
> - **`MountService.java.patch`（第 4 层）**  
>   `onVolumeCreated()` 对 `TYPE_PUBLIC` 只在这两种情况给 `MOUNT_FLAG_VISIBLE`：  
>   `mPrimaryStorageUuid == "primary_physical"` 且 `isDefaultPrimary()`，  
>   或者 `disk.isAdoptable()`。本机 `Primary storage UUID: null`、U 盘非 adoptable，  
>   于是 `mountFlags=0`，framework 发 `{6 volume mount public:8_1 0 0}`；  
>   vold 的 `PublicVolume::doMount()` 里  
>   `if (!(getMountFlags() & MountFlags::kVisible)) return OK;` 直接返回，  
>   不 fork `sdcard`、不建 `/storage/<UUID>`。  
>   补丁在 `TYPE_PUBLIC` 分支里无条件 `vol.mountFlags |= VolumeInfo.MOUNT_FLAG_VISIBLE;`。
> - **`Utils.cpp.patch`（第 3 层）**  
>   `ForkExecvp()` 在 `setexeccon` 失败时 `abort()`。本机 SELinux 是 Disabled，  
>   `setexeccon()` 必然失败，于是 vold 每调一次 `blkid`/`sgdisk`/`fsck_msdos`  
>   就 SIGABRT 一次，init 拉起又自杀，无限循环，volume 永远卡在 `CHECKING`。  
>   补丁把两处 `abort()` 都降级成 `LOG(WARNING)` 继续执行。  
>   **在全量编译生效前**，预编译的 vold 用 `LD_PRELOAD` 垫片绕开：  
>   `prebuilt/lib/libsetexeccon_shim.so`（源码 `setexeccon_shim.c` 同目录）
>   - 覆盖 `vold.rc` 加一行 `setenv LD_PRELOAD /system/lib/libsetexeccon_shim.so`。

另有两处**不是 .patch、但同样是对源码/预编译件的修改**，单独放：

| 位置                              | 内容                                                                                                                      |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `tools/patch_hwc.py`            | 二进制修补 4.4.4 原厂 `hwcomposer.tegra.so` 的二次释放（SF 每 16 秒 SIGSEGV 的根因）                                                       |
| `tools/patch_minijail.py`       | 二进制修补 7.1 的 `libminijail.so`，让 seccomp 软失败生效（media 三兄弟崩溃循环）                                                             |
| `tools/patch_binder.py`         | 二进制修补 7.1 的 `libbinder.so`，让 binder 池线程遇错不 abort（SF 的 `*** BAD COMMAND` 自杀）                                             |
| `tools/patch_inputservice.py`   | ~~二进制修补 `libinputservice.so` 的 `SpriteController::doUpdateSprites`~~ **已被 `patch_libui_gralloc.py` 取代，勿用**（它把鼠标指针彻底关掉了） |
| `tools/patch_libui_gralloc.py`  | **二进制修补 `libui.so`，跳过 `Gralloc1On0Adapter::lock` 里永不 signal 的 acquire fence —— 这才是「USB 鼠标不工作」的正解**                      |
| `tools/mouse_helper.sh`         | 设备侧调试脚本：闭环移动指针 / 单击 / 右键 / 滚轮（不受指针加速影响）                                                                                 |
| `tools/egltest6.c`              | 验证 NVIDIA EGL 驱动幂等性的小工具（证明 `egl_display.cpp.patch` 不会卸载驱动）                                                              |
| `tools/patch_libegl.py`         | **二进制补丁 `libEGL.so`（`cbnz→nop`），等价于 `egl_display.cpp.patch`。`out/` 清空、走文件级重打包时必须靠它产出带修复的 .so**                          |
| `tools/libEGL.orig.so`          | 未打补丁的 `libEGL.so` 基准，md5 `3cd50337aeb9aa2220b5007f786cf8bc`（`patch_libegl.py` 的输入 / 回滚基准）                               |
| `../prebuilt/lib/libEGL.so`     | **补丁产物正式落点**，md5 `4ac10584321c81f8dcddd21a025bced6`；`apply_overlay.py` 从这里取文件写进 `system.img`                            |
| `tools/hwc.orig.so`             | 原厂 `hwcomposer.tegra.so` 副本（patch_hwc.py 的输入 / 回滚基准）                                                                    |
| `tools/libminijail.orig.so`     | 原 `libminijail.so` 副本（patch_minijail.py 的输入 / 回滚基准）                                                                     |
| `tools/libbinder.orig.so`       | 原 `libbinder.so` 副本（patch_binder.py 的输入 / 回滚基准）                                                                         |
| `tools/libinputservice.orig.so` | 原 `libinputservice.so` 副本（`patch_inputservice.py` 的输入 / 回滚基准；**现在应该直接用它覆盖回去**）                                          |
| `tools/libui.orig.so`           | 原 `libui.so` 副本（`patch_libui_gralloc.py` 的输入 / 回滚基准）                                                                    |

设备树侧还有几处**配置类**修复，不在本目录（见文末专章）：

| 文件                                                    | 作用                                                           |
| ----------------------------------------------------- | ------------------------------------------------------------ |
| `audio/audio_policy.conf`                             | 删掉 HAL 做不到的 4 个 profile（`audioserver` 崩溃循环 18 次/开机 → 0）      |
| `initfiles/init.tegra.rc`                             | 注释掉 `powerservice`（4.4 守护进程 + 7.1 power HAL，必崩 pc=0，42 次/开机） |
| `initfiles/zz-persist-log.rc`                         | 全程日志落盘 `/cache/persist_log.txt`（4×4MB 轮转）                    |
| `initfiles/zz-bootanim-fix.rc` + `bootanim_killer.sh` | 开机动画看门狗（SF 重启后动画永久盖住桌面）                                      |
| `initfiles/zz-sf-hwc-off.rc` + `sf_hwc_off.sh`        | **关闭 HWC 合成改走 GLES，根治 SF 每 40~100 秒崩溃 + 永久黑屏**               |

除了上面这些，还有三类坑落在别处：

1. **环境/宿主工具**（不是源码问题）
   - `BASH_ENV` 注入的 `rm` 包装函数 → 在 `env.sh` 里 `unset BASH_ENV`
   - flex 硬编码 `/usr/bin/m4` → `export M4=...`
   - 32 位预编译 `bison` 跑不起来 → 换成包装脚本
   - 见 `/home/dy/WorkBuddy AI/ardbeg-cm-14.1/env.sh` 与 `build.sh` 的注释
2. **源码树被解压坏了**（不是源码问题）
   - `external/chromium-webview` 的 LFS 指针 + 目录错位
   - 见 `env-fix/fix-source-tree.sh`
3. **设备树自己的配置错误**（改在 `device/nvidia/ardbeg/` 里）
   - `KERNEL_OBJ/usr` 没有生成规则 → `AndroidBoard.mk` 里补一条空目录规则
   - 设备树自带的残缺 `kernel-headers/` 挡住 bionic uapi → 改名停用
   - 产品/BoardConfig 的 7.1 语法适配（`PRODUCT_MAKEFILES` 不能用 `name:path`）

---

## `frameworks/native/opengl/libs/EGL/egl_display.cpp.patch`

### 一句话

把 `egl_display_t::getDisplay()` 里的 `disp.dpy` 进程级缓存去掉，让**每个线程**  
的 `eglGetDisplay` 都真实透传给 NVIDIA tegra EGL 驱动。

```diff
-    if (cnx->dso && disp.dpy == EGL_NO_DISPLAY) {
+    if (cnx->dso) {
```

### 症状

移植到 7.1 后，`sys.boot_completed=1`、SurfaceFlinger 和 system_server 都在跑，  
但屏幕**全黑**，`screencap` 出来是一张纯黑 1920x1080（固定 10595 字节）。  
所有应用进程稳定崩溃：

```
W/libEGL        : eglInitialize(0x1) failed (EGL_BAD_DISPLAY)
I/OpenGLRenderer: Initialized EGL, version 1.4
W/OpenGLRenderer: Failed to choose config with EGL_SWAP_BEHAVIOR_PRESERVED, retrying without...
F/OpenGLRenderer: Failed to choose config, error = EGL_BAD_DISPLAY
F/DEBUG         : Abort message: 'Failed to choose config, error = EGL_BAD_DISPLAY'
```

### 为什么极具迷惑性

1. `egl_display_t::initialize()` 在驱动初始化失败时**只打 `ALOGW`，不返回 false**  
   （见 `egl_display.cpp` 的 `else { ALOGW("eglInitialize(%p) failed (%s)", ...) }`），  
   所以日志里 `Initialized EGL, version 1.4` 反而出现在失败警告**之后**。
2. SurfaceFlinger 和一个手写的 EGL 冒烟测试**完全正常**  
   （`eglGetDisplay -> 0x1`、`eglInitialize -> 1.4`、`GL_RENDERER = NVIDIA Tegra`），  
   很容易让人以为驱动没问题、问题在应用侧。
3. 两者的差别不在库、不在权限、不在 SELinux，而在**线程模型**：  
   SF 和测试程序都是单线程、全新 exec 的进程。

### 根因

本机用的是 g100 原厂 Android 4.4.4 的 tegra EGL 驱动：

```
/system/lib/egl/libEGL_tegra.so        (9496 B，纯转发垫片)
  └── NvOsLibraryLoad("libEGL_tegra_impl")
        └── /system/vendor/lib/libEGL_tegra_impl.so   (1251392 B，真正的实现)
```

`libEGL_tegra_impl.so` 的导入符号里有 `NvOsTlsGet` / `NvOsTlsAlloc` /  
`NvOsTlsAddTerminator` / `NvOsTlsRemoveTerminator` —— 它把 display 状态放在  
**线程局部存储**里。也就是说：**哪个线程调过 `eglGetDisplay`，那个线程才能  
`eglInitialize`**。

而 `disp.dpy` 是 `egl_display_t::sDisplay[]` 的成员，**全进程共享**：

- 线程 1 调 `eglGetDisplay` → 驱动被真正调用，线程 1 的 TLS 建立，  
  句柄 `0x1` 被缓存进 `disp.dpy`
- 线程 2 调 `eglGetDisplay` → 因为 `disp.dpy != EGL_NO_DISPLAY` **直接跳过**，  
  压根没调到驱动，线程 2 的 TLS 是空的
- 线程 2 调 `eglInitialize(0x1)` → 驱动查不到 display → `EGL_BAD_DISPLAY`

Android 4.4.4 的 hwui 是单线程的（没有 `RenderThread`），所以老 ROM 不会触发。  
7.1 的 `frameworks/base/libs/hwui/renderthread/EglManager.cpp` 在 RenderThread 上  
先 `eglGetDisplay`（第 104 行）再 `eglInitialize`（第 109 行），正好踩中。

### 验证方法

写了 `egltest5`（见 `/home/dy/WorkBuddy AI/ardbeg-cm-14.1/egl-fix/`），8 种模式：

| 模式        | 场景                                            | 补丁前             | 补丁后                                 |
| --------- | --------------------------------------------- | --------------- | ----------------------------------- |
| `plain`   | 单线程直跑                                         | OK              | OK                                  |
| `libgui`  | 先 dlopen libgui.so                            | OK              | OK                                  |
| `preload` | 预加载 libhwui/libGLESv2/libEGL                  | OK              | OK                                  |
| `fork`    | 父进程 getDisplay 后 fork                         | OK              | OK                                  |
| `thread`  | 线程1 getDisplay，线程2 只 initialize               | **BAD_DISPLAY** | BAD_DISPLAY（线程2 没调 getDisplay，符合预期） |
| `threadB` | 两线程各自 getDisplay + initialize（对齐 EglManager）  | **BAD_DISPLAY** | **OK**                              |
| `direct`  | 绕过 loader 直调垫片                                | OK              | OK                                  |
| `direct2` | 线程1 getDisplay，线程2 自己 getDisplay + initialize | OK              | OK                                  |

`direct2` 是决定性对照：它证明只要「每个线程都透传一次 `eglGetDisplay`」，  
驱动就正常工作 —— 而这正是本补丁做的事。

### 实机结果

- `EGL_BAD_DISPLAY` 出现次数：**122 → 0**
- `screencap`：10595 B 纯黑 → 18352 B / 24717 B，**开机动画（青色进度弧）  
  正常由 GPU 渲染出来**
- `boot_completed=1`，`FallbackHome` → `com.cyanogenmod.trebuchet/Launcher` 都起来了

### 已刷 ROM 上的临时验证（二进制补丁）

源码补丁需要重新编译 `libEGL` 才生效。为了在**已刷的 ROM** 上立刻验证，  
另外做了等价的二进制补丁，工具是  
`/home/dy/WorkBuddy AI/ardbeg-cm-14.1/egl-fix/patch_libegl.py`。

反汇编依据（`libEGL.so`，`_ZN7android13egl_display_t10getDisplayEPv @ 0xa378`）：

```
a3c2: 6820        ldr  r0, [r4, #0]     ; r4 = &gEGLImpl, [r4] = cnx->dso
a3c4: b190        cbz  r0, a3ec         ; dso == NULL 就跳过整块
a3c6: 6870        ldr  r0, [r6, #4]     ; r6 = this, [r6+4] = disp.dpy
a3c8: b980        cbnz r0, a3ec         ; <== 改成 nop (00 bf)
a3ca: ...                               ; cnx->egl.eglGetDisplay(display)
a3d6: 6070        str  r0, [r6, #4]     ; disp.dpy = dpy
```

结构体偏移核对（与 `egl_display.h` 一致）：

```
egl_display_t::magic   @ 0x00
egl_display_t::disp    @ 0x04   (DisplayImpl::dpy)
egl_display_t::lock    @ 0x28   (a382 的 add.w r5, r6, #40 印证)
egl_connection_t::dso  @ 0x00
egl_connection_t::egl  @ 0x14   (dso 0, hooks[2] 4/8, major 12, minor 16)
```

补丁后 `md5` 从 `3cd50337aeb9aa2220b5007f786cf8bc`  
变为 `4ac10584321c81f8dcddd21a025bced6`。

> 注意：这本来是**过渡手段**，理想情况是让源码补丁生效、重新编译  
> `libEGL`。但 2026-11-06 集成核查发现 `out/` 已清空、无法单模块编译  
> （`mmm frameworks/native/opengl/libs/EGL` 失败，源码树里连 `out/`  
> 目录都不存在），而后续所有 ROM 都走文件级重打包，于是这份二进制补丁  
> 已经被**正式收编进设备树**：`device/nvidia/ardbeg/prebuilt/lib/libEGL.so`，  
> 由 `repack/tools/apply_overlay.py` 的 FILES 表写进 `system.img`，  
> 并由 `check.sh` 强制校验 md5。详见文末「十一、补丁集成」专章。  
> 恢复全量编译后，可以删掉 prebuilt 副本、只留源码补丁，但两者必须等价。

---

## 目录结构

补丁按**源码树里的路径**存放，末尾加 `.patch` 后缀。例如：

```
patches/
├── README.md
├── _common.sh          # 三个脚本共用的函数，不要直接执行
├── _udiff.py           # 纯 Python 的 unified diff 应用器（没有 patch/git 时兜底）
├── check.sh
├── install.sh
├── uninstall.sh
├── file-modes.txt      # 文件权限修复（diff 表达不了，单独一条通道）
├── env-fix/            # 非代码类环境修复（不参与自动打补丁）
│   └── fix-source-tree.sh
├── legacy-cm11/        # cm-11 时代的 19 个补丁，仅存档
└── frameworks/av/media/libstagefright/AudioSource.cpp.patch
    ↑ 对应源码树里的 frameworks/av/media/libstagefright/AudioSource.cpp
```

也就是说，把补丁路径里的 `patches/` 前缀和 `.patch` 后缀去掉，  
剩下的就是目标文件在源码树里的相对路径。这样一眼就能看出  
"这个补丁改的是哪个文件"，也不需要在脚本里维护一张对照表。

### `file-modes.txt`：为什么权限修复不在 `.patch` 里

unified diff **表达不了文件权限变更**。git diff 里那种  
`old mode 100644 / new mode 100755` 是 git 的扩展，`patch(1)` 直接忽略，  
`_udiff.py` 也不处理。所以权限类修复单独走 `file-modes.txt`：

```
<相对源码树根的路径>  <期望权限>  # 说明
vendor/cm/prebuilt/common/bin/sysinit  0755   # init.cm.rc 里 `service sysinit` 直接 exec 它
```

`check.sh` 会报告当前权限与期望值的差异，`install.sh` 执行 chmod，  
`uninstall.sh` 改回 0644（这棵树从归档解出来时的原始值）。

**为什么需要它**：本工程的 cm-14.1 源码树是从归档解出来的，不是带 mode 的  
git clone，所以**整棵树的可执行位全丢了**（`build/tools` 缺 65 个、  
`external/e2fsprogs/misc` 缺 58 个、`vendor/cm/prebuilt/common/bin` 缺 5 个）。  
绝大多数不影响 —— AOSP 自己编出来的模块走  
`LOCAL_MODULE_CLASS := EXECUTABLES`，权限由 build 系统设。  
只有**用 `PRODUCT_COPY_FILES` 裸拷**进镜像的脚本会中招，因为那条路径是  
`cp -f 源 目标`，权限原样带过去。目前已确认的唯一受害者是  
`system/bin/sysinit`（源码 0664 → 镜像 0664 → init 报  
`cannot execve: Permission denied`，init.d 机制整个失效）。

---

## 补丁格式

必须是 **unified diff**，且 diff 头里的路径带 `a/` `b/` 前缀  
（`git diff` 和 `diff -u` 配合正确参数都能生成），因为脚本统一用 `-p1` 应用。

正确：

```diff
--- a/frameworks/av/media/libstagefright/AudioSource.cpp
+++ b/frameworks/av/media/libstagefright/AudioSource.cpp
@@ -123,7 +123,7 @@
```

**错误**（没有 a/ b/ 前缀，`-p1` 会剥错一层）：

```diff
--- frameworks/av/media/libstagefright/AudioSource.cpp
+++ frameworks/av/media/libstagefright/AudioSource.cpp
```

---

## 怎么生成一个补丁

在源码树根目录下（假设改了 `frameworks/av/foo/bar.cpp`）：

```sh
# 方法一：源码树是 repo 管理的（推荐）
git diff -- frameworks/av/foo/bar.cpp > \
    device/nvidia/ardbeg/patches/frameworks/av/foo/bar.cpp.patch

# 方法二：没有 git，手头只有改前/改后两份文件
mkdir -p device/nvidia/ardbeg/patches/frameworks/av/foo
diff -u --label a/frameworks/av/foo/bar.cpp --label b/frameworks/av/foo/bar.cpp \
     /path/to/bar.cpp.orig frameworks/av/foo/bar.cpp \
     > device/nvidia/ardbeg/patches/frameworks/av/foo/bar.cpp.patch
```

`--label` 那两个参数不能省，作用就是补上 `a/` `b/` 前缀。

---

## 三个脚本

三个脚本都从源码树根目录开始操作，路径自动按  
`device/nvidia/ardbeg/patches/../../../..` 推算；  
也可以用环境变量 `ANDROID_BUILD_TOP` 显式指定。

> `_common.sh` 里放的是三个脚本共用的逻辑（找源码树根、判断补丁状态、  
> 应用/反向应用），**不要单独执行它**。把它和三个脚本放在同一目录即可，  
> 移动脚本时要一起移。

### 打补丁工具的优先级

三个脚本都会自动挑一个可用的工具，顺序是：

| 优先级 | 工具          | 说明                           |
| --- | ----------- | ---------------------------- |
| 1   | `patch(1)`  | 最标准，会留 `.orig` 备份、失败留 `.rej` |
| 2   | `git apply` | 没有 patch 时用                  |
| 3   | `_udiff.py` | 前两个都没有时兜底，纯 Python 实现        |

**为什么需要第 3 条**：本机是 Flatpak 打包的最小环境，`command -v patch git`  
两个都是空，连 `/usr/bin/patch` 都不存在。原来的实现走到 `detect_tool`  
就返回 `none`，三个脚本直接罢工。源码树自带  
`prebuilts/python/linux-x86/2.7.5/bin/python2.7`，系统也有 python3，  
所以补了一条 Python 路线。`_udiff.py` 自己实现了 hunk 定位（±200 行内搜索），  
`check` 模式只读不写，行为和 `patch --dry-run` 对齐。

已实测：`check → install → check → uninstall → check` 全流程通过，  
且 `install` + `uninstall` 之后文件与原始版本**逐字节一致**。

```sh
# 1) 检查：只做 dry-run，不改任何文件
./check.sh

# 2) 安装：把所有补丁打到源码树上（会自动留 .orig 备份）
./install.sh

# 3) 卸载：反向应用，把源码恢复成干净状态
./uninstall.sh
```

常用参数：

| 参数                 | 说明                        |
| ------------------ | ------------------------- |
| `-l` / `--list`    | 只列出补丁和它们的状态，不动文件          |
| `-f` / `--force`   | 遇到冲突也继续处理后面的补丁（默认是遇到冲突就停） |
| `-v` / `--verbose` | 打印每条命令                    |

`check.sh` 会把每个补丁归到四种状态之一：

| 状态    | 含义                | 处理办法                              |
| ----- | ----------------- | --------------------------------- |
| `未应用` | 可以正常打上            | `./install.sh`                    |
| `已应用` | 已经在源码里了           | 不用管，或者 `./uninstall.sh` 撤掉        |
| `冲突`  | 上下文对不上（源码版本变了/改过） | 手工 `patch -p1 --dry-run` 看 `.rej` |
| `缺失`  | 补丁要改的文件在源码树里不存在   | 检查路径写错没有，或者那个仓库没同步                |

---

## 注意

1. **先 `check.sh` 再 `install.sh`**。直接 install 也可以，但 check 能提前看到  
   哪些会冲突，不至于打到一半停下来。
2. 补丁是**顺序应用**的（按路径排序）。如果两个补丁改同一个文件，  
   生成补丁时就要注意先后顺序，否则后一个的上下文会错位。
3. `install.sh` 成功后会在源码树里留下 `*.orig` 备份文件。  
   `uninstall.sh` 反向应用时会用上它们；确认没问题后可以手动删掉。
4. 这些补丁是**可重复应用/撤销**的：`install.sh` 会先判断是否已应用，  
   已应用的会跳过，不会重复打。

---

## 历史补丁清单（cm-11，现已移到 `legacy-cm11/`）

> **注意**：下面这张表和后续每一节讲的都是 **cm-11（Android 4.4.4）** 时代的补丁，  
> 它们已经全部移进 `legacy-cm11/`，**不参与** `check/install/uninstall.sh`，  
> 也**不适用于** cm-14.1 的源码树（上下文对不上）。  
> 保留这段内容是为了记录"当初为什么那么改"，移植 7.1 时很多思路仍然有参考价值  
> ——比如 64 位宿主链路、aapt 的 libpng 版本、v8 的 arm 快照这些坑，  
> 在 7.1 上换了个形式又出现过。

现在有 **18 个**补丁：

| 补丁文件                                                                                  | 目标                                               | 类别                      |
| ------------------------------------------------------------------------------------- | ------------------------------------------------ | ----------------------- |
| `build/core/main.mk.patch`                                                            | `build/core/main.mk`                             | 宿主 64 位链路               |
| `system/core/libutils/Unicode.cpp.patch`                                              | `system/core/libutils/Unicode.cpp`               | 宿主 64 位链路               |
| `external/openssl/Crypto-config.mk.patch`                                             | `external/openssl/Crypto-config.mk`              | 宿主 64 位链路               |
| `libnativehelper/JNIHelp.cpp.patch`                                                   | `libnativehelper/JNIHelp.cpp`                    | 宿主 64 位链路               |
| `frameworks/compile/libbcc/libbcc-host-build.mk.patch`                                | `frameworks/compile/libbcc/libbcc-host-build.mk` | 宿主 64 位链路（32 位 JIT）     |
| `frameworks/rs/Android.mk.patch`                                                      | `frameworks/rs/Android.mk`                       | 宿主 64 位链路（32 位 JIT）     |
| `art/build/Android.common.mk.patch`                                                   | `art/build/Android.common.mk`                    | 宿主编译器版本适配               |
| `frameworks/base/tools/aapt/Images.cpp.patch`                                         | `frameworks/base/tools/aapt/Images.cpp`          | **未定义行为（UB）**           |
| `frameworks/base/tools/aapt/ZipEntry.h.patch`                                         | `frameworks/base/tools/aapt/ZipEntry.h`          | **未定义行为（UB）**           |
| `external/v8/Android.mk.patch`                                                        | `external/v8/Android.mk`                         | **宿主 64 位链路（ARM 模拟器）**  |
| `external/chromium_org/v8/tools/js2c.py.patch`                                        | `external/chromium_org/v8/tools/js2c.py`         | 预编译 python 缺模块          |
| `external/chromium_org/third_party/WebKit/Source/build/scripts/preprocessor.pm.patch` | 同路径 `.pm`                                        | 预处理器路径写死                |
| `system/vold/Android.mk.patch`                                                        | `system/vold/Android.mk`                         | **GCC 4.8 诊断变严**        |
| `external/chromium_org/GypAndroid.linux-arm.mk.patch`                                 | `external/chromium_org/GypAndroid.linux-arm.mk`  | **宿主 64 位链路（-m32 硬编码）** |
| `external/chromium_org/v8/tools/gyp/v8_snapshot.target.linux-arm.mk.patch`            | 同路径 `.mk`                                        | **宿主 64 位链路（放弃预生成快照）**  |
| `external/srec/srec/EventLog/src/EventLogImpl.c.patch`                                | 同路径 `.c`                                         | **并行构建竞态**              |
| `vendor/cm/vendorsetup.sh.patch`                                                      | `vendor/cm/vendorsetup.sh`                       | **构建期联网挂死**             |
| `vendor/nvidia/ardbeg/ardbeg-vendor-blobs.mk.patch`                                   | `vendor/nvidia/ardbeg/ardbeg-vendor-blobs.mk`    | vendor 缺文件              |

> 前 6 个都是「宿主侧按 64 位编译 + 用 GCC 4.8」这条链路上必须的补丁，  
> 原因见下面各自的小节。它们和 g100 的硬件无关，  
> 换成任何一台没有 32 位运行时的机器编 cm-11 都会撞上。
>
> 中间 2 个（aapt）是 **GCC 4.8 优化器利用 UB 做推断**导致的，  
> 只在"用新版编译器编老代码"时才会暴露，是本次 framework-res 编译失败的根因。
>
> `vendor/cm/vendorsetup.sh.patch` 是唯一一个和编译器无关的补丁：  
> 它修的是上游代码里一个**没有超时的 curl**，会让 `source build/envsetup.sh`  
> 永久卡住。换任何网络受限的机器都会撞上。

### `build/core/main.mk.patch`

排除 `sdk/` 子树。原因：`sdk/hierarchyviewer/src/Android.mk` 里  
`LOCAL_MODULE_TAGS := debug`，而 `main.mk` 给 eng 变体设的  
`tags_to_install := debug eng`，所以它会被默认目标拉进来编译；  
但它依赖的 `org-openide-util.jar`、`org-netbeans-api-visual.jar`  
是 Android SDK 里 NetBeans OpenIDE 的产物，AOSP/LineageOS 源码树  
从来没收录过（`prebuilts/sdk/tools/lib/` 下只有 dx.jar、  
shrinkedAndroid.jar、signapk.jar），make 找不到生成规则就 Stop。

`sdk/` 下全是宿主侧 SDK 开发工具（hierarchyviewer、ddms、  
eventanalyzer、dumpeventlog、monitor、emulator…），产物落在  
`out/host/`，不进 `system.img` / `boot.img`，和 ROM 无关。  
用 `filter-out $(TOP)/sdk/%` 精确剔除，不用 `findleaves --prune=sdk`  
（后者按目录名匹配，会误伤 `external/` 下同名的子目录）。

### `system/core/libutils/Unicode.cpp.patch`

补一行 `#include <limits.h>`。`Unicode.cpp` 只 include 了  
`<stddef.h>`，而 `SSIZE_MAX` 不在那里。设备侧（bionic）是靠  
`<netinet/in.h>` → `<sys/types.h>` → `<limits.h>` 间接带进来的，  
所以一直没暴露；宿主侧用的是 glibc 头文件，这条链不带  
`SSIZE_MAX`，于是 host 版 libutils 报  
`'SSIZE_MAX' was not declared in this scope`。

### `external/openssl/Crypto-config.mk.patch`

宿主 64 位时让 openssl 走 `unknown_arch`（纯 C，不带汇编）。两条弯路：

1. 保持原样（`host_arch := x86`）→ 32 位汇编 `aes-586.S` 被交给  
   64 位汇编器，报 `invalid instruction suffix for 'pop'/'push'`。
2. 改成 `host_arch := x86_64` → 撞 `BN_ULONG` 字宽：  
   `opensslconf.h` 是按**目标平台**（32 位 ARM）生成的，  
   里面是 `THIRTY_TWO_BIT`，`BN_ULONG` = `unsigned int`，  
   而 `crypto/bn/asm/x86_64-gcc.c` 是按 64 位 `BN_ULONG` 写的，  
   函数签名直接冲突。

所以宿主只能用纯 C。宿主 libcrypto 只被  
`frameworks/base/tools/obbtool` 用，一次性打包工具，慢一点无所谓。

### `libnativehelper/JNIHelp.cpp.patch`

`jniStrError()` 里把 `strerror_r()` 的返回值 `(int) ret` 直接和 `0` / `-1` 比较。  
在 64 位下这是指针截断：GNU 版 `strerror_r` 返回 `char*`，转 `int` 会报

```
libnativehelper/JNIHelp.cpp:297:34: error:
    cast from 'char*' to 'int' loses precision [-fpermissive]
```

改成先存 `intptr_t retv = (intptr_t) ret;` 再比较，三种 `strerror_r` 语义  
（GNU 返回 `char*`、XSI 返回 `int`、以及 `_GNU_SOURCE` 未定义时的老 bionic）  
行为都保持不变。

### `frameworks/compile/libbcc/libbcc-host-build.mk.patch` + `frameworks/rs/Android.mk.patch`

**这两个补丁修的是同一件事：宿主 libbcc 的 ELF 加载器是纯 32 位设计。**

`frameworks/compile/libbcc/lib/ExecutionEngine/` 和  
`frameworks/rs/cpu_ref/linkloader/` 是同一套代码的两个拷贝，作用是  
"把 32 位 ARM ELF 目标码映射进当前进程再执行"（JIT 加载器）。  
里面直接把宿主指针塞进 `Elf32_Addr`（32 位），再从 `Elf32_Addr` 强转回指针：

```c
section_header_table[i].sh_addr =
    reinterpret_cast<llvm::ELF::Elf32_Addr>(section->getBuffer());  // 指针 -> uint32
...
sym->setAddress((void *)S);   // uint32 -> 指针
```

64 位宿主上指针是 8 字节，这两步都会截断，GCC 报：

```
ELFObjectLoaderImpl.cpp:94:73: error: cast from 'unsigned char*' to
    llvm::ELF::Elf32_Addr {aka unsigned int} loses precision [-fpermissive]
ELFObject.hxx:384/438/488/526/537/563/605: error:
    cast to pointer from integer of different size [-Werror=int-to-pointer-cast]
```

要真修得把 `ELFObject` / `ELFSection` / `ELFSymbol` 整套模板从写死 32 位  
改成 `ELFW` 宽度自适应 —— 几百行结构性改造，而且改完也没人受益。

#### 为什么可以只放宽诊断

| 用途                            | 实际用的工具                                     | 是否碰 ExecutionEngine               |
| ----------------------------- | ------------------------------------------ | --------------------------------- |
| RenderScript 源码 `.rs` → `.bc` | `llvm-rs-cc`（`config.mk:339` `LLVM_RS_CC`） | 否，和 libbcc 无关                     |
| `.bc` → `.o` 兼容层编译            | `bcc_compat`（`config.mk:340` `BCC_COMPAT`） | 否，走 `RSCompilerDriver::compile()` |
| 宿主 `bcc -f` 执行模式              | 宿主 `bcc`                                   | 是，但 ROM 构建流程从不调用                  |

所以被截断的指针在构建期不会被执行到。**若将来真要用宿主 JIT，  
必须回来做 ELFW 改造，不能指望这段代码。**

#### 为什么必须 `-Wno-error`（而不是 `-Wno-error=permissive`）

两个坑：

1. **`-fpermissive` 只对 C++ 有效**。`libbccSupport` 里有纯 C 文件  
   `lib/Support/sha1.c`，放进 `LOCAL_CFLAGS` 会报  
   `cc1: error: command line option '-fpermissive' is valid for C++/ObjC++ but not for C`。  
   所以要用 `LOCAL_CPPFLAGS`（`binary.mk:733` 只塞给 C++ 编译）。
2. **`-Wno-error=permissive` 这个选项名不存在**。`permerror()` 不是通过  
   `-W<name>` 注册的常规警告，只受 `-fpermissive` 控制，写了会报  
   `cc1plus: error: -Werror=permissive: no option -Wpermissive`。  
   而 `-fpermissive` 只是把它降级成 pedwarn，紧接着又被 `-Werror` 提回错误。  
   所以只能写不带参数的 `-Wno-error`，把这两个模块的 `-Werror` 整体取消。

代价：这两个宿主模块的其它警告不再中断编译。可以接受 ——  
它们只是打包工具，不是要上机的代码。

### `art/build/Android.common.mk.patch`

`-Wthread-safety` 这个警告选项**只在 GCC 4.6 存在**，4.7 起被上游删除。  
原文件无条件往 `ART_HOST_CFLAGS` 里加，用 GCC 4.8 编宿主 ART 时报

```
g++: error: unrecognized command line option '-Wthread-safety'
```

补丁改成先用 `$(HOST_CC) -dumpversion` 探版本，只有确实是 `4.6` / `4.6.x`  
时才加这个选项。用 4.8 时该警告本来就不存在，跳过没有任何损失。

### `frameworks/base/tools/aapt/Images.cpp.patch` + `ZipEntry.h.patch`

**这两个补丁修的是同一类问题：有符号整型左移溢出（未定义行为 UB）。**

原代码模式：

```c
png_uint_32 color = p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24);
```

`p` 的元素类型是 `png_byte`（`unsigned char`）。参与运算时先做整型提升，  
变成 **signed int**。当 `p[3] == 0xFF` 时，`p[3] << 24` 即 `255 << 24`，  
结果是 `0xFF000000`，超出 `int` 的正数范围 → 标准里是未定义行为。

GCC 4.7 起会**利用这个 UB 做推断**：既然左移结果必须能装进 `int`，  
那么被移位的值必然 `< 128`，于是编译器认定结果的**第 31 位恒为 0**，  
把 `color == 0xFF000000`、`color == 0xFF0000FF` 这类比较直接折叠成恒假。

#### 症状

framework-res 资源编译整体失败，日志里是：

```
ERROR: 9-patch image .../btn_default_disabled_focused_holo_dark.9.png malformed.
       Ticks in transparent frame must be black or red.
       Found at pixel #9 along bottom edge.
```

**664 条** 这种 9-patch 报错，外加 **169 条**  
`Public symbol drawable/xxx declared here is not defined.`  
（资源没进去，`public.xml` 里的符号自然找不到）。

#### 定位过程

单文件 A/B 对比（同一张 PNG，只换 aapt 二进制）：

| aapt                                      | 结果     |
| ----------------------------------------- | ------ |
| `prebuilts/sdk/tools/linux/bin/aapt`（预编译） | 正常，无报错 |
| `out/host/linux-x86/bin/aapt`（现编）         | 报错     |

在 `tick_type()` 里加 `fprintf` 打印入参，拿到决定性证据：

```
[DBG9] tick_type COLOR-ERR ff0000ff     ← 连续 8 次
```

`ff0000ff` 就是纯红 `(255,0,0,255)`，而 `0xFF0000FF` 正是  
`COLOR_LAYOUT_BOUNDS_TICK` 的值 —— **本该命中却未命中**，掉进了  
"非法颜色"的兜底分支。

再看这张图的实际像素：底边第 1~~8 像素是纯红（layout bounds 刻度），  
第 9 像素是全透明。`tick_type` 在 1~~8 处把 `*outError` 设成了  
"Ticks in transparent frame must be black or red"（注意这条错误是**非致命**的，  
函数仍然返回 `TICK_TYPE_TICK`），等到第 9 像素返回 `TICK_TYPE_NONE` 时，  
`get_horizontal_ticks()` 看到 `*outError != NULL` 就走了错误分支，  
于是报 "Found at pixel #9"。

黑色刻度之所以侥幸没崩：黑色 `(0,0,0,255)` 虽然同样匹配不上 `COLOR_TICK`，  
但它 `p[0]|p[1]|p[2]` 全为 0，走到了函数末尾的兜底 `return TICK_TYPE_TICK`，  
把同一个 UB 掩盖住了。

#### 修复

每个字节先显式转成 `png_uint_32` / `unsigned long` 再移位，全程无符号运算：

```c
png_uint_32 color = ((png_uint_32) p[0])
                  | ((png_uint_32) p[1] << 8)
                  | ((png_uint_32) p[2] << 16)
                  | ((png_uint_32) p[3] << 24);
```

`ZipEntry.h` 的 `getLongLE()` 是同一个模式，一并修：

```c
return ((unsigned long) buf[0])
     | (((unsigned long) buf[1]) << 8)
     | (((unsigned long) buf[2]) << 16)
     | (((unsigned long) buf[3]) << 24);
```

它读的是 ZIP 条目的 `CRC32`、`mCompressedSize`、`mUncompressedSize`、  
`mCentralDirOffset`。CRC32 最高位为 1 的概率约 50%，属于**必然踩中**；  
超过 16MB 的条目也会踩中。只有签名类调用（高字节恒为 0x02/0x04/0x06）  
侥幸无事，所以之前一直没暴露。

`Images.cpp` 的 `get_color()`（9-patch 各 patch 的颜色值）和  
`write_png()` 的调色板颜色计算 `(rr << 24) | (gg << 16) | (bb << 8) | aa`  
也是同一类问题，一起改了。

#### 验证

- 单文件 `aapt c` 不再报错
- 完整构建日志里 `malformed` 从 664 条降到 **0**，  
  `Public symbol` 从 169 条降到 **0**

### `external/chromium_org/v8/tools/js2c.py.patch`

源码树自带的预编译 python  
（`prebuilts/python/linux-x86/2.7.5/bin/python2.7`）的 `lib-dynload`  
里**没有 `_bz2.so`**，而 `js2c.py` 第 36 行无条件 `import bz2`，  
于是 V8 的代码生成直接失败：

```
Traceback (most recent call last):
  File "../../tools/js2c.py", line 36, in <module>
    import bz2
ImportError: No module named bz2
make: *** [.../obj/GYP/shared_intermediates/libraries.cc] Error 1
make: *** [.../obj/GYP/shared_intermediates/experimental-libraries.cc] Error 1
```

`bz2` 在 `js2c.py` 里只有一个用处：

```python
if env['COMPRESSION'] == 'bz2':
    all_sources = bz2.compress("".join(all_sources))
```

而 `COMPRESSION` 来自 gyp 变量 `v8_compress_startup_data`，  
`external/chromium_org/v8/build/features.gypi:32` 的默认值是 **`'off'`**，  
AOSP 的 `GypAndroid` 也没有覆盖它 —— 也就是说 `bz2.compress()` 在 ROM 构建里  
从来不会被调用。

所以补丁把导入改成 `try/except ImportError`（失败置 `None`），  
并在真的走到 bz2 分支时给出可读报错。行为不变，也不掩盖真实问题。

> 另外补丁在文件第 2 行加了 `# -*- coding: utf-8 -*-`。  
> Python 2 默认按 ASCII 解析源码，注释里的中文会直接报  
> `SyntaxError: Non-ASCII character`，PEP 263 规定的编码声明必须在  
> 第 1 或第 2 行，所以放在 shebang 下面。

### `.../WebKit/Source/build/scripts/preprocessor.pm.patch`

Blink 生成 IDL 绑定时要先用 C 预处理器展开 `.idl` 里的 `#if`。命令行里的  
预处理器路径是**写死**的，来自  
`third_party/WebKit/Source/build/scripts/scripts.gypi:60`：

```python
'preprocessor': '--preprocessor "/usr/bin/gcc -E -P -x c++"'
```

gyp 把这个字符串固化进了已提交的生成文件  
`third_party/WebKit/Source/bindings/bindings_sources.target.linux-arm.mk`  
（同一个字符串在里面出现上百次）。本机没有 `/usr/bin/gcc`，于是：

```
Can't exec "/usr/bin/gcc": 没有那个文件或目录 at .../IPC/Open3.pm line 178.
open2: exec of /usr/bin/gcc -E -P -x c++ .../CSSRule.idl failed
make: *** [.../bindings/V8CSSRule.cpp] Error 2
```

补丁在 `applyPreprocessor()` 里加了一段回退：如果预处理器路径是绝对路径  
但**不可执行**，就按 `$ENV{CC}` → `PATH` 里的 `gcc`/`cc`/`clang` 顺序找一个替代。

> 两个细节：
>
> 1. **不改生成出来的 `.mk`**。那三个 `.mk` 是 gyp 产物，字符串出现上百次，  
>    补丁会非常庞大且难审阅；而且重新跑 gyp 就被覆盖。改在唯一的执行点  
>    `preprocessor.pm` 只需一处，对所有调用方都生效。
> 2. **候选路径不能含空格**。下面用的是 `open2(..., split(' ', $preprocessor), ...)`，  
>    整个命令行按空格切词，路径里有空格会被切成两段，报  
>    `Can't exec "/home/dy/WorkBuddy": 没有那个文件或目录`。  
>    所以构建脚本的 PATH 里把无空格的 `/home/dy/tc-wb/hostbin`（指向同一套  
>    GCC 4.8）排在 `$WT/toolchain/hostbin` 之前，补丁里也显式跳过含空格的目录。

### `ardbeg-vendor-blobs.mk.patch`

`android_vendor_nvidia_ardbeg` 的 cm-11 分支只提交了 **313** 个文件，  
但 `ardbeg-vendor-blobs.mk` 引用了 **345** 个，差 **35** 个。

cm-11 的 `build/core/Makefile` 会为每一条 `PRODUCT_COPY_FILES` 生成一条  
`copy-one-file` 规则；源文件不存在时 make 直接报

```
No rule to make target 'vendor/nvidia/ardbeg/proprietary/lib/libcublas.so',
needed by 'out/target/product/ardbeg/system/lib/libcublas.so'
```

编译就在这一步中断。所以补丁把这 35 条从清单里删掉，并在文件顶部  
加了一段注释说明每一条属于哪类功能、缺了会怎样。

> 这些文件是 vendor 仓库本身没收进去，不是路径写错——  
> 在 `proprietary/` 全树 `find` 过，一个都找不到。  
> 想恢复某个功能就从原厂线刷包重新提取，放进对应目录，再把那行加回清单。

### `external/v8/Android.mk.patch`

cm-11 树里有**两份完全不同的 v8**：

| 路径                         | 谁在用                   |
| -------------------------- | --------------------- |
| `external/v8`              | 遗留版本，只给 `d8`（dex 工具）用 |
| `external/chromium_org/v8` | WebView 用的 Blink 那一套  |

两份都有「先跑一个宿主程序 `mksnapshot` 生成快照，再把快照编进目标库」的流程。  
`external/v8` 的 `mksnapshot` 编译不过：

```
external/v8/src/globals.h:120:2: error: #error Target architecture arm is only
    supported on arm and ia32 host
make: *** [.../mksnapshot.arm_intermediates/...] Error 1
```

根因是 `mksnapshot.arm` 虽然是**宿主可执行文件**（`LOCAL_IS_HOST_MODULE := true`），  
但它带 `-DV8_TARGET_ARCH_ARM` 并把 `simulator-arm.cc` 编进去 —— 它靠 V8 的  
ARM 模拟器在宿主上跑出 ARM 快照。而 V8 3.x 在 `globals.h:118-121` 里有一条硬性检查：

```c
#if V8_TARGET_ARCH_ARM && !(V8_HOST_ARCH_IA32 || V8_HOST_ARCH_ARM)
#error Target architecture arm is only supported on arm and ia32 host
#endif
```

本机是 x86_64，直接撞上。

**没有改 `globals.h` 去掉那个 `#error`**。那个 `#error` 说的是事实：  
`simulator-arm.cc` 里大量依赖 32 位指针宽度假设，硬编出来也许能跑，  
但产出的快照可能有错，而且只在设备上表现为 v8 随机崩溃 —— 这种 bug 极难查。

补丁改成关掉快照生成：

```make
ifeq ($(BUILD_HOST_64bit),1)
    ENABLE_V8_SNAPSHOT = false
else
    ENABLE_V8_SNAPSHOT = true
    include $(BASE_PATH)/Android.mksnapshot.mk
endif
```

依据是 `Android.libv8.mk:73-75` 本来就有 else 分支：

```make
ifeq ($(ENABLE_V8_SNAPSHOT),true)
    LOCAL_SRC_FILES += $(intermediates)/snapshot.cc
else
    LOCAL_SRC_FILES += src/snapshot-empty.cc
endif
```

`snapshot-empty.cc` 把 `Snapshot::data_/size_/raw_data_/...` 全部定义成 0，  
v8 启动时现场初始化堆。功能和有快照完全一致，只是启动慢几十毫秒。

### `system/vold/Android.mk.patch`

GCC 4.8 比 4.4/4.6 更积极地报「缺少声明」类诊断，而 AOSP 4.4 的 vold 从来没清理过，  
再叠加 vold 自己开的 `-Werror`，就成了硬错误：

```
system/vold/Volume.cpp:153:7: error: no previous declaration for
    'char* getFsType(const char*)' [-Werror=missing-declarations]
system/vold/main.cpp:45:16: error: no previous declaration for
    'int vold_main()' [-Werror=missing-declarations]
system/vold/cryptfs.c:737:6: error: no previous prototype for
    'convert_key_to_hex_ascii' [-Werror=missing-prototypes]
```

补丁把这两个诊断关掉。**关键在于两个选项必须分开放**：

```make
common_cflags    += -Wno-missing-declarations    # C 和 C++ 都认
common_conlyflags := -Wno-missing-prototypes     # 只对 C 有效
```

然后 4 个模块（`libvold`、`vold`、`libminivold`、`minivold`）各加一行：

```make
LOCAL_CONLYFLAGS := $(common_conlyflags)
```

> 为什么不能都塞进 `common_cflags`：`-Wno-missing-prototypes` **只对 C 有效**。  
> 放进 `common_cflags` 会同时出现在 C++ 编译命令行上，而 GCC 4.8 对  
> 「选项不适用于当前语言」这件事本身也报诊断，再被 `-Werror` 一提：
>
> ```
> cc1plus: error: command line option '-Wno-missing-prototypes'
>     is valid for C/ObjC but not for C++ [-Werror]
> ```
>
> 这里很不对称：`-Wmissing-prototypes` 在 C++ 下只是 warning 不提升，  
> 而 `-Wno-missing-prototypes` 反而被提升成 error。
>
> 另外实测确认 `-Wno-missing-declarations` **压不住** C 里的 `-Wmissing-prototypes`  
> —— 是两个独立选项。
>
> `LOCAL_CONLYFLAGS` 走的是 `binary.mk:731` → `PRIVATE_CONLYFLAGS`，  
> 由 `definitions.mk:987` 只在编译 `.c/.s` 时拼进命令行，所以 C++ 编译看不到它。
>
> 顺便说明为什么不用 `-fpermissive`：那个只对 C++ 有效，而且  
> `-Wno-error=permissive` 这个选项名根本不存在。

### `external/chromium_org/GypAndroid.linux-arm.mk.patch` + `v8_snapshot.target.linux-arm.mk.patch`

这是第二份 v8（WebView 用的那份）的同款问题，但踩的坑不一样 ——  
**这里的 `-m32` 不在 `Android.mk` 里，而在签入仓库的 gyp 生成文件里**。

报错：

```
/home/dy/tc-host/bin/../x86_64-linux/bin/ld: error:
  .../v8_tools_gyp_mksnapshot_arm_host_gyp_intermediates/v8/src/mksnapshot.o:
  incompatible target
crt1.o(.text+0x20): error: undefined reference to 'main'
make: *** [.../mksnapshot.arm] Error 1
```

> `undefined reference to 'main'` 是个假线索：真正的原因是**链接器根本没认出那个 `.o`**  
> —— `mksnapshot.o` 是 `ELFCLASS32/EM_386`，64 位 ld 直接跳过它，  
> 于是找不到入口点。看到「`incompatible target` + `undefined reference to 'main'`」  
> 这组合，第一反应应该是「这个 .o 架构不对」，而不是「源文件缺 main」。

`-m32` 的来源是 `v8/tools/gyp/mksnapshot.arm.host.linux-arm.mk` 里的  
`MY_CFLAGS_*` 变量（gyp 生成时就把 `-m32` 写死了）。  
全树 `grep '^\s*-m32' *.linux-arm.mk` 一共命中 6 个文件：

```
third_party/icu/icuuc.host.linux-arm.mk
third_party/icu/icudata.host.linux-arm.mk
third_party/icu/icui18n.host.linux-arm.mk
v8_base.arm.host.linux-arm.mk
v8_nosnapshot.arm.host.linux-arm.mk
mksnapshot.arm.host.linux-arm.mk
```

分析依赖后确认：**只有 `v8_snapshot.target.linux-arm.mk` 依赖 `mksnapshot.arm`**，  
其余 5 个静态库只是 mksnapshot 的依赖。所以只要切断这一条依赖链，  
6 个文件一个都不用改。

两个补丁配合：

**1) `GypAndroid.linux-arm.mk`** —— 不再 include mksnapshot 模块：

```make
ifeq ($(BUILD_HOST_64bit),1)
  # 跳过 mksnapshot.arm.host.linux-arm.mk
else
  include $(LOCAL_PATH)/v8/tools/gyp/mksnapshot.arm.host.linux-arm.mk
endif
```

**2) `v8_snapshot.target.linux-arm.mk`** —— 去掉依赖，recipe 换成复制空快照：

```make
GYP_TARGET_DEPENDENCIES := \
	$(call intermediates-dir-for,GYP,v8_tools_gyp_js2c_host_gyp,true)/js2c.stamp \
	$(call intermediates-dir-for,GYP,v8_tools_gyp_generate_trig_table_host_gyp,true)/generate_trig_table.stamp

$(gyp_intermediate_dir)/snapshot.cc: $(LOCAL_PATH)/v8/src/snapshot-empty.cc $(GYP_TARGET_DEPENDENCIES)
	@echo "Gyp action: v8_snapshot -> 使用空快照 snapshot-empty.cc（64 位宿主无 32 位运行时）"
	$(hide)mkdir -p $(gyp_intermediate_dir); cp $(LOCAL_PATH)/v8/src/snapshot-empty.cc $@
```

可以直接覆盖 `snapshot.cc` 是因为 `LOCAL_GENERATED_SOURCES` 里引用的就是这个路径，  
它只需要是一个「定义了那些 `Snapshot` 静态成员」的编译单元，文件名无所谓。

> **为什么不重跑 gyp 生成 64 位版本**：`*.target.linux-arm.mk` 这些文件是  
> **签入仓库的预生成产物**，构建流程不会重新生成它们；就算手工重跑 gyp，  
> gyp 本身也是按 `target_arch=arm` 的配置生成，`-m32` 照样会出现。
>
> **踩过的坑**：改完补丁后必须先跑一遍 `scan_stale_elf.py` 清理陈旧目标文件。  
> 这套构建中途把宿主从 32 位切到 64 位，切换**之前**编出来的 477 个 `.o`  
> 是 32 位的，而源文件没变、make 认为它们还是新的，不会重编 ——  
> 于是同一个 `incompatible target` 会以完全一样的报错再复现一次，  
> 看起来像「补丁没生效」。第 16 次编译就栽在这上面，删掉 428 个陈旧文件后才通。

### `vendor/cm/vendorsetup.sh.patch`

这是唯一一个和编译器完全无关的补丁，修的是**构建期联网挂死**。

`build/envsetup.sh:2179` 会无条件 `source vendor/cm/vendorsetup.sh`，而后者第一行是：

```sh
for combo in $(curl -s https://raw.githubusercontent.com/LineageOS/hudson/master/cm-build-targets | sed -e 's/#.*$//' | grep cm-11.0 | awk '{print $1}')
```

`curl` **没有超时**。`raw.githubusercontent.com` 连不上时（本机就是这样），  
这个 curl 会一直挂着，表现是：

```
$ source build/envsetup.sh
（光标停住，几分钟没有任何输出，logs/ 下一个新文件都不生成）
```

很容易误判成「make 卡住了」或「编译脚本有问题」。

补丁做了三件事：

1. **加超时**：`--connect-timeout 5 --max-time 20`
2. **加缓存**：拉到结果存到 `${TMPDIR:-/tmp}/cm-build-targets.cache`，  
   24 小时内复用（用 `find -mmin +1440` 判断新鲜度）
3. **加开关**：设了 `CM_SKIP_TARGETS_FETCH=1` 就完全跳过网络请求

`build-rom.sh` 和 `mk.sh` 里都 `export CM_SKIP_TARGETS_FETCH=1`，  
所以现在整个构建**完全可离线复现**。

> 这个列表只是用来给 `lunch` 补全菜单添加快捷项的（`add_lunch_combo`），  
> 跳过它不影响任何编译行为 —— 我们本来就显式 `lunch ardbeg-eng`。

### `external/srec/srec/EventLog/src/EventLogImpl.c.patch`

**并行构建竞态**。`make -j16` 编 `external/srec` 的语音识别语法文件时报：

```
ESR_IDENTIFIER_COLLISION
ESR_IDENTIFIER_COLLISION in external/srec/srec/Session/src/SR_Session.c:40
Error: SR_SessionCreate(external/srec/config/en.us/baseline11k.par) ESR_IDENTIFIER_COLLISION
make: *** [.../grammars/phone_type_choice.g2g] Error 19
make: *** [.../grammars/VoiceDialer.g2g] Error 19
```

单线程跑三个语法文件全部成功，并行跑 3 个挂 2 个 —— 典型的竞态。

追到 `EventLogImpl.c` 的 `SR_EventLogCreate()`：

1. `baseline11k.par:32` 里 `cmdline.DataCaptureDirectory = logs`，  
   所以日志目录是**相对当前工作目录**的 `logs/`（构建时就是源码树根）。
2. 目录名用 `gettimeofday` 的 **`tv_sec`（秒级精度）** 拼出来：  
   `logs/<epoch 秒>/SWIevent-<epoch 秒>.log`。
3. `external/srec/config/en.us/Android.mk` 里 `VoiceDialer` / `boolean` /  
   `phone_type_choice` 是三条独立规则，`make -j` 会并行启动三个 `grxmlcompile`。  
   它们在同一秒启动 → 第二个 `mkdir` 撞同一个路径。
4. 关键在于**两处 mkdir 的容错不一致**：
   ```c
   /* 创建 logs/ 本身：容忍"已存在" */
   rc = pf_make_dir (impl->logFilename);
   if (rc != ESR_SUCCESS && rc != ESR_IDENTIFIER_COLLISION) { ... goto CLEANUP; }

   /* 创建 logs/<秒>/：不容忍，碰撞即致命 */
   rc = pf_make_dir (impl->logFilename);
   if (rc != ESR_SUCCESS) { ... goto CLEANUP; }
   ```
   上游在这里留了注释说"1 秒精度下目录已存在基本意味着有 bug"，  
   他们没想到的场景是**并行构建**。

补丁把 `timeStr` 改成 `"<epoch 秒>_<pid>"`，同时把 `TIMESTAMP_LENGTH`  
从 18 调到 40（10 位秒 + `_` + 7 位 pid + `\0` = 19 字节，18 会溢出）。

> **为什么加 pid，而不是把碰撞也容忍掉**：如果只容忍碰撞，两个进程会共用  
> 同一个 `logs/<秒>/` 目录，然后都用 `pfopen(..., "w")`（截断模式）打开  
> 同一个 `SWIevent-<秒>.log`，日志互相覆盖。加 pid 后每个进程一个独立目录，  
> 既不碰撞也不互相覆盖，还保留了"每次运行一份日志"的原语义。
>
> `#else`（非 ANDROID）分支有一模一样的秒级精度问题，但**故意不改**：  
> 它在 `_WIN32` 宿主下也会被编译，而 Windows 上 `getpid()` 叫 `_getpid()`  
> 且需要 `<process.h>`。本次构建走的是 ANDROID 分支，那个分支是死代码。

验证方法（并行跑三个，看是否都 rc=0 且 `.PCLG.txt` 齐全）：

```sh
G=out/target/product/ardbeg/system/usr/srec/config/en.us/grammars
for n in boolean phone_type_choice VoiceDialer; do
    ( out/host/linux-x86/bin/grxmlcompile \
        -par external/srec/config/en.us/baseline11k.par \
        -grxml external/srec/config/en.us/grammars/$n.grxml \
        -outdir $G > /tmp/gx_$n.log 2>&1; echo "$n rc=$?" ) &
done; wait
ls $G/*.PCLG.txt
```

修之前：`rc=0 / rc=19 / rc=19`，缺 2 个 `.PCLG.txt`。  
修之后：三个都 `rc=0`，3 个 `.PCLG.txt` 齐全。

> 副作用：源码树根下会多出 `logs/<秒>_<pid>/` 目录，里面是 `grxmlcompile`  
> 的调试日志。这是 srec 工具本来的行为（以前也有，只是名字不带 pid），  
> 可以随时删掉，不影响任何产物。

---

## 设备树内部的改动（不在这个目录）

为让 ardbeg 跑起来做的其余改动，全部落在设备树内部，没有动 CM11 源码：

| #  | 问题                                                                                                          | 解决办法                                                     | 位置                                               |
| -- | ----------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ------------------------------------------------ |
| 1  | `audio.ardbeg.xml` 是小米平板1 的 WM8994+TFA9890 控件，g100 是 Realtek RT5639，一个都对不上 → 路由全空转                          | 按 RT5639 真实控件名整份重写                                       | `audio/audio.ardbeg.xml`                         |
| 2  | `audio_config.c` 只能按数字指定声卡；且名字匹配失败会返回 -EINVAL，导致**整份 XML 停止解析**（`parse_mixer_start` 失败后 device/stream 永不放行） | 新增按名字解析 + 失败回退默认 card，不中断解析                              | `configmgr/audio_config.c`                       |
| 3  | 预编译内核模式下 `KERNEL_OBJ/usr/include` 不生成，`sound/compress*.h` 缺失，音频栈编不过                                         | 建 `kernel-headers/`（`TARGET_DEVICE_KERNEL_HEADERS` 自动识别） | `kernel-headers/`                                |
| 4  | `TARGET_PREBUILT_KERNEL` 被 `kernel.mk` 的 `$(wildcard $(KERNEL_SRC))` 架空，实际会去编源码然后失败                         | 预编译模式下把 `TARGET_KERNEL_SOURCE` 指到不存在的路径                  | `BoardConfig.mk`                                 |
| 5  | 没有开机日志落盘，进不了系统就取不到现场                                                                                        | 新增 logcat + dmesg/mixer 快照到 `/cache`                     | `initfiles/init.tegra.rc`、`initfiles/bootlog.sh` |
| 6  | `persist.sys.usb.config=mtp` 覆盖 `mtp,adb`，adbd 不启动                                                          | 改 `system.prop` + `on boot` 兜底                           | `system.prop`、`initfiles/init.tegra.rc`          |
| 7  | `rm_ts_service` 在 `init.ray_touch.rc` 和 `init.tegra.rc` 重复定义                                                | 注释掉不生效的那份                                                | `initfiles/init.ray_touch.rc`                    |
| 8  | `/mnt/tmp` 被重复挂载，第二条必报 EBUSY                                                                                | 注释掉 `init.t124.rc` 里那份                                   | `initfiles/init.t124.rc`                         |
| 9  | `libaudiospdif` 在 4.4.4 不存在                                                                                 | 从 PRODUCT_PACKAGES 删掉                                    | `device.mk`                                      |
| 10 | `power.ardbe.rc` 拼写错（少个 g）                                                                                  | 改成 `power.ardbeg.rc`                                     | `device.mk`                                      |
| 11 | `ueventd.ardbeg_sata.rc` 没有模块定义                                                                             | 补上 BUILD_PREBUILT                                        | `initfiles/Android.mk`                           |
| 12 | `bootlog.sh` 需要装进 system.img                                                                                | 新增 EXECUTABLES 模块 + 加入 PRODUCT_PACKAGES                  | `initfiles/Android.mk`、`device.mk`               |
| 13 | `external/tinyhal` 在 4.4.4 不存在                                                                              | include 指向设备树自带的头                                        | `audio/Android.mk`、`configmgr/Android.mk`        |
| 14 | `PRODUCT_MAKEFILES` 指向不存在的 `device_ardbeg.mk`                                                               | 改为 `lineage.mk`                                          | `AndroidProducts.mk`                             |

如果后面发现必须改 CM11 源码（比如 AudioFlinger 的行为、audiopolicy 的解析逻辑），  
按上面的格式放进来就行，脚本会自动带上。

---

## 二进制补丁：`audio_policy_abi/`（修好「音频 HAL 加载不起来」）

这一项**不是**文本 diff，所以没走上面的 `.patch` 机制，单独放一个子目录。

### 症状

- 能开机、界面正常，但**整机一点声音都没有**
- `dumpsys media.audio_policy` 里 `Output devices: 00000000`
- logcat 里只有孤零零一条，前后什么音频日志都没有：
  ```
  W/AudioPolicyManagerBase: could not open HW module primary
  ```
- `audio.primary.tegra.so` 没有被映射进 mediaserver 的地址空间  
  （`grep audio /proc/<mediaserver>/maps` 只看得到 `audio_policy.tegra.so`）

### 根因

`system/lib/hw/audio_policy.tegra.so` 是**厂商预编译 blob**  
（`vendor/nvidia/ardbeg/proprietary/lib/hw/audio_policy.tegra.so`，83516 字节，  
里面是 NVIDIA 的 `NvAudioPolicyManager`），它是按 **Android 4.3** 的  
`hardware/libhardware/include/hardware/audio_policy.h` 编译的。

而 CM11 是 **4.4.4**，`struct audio_policy_service_ops` 把 `invalidate_input`  
这个成员删掉了：

| 索引     | 4.3（blob 编译时）         | 4.4.4（CM11 实际）        |
| ------ | --------------------- | --------------------- |
| 8      | set_stream_output     | set_stream_output     |
| **9**  | **invalidate_input**  | **set_parameters**    |
| 10     | set_parameters        | get_parameters        |
| 11     | get_parameters        | start_tone            |
| 12     | start_tone            | stop_tone             |
| 13     | stop_tone             | set_voice_volume      |
| 14     | set_voice_volume      | move_effects          |
| **15** | move_effects          | **load_hw_module**    |
| **16** | **load_hw_module**    | open_output_on_module |
| 17     | open_output_on_module | open_input_on_module  |
| 18     | open_input_on_module  | （不存在）                 |

**从第 9 项开始，所有函数指针整体前移一格（4 字节）。**

于是 blob 调 `load_hw_module`（偏移 64）实际打到 `aps_open_output_on_module`，  
传进去的「模块句柄」其实是字符串 `"primary"` 的指针，  
`AudioFlinger::findSuitableHwDev_l()` 在 `mAudioHwDevs` 里查不到这个句柄，  
**静默返回 0** —— 所以既没有 HAL 加载日志、也没有报错，  
只有一句 `could not open HW module primary`。

反汇编证据（`AudioPolicyCompatClient::loadHwModule`）：

```asm
10548: b508   push {r3, lr}
1054a: 6843   ldr  r3, [r0, #4]    ; r3 = this->mServiceOps
1054c: 6880   ldr  r0, [r0, #8]    ; r0 = this->mService
1054e: 6c1a   ldr  r2, [r3, #64]   ; ← 偏移 64，4.4.4 里那是 open_output_on_module
10550: 4790   blx  r2
```

### 修法

`audio_policy_abi/patch_audio_policy.py` 把 blob 里 `AudioPolicyCompatClient`  
那 10 处读 ops 表的偏移整体减 4，并把 4.4.4 里没有的 `invalidateInput`  
改成直接返回错误。

| 函数              | 原偏移 | 改后 | 打到 CM11 的                 |
| --------------- | --- | -- | ------------------------- |
| loadHwModule    | 64  | 60 | aps_load_hw_module        |
| openOutput      | 68  | 64 | aps_open_output_on_module |
| openInput       | 72  | 68 | aps_open_input_on_module  |
| moveEffects     | 60  | 56 | aps_move_effects          |
| setParameters   | 40  | 36 | aps_set_parameters        |
| getParameters   | 44  | 40 | aps_get_parameters        |
| startTone       | 48  | 44 | aps_start_tone            |
| stopTone        | 52  | 48 | aps_stop_tone             |
| setVoiceVolume  | 56  | 52 | aps_set_voice_volume      |
| invalidateInput | 36  | —  | 停用（直接返回 1）                |

改的是 Thumb 16 位定长 `LDR (immediate)` 指令的 `imm5` 字段，每处只动 2 字节，  
不改长度、不改地址、不动重定位；改之前逐条校验原机器码，不一致就拒绝修改。

- 原始 blob md5：`c4b51bf2e7381986b3782ef1c8f4a25a`
- 补丁后 md5：`8ed729dd0b5ea11b9464b2973df3d1dc`
- 逐字节差异只有 **15 个字节**

```sh
./audio_policy_abi/check.sh      # 0=已打补丁 1=未打 2=版本不认识
./audio_policy_abi/install.sh    # 打补丁（自动备份 .orig，幂等）
./audio_policy_abi/uninstall.sh  # 还原厂商原始 blob
```

### 实测效果

打补丁后重启 mediaserver：

```
I/AudioFlinger: loadHwModule() Loaded primary audio interface from TinyHAL (audio) handle 1
I/AudioFlinger: loadHwModule() Loaded a2dp audio interface from A2DP Audio HW HAL (audio) handle 3
I/AudioFlinger: loadHwModule() Loaded usb audio interface from USB audio HW HAL (audio) handle 4
W/tiny_hal_config: Sound card name "tegra-snd-rt5639" not found ... fall back to default card 0
```

```
$ dumpsys media.audio_policy | grep devices
 Output devices: 00000403      ← EARPIECE|SPEAKER|AUX_DIGITAL，不再是 00000000
 Input devices:  00000104
```

播放时：

```
$ cat /proc/asound/card0/pcm3p/sub0/status
state: RUNNING                ← HDA 卡上的 HDMI PCM，S16_LE 2ch 48000
```

### 长期正解（需要能全量编译时再做，**与上面的二进制补丁二选一**）

不要改 blob，而是让 CM11 的头文件迁就它：

1. `hardware/libhardware/include/hardware/audio_policy.h`  
   在 `struct audio_policy_service_ops` 的 `set_stream_output` 之后、  
   `set_parameters` 之前**加回**一个成员：
   ```c
   /* 【ardbeg 补丁】厂商预编译的 audio_policy.tegra.so 是按 Android 4.3
    * 的头文件编译的，那里有 invalidate_input；4.4 把它删了，导致从这一项
    * 开始后面所有函数指针整体前移 4 字节，load_hw_module 会错位到
    * open_output_on_module 上。加回来把布局对齐到 4.3，才能继续用这个 blob。 */
   status_t (*invalidate_input)(void *service, audio_io_handle_t input);
   ```
2. `frameworks/av/services/audioflinger/AudioPolicyService.cpp`  
   在 `aps_ops` 初始化列表的 `set_stream_output` 之后补一项  
   `invalidate_input : aps_invalidate_input,`，并加一个安全桩  
   （4.4 的 AudioFlinger 没有对应接口）：
   ```c
   static status_t aps_invalidate_input(void *service, audio_io_handle_t input)
   {
       return INVALID_OPERATION;
   }
   ```
3. 然后**必须**把 blob 还原成厂商原始版本（`./audio_policy_abi/uninstall.sh`），  
   否则会双重错位。

两条路只能选一条。现在设备上跑的是**二进制补丁**这条路（已实测出声）。

---

# 二进制补丁 + rc 补丁：`hwcomposer.tegra.so` 堆越界 与 SurfaceFlinger 崩溃放大链

> 这一章记录的是 2026-11-05 那一轮排查。它是整个 cm-14.1 移植里**最像  
> "玄学"的一段**：现象是"系统能开机、能进桌面，然后 30~90 秒后整机变砖、  
> 无限重启"，而 logcat 里给出的死因（`DeadSystemException`）跟真正的  
> 凶手（厂商 HWC HAL 的堆越界）隔了三层。

## 一句话

两个独立问题叠在一起：

1. **根因**：4.4.4 原厂 `hwcomposer.tegra.so` 把 `hwc_layer_1_t` 当成 4.4 的  
   布局来写，而 7.1 的结构体**少了 `buffer` 字段、也没有 `planeAlpha`**，  
   导致 HAL 越界写堆。SurfaceFlinger 因此每 16 秒 SIGSEGV 一次。  
   → 用 `tools/patch_hwc.py` 做二进制修补。
2. **放大器**：`frameworks/native/services/surfaceflinger/surfaceflinger.rc`  
   里有一行 `onrestart restart zygote`。SF 一崩，init 顺手把 zygote 也重启，  
   于是 `system_server` 被 SIGKILL，整个 Android 框架跟着塌。  
   → 用 `surfaceflinger.rc.patch` 删掉这一行。

只修第 1 条，SF 仍然会偶发崩溃（屏幕会黑一下、应用要重建）；  
只修第 2 条，SF 崩了不会拖死整机，但仍然每 16 秒黑屏。  
**两条都修**，设备才能稳定停在桌面。

---

## 症状

### 表层现象

```
sys.boot_completed = 1
mCurrentFocus = com.cyanogenmod.trebuchet/com.android.launcher3.Launcher
        ← 到这里一切正常，能看见桌面
（30~90 秒后）
dmesg: init: Service 'surfaceflinger' (pid 224) killed by signal 11
dmesg: init: Service 'zygote' (pid 231) killed by signal 9
dmesg: init: Starting service 'zygote'...
（无限循环）
```

### 两种 SF 崩溃签名

有厂商符号时（`debuggerd` 能解出 `hwcomposer.tegra.so` 的符号）：

```
#00 libutils.so            android::RefBase::decStrong(void const*) const+37
#01 hwcomposer.tegra.so    android::sp<android::GraphicBuffer>::operator=(GraphicBuffer*)+22
#02 hwcomposer.tegra.so    destroy_graphic_buffer+8
#03 hwcomposer.tegra.so    (无符号)
#04 hwcomposer.tegra.so    glc_set+250
#05 hwcomposer.tegra.so    hwc_composite_set+252
#06 hwcomposer.tegra.so    hwc_set+xx
#07 libsurfaceflinger.so   (SF 调 HWC set())
#12 libutils.so            android::Looper::pollInner(int)+496
```

堆已经被写烂之后，崩溃点会飘到完全无关的地方（因为 `je_malloc` 的  
tcache 元数据被踩了）：

```
#00 libc.so   pthread_mutex_lock+1        fault addr 0x8
#01 libc.so   je_tcache_bin_flush_large+132
#03 libc.so   je_malloc+762
#04 libutils.so android::SharedBuffer::alloc+24
#07 libui.so  android::Region::rasterizer::operator()
```

第二种签名极具误导性 —— 看起来像 `Region` 或 `SharedBuffer` 的 bug，  
实际上是前面某次越界写把 jemalloc 的空闲链表踩坏了。

---

## 为什么极具迷惑性

### 1. `system_server` 的死因是一行没有堆栈的日志

```
FATAL EXCEPTION IN SYSTEM PROCESS: main
java.lang.RuntimeException: android.os.DeadSystemException
```

**没有堆栈**。这不是日志丢了，是设计如此：

```java
// frameworks/base/core/java/android/util/Log.java:410
// DeadSystemException 被特判，只打一行说明，不打堆栈
```

来源是 `RemoteException.java:53`：

```java
public RuntimeException rethrowAsRuntimeException() {
    throw new RuntimeException(new DeadSystemException());
}
```

也就是说 `system_server` 只是**受害者**：它调某个系统服务时发现对方已经死了  
（binder 返回 `DEAD_OBJECT`），于是抛异常自杀。真正的凶手在更下面。

### 2. 重启循环里每一环看起来都"合理"

完整链条：

```
SF SIGSEGV
  → init 重启 SF
  → surfaceflinger.rc 的 onrestart restart zygote 触发
  → init 重启 zygote，**同时杀掉 zygote 的整个进程组**（system_server 在里面）
  → system_server 收到 SIGKILL
  → zygote 的 SigChldHandler 发现 system_server 没了，自己也退出
  → init 拉起新 zygote + 新 system_server
  → servicemanager 里还留着旧 system_server 注册的服务 handle
  → 新 system_server 一启动就去取这些 handle，拿到 DEAD_OBJECT
  → DeadSystemException 秒退
  → 无限循环
```

每一环单独看都是 Android 的正常行为，串起来才是灾难。

### 3. 我们自己的 EGL 补丁是"放大器"，不是根因

`egl_display.cpp.patch` 去掉 `egl_display_t::getDisplay()` 的进程级缓存后，  
SF 的 GPU 合成路径跑得比原来频繁得多。而 `destroy_graphic_buffer` 的越界  
只在"合成配置发生变化"时才走到，于是崩溃频率从"偶发"变成"每 16 秒必炸"。

**排查时一度以为 EGL 补丁是凶手**。对照实验推翻了它：

| 实验                                       | 结果                                      |
| ---------------------------------------- | --------------------------------------- |
| 换回原厂 `libEGL.so`，跑 150 秒                 | SF **0 崩溃** → 说明 EGL 补丁确实放大了问题          |
| `tools/egltest6` 连续调 4 次 `eglGetDisplay` | 每次都返回 `0x1`，`err=0x3000` → 驱动**完全幂等**   |
| `egltest6` 查 `/proc/self/maps`           | `libEGL_tegra_impl.so` 始终在，没被 `dlclose` |

结论：EGL 补丁逻辑是对的，它只是让原本"偶发"的 HAL bug 变得"必然"。  
**不要为了压崩溃而回退 EGL 补丁** —— 那个补丁修的是"应用进程全崩"，  
回退它等于用一个更严重的问题换一个更轻的问题。

---

## 根因一：`hwc_layer_1_t` 的布局在两代之间变了

### 结构体对比

**4.4.4**（厂商 HAL 编译时用的）：

```c
typedef struct hwc_layer_1 {
    int32_t compositionType;
    int32_t hints;
    uint32_t flags;
    buffer_handle_t handle;          /* 4 字节 */
    struct private_handle_t *buffer; /* ← 4.4 有独立 buffer 字段 */
    uint32_t transform;
    int32_t  blending;
    int32_t  planeAlpha;             /* ← 4.4 有 planeAlpha */
    hwc_rect_t      sourceCrop;
    hwc_rect_t      displayFrame;
    hwc_region_t    visibleRegionScreen;
    int acquireFenceFd;
    int releaseFenceFd;
} hwc_layer_1_t;
```

**7.1**（`hardware/libhardware/include/hardware/hwcomposer.h:40`）：

```c
typedef struct hwc_layer_1 {
    int32_t compositionType;
    int32_t hints;
    uint32_t flags;
    union {
        buffer_handle_t handle;
        const native_handle_t *sidebandStream;   /* ← 7.0 起和 handle 共用 union */
    };
    uint32_t transform;
    int32_t  blending;
    union {
        hwc_rect_t      sourceCropi;             /* ← 7.0 起是 union */
        hwc_rect_float_t sourceCropf;
    };
    hwc_rect_t      displayFrame;
    hwc_region_t    visibleRegionScreen;
    int acquireFenceFd;
    int releaseFenceFd;
} hwc_layer_1_t;
```

### 差在哪

| 字段             | 4.4.4 偏移 | 7.1 偏移 | 差异             |
| -------------- | -------- | ------ | -------------- |
| `handle`       | 12       | 12     | 一致             |
| `buffer`       | 16       | —      | **7.1 没有这个字段** |
| `transform`    | 20       | 16     | 前移 4           |
| `blending`     | 24       | 20     | 前移 4           |
| `planeAlpha`   | 28       | —      | **7.1 没有这个字段** |
| `sourceCrop`   | 32       | 24     | **前移 8**       |
| `displayFrame` | 48       | 40     | 前移 8           |

HAL 按 4.4 的偏移去写 `sourceCrop`（偏移 32），在 7.1 里那块内存对应的是  
`displayFrame` 的后半部分 + `visibleRegionScreen` 的前半部分。  
于是 SF 拿到一个**完全错乱的可见区域**，`Region::rasterizer` 按它算出一堆  
越界矩形；同时 HAL 自己写的 `buffer` 字段落在 7.1 的 `transform` 上，  
把 `transform` 踩成一个非法值。

### 为什么 4.4 上不炸

4.4 的 SF 释放 `GraphicBuffer` 的时机比 7.1 晚（`GraphicBuffer` 的生命周期  
管理在两代之间改过）。HAL 把一个**它自己没加过引用**的裸指针塞进 `sp<>`，  
在 4.4 上那个对象那时候还活着，所以 `decStrong` 不会踩空；到了 7.1，  
SF 提前释放，HAL 手里的 `sp<>` 变成悬空指针。

---

## 根因二：`destroy_graphic_buffer` 的二次释放

反汇编 4.4.4 原厂 `hwcomposer.tegra.so`（`tools/hwc.orig.so`）：

```
10194:  b510        push  {r4, lr}
10196:  4604        mov   r4, r0
10198:  b160        cbz   r0, 101b4        ; if (!p) return;
1019a:  2100        movs  r1, #0
1019c:  f7ff ffb6   bl    1010c <sp<GraphicBuffer>::operator=(GraphicBuffer*)>
101a0:  6800        ldr   r0, [r4, #0]
101a2:  b108        cbz   r0, 101aa
101a4:  4621        mov   r1, r4
101a6:  f7ff ff..   blx   RefBase::decStrong(void const*)
101aa:  ...         （tail call）
```

`*p = NULL` 这一句会走到 `sp::operator=` 内部，对**旧指针**做 `decStrong`。  
如果旧指针已经死了：

```
decStrong:
  ldr  r2, [r1, #12]      ; r1 = mBase，mBase->mRefs->mStrong ...
```

`mBase` 是 NULL 时 `[r1+12]` 正好是 `0xc` —— 和崩溃日志里的  
`fault addr 0xc` 完全对上。

### 修法

把 4 字节的 `bl sp::operator=` 换成 `str r1, [r4, #0]` + `nop`：

```
1019a:  2100        movs  r1, #0
1019c:  6021        str   r1, [r4, #0]   ; 直接清 m_ptr，不碰旧对象
1019e:  bf00        nop
101a0:  6800        ldr   r0, [r4, #0]   ; 读到 0
101a2:  b108        cbz   r0, 101aa      ; 跳过 decStrong
```

**代价**：如果那一刻指针还活着，就少减一次引用（那个 `GraphicBuffer` 泄漏一次）。  
实测这条路径只在合成配置变化时走，不是每帧，泄漏量可以接受；  
而且崩溃的前提恰恰就是"指针已死"，那种情况下跳过 `decStrong` 不丢任何东西。

### 用法

```sh
# 检查当前状态（不改文件）
python3 tools/patch_hwc.py --check hwc.orig.so

# 生成打过补丁的副本
python3 tools/patch_hwc.py --apply hwc.orig.so -o hwc.patched.so

# 回滚
python3 tools/patch_hwc.py --restore hwc.patched.so -o hwc.orig.so
```

脚本自带 ELF32 `PT_LOAD` 解析（`vaddr_to_off()`），并且会在动手前校验  
目标位置**前面 8 个字节的上下文**（`push {r4,lr} / mov r4,r0 / cbz r0 /
movs r1,#0`），位置不对就拒绝操作。改完还会回读校验。

**字节序注意**：`objdump` 打印的是 Thumb halfword 的**值**（如 `0xb510`），  
文件里是小端存放（`10 b5`）。脚本里所有常量都用文件字节序，  
第一次写的时候踩过这个坑，上下文校验报"期望 `b5104604b1602100`，  
实际 `10b5044660b10021`"。

实测：上下文匹配 ✓，md5 `d1ddeb57692b7ebf1a060cd37136325c`  
→ `5544622e26e92a180c67f15007609dde`，  
反汇编确认 `1019c: str r1, [r4, #0]` / `1019e: nop`，  
后续 `101a0: ldr r0, [r4, #0]` 读到 0 即跳过 `decStrong`。

---

## 放大器：`surfaceflinger.rc` 的 `onrestart restart zygote`

### 原始文件（只有 6 行）

```
service surfaceflinger /system/bin/surfaceflinger
    class core
    user system
    group graphics drmrpc readproc
    onrestart restart zygote
    writepid /dev/stune/foreground/tasks
```

### 这一行的来历

Android 4.x 时代，SF 崩溃通常意味着"显示子系统挂了"，重启 zygote 是  
一种"反正也救不回来，不如整体重来"的粗暴恢复策略。在 Nexus 设备上  
SF 几乎不崩，所以这行基本是死代码。

但在 ardbeg 上，SF 会因为 HAL 的堆越界**周期性**崩溃。于是这一行把  
"SF 自己重启（用户看到黑一下）"放大成"整个 Android 框架重启（无限循环）"。

### 修法

```diff
 service surfaceflinger /system/bin/surfaceflinger
     class core
     user system
     group graphics drmrpc readproc
-    onrestart restart zygote
+    # onrestart restart zygote    # ← 见上方说明，已禁用
     writepid /dev/stune/foreground/tasks
```

补丁在 `frameworks/native/services/surfaceflinger/surfaceflinger.rc.patch`，  
文件头部插了 71 行中文注释说明根因链（原文件只有 6 行，注释比代码长得多，  
这是刻意的：后来人看到 `onrestart` 被注释掉，第一反应一定是"谁手贱改的"）。

> **生成补丁时的坑**：手写 hunk 头时把 `@@ -1,6 +1,48 @@` 写错了  
> （实际插入 71 行，正确是 `@@ -1,6 +1,77 @@`），`check.sh` 报 `[冲突]`。  
> 正确做法是用 `diff -u` 生成，别手算行数。

---

## 连带修复：开机动画永久盖住桌面

SF 被 init 重启后，新 SF 的 `onFirstRef()` 会再走一遍 `startBootAnimation()`：

```cpp
property_set("service.bootanim.exit", "0");
property_set("ctl.start", "bootanim");
```

而 `WindowManagerService` 的 `mBootAnimationStopped` 是**一次性标志**，  
开机那次已经置位，不会再调 `performEnableScreen()` 把 `exit` 设回 1。  
结果 bootanimation 被重新拉起后永远不退出。

表现：`mCurrentFocus` 明明是 Launcher，截图却是黑的/白的 —— 因为动画层  
一直盖在最上面。

修法在设备树（不在 patches 里）：  
`initfiles/zz-bootanim-fix.rc` + `initfiles/bootanim_killer.sh`，  
`sys.boot_completed=1` 之后每 5 秒把 `service.bootanim.exit` 拉回 1。

---

## 验证：修复前后对照

| 指标                   | 修复前    | 修复后                                     |
| -------------------- | ------ | --------------------------------------- |
| SF 崩溃频率              | 每 16 秒 | 偶发（118 秒一次）                             |
| zygote 重启次数          | 无限循环   | **1 次**                                 |
| `system_server`      | 必死     | **原实例 pid 1491 全程存活**                   |
| SF 崩溃后果              | 整机变砖   | 仅 SF 自己重启（pid 224 → 4399）               |
| `EGL_BAD_DISPLAY`    | 大量     | **0**                                   |
| `sys.boot_completed` | 反复归零   | **稳定为 1**                               |
| `mCurrentFocus`      | 无      | `com.cyanogenmod.trebuchet/...Launcher` |

设备侧最终状态：

```
boot_completed=1
surfaceflinger = 4399（224 崩后自己重启）
system_server  = 1491（原始实例，从未死过）
zygote 启动次数 = 1
EGL_BAD_DISPLAY = 0
init.svc.bootanim_killer = running
init.svc.persist_logcat  = running
/cache/persist_log.txt   = 1.69 MB 且在增长
```

### 怎么在设备上快速复查

```sh
# SF 崩溃
dmesg | grep surfaceflinger | grep 'killed by signal'
# zygote 重启次数（正常应为 1）
dmesg | grep 'Starting service' | grep zygote | wc -l
# EGL 错误
logcat -b all -d | grep -c EGL_BAD_DISPLAY
# 崩溃计数
logcat -b crash -d | grep 'name: surfaceflinger' | wc -l
```

---

## 长期正解（需要能全量编译时再做，**与二进制补丁二选一**）

不要改 blob，而是在 SF 和 HAL 之间加一层**布局适配**。两条路：

### 路 A：改 HAL 头文件，让 7.1 的结构体迁就 blob

在 `hardware/libhardware/include/hardware/hwcomposer.h` 里给  
`hwc_layer_1_t` 加回 `buffer` 和 `planeAlpha` 两个字段（放在 4.4 的位置），  
并取消 `sourceCrop` 的 union。这样整个 AOSP 的 HWC 调用方都会按 4.4 布局  
传递，blob 不用改。

**风险**：`hwc_layer_1_t` 是 `hwc_display_contents_1_t` 的一部分，  
`frameworks/native/services/surfaceflinger/DisplayHardware/HWC2On1Adapter.cpp`  
和所有 HWC2 兼容层都会受影响；而且 7.1 的 `sidebandStream` union 语义会丢。  
**这条路改动面大，不推荐。**

### 路 B：写一个 `hwcomposer.ardbeg.so` 中间层

用 7.1 的头文件编译一个 shim，内部 `dlopen` 原厂 blob，在  
`set()` 里做结构体逐字段翻译（7.1 `hwc_layer_1_t` → 4.4 布局的临时数组），  
调用完再翻译回来。

**优点**：AOSP 侧零改动，blob 零改动，越界写被彻底消灭。  
**代价**：`set()` 是每帧调用的热路径，多一层 memcpy 在 Tegra K1 上有成本；  
需要能编出 `hwcomposer.ardbeg.so` 并让它和 `hw_get_module()` 的命名对上  
（`/system/vendor/lib/hw/hwcomposer.ardbeg.so`）。

> **路径更正**：本机的厂商 HAL 全部装在 `/system/vendor/lib/hw/` 下，  
> 不是 `/system/lib/hw/`。实测确认：  
> `find /system -name 'hwcomposer*'` → `/system/vendor/lib/hw/hwcomposer.tegra.so`；  
> `surfaceflinger` 的 `/proc/<pid>/maps` 里也是这个路径。  
> 所以 `tools/patch_hwc.py` 要作用在这个文件上。

### 路 C（最彻底）：换用 NVIDIA 开源 HWC

`gitlab.com/nvidia/nv-tegra/tegra/prebuilts-device-nvidia` 的  
`rel-st8-l-r7-partner` 分支里有 L4T 的 HWC 源码，理论上可以按 7.1 的  
`hwc_layer_1_t` 重新编译。但 Tegra K1 的 L4T 分支停在 4.4 时代，  
移植到 7.1 的 HWC 接口工作量很大。

**当前选择**：路 B 的简化版 —— 二进制补丁（`tools/patch_hwc.py`）。  
它只堵住了"二次释放"这一个必崩点，`sourceCrop` 错位导致的画面异常  
仍然存在（表现为偶发的局部花屏/黑屏）。等构建环境恢复后再做路 B。

---

## 附：`/system/etc/init/*.rc` 为什么能直接改

调试这一轮时，最重要的效率来源是：**改 rc 不用重编 ROM、不用重刷 boot.img**。

### 加载机制（不是 init.rc 里的 import）

查过源码，本机 `/init.rc` 只有 6 条 import：

```
import /init.environ.rc
import /init.usb.rc
import /init.${ro.hardware}.rc      -> /init.ardbeg.rc
import /init.usb.configfs.rc
import /init.${ro.zygote}.rc        -> /init.zygote32.rc
import /init.cm.rc
```

顺着 `/init.ardbeg.rc` 往下（`init.cal` / `init.tegra` / `init.tegra_emmc` /  
`init.t124` / `init.ray_touch`）也没有任何一条指向 `/system/etc/init`。

真正的入口是 `init.ardbeg.rc:16` 的

```
mount_all /fstab.ardbeg
```

对应 `system/core/init/builtins.cpp` 的 `do_mount_all()`：

```cpp
int ret = mount_fstab(fstabfile, mount_mode);   // 先挂载
if (import_rc) {
    import_late(args, 2, path_arg_end);         // 再解析 rc
}
```

而 `import_late()`（同文件 524-542 行）在**没有给路径参数**时，会遍历  
这个硬编码列表：

```cpp
static const std::vector<std::string> init_directories = {
    "/system/etc/init",
    "/vendor/etc/init",
    "/odm/etc/init"
};
```

逐个 `Parser::ParseConfig(dir)` —— 目录走 `ParseConfigDir()`  
（`init_parser.cpp:117-142`）：`readdir` 出所有 `DT_REG` 普通文件、  
**按文件名排序**后依次解析。

> **重要推论**：如果哪天把 `mount_all /fstab.ardbeg` 改成带路径的形式  
> （`mount_all /fstab.ardbeg /fstab.xxx`），`/system/etc/init` 就**整个不加载**了，  
> `audioserver` / `servicemanager` / `surfaceflinger` 全都会消失，系统直接起不来。  
> 这是个很容易在"优化 fstab"时踩到的地雷。

### 实测佐证

`audioserver`、`servicemanager`、`logd` 这三个服务在 `/init.rc` 和设备树  
所有 rc 里都没有定义，只在 `/system/etc/init/*.rc` 里有；  
而 `getprop init.svc.audioserver` 返回 `running` —— 说明该目录确实被解析了。

### 操作要点

```sh
adb shell mount -o rw,remount /system
adb push surfaceflinger.rc /system/etc/init/surfaceflinger.rc
# 重启 SF 让新配置生效（不用重启整机）
adb shell stop surfaceflinger; adb shell start surfaceflinger
```

重启后 `/system` 会变回 ro，每次推送前都要重新 remount。

---

# 二进制补丁：`libminijail.so` 的 seccomp 软失败（修 media 三兄弟崩溃循环）

## 症状

```
F libc: Fatal signal 6 (SIGABRT) in tid (mediacodec)
#00 libc.so        tgkill+12
#01 libc.so        pthread_kill+34
#02 libc.so        raise+10
#03 libc.so        __libc_android_abort+34
#04 libc.so        abort+4
#05 libminijail.so set_seccomp_filter+132
#06 libminijail.so minijail_enter+404
#07 mediacodec
#09 libc.so        __libc_init+48
```

`mediaextractor`、`mediadrm` 完全一样。三者共用同一份 minijail 胶水代码：

```
frameworks/av/services/mediacodec/minijail/minijail.cpp
frameworks/av/services/mediaextractor/minijail/minijail.cpp
frameworks/av/services/mediadrm/minijail/minijail.cpp
```

三份内容几乎逐行相同，都是：

```cpp
minijail_no_new_privs(jail);
minijail_log_seccomp_filter_failures(jail);
minijail_use_seccomp_filter(jail);
minijail_parse_seccomp_filters(jail, kSeccompFilePath);
minijail_enter(jail);
```

崩溃前 logcat 里的三行是最直接的证据：

```
W libminijail: allowing syscall: clock_gettime
W libminijail: logging seccomp filter failures
E libminijail: prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER): Invalid argument
F libc: Fatal signal 6 (SIGABRT) in tid (mediacodec)
```

## 根因

本机是 **4.4.4 的原厂预编译内核，没有编 `CONFIG_SECCOMP_FILTER`**，  
所以 `prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER)` 必然返回 `EINVAL`。

`external/minijail/libminijail.c` 本来就有软失败分支（`Android.mk:35` 加了  
`-DUSE_SECCOMP_SOFTFAIL`，代码是编译进去的）：

```c
if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, j->filter_prog)) {
    if ((errno == EINVAL) && can_softfail()) {
        warn("seccomp not supported");
        return;                       /* 软失败：不装过滤器，继续跑 */
    }
    pdie("prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER)");   /* abort */
}
```

但 `can_softfail()` 被一个**版本启发式**挡住了：

```c
int seccomp_kernel_support_not_required()          /* libminijail.c:183 */
{
    int major, minor;
    struct utsname uts;
    return (uname(&uts) != -1 &&
            sscanf(uts.release, "%d.%d", &major, &minor) == 2 &&
            ((major < 3) || ((major == 3) && (minor < 8))));
}
```

它的假设是"只有内核 < 3.8 才可能没有 seccomp filter"。  
本机内核是 **4.4.x**，按版本判断"应该有"，于是返回 0，软失败被关掉，直接 abort。  
**"版本新"和"功能有"在这台机器上恰好不成立。**

## 修法

反汇编 `set_seccomp_filter()`（0x5d2c，大小 0x9c）：

```
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
```

把 `5d8a: b130 cbz r0, 5d9a` 改成 `00 bf`（Thumb `nop`）：

```
5d8a: bf00        nop                      ; ← 补丁
5d8c: 490c        ldr    r1, [pc, #48]     ; warn("seccomp not supported")
```

### 踩过的坑：第一次改错了地方

第一次尝试是把**导出符号** `can_softfail`（0x4a6c，14 字节）整个换成  
`movs r0,#1; bx lr`。推上去之后仍然崩在同一个地方。

原因：`can_softfail()` 和 `set_seccomp_filter()` 在同一个编译单元  
（`libminijail.c`），`-O2` 下**被内联**了。`set_seccomp_filter` 里根本没有对  
`can_softfail` 的调用，只有对 `seccomp_kernel_support_not_required` 的 PLT 调用。  
改那个独立符号等于改了一段没人执行的代码。

**判断依据**：反汇编里 grep 不到 `can_softfail@plt`，只有  
`seccomp_kernel_support_not_required@plt` —— 看到这个就该知道它被内联了。

### 用法

```sh
python3 tools/patch_minijail.py --check   libminijail.orig.so
python3 tools/patch_minijail.py --apply   libminijail.orig.so -o libminijail.patched.so
python3 tools/patch_minijail.py --restore libminijail.patched.so -o libminijail.orig.so
```

脚本会校验 10 字节上下文  
（`blx seccomp_kernel_support_not_required` + 目标 + 后面两条指令），  
位置不对直接拒绝。注意字节序：`objdump` 打印 `f7fe e9a2`，文件里是 `fe f7 a2 e9`。

### 安全性

seccomp 过滤器在本机上**本来就装不上**，所以跳过它不降低任何实际安全性 ——  
真正的隔离边界（uid/gid 降权、capabilities、mount namespace）由 minijail  
的其它部分负责，那些仍然照常生效。

软失败后每个 media 服务会留一条  
`E libminijail: prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER): Invalid argument`  
然后继续启动。

### 实测

| 服务               | 修复前                    | 修复后           |
| ---------------- | ---------------------- | ------------- |
| `mediacodec`     | `restarting`（每次开机崩十几次） | **`running`** |
| `mediaextractor` | `restarting`           | **`running`** |
| `mediadrm`       | `restarting`           | **`running`** |

`service list` 里三个 binder 全部发布：

```
0    media.extractor: [android.media.IMediaExtractorService]
1    media.codec:     [android.media.IMediaCodecService]
116  media.drm:       [android.media.IMediaDrmService]
```

对 TV 版来说这条很关键 —— 没有 media.codec，任何视频都播不了。

### 长期正解（需要能全量编译时再做）

改 `external/minijail/libminijail.c` 的 `can_softfail()`，加一条"按属性开关"  
的逃生门，而不是靠内核版本猜：

```c
static int seccomp_softfail_by_property(void)
{
    char value[PROP_VALUE_MAX] = {0};
    if (__system_property_get("minijail.seccomp", value) <= 0)
        return 0;
    return (strcmp(value, "0") == 0);
}

int can_softfail(void)
{
#if SECCOMP_SOFTFAIL
    if (is_android()) {
        if (seccomp_kernel_support_not_required())
            return 1;
        if (seccomp_softfail_by_property())      /* 【ardbeg 补丁】 */
            return 1;
        return 0;
    } else {
        return 1;
    }
#endif
    return 0;
}
```

然后 `system.prop` 里加 `minijail.seccomp=0`。  
这样比"内核版本 < 3.8"可靠得多 —— 版本号和功能支持从来不是一回事。

---

# 设备树配置：`audio_policy.conf` 去掉 HAL 做不到的 profile

## 症状

`audioserver` 开机后无限崩溃重启，实测一次开机崩 **18 次**：

```
I AudioFlinger: openOutput(), module 10 Device 400, SamplingRate 8000,
                Format 0x000001, Channels 33, flags 1
I AudioFlinger: HAL output buffer size 512 frames, normal sink buffer size 512 frames
I AudioFlinger: openOutput(), module 10 Device 400, SamplingRate 0,
                Format 00000000, Channels 0, flags 1
F AudioFlinger: HAL format 0 not valid for output
F libc        : Fatal signal 6 (SIGABRT) in tid (audioserver)
```

崩溃点 `frameworks/av/services/audioflinger/Threads.cpp:2484`：

```c
if (!audio_is_valid_format(mFormat)) {
    LOG_ALWAYS_FATAL("HAL format %#x not valid for output", mFormat);
}
```

**`LOG_ALWAYS_FATAL` 不是 `ALOGE`** —— 没有任何挽回余地，直接 abort。

## 日志里那几个数字的含义

| 值                   | 含义                                                |    |    |     |
| ------------------- | ------------------------------------------------- | -- | -- | --- |
| `Device 400`        | `0x400` = `AUDIO_DEVICE_OUT_AUX_DIGITAL`（就是 HDMI） |    |    |     |
| `Channels 33`       | `0x33` = `AUDIO_CHANNEL_OUT_QUAD`（前左              | 前右 | 后左 | 后右） |
| `SamplingRate 8000` | `multichannel` profile 里 `sampling_rates` 的第一项    |    |    |     |
| `flags 1`           | `AUDIO_OUTPUT_FLAG_DIRECT`（不是 `PRIMARY=2`）        |    |    |     |

=> 命中的是 `multichannel` profile，一个 4 声道 DIRECT 输出。

## 根因：配置撒谎，HAL 兜不住，AudioFlinger 只好自杀

`device/nvidia/ardbeg/audio/audio_hw.c` 的 `start_output_pcm()` 里，  
pcm_config 的 format 是**写死**的：

```c
struct pcm_config config = {
    ...
    .format = PCM_FORMAT_S16_LE,     /* ← 只会 16bit 小端 PCM */
};
```

声道数由 `audio.ardbeg.xml` 里 hw_stream 的配置决定（本机只有 2 声道扬声器通路）。  
所以这个 tinyalsa HAL 根本不支持：

- 多声道（QUAD / SURROUND / 5POINT1 / 7POINT1）
- IEC61937 压缩透传（AC3 / EAC3 / DTS）
- 压缩音频直通（MP3 / AAC offload）
- HDMI（`AUX_DIGITAL`）输出

但原来的 `audio_policy.conf`（照抄 NVIDIA Shield Tablet 的）把这些全声明了。

AudioPolicyManager 信了配置，去为 HDMI 打开 `multichannel` 输出：

1. 第一次 `openOutput` 带着 profile 的初始参数（8000/QUAD/PCM16）——  
   HAL 硬着头皮开了（`pcm_open` 用了 S16_LE，缓冲区 512 帧）；
2. 随后 APM 发现这是个**动态 profile**，走  
   `AudioPolicyManager.cpp:3869` 的 `hasDynamicAudioProfile()` 分支，  
   先 `closeOutput()` 再 `pickAudioProfile()` 重新取参数；
3. `pickAudioProfile()`（`AudioPort.cpp:298`）**开头就把三个值清零**：
   ```c
   format = AUDIO_FORMAT_DEFAULT;
   samplingRate = 0;
   channelMask = AUDIO_CHANNEL_NONE;
   if (!mProfiles.hasValidProfile()) return;   /* 拿不到有效 profile 就直接返回 */
   ```
4. 第二次 `openOutput` 带着全 0 参数进 HAL，HAL 原样回填  
   （`audio_hw.c:2371` `config->format = out.common->format`），  
   AudioFlinger 拿到 `format=0`，撞上 `LOG_ALWAYS_FATAL`。

## 修法

把配置改成"只说真话"：删掉 HAL 做不到的 profile，并去掉所有  
`AUDIO_DEVICE_OUT_AUX_DIGITAL` 声明。APM 没有可用 profile 就根本不会  
去为 HDMI 开输出，也就不会走到那个清零的 `pickAudioProfile`。

删掉的四个：

| profile                    | 为什么删                      |
| -------------------------- | ------------------------- |
| `multichannel`             | 4 声道 DIRECT，HAL 只做立体声     |
| `aux_ac3_dts_pass_through` | IEC61937 透传，HAL 不支持       |
| `ulp_output`               | MP3/AAC 压缩直通，HAL 不支持      |
| `dual_audio`               | 多声道 + 全采样率 DIRECT，HAL 不支持 |

保留的三个：`primary`（48kHz/立体声/PCM16/PRIMARY，唯一真实通路）、  
`a2dp`（蓝牙，走独立 HAL）、`usb`（USB 声卡，走独立 HAL）。

> **注意保留 `ALL_SCO` 但删掉 `AUX_DIGITAL`**：  
> `AUDIO_DEVICE_OUT_ALL_SCO` 是蓝牙 SCO（通话音），APM 会把它路由到  
> a2dp/primary 而不会让本 HAL 开独立输出；  
> 而 `AUX_DIGITAL` 会触发"为这个设备新开一个输出"的路径，正是崩溃点。

### 实测

| 指标                    | 修复前     | 修复后                                       |
| --------------------- | ------- | ----------------------------------------- |
| `audioserver` 崩溃次数    | 18 次/开机 | **0**                                     |
| `audioserver` pid     | 反复变化    | **稳定**                                    |
| `media.audio_policy`  | 未发布     | **`[android.media.IAudioPolicyService]`** |
| `media.audio_flinger` | 未发布     | **`[android.media.IAudioFlinger]`**       |
| `audio`（AudioService） | 未发布     | **`[android.media.IAudioService]`**       |

## 本机音频的硬限制（必须记下来，否则会反复走弯路）

改完配置后音频**框架**健康了，但**仍然没有声音**，原因是硬件/内核层面：

```
$ cat /proc/asound/cards
 0 [Tegra          ]: HDA-Intel - HDA NVIDIA Tegra
                      HDA NVIDIA Tegra at 0x70038000 irq 113
 1 [tegradummy     ]: tegra-dummy - tegra-dummy

$ cat /proc/asound/pcm
00-03: HDMI 0 : HDMI 0 : playback 1
01-00: dummy PCM snd-soc-dummy-dai-0 :  : playback 1 : capture 1
01-01: SPDIF PCM dit-hifi-1 :  : playback 1
01-02: BT-SCO PCM dit-hifi-2 :  : playback 1 : capture 1
01-03: VOICE CALL PCM snd-soc-dummy-dai-3 :  : playback 1 : capture 1
01-04: BT VOICE CALL PCM snd-soc-dummy-dai-4 :  : playback 1 : capture 1

$ ls /sys/module | grep -i snd
snd
snd_hda_codec_hdmi
snd_hda_intel
snd_pcm
snd_timer
snd_usb_audio
```

三条结论（**2026-11-10 已全部推翻，见下方「复核」**）：

1. ~~**内核里没有 ASoC**~~ —— 错。`/proc/kallsyms` 里有 `rt5639_*` 全套符号，
   `/sys/bus/platform/drivers/` 里 `tegra-snd-rt5639`、`tegra-snd-rt5640`、
   `tegra30-ahub`、`tegra30-i2s`、`tegra30-dam`、`tegra30-spdif`、`soc-audio`
   全在。
2. ~~**`tegra-snd-rt5639` 声卡不存在**~~ —— 准确说法是
   **有 driver 没有 device**：`/sys/bus/platform/devices/` 里只有
   `tegra-snd-dummy.0`，机器驱动从未被实例化。
3. ~~**扬声器出声在预编译内核上做不到**~~ —— 内核侧做得到，
   做不到的是**硬件**：codec 不在总线上。

## 复核（2026-11-10 真机实测）

### 一、驱动全在，只是没有设备

```
$ ls /sys/bus/platform/drivers/ | grep -E "snd|ahub|i2s|spdif|dam"
snd-soc-dummy  spdif-dir  spdif-dit  tegra-snd-dummy  tegra-snd-rt5639
tegra-snd-rt5640  tegra30-ahub  tegra30-dam  tegra30-i2s  tegra30-spdif

$ ls /sys/devices/platform/ | grep -E "i2s|ahub|dam|spdif"
spdif-dit.0  spdif-dit.1  spdif-dit.2  tegra30-ahub
tegra30-dam.0  tegra30-dam.1  tegra30-dam.2
tegra30-i2s.0  tegra30-i2s.1  tegra30-i2s.3  tegra30-i2s.4  tegra30-spdif
```

`tegra30-i2s.*` / `tegra30-ahub` / `tegra30-spdif` 这些 **CPU DAI 是板级 C 代码
静态注册的，不依赖 DT**。所以当年裁掉 `/ahub` 节点并没有弄丢它们。

### 二、机器驱动支持 DT，可以纯靠 DTB 实例化

`tegra_rt5639.c` 有 `of_match_table`，compatible = **`nvidia,tegra-audio-rt5639`**。
probe 读这几个属性（都在真机内核 `vmlinux` 里逐字确认过存在）：

| 属性 | 取值 |
|---|---|
| `nvidia,codec_name` | `rt5639.0-001c`（dai_link 里写死的默认值是 `rt5639.0-001a`，板级代码会覆盖） |
| `nvidia,codec_dai_name` | `rt5639-aif1` |
| `nvidia,ldo-gpios` | `TEGRA_GPIO_PR2` = 138 |
| `nvidia,hp-det-gpios` | `TEGRA_GPIO_PH4` = 60（P1761 分支） |
| `nvidia,i2s-param-hifi` | `<port is_master daifmt>` = `<1 1 2>`，`TEGRA_DAIFMT_I2S` = 2 |
| `nvidia,i2s-param-bt` | `<3 1 0>`，`TEGRA_DAIFMT_DSP_A` = 0 |

**主线那套属性（`nvidia,model` / `nvidia,audio-codec` / `nvidia,i2s-controller` /
`nvidia,audio-routing`）在这颗内核里根本不存在** —— 3.10.24 用的是
platform_data 式 DT 绑定，抄主线 `tegra-audio-rt5640` 的 DTS 会全部落空。

`tegra_asoc_utils_init()` 用 `clk_get_sys(NULL, "pll_a")` 按名字全局取时钟，
**不需要** DT 里写 `clocks`；但它靠 `of_machine_is_compatible("nvidia,tegra124")`
判断 SoC，根节点 compatible 必须含 `nvidia,tegra124`（当前是
`"nvidia,tn8\0nvidia,tegra124"`，满足）。

### 三、DTB 实测：走到 codec probe，然后卡在两处

用 `fdtput` 往 DTB 里加 `/sound`（不重新编译，避免 phandle 重排）后，
`sound.0` 平台设备确实建出来了，
`MODALIAS=of:NsoundT<NULL>Cnvidia,tegra-audio-rt5639` 也对，但 probe 失败：

```
tegra-i2c tegra12-i2c.0: no acknowledge from address 0x1c     ← 反复几十条
rt5639 0-001c: Failed to set private addr: -121
tegra30-i2s tegra30-i2s.1: ASoC: pcm constructor failed: -12
tegra-snd-rt5639 sound.0: ASoC: can't create pcm rt5639 PCM :-12
tegra-snd-rt5639 sound.0: snd_soc_register_card failed (-12)
tegra-snd-rt5639: probe of sound.0 failed with error -12
```

两个互相独立的死结：

1. **codec 不在总线上**。板级代码是
   `i2c_register_board_info(0, &rt5639_board_info, 1)`，
   `I2C_BOARD_INFO("rt5639", 0x1c)` —— 地址 i2c-0 @0x1c。芯片**不应答**。
   ⚠️ 陷阱：`rt5639_i2c_probe` 在 I2C 全 NAK 时**仍然会注册 codec**，
   `/sys/kernel/debug/asoc/codecs` 里能看到 `rt5639.0-001c`，
   `/sys/bus/i2c/devices/0-001c/driver` 也有 symlink，`rt5639-aif1` 也出现在
   `dais` 里 —— **看起来像成功，其实全是假的**。判断 codec 真在位的唯一标准是
   `dmesg` 里有没有 `no acknowledge from address 0x1c`。
2. **i2s DMA 分配失败**：`coherent DMA mask 0xffffffff is smaller than
   system GFP_DMA mask 0xffffffffffffffff` → `pcm constructor failed: -12`
   （`-ENOMEM`）。这条与 DT 无关，是内核 DMA 域的问题
   （`tegra30-i2s.3` 挂 dummy 卡却能建 PCM，`.1` 不行，差异未查清）。

### 四、结论：这台机器没有模拟音频 codec

硬件事实。改 DTB / 改 HAL / 重编内核都改变不了。

- 2026-10-23 那次 `I2C_SLAVE_FORCE` 全总线扫描（0x03~0x77）的结论是对的：
  RT5639(0x1a/0x1c)、RT5640(0x1c)、TFA9887(0x34~0x36) 在六条总线上全部 NAK。
- 2026-11-10 用 `/sys/bus/i2c/devices/i2c-0/new_device` 再验一次，仍然 NAK。

**唯一可能有声的出口是 HDMI**：card 0 = `HDA NVIDIA Tegra`，`pcmC0D3p`。
但 `audio.primary.ardbeg.so`（tinyhal）的 `device_table[]` 里没有
`AUDIO_DEVICE_OUT_AUX_DIGITAL`，而且输出设备硬编码成 `/dev/snd/pcmC0D0p`
（每次开机刷 `pcm_open(out) failed`）。要走 HDMI 必须改 HAL 源码 +
`audio_policy.conf`，不是改配置能解决的。

### 五、顺带确认：`nvidia,boardids` 对音频没有影响

`/proc/cmdline` 里有 `board_info=0x06e1:0x0000:0x00:0x00:0x00`
（bootloader 直接给），`tegra_get_board_info()` 优先用它。
往 DTB 根节点补 `nvidia,boardids = "1761:1470:0"` 后，
`/proc/device-tree/nvidia,boardids` 读得到，但**行为零变化**。
以后不要再往这个方向试。

**当前状态（2026-11-10 收尾）**：DTB 已恢复成实验前那份
（整分区 md5 `f78c0268beea0a815304f1a63dd326e8`），
`/proc/asound/cards` 仍是 `HDA NVIDIA Tegra` + `tegradummy` 两张。
这个方向不再投入。

---

# 二进制补丁：`libinputservice.so` 的 `SpriteController` fence 死等（修 Watchdog 杀 system_server）

## 症状

系统能起来、`sys.boot_completed=1`、Launcher 拿到焦点，但开机 2 分半左右  
`system_server` 被 Watchdog 杀掉，之后进入**无限崩溃循环**（每 6 秒一轮）：

```
W Watchdog: *** WATCHDOG KILLING SYSTEM PROCESS:
            Blocked in handler on display thread (android.display)
W Watchdog: display thread stack trace:
W Watchdog:     at android.os.MessageQueue.nativePollOnce(Native Method)
W Watchdog:     at android.os.Looper.loop(Looper.java:136)
W Watchdog:     at android.os.HandlerThread.run(HandlerThread.java:61)
W Watchdog:     at com.android.server.ServiceThread.run(ServiceThread.java:46)
W Watchdog: *** GOODBYE!
I Process : Sending signal. PID: 1520 SIG: 9
```

之后每 6 秒一次：

```
E AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS: main
E AndroidRuntime: DeadSystemException: The system died; earlier logs will point to the root cause
E AndroidRuntime: Error reporting crash
E AndroidRuntime: java.lang.NullPointerException: Attempt to invoke virtual method
                  'void android.app.ActivityThread$Profiler.stopProfiling()' on a null object reference
```

## 第一个陷阱：Watchdog 打印的堆栈是"事后"的

上面那段 `nativePollOnce` 看起来是**空闲等待**，完全不像卡死。  
这是 Android 7.x Watchdog 的一个特性：

1. 第一次检查超时（30 秒）时，它把**所有线程的完整堆栈** dump 到  
   `/data/anr/traces_SystemServer_WDT*.txt`，然后**不会重新 post monitor**；
2. 再等 30 秒，第二次检查直接判死。

所以 `logcat` 里那条 `nativePollOnce` 是**第二次检查时**的状态，  
那时 display thread 早就恢复了。真正的卡死现场只在 traces 文件里。

**真正的现场**（`traces_SystemServer_WDT05_11月_22_26_02.826.txt` 第 1128 行）：

```
"android.display" prio=5 tid=18 Native
  native: #00 pc 00049424  /system/lib/libc.so (__ioctl+8)
  native: #01 pc 0001af3b  /system/lib/libc.so (ioctl+38)
  native: #02 pc 0000093f  /system/lib/libsync.so (sync_wait+26)
  native: #03 pc 0000a6a1  /system/lib/libui.so (Fence::waitForever+116)
  native: #04 pc 0000ce7d  /system/lib/libui.so (Gralloc1On0Adapter::lock+88)
  native: #05 pc 0000c437  /system/lib/libui.so (???)
  native: #06 pc 0000b4eb  /system/lib/libui.so (Gralloc::Device::lock+50)
  native: #07 pc 0000f7b7  /system/lib/libui.so (GraphicBufferMapper::lockAsync+142)
  native: #08 pc 0000e5bb  /system/lib/libui.so (GraphicBuffer::lockAsync+98)
  native: #09 pc 000543b7  /system/lib/libgui.so (Surface::lock+490)
  native: #10 pc 00008a0b  /system/lib/libinputservice.so
                            (SpriteController::doUpdateSprites+878)
  native: #11 pc 0001177f  /system/lib/libutils.so (WeakMessageHandler::handleMessage)
  native: #12 pc 00012069  /system/lib/libutils.so (Looper::pollInner+496)
  at android.os.MessageQueue.nativePollOnce(Native method)
```

翻译成人话：

> display thread 在跑 `SpriteController::doUpdateSprites`（渲染鼠标指针），  
> 它调 `Surface::lock()` 想用 CPU 直接往 surface 的 buffer 里画，  
> `Surface::lock()` 需要等这块 buffer 的 acquire fence，  
> 于是调 `Fence::waitForever()`，而 `waitForever` 里的 `sync_wait()`  
> 超时参数是 `INT_MAX` —— **永远等下去**。  
> 而这块 buffer 的 fence 永远不会 signal。

## 为什么 fence 永远不 signal

这块 sprite surface 是 SF 合成管线的一部分。而 SF 用的 HWC 是  
4.4.4 的原厂 blob，在 7.1 下 fence 管理本身就是错乱的  
（详见下面 sf_hwc_off 那一章）。有时能正常 signal，  
有时永远不 signal —— **这是个随机 bug**。

**触发条件**：只要接了鼠标，`InputReader` 就会上报 pointer 事件，  
`PointerController` 就会让 sprite 可见，`SpriteController` 就会去 lock surface。  
实测本机输入设备：

```
/dev/input/event2  name: "gpio-keys.4"
/dev/input/event1  name: "2.4G Mouse"     ← 就是这个
/dev/input/event0  name: "aw9201_ts"      （触摸屏）
```

所以插着 2.4G 无线鼠标 = 必踩。

## 修法

`SpriteController::doUpdateSprites` 是 void 返回，直接在入口写 `bx lr`  
就等价于"整个函数什么都不做"：

```
符号：_ZN7android16SpriteController15doUpdateSpritesEv  @ 0x869c

原始（Thumb-2）：
    869c: e92d 4ff0   stmdb  sp!, {r4, r5, r6, r7, r8, r9, sl, fp, lr}
    86a0: f5ad 5d93   sub.w  sp, sp, #4704
    86a4: b085        sub    sp, #20
    86a6: 4680        mov    r8, r0

改成：
    869c: 7047        bx     lr
    869e: 00bf        nop
```

**为什么敢整个函数跳过**：`doUpdateSprites` 的职责是"把 mSprites 里所有  
sprite 的最新属性提交到 SurfaceControl 上并画出来"，它改的状态全是输出型  
（`mTransactionOpen` / `mSurfaceLocked` / `mLockedBuffer`）。跳过它就保持  
"未打开/未锁定"的自洽空状态。它唯一的调用者是 `handleMessage` 的  
`MSG_UPDATE_SPRITES` 分支，而 `handleMessage` 也是 void 返回。

**会不会有别的路径也 lock surface**：`SpriteController` 里跟 Surface  
打交道的只有三个函数，只有 `doUpdateSprites` 会 lock：

| 函数                  | 地址     | 是否 lock               |
| ------------------- | ------ | --------------------- |
| `obtainSurface`     | 0x8efc | 只 new / 复用，不 lock     |
| `doUpdateSprites`   | 0x869c | **唯一 lock 点** ← 本补丁干掉 |
| `doDisposeSurfaces` | 0x8e80 | 只 destroy，不 lock      |

`PointerController::Spot::updateSprite`（0x7328）只调  
`setIcon`/`setPosition`/`setVisible` 这些纯属性设置，然后 invalidate 一下  
触发 `handleMessage`，本身不碰 surface。

## 代价

鼠标指针不画了。**点击事件完全不受影响**（事件走  
`InputReader`/`InputDispatcher`，跟 sprite 渲染是两条独立的路），  
只是屏幕上看不到那个箭头。TV 盒子本来就是遥控器/键盘操作为主，可接受。

**系统能起来 > 有鼠标指针。** 等 hwcomposer shim 做好、fence 链路正常了，  
就可以回滚这个补丁。

## 用法

```bash
python3 tools/patch_inputservice.py --check   libinputservice.so
python3 tools/patch_inputservice.py --apply   libinputservice.so -o libinputservice.patched.so
python3 tools/patch_inputservice.py --restore libinputservice.patched.so -o libinputservice.orig.so
```

设备侧落地：

```bash
adb root && adb remount
adb push libinputservice.patched.so /system/lib/libinputservice.so
adb shell chmod 644 /system/lib/libinputservice.so
adb reboot     # ← 必须整机重启
```

⚠ `libinputservice.so` 被 **system_server** 加载（不是独立进程），  
改完必须整机重启。`stop zygote; start zygote` 那种手工重启会因为  
servicemanager 残留旧 handle 引发 zygote 崩溃循环（见下文）。

## 实测

```
改之前：system_server 开机 2 分 25 秒被 Watchdog 杀，之后每 6 秒崩一次，永远起不来
改之后：system_server pid 跨越 166 秒 / 334 秒 全程未变，一次都没被 Watchdog 杀
```

---

# USB 鼠标不工作：指针 sprite 画不出来（fence 死等的**正确**修法）

> 这一章是上一章 `libinputservice.so` 补丁的**收尾与纠错**。  
> 上一章的补丁把 `doUpdateSprites` 整个跳过，副作用就是鼠标指针彻底消失。  
> 本章给出真正的修法：不动 SpriteController，改在更底层掐掉那条永不返回的 fence 等待。

## 症状

插上 USB 2.4G 无线鼠标后：

- 屏幕上看不到指针箭头
- 移动鼠标没有任何反应
- 点击也没有反应

看起来像"鼠标完全不被识别"。

## 排查过程：一层层排除

这一轮排查的**关键收获**是：鼠标其实一直是好的，坏在最后一公里。

| 层次          | 检查命令                                    | 结果                                                 | 结论       |
| ----------- | --------------------------------------- | -------------------------------------------------- | -------- |
| 设备节点        | `ls /dev/input/`                        | `event1` 存在                                        | ✓        |
| 内核能力        | `getevent -pl /dev/input/event1`        | `BTN_MOUSE` + `REL_X/REL_Y/REL_WHEEL` 齐全           | ✓        |
| EventHub 分类 | `dumpsys input` → `Classes: 0x80000008` | = `EXTERNAL \| CURSOR`                             | ✓        |
| InputReader | `dumpsys input` → `Cursor Input Mapper` | `Mode: pointer`，X/Y 范围 `0~1919 / 0~1079`（正好是屏幕分辨率） | ✓        |
| 事件上报        | `sendevent /dev/input/event1 2 0 100 …` | `RecentQueue` 里出现新 `MotionEvent`，**零条 `Dropping`** | ✓        |
| 坐标变换        | 注入 `+100 X` / `-100 X` / `±100 Y`       | 指针坐标**严格 1:1 跟随**                                  | ✓        |
| 渲染          | `dumpsys SurfaceFlinger --list`         | **没有 `Sprite` 图层**                                 | ✗ ← 问题在这 |

### 第一个坑：`INPUT_DEVICE_CLASS_*` 的枚举值和直觉不一样

一开始看到 `Classes: 0x80000008`，按"`0x08` 是 `TOUCH_MT`"去理解，  
误判成"EventHub 把鼠标认成了多点触摸屏"。

查 `frameworks/native/services/inputflinger/EventHub.h:103-145` 才发现：

```c
INPUT_DEVICE_CLASS_KEYBOARD  = 0x00000001,
INPUT_DEVICE_CLASS_ALPHAKEY  = 0x00000002,
INPUT_DEVICE_CLASS_TOUCH     = 0x00000004,
INPUT_DEVICE_CLASS_CURSOR    = 0x00000008,   // ← 0x08 是 CURSOR，不是 TOUCH_MT
INPUT_DEVICE_CLASS_TOUCH_MT  = 0x00000010,   // ← TOUCH_MT 是 0x10
```

所以 `0x80000008` = `EXTERNAL | CURSOR`，分类**完全正确**。  
而且 `EventHub.cpp:1188` 的判定条件就是  
`test_bit(BTN_MOUSE) && test_bit(REL_X) && test_bit(REL_Y)` → `|= CURSOR`。

**教训：不要凭记忆猜枚举值，去头文件里数。**

### 第二个坑：`Dropping event because there is no touchable window` 是假线索

排查中抓到过 23 条：

```
I/InputDispatcher: Dropping event because there is no touchable window at (1172, 195).
```

看着像"命中测试失败"，但仔细看时间戳和坐标：

- 坐标在连续变化（1172,195 → 1204,175），说明**鼠标事件本身完全正常**
- 那一刻正好是 Launcher → DeskClock 的**窗口切换空档**，输入窗口列表里  
  只有 `StatusBar(0~36)` 和 `NavigationBar(1008~1080)`，  
  屏幕中部的 (1172,195) 确实没有任何窗口
- 窗口切换完成后重新 dump，DeskClock 窗口就在列表里了，`Dropping` 也消失了

**这是过渡态的正常现象，不是 bug。**

### 真正的根因：`SpriteController` 建了 surface，但永远画不进去

`dumpsys SurfaceFlinger --list` 里始终没有 `Sprite` 图层。  
而上一章已经把 `SpriteController::doUpdateSprites()` 整个打成 `bx lr` ——  
**这个函数就是负责"把指针画到自己的 surface 上"的**。  
函数被跳过 → surface 不建、不画、不显示 → 屏幕上看不到箭头。

上一章的 traces 已经给出了完整的死锁栈：

```
sync_wait                                    libc
Fence::waitForever                           libui
Gralloc1On0Adapter::lock+88                  libui     ← 等待点
Gralloc::Device::lock                        libui
GraphicBufferMapper::lockAsync               libui
GraphicBuffer::lockAsync                     libui
Surface::lock+490                            libgui
SpriteController::doUpdateSprites+878        libinputservice
```

## 为什么 fence 永远不 signal —— 以及为什么只有鼠标受影响

fence 是 SF 交给 client layer 的 release fence。因为本机 HWC 是 4.4.4 编的  
（`hwc_layer_1_t` 布局错位，见上文 HWC 专章），这条 fence 永远不会被 signal。

**关键问题：为什么 App 渲染不受影响，只有鼠标指针卡死？**

因为生产者侧根本不等 acquire fence：

| 路径                                           | 是否等 acquire fence                             | 谁在用                                                  |
| -------------------------------------------- | --------------------------------------------- | ---------------------------------------------------- |
| `BufferQueueProducer::dequeueBuffer`         | **否**，靠 slot 状态 + `waitForFreeSlotThenRelock` | 所有 App 的 GPU 渲染                                      |
| GPU 绘制                                       | **否**，靠 EGL 隐式同步                              | 所有 App                                               |
| `Surface::lock` → `GraphicBuffer::lockAsync` | **是**，`Fence::waitForever`                    | `SpriteController`（鼠标指针）、少数用 `lockCanvas` 的软件 Canvas |

也就是说，全系统里唯一显式"等 acquire fence 再 CPU 写内存"的主流路径，  
恰好就是画鼠标指针这一条。所以症状表现为"系统一切正常，只有鼠标不行"。

## 修法：两件事，缺一不可

### 1) 给 `libui.so` 打补丁，跳过那条 fence 等待

`frameworks/native/libs/ui/Gralloc1On0Adapter.cpp:398-403`：

```cpp
    } else {
        acquireFence->waitForever("Gralloc1On0Adapter::lock");   // ← 返回值被丢弃
        int result = mModule->lock(mModule, buffer->getHandle(), ...);
```

两个关键事实让这个补丁非常安全：

1. **`waitForever()` 的返回值完全没被使用**（没赋给任何变量），  
   后面只检查 `mModule->lock()` 的 `result`。
2. 反汇编显示 `blx` 之后的两条指令会**重新加载 r0 和 r1**：

```
   ce7c: f7fc ee86   blx  9b8c <Fence::waitForever@plt>
   ce80: 6831        ldr  r1, [r6, #0]     ; r1 被覆盖
   ce82: 6d68        ldr  r0, [r5, #84]    ; r0 被覆盖
```

所以把 `blx` 换成两条 `nop`，**不破坏任何寄存器语义、不改变控制流**。

为什么"不等"是安全的：`SpriteController` 每帧都用  
`SkXfermode::kSrc_Mode` 把整个 buffer 重画一遍  
（`SpriteController.cpp:218-231`，图标 + 透明填充剩余区域），  
不存在"基于旧内容增量修改"。所以即使 buffer 还在被扫描输出，  
写进去的内容也是完整正确的，最多一帧撕裂 —— 对 33×42 的箭头不可感知。

**补丁点**（两个，都是 gralloc0 回退分支）：

| 函数                              | 函数基址     | 等待点              | 原始 4 字节（文件序）  |
| ------------------------------- | -------- | ---------------- | ------------- |
| `Gralloc1On0Adapter::lock`      | `0xce24` | `+0x58 = 0xce7c` | `fc f7 86 ee` |
| `Gralloc1On0Adapter::lockYCbCr` | `0xceb4` | `+0x62 = 0xcf16` | `fc f7 3a ee` |

都替换成 `00 bf 00 bf`（`nop; nop`）。

> ⚠ 注意：**不要去改 `Fence::waitForever` 本身**。  
> 它有 12 处调用，其中 `HWComposer_hwc1.cpp:920` 的  
> `acquireFence->waitForever("HWComposer::fbPost")` 是 SF 投屏同步的关键，  
> 全局改成 no-op 会把显示时序彻底搞乱。

### 2) 把 `libinputservice.so` 恢复成原始版本

让 `SpriteController::doUpdateSprites()` 正常工作。

```sh
# 用归档的原始库直接覆盖
adb push tools/libinputservice.orig.so /system/lib/libinputservice.so
# 或者用脚本回滚
python3 tools/patch_inputservice.py --restore <已打补丁的.so> -o libinputservice.orig.so
```

## 用法

```sh
# 检查
python3 tools/patch_libui_gralloc.py --check   libui.so

# 生成打过补丁的副本
python3 tools/patch_libui_gralloc.py --apply   libui.so -o libui.patched.so

# 回滚
python3 tools/patch_libui_gralloc.py --restore libui.patched.so -o libui.orig.so
```

设备侧落地（`libui.so` 被 system_server / surfaceflinger / 所有 App 加载，  
**必须整机重启**）：

```sh
adb root && adb remount
adb push libui.patched.so          /system/lib/libui.so
adb push tools/libinputservice.orig.so /system/lib/libinputservice.so
adb shell chmod 644 /system/lib/libui.so /system/lib/libinputservice.so
adb shell chcon u:object_r:system_lib_file:s0 /system/lib/libui.so /system/lib/libinputservice.so
adb reboot
```

> ⚠ 不能 `stop zygote; start zygote` 手工重启 —— servicemanager 会残留  
> 123 个指向旧 system_server 的死服务条目，新 system_server 在  
> `ActivityThread.hasCodec()` 里拿到死 handle → `DeadSystemException`  
> → 崩溃循环（已实测）。

## 实测结果（2026-11-05 23:32 重启后）

```
uptime 212 秒
surfaceflinger = 267   system_server = 1592      ← 全程未变，零 Watchdog 击杀
service call SurfaceFlinger 1010 → 00000001      ← disableHWC 已生效
dumpsys SurfaceFlinger --list → 出现 "Sprite" 图层

Sprite 图层：
  pos=(493.402,792.201)  size=(33,42)  mTexName=2（已绘制）
  GLES | … | 0,0,33,42 | 493,792,526,834 | Sprite    ← 参与合成

四方向注入测试（严格 1:1）：
  起点            (493.402, 792.201)
  +100 X (向右)   (593.402, 792.201)   ✓
  -100 X (向左)   (493.402, 792.201)   ✓
  +100 Y (向下)   (493.402, 892.201)   ✓
  -100 Y (向上)   (493.402, 792.201)   ✓

点击测试：
  点应用抽屉按钮 → 抽屉展开 ✓
  点"计算器"     → mCurrentFocus=com.android.calculator2/com.android.calculator2.Calculator ✓
```

## 调试工具：`tools/mouse_helper.sh`

在没有物理鼠标 / 需要精确落点时，用 `sendevent` 往 `/dev/input/event1`  
注入真实鼠标事件：

```sh
adb push tools/mouse_helper.sh /data/local/tmp/mh.sh
adb shell chmod 755 /data/local/tmp/mh.sh

adb shell /data/local/tmp/mh.sh pos                 # 打印当前指针坐标
adb shell /data/local/tmp/mh.sh move 500 410        # 闭环移动到 (500,410)
adb shell /data/local/tmp/mh.sh click 500 410       # 移动后左键单击
adb shell /data/local/tmp/mh.sh rclick 500 410      # 右键
adb shell /data/local/tmp/mh.sh wheel 3             # 滚轮向下 3 格
```

**为什么必须闭环**：7.1 的 `CursorInputMapper` 开了指针加速  
（`PointerVelocityControlParameters: lowThreshold=500, highThreshold=3000,
acceleration=3.0`），一次注入大位移会被放大数倍，落点完全不可预测  
（实测注入 `+300/-200`，指针跑到 `-236/+106`）。  
脚本每步只走 12px（低于 `lowThreshold`，不触发加速），走完读回  
Sprite 真实坐标再修正。

> 脚本里有个已经踩过的坑：循环内 `set -- $(getpos)` 会覆盖位置参数 `$1`，  
> 所以动作名必须先存进 `act` 变量，否则 `click` 分支永远不执行  
> （表现为只移动不点击，而且不报错）。

## 长期正解

写 `hwcomposer.ardbeg.so` shim，把 7.1 的 `hwc_layer_1_t` 翻译成 4.4.4 的  
再喂给原厂 HWC。fence 正常之后：

1. `sf_hwc_off.sh` 可以去掉，恢复硬件合成（省电 + 性能）
2. `patch_libui_gralloc.py` 可以回滚

在 shim 做完之前，这两个补丁是稳定可用的方案。

---

# 设备树配置：`sf_hwc_off.sh` 关闭 HWC 合成（根治 SurfaceFlinger 崩溃 + 永久黑屏）

## 症状

`SurfaceFlinger` 每 40~100 秒 `SIGSEGV` 一次，而且**崩一次就永久黑屏**。

两种崩溃签名交替出现：

**签名 A：jemalloc 堆被写坏**

```
F libc  : Fatal signal 11 (SIGSEGV), code 1, fault addr 0x8 in tid 230 (surfaceflinger)
    #00 pc 00048446  /system/lib/libc.so (pthread_mutex_lock+1)
    #01 pc 0006f4ad  /system/lib/libc.so (je_tcache_bin_flush_large+132)
    #02 pc 0006f20b  /system/lib/libc.so (je_tcache_event_hard+90)
    #03 pc 00063cbf  /system/lib/libc.so (je_malloc+762)
    #04 pc 00048c49  /system/lib/libc++.so (_Znwj+16)      ← operator new
    #05 pc 000181c9  /system/lib/libsurfaceflinger.so
```

**签名 B：EGL 驱动内部跳到 NULL**

```
F libc  : Fatal signal 11 (SIGSEGV), code 1, fault addr 0x0 in tid 293 (Binder:222_1)
    #00 pc 00000000  <unknown>                             ← 跳到地址 0
    #01 pc 00003597  /system/vendor/lib/libnvglsi.so
    #02 pc 000036b7  /system/vendor/lib/libnvglsi.so (_nv054glsi+22)
    #03 pc 0003ba5f  /system/vendor/lib/libEGL_tegra_impl.so
    #08 pc 0000e683  /system/lib/libEGL.so (eglDestroyImageKHR+62)
    #09 pc 000443e9  /system/lib/libgui.so (GLConsumer::EglImage::~EglImage+20)
```

签名 B 大概率是签名 A 的后果（堆被踩烂后，驱动里的函数指针变成垃圾）。

## 根因：`hwc_layer_1_t` 字段偏移错位 4 字节

先说结论：**两代的 `hwc_layer_1_t` 都是 96 字节**（末尾都有  
`int32_t reserved[24 - 19]` 的 padding），所以**步长一致、不越界**。  
但**字段偏移从 offset 16 开始整体错位 4 字节**：

| 字段                    | 4.4.4  | 7.1                  |
| --------------------- | ------ | -------------------- |
| `compositionType`     | 0      | 0                    |
| `hints`               | 4      | 4                    |
| `flags`               | 8      | 8                    |
| `handle`              | 12     | 12                   |
| `buffer`              | **16** | （无，被 `transform` 顶替） |
| `transform`           | 20     | **16**               |
| `blending`            | 24     | **20**               |
| `sourceCrop`          | 28     | **24**               |
| `displayFrame`        | 44     | **40**               |
| `visibleRegionScreen` | 60     | **56**               |
| `acquireFenceFd`      | 68     | **64**               |
| `releaseFenceFd`      | 72     | **68**               |
| `planeAlpha`          | （无）    | 72                   |
| `_pad[3]`             | —      | 73                   |
| `reserved[5]`         | 76     | 76                   |
| **sizeof**            | **96** | **96**               |

后果：

1. **`visibleRegionScreen` 错位最致命**：  
   厂商 HWC 按 4.4.4 读 offset 60，实际落到 7.1 的  
   `visibleRegionScreen.rects`（指针字段）上，  
   于是它把 `numRects` 读成 `rects` 指针，把 `acquireFenceFd`  
   读成下一个 `rects` 指针 —— **拿一个小整数 fd 当指针去解引用**。
2. **`releaseFenceFd` 永远没被正确写**：  
   HWC 写 offset 72（4.4.4 的 `releaseFenceFd`），  
   实际落到 7.1 的 `planeAlpha`/`_pad` 上；  
   而 7.1 真正的 `releaseFenceFd`(68) 是未初始化的垃圾。  
   SF 后续拿这个垃圾 fd 去 `close()` 或者等 fence，行为不可预测。
3. **`sourceCrop` / `displayFrame` 错位**：裁剪和缩放区域整体偏移，  
   表现为花屏或局部撕裂（在没崩的时候）。

### 反汇编佐证

`hwc.orig.so` 的 `hwc_composite_set`（0x74c0）：

```
75e8: movs r3, #96          ; 步长 96 —— 与 7.1 一致，确认不越界
75f0: mla  r6, r3, fp, r7   ; 内部 layer 数组
75f6: mla  r8, r3, r2, r0   ; r8 = 96*i + list
75fc: add.w r8, r8, #20     ; +20 → &hwLayers[i]（与 7.1 的 hwLayers 偏移一致）
760c: str.w r6, [r8, #64]   ; acquireFenceFd @ 64  ← 7.1 偏移
7642: str.w r6, [r8, #68]   ; releaseFenceFd @ 68  ← 7.1 偏移
```

fence 这两个字段居然是按 7.1 偏移写的，说明厂商在 4.4.4 的 blob 里  
可能已经做了部分兼容；但 `visibleRegionScreen` 等其他字段没有，  
所以还是会踩坏内存。

另外 `7562: str r0, [r3, #72]` 是往 **HWC 内部结构**（`disp + 0x624`）  
写 `-1`，不是 SF 的 layer，不要误读。

## 为什么崩一次就永久黑屏

SF 一死，所有客户端（Launcher、SystemUI、Wallpaper）手里的 `Surface`  
背后的 `BufferQueue` 是通过 binder 连到 SF 的。SF 进程没了，这些队列  
就成了孤儿。框架层**没有**"SF 重启了"这个通知 —— 客户端只会在下次  
`dequeueBuffer` 时拿到 `DEAD_OBJECT`，而 `WMS` 不会主动让所有窗口重建 Surface。

结果：窗口层级完好、`dumpsys window` 一切正常、`mCurrentFocus` 有值，  
`dumpsys SurfaceFlinger --list` 也能看到 Layer，但**每个 Layer 都没有 buffer**，  
屏幕上永远黑着。

实测佐证（黑屏时）：

```
flips=639    →    flips=639    →    flips=639      # 三次采样完全不变，SF 停止合成
/proc/<sf>/wchan = SyS_epoll_wait                  # 主线程在等事件，没卡死
screencap 输出 = 10,595 字节                        # 纯黑
```

而且**杀客户端进程让它重建 Surface 也没用** —— 因为 `WMS` 侧的  
`SurfaceControl` 还是旧的，客户端重启只会建出新 Surface，但 WMS 不会  
把它们挂到窗口上。**必须重启 system_server（也就是 zygote）才能恢复。**

## 为什么不能简单恢复 `onrestart restart zygote`

`surfaceflinger.rc` 原本有 `onrestart restart zygote`，看起来正好能解决  
"SF 崩了就重启框架"的问题。但它会触发一个更糟的死循环：

```
SF 崩 → init 重启 SF → onrestart restart zygote
      → init kill(-zygote_pid, SIGKILL) 杀掉整个进程组（system_server 也在里面）
      → 新 zygote fork 新 system_server
      → 新 system_server 启动时，servicemanager 里 activity/window/package
        等 123 个服务条目还指向**已经死掉的旧 system_server**
      → 新 system_server 在 createSystemContext() → ActivityThread.systemMain()
        → ActivityManager.isHighEndGfx() → ActivityThread.hasCodec()
        里 binder 调 media.codec，拿到死 handle
      → DeadObjectException → RemoteException.rethrowFromSystemServer()
      → DeadSystemException → RuntimeInit$UncaughtHandler 杀进程
      → zygote 的 SigChldHandler 发现 system_server 没了，kill(getpid(), SIGKILL)
      → 无限循环，每 5~6 秒一轮
```

**实测**（`setprop ctl.restart zygote`）：

```
[5s]  zygote=8208   ss=        sf=3868
[10s] zygote=9036   ss=        sf=3868
[15s] zygote=9803   ss=        sf=3868
[20s] zygote=10576  ss=        sf=3868
[25s] zygote=11345  ss=        sf=3868
[30s] zygote=        ss=        sf=3868
[35s] zygote=12161  ss=        sf=3868
...
```

`system_server` 从 5 秒到 60 秒**一直是空的**，从来没起来过。  
而 servicemanager 里那 123 个死服务条目就是元凶：

```
$ adb shell service list | grep -E 'activity|window|package|display|power'
77   window: []
97   activity: []
100  package: []
101  display: []
102  power: []
```

所以 `surfaceflinger.rc` 里那行 `onrestart restart zygote` 是**必须禁用的**  
（见 `frameworks/native/services/surfaceflinger/surfaceflinger.rc.patch`）。

## 修法：让 SF 完全不用 HWC 合成 layer

`SurfaceFlinger` 有个隐藏的 binder 命令（`SurfaceFlinger_hwc1.cpp:3290`）：

```cpp
case 1008:  // toggle use of hw composer
    n = data.readInt32();
    mDebugDisableHWC = n ? 1 : 0;
    invalidateHwcGeometry();
    repaintEverything();
    return NO_ERROR;
```

设成 1 之后：

- 所有 layer 的 `compositionType` 被强制成 `HWC_FRAMEBUFFER`；
- 全部由 GPU 用 OpenGL ES 合成到 framebuffer target；
- 厂商 HWC 只需要处理**最后那一个 `FB TARGET` layer**；
- 于是它再也不会去遍历/改写客户端 layer 数组，**堆就不会被踩坏**。

调用方式：

```bash
adb shell service call SurfaceFlinger 1008 i32 1
```

查询当前状态（1010 返回的最后一个 i32 就是 `mDebugDisableHWC`）：

```bash
adb shell service call SurfaceFlinger 1010
# 输出最后 4 字节是 00000001 表示已禁用
```

### 注意：这个开关没有属性入口

7.1 里**没有** `debug.sf.disable_hwc` 这个属性  
（只有 `debug.sf.disable_hwc_vds`，那是 virtual display 用的）。  
`mDebugDisableHWC` 初始化为 0 且不从属性读，所以只能通过 binder 命令设置。

## 时机是关键：必须用 `on post-fs`，不能用 `post-fs-data`

这是本章最关键的一条，实测踩了两次坑：

| 启动时机                               | 触发时刻        | 结果                                |
| ---------------------------------- | ----------- | --------------------------------- |
| `on property:sys.boot_completed=1` | uptime ~45s | **太晚**，SF 已崩                      |
| `on post-fs-data`                  | uptime ~40s | **太晚**，SF 在 44s 崩（pid 269 → 2697） |
| `on post-fs`                       | uptime ~2s  | **刚好**，SF 不崩，66s 自动出桌面            |

实测日志（`on post-fs`）：

```
22:58:21.259  sf_hwc_off: watchdog started
22:58:23.696  sf_hwc_off: disableHWC=1 applied to surfaceflinger pid=271   ← 开机 2.4 秒
```

对比（`on post-fs-data`）：

```
[up=24s] sf=269  hwc=00000000     ← 还没设置
[up=34s] sf=269  hwc=00000000     ← 还没设置
[up=44s] sf=      hwc=            ← SF 正在崩
[up=55s] sf=2697 hwc=00000001     ← 崩完才设置，已经晚了
```

注意**不能用 `on fs`**：那一段里正在执行 `mount_all /fstab.ardbeg`，  
此时 `/system` 还没挂好，`/system/bin/sh` 和脚本本身都还不存在。

### 如果以后发现 `post-fs` 仍然来不及

正解是把 `mDebugDisableHWC` 的初值直接改掉：

```cpp
// SurfaceFlinger_hwc1.cpp:157
mDebugDisableHWC(0),     →     mDebugDisableHWC(1),
```

即二进制 patch `libsurfaceflinger.so` 的构造函数。这样 SF 从第一帧起  
就是纯 GLES 合成，完全不依赖启动时机。

## 不需要注入任何输入事件

中间试过用 `input keyevent` 去"踢"一下让 SF 出帧，结论是**不需要且有副作用**：

- **不需要**：实测 uptime 66 秒桌面就自己渲染出来了（1.85 MB），  
  而注入逻辑最早也要到 `boot_completed + 30s`（约 uptime 75 秒）才动作；
- **有副作用**：
  - `KEYCODE_WAKEUP(224)` 在本机被 `gpio-keys` 映射成**电源键**，  
    会弹出"关机 / 重新启动"的 `GlobalActions` 对话框；
  - 改用 `KEYCODE_DPAD_DOWN(20)` 又会在桌面上移动焦点、误开 `DeskClock`。

所以最终版本**只做诊断记录，绝不注入输入事件**。

### 顺带一个坑：`service check` 的 `not found` 也包含 "found"

```bash
$ adb shell service check SurfaceFlinger
Service SurfaceFlinger: found        # 存在
Service SurfaceFlinger: not found    # 不存在 ← 也含 "found"！
```

所以脚本里必须精确匹配 `'Service SurfaceFlinger: found'`，  
不能只 `grep -q found`，否则会在 SF 还没注册的时候误判为"已就绪"。

## 最终实测数据

2026-11-05 23:15 那次开机（最干净的一次）：

```
[23:16:28] up=39s  sf=244 ss=1634 png=42161B
[23:16:54] up=67s  sf=244 ss=1634 png=52235B    ← 权限对话框（首次启动正常流程）
[23:17:21] up=94s  sf=244 ss=1634 png=52099B
...
[23:20:54] up=307s sf=244 ss=1634 png=52399B    ← 5 分钟内 pid 全程未变
```

2026-11-05 23:09 那次（桌面场景）：

```
[23:10:12] up=39s  sf=261 ss=1669 png=25393B    FallbackHome，启动中
[23:10:40] up=66s  sf=261 ss=1669 png=1854963B  ← 桌面完整渲染
[23:11:07] up=93s  sf=261 ss=1669 png=1847037B
[23:15:07] up=334s sf=261 ss=1669 png=41690B    ← 5.5 分钟零崩溃
```

对比修改前：SF 每 40~100 秒崩一次，崩完永久黑屏。

## 代价与长期正解

**代价**：所有合成都走 GPU，没有硬件 overlay，功耗和带宽会高一些。  
Tegra K1 的 GPU 应付 1080p 桌面合成没有问题，实测操作流畅。

**长期正解**（等能全量编译时再做）：写 `hwcomposer.ardbeg.so` shim，  
在 `prepare`/`set` 里做 4.4.4 ↔ 7.1 的 layer 字段翻译  
（保持 96 字节步长不变，只搬运字段），然后就可以去掉这个脚本、  
恢复硬件合成。字段映射表见本章开头的表格。

## 相关文件

| 文件                           | 作用                                               |
| ---------------------------- | ------------------------------------------------ |
| `initfiles/sf_hwc_off.sh`    | 看门狗脚本本体，装到 `/system/bin/`                        |
| `initfiles/zz-sf-hwc-off.rc` | init 服务定义，`on post-fs` 启动，装到 `/system/etc/init/` |
| `initfiles/Android.mk`       | 模块定义（`EXECUTABLES` / `ETC`）                      |
| `device.mk`                  | `PRODUCT_PACKAGES` 里登记                           |

## 验证命令速查

```bash
# 1. 脚本在不在跑
adb shell getprop init.svc.sf_hwc_off          # 期望 running

# 2. disableHWC 是否生效（最后 4 字节 00000001）
adb shell service call SurfaceFlinger 1010

# 3. SF 是否稳定（pid 应全程不变）
adb shell pidof surfaceflinger

# 4. 屏幕是否有内容（>50KB 为正常，纯黑约 10KB）
adb shell screencap -p /data/local/tmp/s.png
adb shell wc -c < /data/local/tmp/s.png

# 5. 脚本日志
adb logcat -d -s sf_hwc_off

# 6. 有没有新的崩溃
adb logcat -d -b crash | grep -E 'Fatal signal|libsurfaceflinger'
```

---

# SELinux 旁路：让 7.1 用户空间跑在 4.4.4 的策略上（修「设备不启动」）

这是**整套移植里最关键的一块**。没有它，刷完包开机只会看到 Tegra 的 logo，  
adb 能连但 `sys.boot_completed` 永远是空，zygote 无限重启。

## 症状

刷完 `cm_ardbeg_tv-ota-eng.dy.zip` + `boot.img` 后：

```
$ adb shell getprop sys.boot_completed
（空）

$ adb shell ps | grep system_server
（没有）

$ adb logcat -d | tail
E/Zygote  : Exit zygote because system server (11057) has terminated
I/ServiceManager: Waiting for service media.audio_flinger...
```

`init.svc.zygote` 反复 `restarting`，每 5 秒一轮。

## 四层根因

这**不是一个问题，是四个**。修好前一层才会暴露下一层，所以必须一次性全部修掉。

### 第 1 层：`system_server` type 在策略里不存在 → zygote 里 SIGABRT

zygote fork 出 system_server 后调 `selinux_android_setcontext()`，  
（`external/libselinux/src/android.c:905`）：

```c
int selinux_android_setcontext(uid_t uid, bool isSystemServer,
                               const char *seinfo, const char *pkgname)
{
    ...
    if (is_selinux_enabled() <= 0) return 0;        /* ← 914 行，唯一的快路径 */
    ...
    if (isSystemServer) {
        rc = security_check_context("u:r:system_server:s0");
        if (rc < 0) {
            selinux_log(SELINUX_ERROR,
                "selinux_android_setcontext: Error setting context for system server: %s",
                strerror(errno));
            return -1;
        }
    }
```

原厂 `/sepolicy` 的 type 表只有 **307 个**（dmesg：`1 users, 2 roles, 307 types`），  
`system_server` 和 `priv_app` 都**不在里面**（4.4.4 时代 system_server 跑在 `system` 域）。  
`security_check_context()` 返回 `-1 / EINVAL`，然后：

```
E/SELinux: selinux_android_setcontext: Error setting context for system server: Invalid argument
F/art    : JNI FatalError called: com_android_internal_os_Zygote.cpp:631: selinux_android_setcontext failed
F/libc   : Fatal signal 6 (SIGABRT), code -6 in tid 11057 (system_server)
```

### 第 2 层：`service_manager` class 不存在 → 服务注册全被拒

（`frameworks/native/cmds/servicemanager/service_manager.c:83`）

7.1 把 binder 服务的注册权限检查从 `binder` class 拆到了新的 `service_manager` class。  
老策略的 class 表里没有它，`security_compute_av()` 因为 class 查不到直接返回 `-1`：

```
E/SELinux       : Unknown class service_manager
E/ServiceManager: add_service('batterystats',1) uid=1000 - PERMISSION DENIED
E/ServiceManager: add_service('netd',1) uid=0 - PERMISSION DENIED
```

后果是 `BatteryStatsService.publish()` 抛 `SecurityException`：

```
java.lang.SecurityException
    at android.os.ServiceManagerProxy.addService(ServiceManagerNative.java:62)
    at com.android.server.am.BatteryStatsService.publish(BatteryStatsService.java:225)
    at com.android.server.SystemServer.startBootstrapServices(SystemServer.java:462)
FATAL EXCEPTION IN SYSTEM PROCESS
Failed to start service ActivityManagerService$Lifecycle: onStart threw an exception
```

### 第 3 层：`installd` 在 `libselinux.so` 里 SIGSEGV → `/data/user_de/0/` 建不出来

```
pid: 25711, name: installd
signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x4
    #00 pc 0000c612  /system/lib/libselinux.so
    #01 pc 0000b993  /system/lib/libselinux.so
    #02 pc 00004e5b  /system/bin/installd
```

根因是**数据结构不配套**，不是权限：7.1 的 `libselinux` 用新版二进制格式解析  
`file_contexts.bin`，而 ramdisk 里那份是原厂 4.4.4 的（11273 字节）。  
`selabel_open()` 拿到的 handle 里正则/字面量表是空的，`selabel_lookup()`  
解引用空表 → 读 `0x4` 偏移 → SIGSEGV。

installd 一崩，包管理相关目录全建不出来，尤其是 7.1 新引入的 device-encrypted 存储：

```
E/SQLiteLog: (14) os_unix.c:32493: (2) open(
    /data/user_de/0/com.android.providers.settings/databases/settings.db)
```

`(14)` = `SQLITE_CANTOPEN`，`(2)` = `ENOENT`。

> **踩坑记录**：一开始只看到 `SQLiteCantOpenDatabaseException: unknown error (code 14)`，  
> 去查 `/data/data/com.android.providers.settings/` 发现不存在，手动 `mkdir -p`  
> 之后**仍然失败**。直到打开 `SQLiteLog` 才看到真实路径是  
> `/data/user_de/0/...` —— 7.1 把 SettingsProvider 的 db 挪到 device-encrypted  
> 存储了，和 4.4.4 完全不是同一个地方。

### 第 4 层：`audioserver` / `cameraserver` 域不存在 → 服务压根不启动

（`system/core/init/service.cpp:346-390`，`Service::Start()`）

```cpp
if (!seclabel_.empty()) {
    scon = seclabel_;
} else {
    getcon(&mycon);
    getfilecon(args_[0].c_str(), &fcon);
    rc = security_compute_create(mycon, fcon, string_to_security_class("process"), &ret_scon);
    if (rc < 0) {
        ERROR("could not get context while starting '%s'\n", name_.c_str());
        return false;                      /* ← 服务直接不启动 */
    }
}
```

`audioserver` / `cameraserver` 这两个域在 4.4.4 策略里**不存在**  
（那时候音视频全在 `mediaserver` 里，是 6.0 才拆出来的）。于是：

```
init: could not get context while starting 'audioserver'     ← 每 15 秒一条
W/AudioSystem: AudioPolicyService not published, waiting...
```

`AudioPolicyService` 永远等不到，`sys.boot_completed` 永不置 1。

> **注意区分**：`service.cpp:340-345` 的 `cannot find '%s'` 是更早的一道检查  
> （可执行文件不存在），和这里的 `could not get context` 不是一回事。

### 第 5 层：`mediacodec` / `mediaextractor` 同样缺域

和第 4 层一模一样的问题，只是没那么显眼（不影响开机）：

```
init: could not get context while starting 'mediacodec'       ← 每 15 秒一条
init: could not get context while starting 'mediaextractor'
```

`mediacodec.rc` / `mediaextractor.rc` 原版都没有 `seclabel`，而 4.4.4 策略里  
没有这两个域（4.4.4 时代编解码和容器解析全在 `mediaserver` 里，它们是 5.0  
才拆出来的独立进程）。修法同上，加 `seclabel u:r:mediaserver:s0`。

后果是 MediaCodec 的 OMX 服务端和 MediaExtractor 的 binder 服务端都不存在，  
**所有视频播放和媒体文件解析都会失败**。

> 这两个服务在 dmesg 里各刷了 66 条，但因为系统已经起来了，很容易被忽略。

### 第 3.5 层（反面教材）：vold 的 `setenv` 陷阱

这一层不是 SELinux 策略问题，是**我们自己的 rc 写错了**，但因为症状和  
上面几层混在一起，值得单独记一笔。

`vold` 也有 `Failed to setexeccon` → `abort()` 的问题（`ForkExecvp()` 里  
`setexeccon()` 失败就自杀），所以 `vold.rc` 里加了垫片。但加了之后  
**vold 照旧崩**：

```
E vold: Failed to setexeccon
F libc: Fatal signal 6 (SIGABRT), code -6 in tid 25059 (vold)
dmesg : init: Service 'vold' (pid 165) killed by signal 6     ← 每 1~3 分钟一次
```

查 `/proc/<vold>/maps` 发现**垫片根本没加载**，`/proc/<vold>/environ` 里  
也没有 `LD_PRELOAD`。

根因在 `system/core/init/service.cpp:294`：

```cpp
{"setenv",      {2,     2,    &Service::HandleSetenv}},
```

中间两个数字是**参数个数的最小值和最大值**（不含 keyword 本身），都是 2，  
也就是 `setenv NAME VALUE` 恰好 3 个 token。原来写的是

```
setenv LD_PRELOAD /system/lib/libselinux_bypass.so /system/lib/libsetexeccon_shim.so
```

4 个 token → `OptionHandlerMap::FindFunction()` 找不到匹配 →  
`Service::HandleLine()` 报错并**丢弃这一行**。

**最坑的地方**：只丢弃这一行，同一个 service 定义里的  
`class` / `socket` / `ioprio` / `writepid` 全部照常生效。  
所以 `ANDROID_SOCKET_cryptd` 环境变量在、vold 的 socket 也在，  
唯独 `LD_PRELOAD` 静默消失 —— 从 rc 文件本身完全看不出问题。

**结论：一行 `setenv` 只能设一个变量、一个值。**

后果链条：vold 无限重启 → `/data/user_de/` 一直是空的  
（7.1 的 device-encrypted 存储由 vold 建）→ SettingsProvider 的  
`settings.db` 打不开 → U 盘 / SD 卡也全挂不上。

> 教训：rc 里凡是加了 `setenv`，起来后一定要  
> `grep LD_PRELOAD /proc/<pid>/environ` 确认，不能只看 rc 文件。

## 为什么 `androidboot.selinux=permissive` 救不了

permissive 只影响「**已经判定为 deny** 的操作是否真的拦」。  
上面四种失败都不是 deny，而是**决策过程本身出错**（type / class / 域不存在），  
permissive 分支根本走不到。实测 `getenforce` 显示 `Permissive`，  
但 `system_server` 照样 SIGABRT。

## 为什么不能直接关掉 SELinux

`device/nvidia/ardbeg/kernel-config/ardbeg_defconfig`：

```
CONFIG_SECURITY_SELINUX=y
# CONFIG_SECURITY_SELINUX_BOOTPARAM is not set   ← 所以 selinux=0 无效
# CONFIG_SECURITY_SELINUX_DISABLE is not set     ← 运行时也关不掉
```

还试过在 cmdline 加 `lsm=capability`：这个 4.4 内核的 `security_module_enable()`  
不认 `lsm=` 参数，策略照旧加载（dmesg 依旧 `307 types`）。**此路不通。**

## 为什么不能换成 7.1 自己的 sepolicy

7.1 的策略是 `policydb version 30`，本机内核只支持 15-28：

```
SELinux: policydb version 30 does not match my version range 15-28
init: SELinux: Could not load policy: Invalid argument
init: Security failure; rebooting into recovery mode...
```

一加载就重启进 recovery。所以策略只能继续用原厂那份 28 版本的。

## 修法：一个垫片 + 五处挂载

### 垫片本体

`prebuilt/lib/libselinux_bypass.c` → `libselinux_bypass.so`（5512 字节，ARM ELF32 DYN）

覆盖 **10 个** libselinux 入口，全部返回 0：

| 符号                                     | 修哪一层                          |
| -------------------------------------- | ----------------------------- |
| `selinux_android_setcontext`           | 第 1 层（zygote → system_server） |
| `selinux_android_setcon`               | 第 1 层辅助                       |
| `selinux_check_access`                 | 第 2 层（servicemanager）         |
| `selinux_android_restorecon`           | 第 3 层（installd）               |
| `selinux_android_restorecon_pkgdir`    | 第 3 层                         |
| `selinux_android_restorecon_recursive` | 第 3 层                         |
| `security_check_context`               | 兜底                            |
| `setexeccon`                           | vold 兜底（文件级重打包时用）             |
| `is_selinux_enabled`                   | 让调用方走「未启用」快路径                 |
| `security_getenforce`                  | 同上                            |

编译：

```bash
GCC=/home/dy/aosp14/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/bin/arm-linux-androideabi-gcc
$GCC -shared -fPIC -O2 -Wall -nostdlib -nostartfiles \
     -o libselinux_bypass.so libselinux_bypass.c
```

> 必须 `-nostdlib -nostartfiles`：预编译 gcc 没有 `crtbegin_so.o`，也没有 bionic 的  
> `-lc`。垫片本身不调用任何 libc 函数，所以不受影响。
>
> **编译完务必数符号**：  
> `readelf -sW --dyn-syms libselinux_bypass.so | awk '$4=="FUNC" && $7!="UND"' | wc -l`  
> 必须是 **10**。曾经出过一次固化进包的 `.so` 只有 7 个符号（少了三个  
> `restorecon`），包内文件校验全过、大小也对，但刷上去 installd 照样崩 ——  
> 因为第 3 层根本没修。

### 八处挂载

| 补丁                                                              | 挂载点            | 加的东西                                                 |
| --------------------------------------------------------------- | -------------- | ---------------------------------------------------- |
| `system/core/rootdir/init.zygote32.rc.patch`                    | zygote         | `setenv LD_PRELOAD /system/lib/libselinux_bypass.so` |
| `frameworks/native/cmds/servicemanager/servicemanager.rc.patch` | servicemanager | 同上                                                   |
| `frameworks/native/cmds/installd/installd.rc.patch`             | installd       | 同上                                                   |
| `system/vold/vold.rc.patch`                                     | vold           | 同上                                                   |
| `frameworks/av/media/audioserver/audioserver.rc.patch`          | audioserver    | `seclabel u:r:mediaserver:s0`                        |
| `frameworks/av/camera/cameraserver/cameraserver.rc.patch`       | cameraserver   | 同上                                                   |
| `frameworks/av/services/mediacodec/mediacodec.rc.patch`         | mediacodec     | 同上                                                   |
| `frameworks/av/services/mediaextractor/mediaextractor.rc.patch` | mediaextractor | 同上                                                   |

**为什么第 4、5 层不用垫片**：`security_compute_create()` 失败发生在 `exec` **之前**，  
那时候 LD_PRELOAD 还没生效，垫片拦不到。只能在 rc 里写死 `seclabel`，  
让 init 跳过「自动算域」那段代码。

`mediaserver` 域在 4.4.4 策略里**是存在的**（实测 `/system/bin/mediaserver`  
正常起且 dmesg 无 deny），所以借它用。

### 第 6 层：`mediacodec` 起了又崩 —— `libminijail` 的 seccomp

把第 5 层的 `seclabel` 加上之后，`mediacodec` 从「起不来」变成「起来就崩」：

```
W /system/bin/mediacodec: libminijail: allowing syscall: clock_gettime
W /system/bin/mediacodec: libminijail: logging seccomp filter failures
E /system/bin/mediacodec: libminijail: prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER): Invalid argument
F libc                  : Fatal signal 6 (SIGABRT), code -6 in tid (mediacodec)
```

根因：本机 4.4.4 内核没编 `CONFIG_SECCOMP_FILTER`，  
`prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER)` 必然返回 `EINVAL`。

`external/minijail/libminijail.c` 本来有软失败分支（`Android.mk` 加了  
`-DUSE_SECCOMP_SOFTFAIL`）：

```c
if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, j->filter_prog)) {
    if ((errno == EINVAL) && can_softfail()) {
        warn("seccomp not supported");
        return;                                  /* 软失败：不装过滤器，继续跑 */
    }
    pdie("prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER)");   /* abort */
}
```

但 `can_softfail()` 里有一段**内核版本启发式**（认为 3.8+ 的内核一定支持  
seccomp filter），把软失败路径挡住了，于是走 `pdie()` → `abort()`。

修法：用 `tools/patch_minijail.py` 二进制修补 `libminijail.so`，把  
`can_softfail()` 改成恒 `true`。补完之后日志变成

```
W /system/bin/mediacodec: libminijail: seccomp not supported
```

然后正常往下跑。

> **注意补哪个文件**：`mediacodec` 里有一层 `minijail.cpp` 胶水是静态链的，  
> backtrace 看起来崩在 `/system/bin/mediacodec` 本身，但真正的  
> `set_seccomp_filter()` 仍在 `/system/lib/libminijail.so` 里 ——  
> **补 `.so` 就够了**，不用动 mediacodec 二进制。实测补完后  
> 20:33 之后零崩溃，`service list` 里 `media.codec` 和 `media.extractor`  
> 两个 binder 服务都注册成功。

## 实测结果

修复前后对比（同一台机器，同一份包）：

| 指标                                     | 修复前              | 修复后                                |
| -------------------------------------- | ---------------- | ---------------------------------- |
| `sys.boot_completed`                   | 空                | **1**（约 65 秒）                      |
| `init.svc.audioserver`                 | 起不来              | **running**                        |
| `init.svc.cameraserver`                | 起不来              | **running**                        |
| `init.svc.mediacodec`                  | 起不来              | **running**（`media.codec` 已注册）     |
| `init.svc.mediaextractor`              | 起不来              | **running**（`media.extractor` 已注册） |
| `init.svc.installd`                    | 反复 SIGSEGV       | **running**（pid 230 稳定）            |
| `init.svc.vold`                        | 每 1~3 分钟 SIGABRT | **running**（pid 156 稳定，0 次崩溃）      |
| `Failed to setexeccon`                 | 每 1~3 分钟         | **0**                              |
| `/data/user_de/`                       | 空（vold 崩，建不出来）   | **有 `0` 目录**                       |
| `FATAL EXCEPTION IN SYSTEM PROCESS`    | 每轮一次             | **0**                              |
| `Unknown class service_manager`        | 刷屏               | **0**                              |
| `could not get context while starting` | 每 15 秒           | **0**                              |
| tombstones                             | 持续新增             | 停在修复前的 10 个                        |

`mResumedActivity` 走到 `com.cyanogenmod.setupwizard/.SetupWizardActivity`。

## 验证命令速查

```bash
# 1. 是否真的起来了
adb shell getprop sys.boot_completed                  # 期望 1

# 2. 四个关键服务
adb shell 'getprop init.svc.audioserver; getprop init.svc.cameraserver; \
           getprop init.svc.installd; getprop init.svc.zygote'
# 期望全部 running

# 3. 垫片在不在、符号全不全
adb shell ls -l /system/lib/libselinux_bypass.so      # 期望 5512
adb shell 'readelf -sW --dyn-syms /system/lib/libselinux_bypass.so | grep -c FUNC'

# 4. 有没有漏网的 SELinux 错误
adb shell dmesg | grep -E "could not get context|Security failure"
adb logcat -d | grep -E "Unknown class service_manager|selinux_android_setcontext failed"
# 期望全部为空

# 5. installd 是否还在崩
adb shell 'ls /data/tombstones/ | wc -l'              # 数字应不再增长
adb shell 'ls /data/user_de/0/ | wc -l'               # 期望 17 个左右

# 6. 每层各自的挂载点是否生效
adb shell 'grep -l LD_PRELOAD /system/etc/init/servicemanager.rc \
                            /system/etc/init/installd.rc \
                            /init.zygote32.rc'
adb shell 'grep seclabel /system/etc/init/audioserver.rc \
                          /system/etc/init/cameraserver.rc'
```

## 相关文件

| 文件                                  | 作用                                                         |
| ----------------------------------- | ---------------------------------------------------------- |
| `prebuilt/lib/libselinux_bypass.c`  | 垫片源码，头部有完整六层根因注释                                           |
| `prebuilt/lib/libselinux_bypass.so` | 编译产物，5512 字节 / 10 符号                                       |
| `initfiles/init.zygote32.rc`        | 覆盖 AOSP 原版，ramdisk 根目录                                     |
| `initfiles/servicemanager.rc`       | 覆盖 AOSP 原版                                                 |
| `initfiles/installd.rc`             | 覆盖 AOSP 原版（原版只有 3 行）                                       |
| `initfiles/vold.rc`                 | 覆盖 AOSP 原版，多一行 `setenv LD_PRELOAD`                         |
| `initfiles/audioserver.rc`          | 覆盖 AOSP 原版，多一行 `seclabel`                                  |
| `initfiles/cameraserver.rc`         | 同上                                                         |
| `initfiles/mediacodec.rc`           | 同上                                                         |
| `initfiles/mediaextractor.rc`       | 同上                                                         |
| `tools/patch_minijail.py`           | 二进制修补 `libminijail.so` 的 `can_softfail()`                  |
| `tools/libminijail.patched.so`      | 补丁产物，58996 字节，md5 `29f2b8bb...`                            |
| `initfiles/Android.mk` 第 9 节        | 把 `.so` 装到 `$(TARGET_OUT)/lib`                             |
| `device.mk`                         | `PRODUCT_PACKAGES += libselinux_bypass.so`（**必须装，全量编译也要**） |
| `repack/tools/mk_ramdisk4.py` 第 8 步 | 文件级重打包时覆盖 ramdisk 里的 `init.zygote32.rc`                    |
| `repack/tools/apply_overlay.py`     | 文件级重打包时覆盖 `/system` 里那 7 个 rc + 2 个 `.so`                  |

## 代价

- `getenforce` 恒为 `Permissive`，avc 日志里的 `scontext` 会统一显示成 zygote 域 ——  
  调试权限问题时会失真
- 所有进程实际上都没有域隔离，**安全性等同关闭 SELinux**
- 借用了 `mediaserver` 域，`audioserver` 的权限集是 media 那一套（能读音频设备，  
  但它本来也需要）

## 长期正解

换自编内核（把 `policydb` 上限从 28 抬到 30）＋ 7.1 完整 sepolicy，然后：

1. 删掉 5 个 rc 补丁里的 `LD_PRELOAD` / `seclabel`
2. 删掉 `libselinux_bypass.so`（源码一起删）
3. `device.mk` 里去掉 `PRODUCT_PACKAGES`
4. `mk_ramdisk4.py` 第 8 步、`apply_overlay.py` 里对应条目一并清理

在那之前，这个垫片是唯一能开机的手段。

---

# 【2026-11-06 晚】四清专项：SetupWizard / 黑屏 / wifiloader / 清单漏注册

这一节记录「TWRP 四清后重新刷包不启动」的完整排查。结论先说：  
**四清不是原因，是照妖镜**，它把上次开机留下的 `/data` 目录树这层缓冲去掉，  
让本来就在的 SELinux / 内核不兼容问题从偶发崩溃变成必然失败。

## 一、为什么四清后必崩

四清清掉的是 7.1 新引入、4.4.4 时代不存在的东西：  
`/data/user_de/0/<pkg>`（vold 建 `/data/user_de`，installd 建包目录）、  
`/data/misc/profiles/cur/0/<pkg>`、`/data/system/packages.xml`、  
`/data/dalvik-cache/arm/`、`security.selinux` xattr。

链条：

```
四清 → /data/user_de/ 不存在
     → vold 崩（setenv 4 token 被 init 丢弃 → 垫片没挂 → Failed to setexeccon → abort）
     → 目录建不出来 → SettingsProvider 打不开
       /data/user_de/0/com.android.providers.settings/databases/settings.db
       E/SQLiteLog: (14) os_unix.c:32493: (2) ...   ← CANTOPEN + ENOENT
     → system_server 构造失败 → 卡死
```

四清前 `/data/user_de/0/` 已有 85 个包目录，db 文件已经在，所以能起来 ——  
之前「能开机」是假象。

四清特有的第二个坑：`device_provisioned=0` → SetupWizard 启动 →  
缺 `com.google.android.tungsten.setupwraith`（TV 版专用，没进 PRODUCT_PACKAGES）：

```
java.lang.IllegalArgumentException: Unknown package:
    com.google.android.tungsten.setupwraith
  at SetupWizardUtils.disableApplication(SetupWizardUtils.java:294)
  at SetupWizardUtils.disableComponentsForMissingFeatures(...:264)
  at SetupWizardApp.onCreate(SetupWizardApp.java:104)
```

实测崩 40 次以上。dirty flash 时 `device_provisioned=1`，它根本不启动。

## 二、★ 本轮最重要的发现：文件根本没进包 ★

`zz-ardbeg-firstboot-fix.{sh,rc}` 之前只放在 `repack/overlay/` 目录里，  
**既没注册进 `repack/tools/apply_overlay.py` 的 `FILES` 清单，  
也没加进 `device/nvidia/ardbeg/device.mk` 的 `PRODUCT_PACKAGES`**。

- `Android.mk` 只是「声明有这个模块」，不引用就不会安装；
- `FILES` 清单才是决定「进不进 system.img」的地方。

两处一起漏 → 历次 zip 里没有这些文件、设备上 `adb shell ls` 也找不到、  
全量编译同样不会装 → 四清黑屏一直没被真正修掉。  
本轮补齐后 overlay 文件数 36 → 40，`debugfs` 已从还原镜像里核对到全部 4 个文件。

**教训：新增文件必须同时检查「构建侧 PRODUCT_PACKAGES」和  
「重打包侧 apply_overlay.py FILES」，只放进目录等于没做。**

## 三、★ settings 命令的两个坑 ★

1. `/system/bin/settings` 不是原生命令，是  
   `exec app_process /system/bin com.android.commands.settings.SettingsCmd "$@"`。  
   它**写完值不会退出**：`settings get` 打印结果后进程仍挂着，  
   `timeout 12` / `timeout 18` 全是 rc=124。所以每条都必须 timeout 包住，  
   包括 get。
2. app_process 启动 ART VM + 连 SettingsProvider + 写盘要十几秒。  
   实测 `timeout 10 settings put system screen_off_timeout 2147483647`  
   **没生效**，读回来还是 60000；`timeout 30` 才生效。  
   **不要为了加速缩短超时**。脚本里改成 30 秒并分组并行 + `wait`，  
   把 6 条串行 180 秒压到约 60 秒。

## 四、★ 判据陷阱 ★

- 判断 display 不能用 `grep "state OFF"`：`dumpsys display` 里  
  `mOverrideDisplayInfo` 那行可能永远是 `state OFF`，会永远误判。  
  必须只取第一行 `DisplayDeviceInfo`。
- `screencap` 不能用来判断亮屏：`SurfaceFlinger` 的 `DisplayDevice`  
  带 `isSecure=1`（`FLAG_SECURE`），7.1 在 secure display 上 screencap  
  会挂住或返回 10595 字节纯黑 PNG。之前「纯黑 PNG = 黑屏」是被误导。
- `ps -A` / `dumpsys` 在 system_server 死掉时返回空，但  
  `getprop sys.boot_completed` 仍是残留值 1，必须用 `pidof system_server`。

## 五、display 点亮的唯一可靠开关

本机 `/sys/class/backlight/` 是空的（内核没注册 pwm-backlight），  
LightsService 写不进背光，DisplayPowerController 卡在等「亮度已设置」的确认。

实测：`input keyevent 224`（WAKEUP）只把 `mWakefulness` 改成 Awake，  
**display 仍是 OFF**；执行 `settings put system screen_brightness 255`  
后 `dumpsys display` 立刻从 `state OFF` → `state ON`。  
只有 SettingsProvider 的 `onBrightnessChanged` 能触发 DPC 重新评估。  
写同一个值不算变化，所以守护用 254/255 交替。

配套：`screen_off_timeout=2147483647`（默认 60000，1 分钟就睡）、  
`stay_on_while_plugged_in=7`、`lockscreen.disabled=1`。

## 六、Trebuchet / SystemUI 会死，必须常驻守护

实机 logcat：

```
F/libc (25846): Fatal signal 6 (SIGABRT) ... tid 2357 (RenderThread)
E/ActivityManager: ANR in com.android.systemui
I/ActivityManager: Process com.android.systemui (pid 1429) has died
I/ActivityManager: Process com.cyanogenmod.trebuchet (pid 25846) has died
```

4.4.4 的 NVIDIA GL/HWC 与 7.1 的 hwui/RenderThread 不兼容。死后 AMS 里  
残留 Launcher 的 `ActivityRecord`、SF 里只剩僵尸 `KeyguardScrim` 图层，  
系统判定「HOME 已在前台」所以不会自恢复 → 全黑且永不恢复。  
所以一次性拉起不够，新增 `ardbeg_homewd` 每 15 秒 `pidof` 巡检 +  
display OFF 时重新点亮（90 秒冷却）。

## 七、`wifiloader` 每 5 秒重启

`init.comms.rc` 的 `service wifiloader` 缺 `oneshot`，`wifi_loader.sh`  
写完 `commchip_id` 就 `exit 0`，init 当异常退出立刻重拉：

```
init: Service 'wifiloader' (pid 1322) exited with status 0
init: Starting service 'wifiloader'...
```

实测开机 20 分钟累计 990 条日志（含 254+ 条  
`Service wifiloader does not have a SELinux domain defined.`）。  
`init.comms.rc` 在 ramdisk，`apply_overlay.py` 覆盖不到，  
本轮给 `mk_ramdisk4.py` 加第 9 步用设备树版本覆盖，已验证包内  
boot 的 `init.comms.rc:129` 是 `oneshot`。

## 八、遗留：KeyguardScrim 残留遮罩

开机后 WMS 里只有 `KeyguardScrim` 一个窗口  
（`ty=2029`、`mSession=Session{... 1519:1000}` → owner 是 system_server，  
不是 SystemUI），Launcher 的 `hasBeenVisible=false`，窗口从未被添加：

```
W/KeyguardServiceDelegate: onScreenTurningOn(): no keyguard service!
E/ActivityManager: ANR in com.android.systemui ... bg anr
V/KeyguardServiceDelegate: *** Keyguard disconnected (boo!)
W/WindowManager: Keyguard drawn timeout. Setting mKeyguardDrawComplete
```

开机早期 SystemUI ANR → KeyguardService 断连 → `screenTurningOn` 回调链  
不完整 → 黑遮罩不移除。已验证 `wm dismiss-keyguard`、MENU/上滑、  
POWER 睡醒循环、`am force-stop com.android.systemui` 都无效；  
`stop; start` 重启 framework 在本机**不可靠**（会卡到 system_server 为空），  
不能作为自动修复手段。三个 provisioning 值（1/1/1）都正确。

推测新包禁用 SetupWizard 后，40 次崩溃带来的 AMS 负载消失，  
干净四清首次开机时 SystemUI 不再 ANR，遮罩可能不会重现 ——  
需要实机四清验证。

`lmkd` 也起不来（`init.svc.lmkd` 空、`/dev/socket/lmkd` 不存在、  
手动跑 `/system/bin/lmkd` 立刻退出）。旧内核有内核态 lowmemorykiller  
驱动，AMS 降级写 `oom_score_adj`，功能没丢，只刷 warning。  
**不要手工拉起 lmkd**：rc 带 `critical`，反复崩溃会触发 reboot。

## 九、本轮改动落点

| 文件                                     | 改动                                           |
| -------------------------------------- | -------------------------------------------- |
| `initfiles/zz-ardbeg-firstboot-fix.sh` | 重写：并行 settings、显式 HOME 组件、多轮 display 确认、修正判据 |
| `initfiles/zz-ardbeg-home-watchdog.sh` | 新增，常驻 15s 巡检                                 |
| `initfiles/zz-ardbeg-home-watchdog.rc` | 新增，服务名 `ardbeg_homewd`（13 字符，7.1 限 <=16）     |
| `initfiles/zz-ardbeg-firstboot-fix.rc` | oneshot，`class late_start`                   |
| `initfiles/init.comms.rc`              | `wifiloader` 加 `oneshot`                     |
| `initfiles/Android.mk`                 | 5.5 / 5.6 节注册 4 个模块                          |
| `device.mk`                            | 新增 `PRODUCT_PACKAGES +=` 四清专项块               |
| `repack/tools/apply_overlay.py`        | `FILES` 补 4 个条目                              |
| `repack/tools/mk_ramdisk4.py`          | 新增第 9 步覆盖 `init.comms.rc`                    |

产物：`dist/allfix-1106-2115/`，zip md5 `aa83238ded230e321e2e370903f7cdac`，  
boot md5 `9aa6a27985baad70637aee30752fd134`。

---

## 十、【2026-11-06 深夜】黑屏根因终结 + 补丁集成核查

### 10.1 用户问「调试后有没有把补丁集成到设备树」——逐项核查结论

| 检查项                                                      | 结果                                                 |
| -------------------------------------------------------- | -------------------------------------------------- |
| `patches/` 下 `.patch` 总数                                 | **41**（22 个 cm14.1 活跃 + 19 个 `legacy-cm11/` 历史）    |
| `check.sh`（在源码根 `/home/dy/aosp14` 执行）                    | 共 22 个：**可应用 0 / 已应用 22 / 有问题 0**                  |
| `file-modes.txt`                                         | 1 项已修（`vendor/cm/prebuilt/common/bin/sysinit` 755） |
| `check.sh` / `install.sh` / `uninstall.sh` / `README.md` | 均存在、脚本可执行                                          |
| 本次调试的新修复是否已进设备树                                          | **核查时：没有**，全部只是设备上的临时 `setprop` / `settings put`   |

**必须区分两个不同层次的「集成」，之前混在一起了：**

1. **补丁文本应用到 AOSP 源码** —— 已完成、全绿（`check.sh` 22/22）。
2. **补丁的编译产物进入刷机包** —— **这里断了**：  
   `frameworks/native/opengl/libs/EGL/egl_display.cpp.patch` 已应用到源码  
   （`egl_display.cpp:157` 已是 `if (cnx->dso)`），但 `out/` 被清空后编译产物  
   没有重新生成，`repack/tools/apply_overlay.py` 的 `FILES` 里也没有  
   `libEGL.so`。设备上 `/system/lib/libEGL.so` 仍是旧版  
   **md5 `3cd50337aeb9aa2220b5007f786cf8bc` / 104084 字节**（AOSP EGL loader），  
   而 vendor 里原厂 4.4.4 的实现是 **332608 字节 / `623f4e93...`**。  
   也就是说这个补丁**从未真正进包**，这正是 `EGL_BAD_DISPLAY` 至今仍在的原因。

### 10.2 黑屏的三层根因（tombstone + dumpsys 实测）

```
tombstone_02:
  pid 9669 tid 10722 name RenderThread >>> com.cyanogenmod.trebuchet
  Abort message: 'Failed to choose config, error = EGL_BAD_DISPLAY'
  #06 libhwui.so ... #13 RenderThread::threadLoop
  maps: /system/vendor/lib/libEGL_tegra_impl.so   ← 原厂 4.4.4 驱动
```

1. **`persist.sys.ui.hw=1`（我们自己设备树 `lineage_tv.mk:52` 写的）**  
   → `Window.java:755` 让每个 app 窗口强制走 HWUI/RenderThread  
   → 老 Tegra EGL 驱动用线程局部存储存 display，7.1 的 RenderThread 在  
   另一个线程 `eglGetDisplay` → `eglChooseConfig` 返回 `EGL_BAD_DISPLAY`  
   → SystemUI / Trebuchet / Settings / Email 反复 SIGABRT。
2. **SystemUI 一死 → `KeyguardScrim` 永不撤**  
   `PhoneWindowManager.removeWindowLw()`（3409-3435）在状态栏窗口被移除时  
   调 `mKeyguardDelegate.showScrim()`；  
   `KeyguardServiceDelegate.onScreenTurningOn()`（290-303）在  
   `mKeyguardService == null` 时也 `showScrim()` + 打  
   `onScreenTurningOn(): no keyguard service!`。  
   而 `hideScrim()` 只有 `KeyguardShowDelegate.onDrawn()`（100）和  
   `bindService()` 返回 false（149）两个入口 → keyguard 画不出来就永远不撤。  
   实测 `dumpsys window policy`：`deviceHasKeyguard=true / enabled=false / showing=true`，  
   logcat 刷 `Screen frozen for +4s911ms due to Window{... KeyguardScrim}`，  
   WMS 把 Launcher 窗口压成 `mViewVisibility=0x4 / mObscured=true`。
3. **窗口淡入动画卡住 → SF layer alpha 恒为 `0x00`**  
   `dumpsys SurfaceFlinger` 里 `ImageWallpaper` 与  
   `Starting com.cyanogenmod.trebuchet` 两个 layer 的 alpha 都是 `0x00`，  
   即使窗口已 VISIBLE，合成出来仍是全黑。

### 10.3 三把钥匙与实测效果

| 钥匙                     | 落点                                                            |
| ---------------------- | ------------------------------------------------------------- |
| `persist.sys.ui.hw=0`  | `lineage_tv.mk`、`overlay/system/build.prop`、首启脚本 `setprop` 兜底 |
| 不禁用 `KeyguardService`  | 关掉硬加速后 SystemUI 不再崩，`onDrawn()` 能回调，scrim 自己变 GONE            |
| 三个 `animation_scale=0` | `zz-ardbeg-firstboot-fix.sh` 第 4b 步（`timeout 30`）             |

实测重启后：

```
KeyguardScrim  mViewVisibility=0x8 (GONE)   mHasSurface=false
dumpsys window policy: deviceHasKeyguard=false / showing=false / screenState=2
Launcher 窗口 mViewVisibility 0x4 -> 0x0, mHaveFrame false -> true
SF layers: ImageWallpaper / Starting trebuchet alpha 0x00 -> 0xff
SystemUI 与 Trebuchet 不再 SIGABRT
```

**注意**：`screencap` 依然不可信 —— `DisplayDeviceInfo` 带 `FLAG_SECURE`  
（isSecure=1），secure display 上固定返回 10595 字节纯黑 PNG。  
判据要用 `dumpsys window windows` 的 `mViewVisibility` 和  
`dumpsys SurfaceFlinger` 的 layer alpha。

### 10.4 本轮改动落点

| 文件                                     | 改动                                                                                     |
| -------------------------------------- | -------------------------------------------------------------------------------------- |
| `lineage_tv.mk`                        | `persist.sys.ui.hw` 1 → 0，附完整根因注释                                                      |
| `repack/overlay/system/build.prop`     | 同步 1 → 0                                                                               |
| `initfiles/zz-ardbeg-firstboot-fix.sh` | 头部新增「问题 4」；第 0 步 `setprop`；第 4b 步三个 animation scale；第 8 步 `launcher_visible()` 窗口可见性确认 |
| `initfiles/zz-ardbeg-home-watchdog.sh` | 头部新增第三职责；新增 `launcher_visible()`；循环第 3 步按窗口可见性兜底（共用 90s 冷却）                            |
| `repack/tools/apply_overlay.py`        | build.prop 加说明；**预留** `libEGL.so` 条目（注释状态，附恢复步骤）                                       |
| `device.mk` / `initfiles/Android.mk`   | 无需改：4 个模块的 `PRODUCT_PACKAGES` 上轮已注册，本次只改文件内容                                           |

**本轮没有新增 AOSP 源码补丁**（改动全在设备树 / 产品配置 / 脚本层），  
所以 `check.sh` 仍是 22/22，`install.sh` / `uninstall.sh` 无需变动。

### 10.5 遗留

- 恢复全量编译后，把 `out/target/product/ardbeg/system/lib/libEGL.so`  
  拷进 overlay 并取消 `apply_overlay.py` 里预留条目的注释，  
  **才谈得上把 `persist.sys.ui.hw` 改回 1 做性能验证**。
- 四清后首次开机（TWRP 四清 + 刷本轮新包）仍需用户最终确认。
- `mCurrentFocus=null` / Launcher `mHasSurface=false` 在验证时仍偶见，  
  但窗口已 VISIBLE、layer alpha=0xff，属于启动窗口尚未撤下的过渡态。

> 上面 10.5 的第一条**已在下一节解决**：不再等全量编译，  
> 改用等价二进制补丁产物直接集成。

---

## 十一、【2026-11-06 深夜补完】把 EGL 补丁真正集成进设备树与刷机包

### 11.1 这次修的是「集成缺口」，不是新 bug

10.4 里 `apply_overlay.py` 只留了一行**注释状态**的 `libEGL.so` 条目，  
写着「恢复全量编译后再启用」。结果就是：

```
check.sh                     22/22 全绿（源码补丁确实已应用）
设备上 /system/lib/libEGL.so  md5 3cd50337... （原版，补丁根本没进包）
logcat                       仍有 EGL_BAD_DISPLAY，Trebuchet 反复 SIGABRT
dumpsys window               mCurrentFocus=null
```

根因链：**`out/` 目录整个不存在** → 早前尝试的  
`mmm frameworks/native/opengl/libs/EGL` 单模块编译直接失败、没有任何产物  
→ 而后续所有 ROM 都是「解 `system.img` → 只换改动文件 → 重新打包签名」，  
这条链路只认 `repack/overlay/` 下的现成文件，不会去编译 `libEGL`。  
所以「源码补丁应用了」和「修复进了 ROM」是两件事，之前只做了前半件。

### 11.2 解决方案：二进制补丁产物收编为设备树正式 prebuilt

调试阶段那份 `egl-fix/patch_libegl.py` 早已验证过等价性  
（`EGL_BAD_DISPLAY` 122 → 0、`screencap` 从纯黑变成能渲染开机动画、  
`boot_completed=1` 进入 Trebuchet）。它把  
`egl_display.cpp.patch` 去掉的那条 `cbnz r0, a3ec`  
在机器码层面改成 `nop`，二者语义完全一致。现在把它正式收编：

| 角色        | 路径                                    | md5 / 说明                                             |
| --------- | ------------------------------------- | ---------------------------------------------------- |
| 原始基准      | `patches/tools/libEGL.orig.so`        | `3cd50337aeb9aa2220b5007f786cf8bc`，104084 B          |
| 补丁工具      | `patches/tools/patch_libegl.py`       | ELF `PT_LOAD` 换算 + 上下文校验，只改 0xA3C8 两字节 `80b9 → 00bf` |
| **设备树真源** | `prebuilt/lib/libEGL.so`              | **`4ac10584321c81f8dcddd21a025bced6`**，104084 B      |
| 打包侧副本     | `repack/overlay/system/lib/libEGL.so` | 必须与真源 md5 一致                                         |
| 全量编译路径    | `egl_display.cpp.patch`               | 仍保留；`install.sh` 应用后由 AOSP 自己编出等价结果                  |

`file` 校验两份都是 `ELF 32-bit LSB shared object, ARM, EABI5,
for Android 25`，BuildID 相同，只有那 2 字节不同 —— 不是拿别的版本混进来的。

### 11.3 登记点（缺一处就不会进包，这是本项目踩过两次的坑）

1. **`repack/tools/apply_overlay.py` 的 `FILES` 表**：把原来注释掉的  
   `('/lib/libEGL.so', 'lib/libEGL.so', 0o100644)` 正式启用，  
   并在生成 debugfs 命令时强制校验 md5，防止误放原版。  
   同时 `write` 会自动补 `mode 0644` / `uid 0` / `gid 0` /  
   `security.selinux=u:object_r:system_file:s0`。
2. **`patches/check.sh`**：新增「二进制补丁产物核验」段，  
   同时检查设备树真源与 repack 副本的 md5，不一致就把 `N_BAD` 加一、  
   让 `check.sh` 以非零退出。以后 `check.sh` 不再只报「补丁是否应用」，  
   还会报「修复是否真的在待打包文件里」。
3. **`device.mk` 第二十三节**：写清两条出包路径与配套修复，并加  
   **构建期断言**：若 `egl_display.cpp` 里仍存在生效的  
   `if (cnx->dso && disp.dpy == EGL_NO_DISPLAY)` 代码行就 `$(warning)`。
   - 断言用 `^[[:space:]]*if` 锚定代码行，因为补丁自带注释里也写了  
     这串文字，朴素 `grep` 会误判成「未打补丁」（实测踩到过）。
   - 模式里不用圆括号，否则 make 会把 `)` 当 `$(shell ...)` 的结束符。
   - 路径是 `$(LOCAL_PATH)/../../../frameworks/...`（三级回到源码根），  
     写四级会指到源码树外、断言永远不生效。
4. **刻意不写 `PRODUCT_COPY_FILES`**：`system/lib/libEGL.so` 已由 AOSP 的  
   `libEGL` 模块产出，加进去会被 build/core 静默  
   `"PRODUCT_COPY_FILES ... ignored"` 丢弃（`audio_effects.conf` 踩过同款坑）。  
   全量编译靠源码补丁、文件级重打包靠 `FILES` 表，两条路各自登记。

### 11.4 配套修复（EGL 补丁不能单独上）

| 依赖                                   | 原因                                                                                                                                                                          |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sf_hwc_off.sh` + `zz-sf-hwc-off.rc` | 第 1359 行写明 EGL 补丁是「放大器」：GPU 合成变频繁会暴露 4.4.4 hwcomposer 与 7.1 `hwc_layer_1_t` 布局不符的越界释放。守护用 `service call SurfaceFlinger 1008 i32 1` 关掉 HWC 合成走 GLES。**不要为了压 SF 崩溃回退 EGL 补丁** |
| `persist.sys.ui.hw=0`                | 关掉属性强制硬件加速；但 `Window.java:755` 是 `hardwareAccelerated \|\| 属性`，app 自己声明硬加速时仍会起 RenderThread，所以它只是缓解、不是根治                                                                    |
| 三个 `animation_scale=0`               | 避免窗口淡入把 SF layer alpha 卡在 `0x00`                                                                                                                                            |
| 废弃 `persist.sys.force_sw_gles=1`     | 实测本机无 software GLES，SurfaceFlinger 每 5 秒 `couldn't find an OpenGL ES implementation` 崩溃、`boot_completed` 为空，已回滚                                                             |

### 11.5 复现与自检命令

```sh
cd device/nvidia/ardbeg/patches

# 1) 从基准重新生成补丁产物（原地改 libEGL.orig.so，之后再拷出来）
python3 tools/patch_libegl.py tools/libEGL.orig.so
cp tools/libEGL.orig.so ../prebuilt/lib/libEGL.so
cp tools/libEGL.orig.so "/home/dy/WorkBuddy AI/ardbeg-cm-14.1/repack/overlay/system/lib/libEGL.so"

# 2) ELF 级确认补丁点（输出「已经是打过补丁的状态」）
python3 tools/patch_libegl.py ../prebuilt/lib/libEGL.so --check

# 3) 总检查：22 个源码补丁 + 两份二进制产物
./check.sh
```

### 11.6 遗留

- `persist.sys.ui.hw` 目前仍固定为 0（稳定优先）。EGL 修复进包之后才具备  
  把它改回 1 做性能验证的条件，但必须先实测 SF/HWC 稳定性，不要盲改。
- 四清 + 刷最终包的首次开机仍需用户确认。
- 若将来恢复全量编译，`prebuilt/lib/libEGL.so` 与 overlay 副本可以删掉，  
  只保留源码补丁；但 `check.sh` 里对应的核验段也要同步改成校验  
  `out/target/product/ardbeg/system/lib/libEGL.so`。

### 11.7 同轮实机验证：EGL 修复生效，抓出第二个黑屏源

把 `prebuilt/lib/libEGL.so` 推到设备  
（`/system` remount rw → `cat > .new` → `chmod 644` → `chcon` → `mv -f`  
原子替换，避免覆盖正在被 mmap 的旧 inode），清空 logcat 后重启：

```
boot_completed=1（16 轮 ×3s）
EGL_BAD_DISPLAY          : 0        <- 修复前近 3000 行有 5 次
F DEBUG / tombstone      : 0
system_server=1466  sf=230  systemui / trebuchet 均在
persist.sys.ui.hw=0  / 三个 animation_scale=0
init.svc.sf_hwc_off=running  init.svc.ardbeg_homewd=running
init.svc.wifiloader=stopped
某个稳定时刻：mCurrentFocus=Window{... Launcher}
              mViewVisibility=0x0  mHasSurface=true
              isReadyForDisplay()=true，SF 出现 Trebuchet layer（alpha 0xff）
```

**但桌面仍会被反复重拉**，日志显示与 EGL 完全无关的第二条链：

```
22:27:56 ANR SystemUI            (TIME_TICK 广播)
22:28:06 ANR weatherservice      (executing service)
22:28:18 ANR printspooler
22:28:33 ANR android.process.media (USB_STATE 广播)
22:29:42 ANR Trebuchet           (Input dispatching timed out, wait queue 77)
22:29:43 ANR SystemUI            (TIME_TICK 广播)
  -> AMS "Force finishing activity ...Launcher"
  -> ardbeg_homewd "launcher dead -> am start"
```

`grep -al screencap /proc/[0-9]*/cmdline` 抓到  
`/proc/4612/cmdline = /system/bin/screencap -p /data/local/tmp/.sf_hwc_off_chk.png`  
从 22:28 挂到 22:32 都不返回，`timeout 3` 也杀不掉；连带  
`am broadcast MEDIA_SCANNER_SCAN_FILE` 一起卡住。来源是  
`initfiles/sf_hwc_off.sh` 的 `do_screen_diag_async()`（boot_completed+90s  
调用一次 `screencap -p` 用截图体积判断亮屏）。本机  
`DisplayDeviceInfo` 带 `FLAG_SECURE / isSecure=1`，而  
`zz-ardbeg-firstboot-fix.sh:61` 和 `zz-ardbeg-home-watchdog.sh:55`  
**早就写了「secure display 上 screencap 会挂住」** —— 注释和代码自相矛盾。

挂死的 screencap 占住 SurfaceFlinger 客户端连接 → system_server 的  
WindowManager 拿不到 SF 锁 → binder 事务排队 → 全局 ANR。

**A/B 验证**：`kill -9` 掉所有挂住的 screencap 后观察 60 秒，  
ANR 计数保持 6 不再增长（EGL_BAD_DISPLAY 始终 0）。

**修复（已固化）**：删除 `check_screen()` / `do_screen_diag_async()`  
以及主循环前的调用，脚本现在只保留「盯 SF pid 变化就重设  
`service call SurfaceFlinger 1008 i32 1`」。窗口可见性判断交给  
`zz-ardbeg-home-watchdog.sh` 的 `launcher_visible()`  
（读 `dumpsys window windows`，不碰 secure display 像素）。  
设备树 `initfiles/sf_hwc_off.sh` 与  
`repack/overlay/system/bin/sf_hwc_off.sh` 已同步为同一份  
（9507 字节 / md5 `f1223c35f9d7ea3706d74cbe83a4a24b`），  
`apply_overlay.py` 对应条目也补了说明。

> 当时记下的遗留：22:34 观察到一次 framework 整体重启（Netd 重新启动、  
> `sys.boot_completed=1` 残留但 `pidof system_server` 为空），  
> 与早前 `/data/anr/traces_SystemServer_WDT*.txt` 指向的  
> **system_server Watchdog** 同源，与 EGL / screencap 两条链相互独立。
>
> **这个遗留项已在下一章定位并修复**，根因既不是 EGL、也不是  
> KeyguardScrim，而是 `lmkd` 服务因 `lmkd_exec` 域缺失起不来，导致  
> `ProcessList.writeLmkd()` 在 AMS 大锁里 sleep。详见「十二、」。

---

# 十二、【2026-11-06 深夜补完】Watchdog 杀 system_server：lmkd 缺失 → AMS 持锁 sleep

> 这一章解决的是 11.7 结尾记下的**唯一遗留项**：开机后一段时间突然  
> framework 整体重启 / 黑屏。它和 EGL、screencap、KeyguardScrim  
> **三条链全都无关**，是独立的第四条。

## 12.1 症状与取证

设备在线、`sys.boot_completed=1`、`pidof system_server` 非空，  
但 `/data/anr/` 里有两份 `traces_SystemServer_WDT*.txt`：

```
-rw-rw-rw- system system 571508 2026-11-06 21:54 traces_SystemServer_WDT06_11月_21_54_18.340.txt
-rw-rw-rw- system system 562617 2026-11-06 22:31 traces_SystemServer_WDT06_11月_22_31_58.632.txt
-rw-rw-rw- system system  25601 2026-11-06 22:40 traces.txt
```

把 22:31 那份拉下来分析。**先记一个判据陷阱**：设备上的 toybox `grep`  
不支持 BRE 的 `\|` alternation，  
`grep -n "import\|lmkd\|class_start" /init.rc` 会返回空，  
一度让我误判成「`/init.rc` 没有 import、init 不会扫 `/system/etc/init`」。  
必须用 `grep -E` 或逐个单模式 `grep -c`。这个项目已经因为  
「screencap 纯黑 PNG」「display 判据取错行」踩过两次同类坑，  
这次是第三次 —— **任何"没有找到"的结论都要换一种判据复核**。

## 12.2 WDT trace 现场：AMS 大锁被一个 sleep 占住

第一次 dump（第 2594 行起）：

```
"Binder:1466_6" prio=5 tid=80 Sleeping
  at java.lang.Thread.sleep!(Native method)
  at com.android.server.am.ProcessList.writeLmkd(ProcessList.java:723)
  at com.android.server.am.ProcessList.setOomAdj(ProcessList.java:683)
  at com.android.server.am.ActivityManagerService.applyOomAdjLocked(...)
  at com.android.server.am.ActivityManagerService.attachApplication(...)
  - locked <0x0eb155e3> (a com.android.server.am.ActivityManagerService)

"main"            tid=1  Blocked
"android.display" tid=18 Blocked
"android.ui"      tid=12 Blocked
"ActivityManager" tid=11 Blocked
    - waiting to lock <0x0eb155e3> ... held by thread 80
```

`android.display` 的具体卡点是  
`ActivityManagerService$LocalService.notifyStartingWindowDrawn`  
← `WindowManagerService$H.handleMessage(WindowManagerService.java:8971)`。

第二次 dump（第 3398 行起）换成 tid=11 持锁，**仍然卡在 writeLmkd**，  
只是路径变成 `remove()` ← `handleAppDiedLocked()` ←  
`removeProcessLocked()` ← `processContentProviderPublishTimedOutLocked()`。

> 注意：这次 `android.display` 是 `Blocked`（Java monitor 等待），  
> **不是** README 前面「libinputservice.so SpriteController fence 死等」  
> 那章里的 `Native` + `Fence::waitForever` + `sync_wait`。  
> 两章的 Watchdog 现场完全不同，不要用旧补丁去套。

## 12.3 根因链

`frameworks/base/services/core/java/com/android/server/am/ProcessList.java`：

```java
private static void writeLmkd(ByteBuffer buf) {
    for (int i = 0; i < 3; i++) {
        if (sLmkdSocket == null) {
            if (openLmkdSocket() == false) {
                try { Thread.sleep(1000); } catch (InterruptedException ie) {}
                continue;
            }
        }
        sLmkdOutputStream.write(buf.array(), 0, buf.position());
        return;
    }
}
```

`openLmkdSocket()` 连 `/dev/socket/lmkd`。本机实测：

```
getprop init.svc.lmkd     -> (空)
pidof lmkd                -> (空)
ls /dev/socket/           -> 有 adbd/vold/netd/zygote/... 唯独没有 lmkd
```

于是**每一次** `setOomAdj()` / `remove()` 都要在 **AMS 大锁里睡 3 秒**。  
开机阶段 app 频繁 attach / die / content provider timeout，  
这些调用排队累积，轻松超过 Watchdog 的 30s 首次 dump + 30s 判死窗口：

```
四清后开机 -> lmkd socket 不存在
  -> writeLmkd 每次持 AMS 锁 sleep 3s
  -> main / android.display / android.ui 全部 Blocked
  -> Watchdog 30s dump + 30s 判死 -> SIGKILL system_server
  -> zygote / netd 重启、桌面重载、黑屏
```

这也**推翻了 README 第 3490 行附近早前的结论**  
「lmkd 起不来但内核态 lowmemorykiller 在，AMS 降级写 oom_score_adj，  
功能没丢；不要手工拉起」。降级路径根本没有，  
`writeLmkd` 失败就是失败，而且失败代价是拖死整个 system_server。

## 12.4 `/dev/socket/lmkd` 为什么不存在的实锤

dmesg（用 `grep -E` 取）：

```
init: (Parsing /system/etc/init/lmkd.rc took 0.00s.)
...
SELinux:  Context u:object_r:lmkd_exec:s0 is not valid (left unmapped).
```

`/system/etc/init/` **确实被 7.1 init 完整解析了**（`atrace.rc` 到  
`zz-usb-storage-mount.rc` 逐条都有 Parsing 日志，`keystore.rc` 的服务  
也确实 running）。`lmkd.rc` 被解析，但 7.1 的 `lmkd_exec` 域在原厂  
4.4.4 的 `/sepolicy` 里不存在（那份 policy 只有  
307 types / 84 classes / policyvers 28），init 在启动服务前做  
`security_compute_create()` 就失败，**连 execve 都没走到**，  
服务属性是空的、socket 也没被创建。

这跟本项目 `audioserver` / `cameraserver` / `mediacodec` /  
`mediaextractor` 的「7.1 新 SELinux 域不存在」是**同一条根因链**，  
只是这一次受害者换成了 `class core` 的 lmkd。

### 纠正一处旧误判

旧笔记写「手动跑 `/system/bin/lmkd` 立刻退出，所以内核不支持」。  
手工运行没有 init 为服务注入的 `ANDROID_SOCKET_lmkd` fd，  
`system/core/lmkd/lmkd.c` 的 `init()` 里：

```c
ctrl_lfd = android_get_control_socket("lmkd");
if (ctrl_lfd < 0) { ALOGE("get lmkd control socket failed"); return -1; }
```

必然返回 -1 → `main()` 里 `if (!init()) mainloop();` 不成立 → 直接退出。  
这只能说明「没在 init 服务环境里」，不能说明二进制或内核有问题。

本机跑 lmkd 的条件其实齐全：

```
/dev/memcg/                                      完整（含 memory.pressure_level
                                                 / cgroup.event_control）
/sys/module/lowmemorykiller/parameters/minfree  存在且 root 可写
                                                内容 1536,2048,4096,16384
```

所以 `use_inkernel_interface = !access(INKERNEL_MINFREE_PATH, W_OK)` 为真，  
`init()` 连 `init_mp()` 都不进，走的是最老最稳的内核态 lowmemorykiller  
接口。问题从头到尾只在 SELinux 域。

## 12.5 为什么不改 `ProcessList.java` 去掉 sleep

- 那是 AOSP 的设计（socket 短暂不可用时退避重试），  
  改它要重编 `services.jar`；
- 本机 `out/` 已清空、所有 ROM 都走「解 system.img → 只换改动文件 →  
  重新打包签名」的文件级重打包，改 Java **落不了地**，  
  只会再制造一个「check.sh 全绿但产物没进 ROM」的假修复 ——  
  `egl_display.cpp.patch` 已经踩过一次（见第十一章）；
- 把 lmkd 服务修好之后 socket 一直连通，sleep 分支根本不会进。

**治本点在 rc，不在 framework Java。**

## 12.6 修法：给 lmkd 加 seclabel

`device/nvidia/ardbeg/initfiles/lmkd.rc` 是唯一真源（8174 字节，  
带完整中文注释）。有效服务段：

```ini
service lmkd /system/bin/lmkd
    class core
    user root
    group root
    seclabel u:r:mediaserver:s0
    socket lmkd seqpacket 0660 system system
    writepid /dev/cpuset/system-background/tasks
```

相对 AOSP 原版 `system/core/lmkd/lmkd.rc`（176 字节）三处差异：

| 改动                                     | 理由                                                                                                                                                                 |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 加 `seclabel u:r:mediaserver:s0`        | 绕开 init 对 `lmkd_exec` 的计算。设备树里另外 4 个 7.1 新服务已经用这个域并实机验证 running；本机 SELinux 是 permissive（`androidboot.selinux=permissive`），域不 enforce，关键是 context 字符串必须在 policy 里有效 |
| 去掉 `group root readproc` 里的 `readproc` | 7.1 bionic `android_ids` 没有 readproc，本机 `/system/etc/group` 也不存在，`decode_uid()` 会给出无效 gid，`setgroups()` 可能让服务启动失败                                                  |
| 去掉 `critical`                          | critical 服务反复崩溃会触发 init reboot，而本机 recovery 是 4.4.4 ramdisk，进去就再也加载不了 7.1 `/system`，等于变砖。lmkd 挂掉只影响 OOM 调节                                                         |

另加 `user root`（AOSP 靠默认值，显式写出便于核对）。  
`socket` / `writepid` 保持原样：`/dev/cpuset/system-background/tasks`  
确实存在，其它 core 服务的 socket 也都用不带 socketcon 的写法。

> 关于重复定义：ramdisk 的 `/init.rc` 先解析，`/system/etc/init/`  
> 后解析；7.1 init 遇到同名 service 会打  
> `ignored duplicate definition of service` 并忽略后者。  
> 本次**只改 `/system/etc/init/lmkd.rc` 这一份**，不动 ramdisk，  
> 因此不存在重复，也不需要改 `mk_ramdisk4.py`。

## 12.7 固化清单（缺一条就会「看着修好了其实没修」）

| # | 位置                                       | 作用                                                                                             |
| - | ---------------------------------------- | ---------------------------------------------------------------------------------------------- |
| 1 | `patches/system/core/lmkd/lmkd.rc.patch` | AOSP 源码补丁，**全量编译路径**。`check.sh` 已从 22 → 23 个补丁并全绿                                              |
| 2 | `device/nvidia/ardbeg/initfiles/lmkd.rc` | 设备树唯一真源，带完整根因注释                                                                                |
| 3 | `system/core/lmkd/lmkd.rc`               | 源码树当前内容，与真源 md5 一致                                                                             |
| 4 | `repack/overlay/system/etc/init/lmkd.rc` | **文件级重打包路径**的实物                                                                                |
| 5 | `repack/tools/apply_overlay.py` `FILES`  | 决定文件是否真的写进 `system.img`。已加 `('/etc/init/lmkd.rc', 'etc/init/lmkd.rc', 0o100644)`，打包文件数 41 → 42 |
| 6 | `apply_overlay.py` `main()` 硬校验          | 与设备树真源 md5 一致 + 有效行必须含 `seclabel` + 不含 `critical` / `group root readproc`。防原版 rc 混入            |
| 7 | `patches/check.sh`                       | 新增「lmkd 服务定义」核验段，同时校验真源 / 源码树 / overlay 三处 md5                                                 |
| 8 | `device.mk` 第二十四节                        | 全量编译侧的集成说明与构建期断言                                                                               |

> 注意第 6/7 条里的语义校验必须**只取有效行**（去掉 `#` 注释行）：  
> 设备树那份长注释里就写着 `critical` / `readproc` 这两个词，  
> 朴素 `grep` 会把修复版误判成原版。这是 `device.mk` 里 EGL 断言  
> 踩过的同一个坑，换了个形式又出现一次。

## 12.8 验证口径

打包侧（往返校验）：

```
debugfs -R "cat /etc/init/lmkd.rc" system.img
  -> 8174 字节 / md5 4635029e48b1ef36190332742188bf65
  -> 有效行含 seclabel u:r:mediaserver:s0
```

实机侧（重启后）：

```
getprop init.svc.lmkd                    -> running
ls -l /dev/socket/lmkd                   -> srw-rw---- system system
logcat                                   -> 无 "lowmemorykiller daemon socket open failed"
dmesg                                    -> 无 "Context u:object_r:lmkd_exec:s0 is not valid"
连续观察 ≥10 分钟：无新增 traces_SystemServer_WDT*.txt
pidof system_server 全程不变
```

### 12.8.1 实机验证结果（2026-11-06 22:53 重启后）

```
init.svc.lmkd                = running
pidof lmkd                   = 215
/dev/socket/lmkd             = srw-rw---- system system
sys.boot_completed           = 1（27 秒）
pidof system_server          = 1438
logcat "lowmemorykiller daemon socket open failed" 计数 = 0
logcat "SLOW OOM ADJ" / "WATCHDOG KILLING"        = 无
/data/anr/ 无新增 traces_SystemServer_WDT*.txt
dmesg: init: Starting service 'lmkd'...
```

**两个不要误判的残留日志**：

1. `SELinux: Context u:object_r:lmkd_exec:s0 is not valid (left unmapped)`  
   **仍会出现**。这是 init 在 `/system` 挂载后对 `/system/bin/lmkd`  
   做 restorecon 打文件标签时的告警，不是服务启动判断。  
   服务已经靠 `seclabel` 显式指定了域，紧接着的  
   `init: Starting service 'lmkd'...` 才是指标。
2. 一批 `avc: denied { entrypoint / read / open / getattr }`  
   `scontext=u:r:mediaserver:s0`。本机 cmdline 是  
   `androidboot.selinux=permissive`，只审计不 enforce，功能不受影响；  
   设备树里另外 4 个 7.1 新服务也是同样待遇。  
   若将来换成自带 7.1 policy 的内核并切 enforcing，  
   应把 seclabel 换成真正的 `u:r:lmkd:s0` 并补 policy，  
   而不是继续借 mediaserver 域。

## 12.9 与整体根因链的关系

到目前为止四清后不启动/黑屏可以归纳成**四条独立的链**，  
彼此叠加才让现象看起来像"随机黑屏"：

1. **SELinux 六层**（`/sepolicy` 是 4.4.4 的）→ vold / installd /  
   servicemanager / audioserver / mediacodec 起不来 → 四清后首启失败；
2. **EGL / HWUI**（`libEGL_tegra_impl.so` 的 display 放 TLS）→  
   RenderThread `EGL_BAD_DISPLAY` → app 全崩 → `KeyguardScrim` 常驻；
3. **screencap 挂死**（`FLAG_SECURE` display）→ 占住 SF 连接 →  
   全局 ANR → 桌面被反复重拉；
4. **lmkd 域缺失**（本章）→ `writeLmkd` 持 AMS 锁 sleep →  
   Watchdog 杀 system_server → framework 整体重启。

前三条已在前面各章固化，本章补上第四条。

---

# 十三、【2026-11-06 深夜补完】OTA 包缺 `install/` 目录 —— 一次「看着像致命 bug」的误判与最终补齐

## 13.1 怎么发现的

准备做「四清 + 刷最终包」端到端验证时，先枚举了最终包  
`dist/lmkdfix-1106-2255/cm_ardbeg_tv-ota-eng.dy.zip` 的条目，发现只有  
**14 个**，其中**没有 `install/` 目录**。但 `updater-script` 前 30 行里  
明明白白引用了它：

```edify
package_extract_dir("install", "/tmp/install");
set_metadata_recursive("/tmp/install", "uid", 0, "gid", 0, "dmode", 0755, "fmode", 0644);
set_metadata_recursive("/tmp/install/bin", "uid", 0, "gid", 0, "dmode", 0755, "fmode", 0755);
mount("ext4", "EMMC", ".../by-name/APP", "/system", "");
run_program("/tmp/install/bin/backuptool.sh", "backup");
...
run_program("/tmp/install/bin/otasigcheck.sh") != "31744" ||
    abort("Can't install this package on top of incompatible data...");
...
run_program("/tmp/install/bin/backuptool.sh", "restore");
```

顺着查了 `dist/` 下**全部 15 个历史包**，全是 14 条目、全都没有  
`install/`，源头是模板包 `tv-1104-1728` 本身就没带。而源码树里这三个脚本  
是齐的：

```
/home/dy/aosp14/vendor/cm/prebuilt/common/bin/backuptool.sh
/home/dy/aosp14/vendor/cm/prebuilt/common/bin/backuptool.functions
/home/dy/aosp14/vendor/cm/prebuilt/common/bin/otasigcheck.sh
```

`vendor/cm/config/common.mk:39-47` 也用 `PRODUCT_COPY_FILES` 把它们声明成  
`install/bin/*`：

```makefile
PRODUCT_COPY_FILES += \
    vendor/cm/prebuilt/common/bin/backuptool.sh:install/bin/backuptool.sh \
    vendor/cm/prebuilt/common/bin/backuptool.functions:install/bin/backuptool.functions \
    vendor/cm/prebuilt/common/bin/50-cm.sh:system/addon.d/50-cm.sh \
    vendor/cm/prebuilt/common/bin/blacklist:system/addon.d/blacklist
...
PRODUCT_COPY_FILES += \
    vendor/cm/prebuilt/common/bin/otasigcheck.sh:install/bin/otasigcheck.sh
```

`updater-script` 里那行也不是手写的，来自  
`build/tools/releasetools/edify_generator.py:171`。

## 13.2 第一反应是「所有包都刷不进去」—— 查源码后发现判反了

直觉上：`run_program` 找不到脚本 → 返回非 0 → `!= "31744"` 为真 →  
`||` 右边不管怎样…… 这里最容易把 edify 的 `||` 当成 C 的「或运算 +  
布尔结果」。实际上 `||` 是**短路运算符**：

```
a || b     a 为真 -> 整个表达式为真，b 不执行
           a 为假 -> 执行 b
```

`abort()` 在**右边**。所以只有 `run_program(...) != "31744"` 为**假**、  
也就是返回值恰好等于 `31744` 时，才会执行 abort。

再看 `bootable/recovery/updater/install.cpp:1309` 的 `RunProgramFn`：

```cpp
pid_t child = fork();
if (child == 0) {
    execv(args2[0], args2);
    printf("run_program: execv failed: %s\n", strerror(errno));
    _exit(1);                       // exec 失败
}
int status;
waitpid(child, &status, 0);
...
sprintf(buffer, "%d", status);      // 注意：返回的是**原始 wait status**
return StringValue(strdup(buffer));
```

- 脚本缺失：`_exit(1)` → `WEXITSTATUS=1` → `status = 1 << 8 = 256` → `"256"`  
  → `!= "31744"` 为真 → **abort 被短路跳过**。
- 脚本存在但判定签名不兼容：`otasigcheck.sh` 末尾 `exit 124` →  
  `status = 124 << 8 = 31744` → `"31744"` → 左值为假 → **执行 abort**。

`31744` 这个魔法数就是这么来的。

顺带也排除了另一个疑点：`set_metadata_recursive("/tmp/install", ...)`  
在 `install.cpp:926` 里对目标 `lstat` 失败会 `ErrorAbort()`，但 TWRP 的  
`package_extract_dir` 会把目标目录建出来（哪怕一个条目都没匹配上），  
所以这一步没炸 —— 实机日志也证明流程走到了后面的 `block_image_update`。

## 13.3 实机日志坐实

从设备拉回 `/cache/recovery/last_log`（TWRP 3.1.1-raphaelcfrajuca），  
里面完整记录了一次刷本工程 OTA 的过程：

```
I:Update binary zip
Target: nvidia/cm_ardbeg_tv/ardbeg:7.1.2/NJH47F/eng.dy.20261104.172145:eng/test-keys
detected filesystem ext4 for /dev/block/platform/sdhci-tegra.3/by-name/APP
about to run program [/tmp/install/bin/backuptool.sh] with 2 args
run_program: execv failed: No such file or directory
run_program: child exited with status 1
about to run program [/tmp/install/bin/otasigcheck.sh] with 1 args
run_program: execv failed: No such file or directory
run_program: child exited with status 1
Patching system image unconditionally...
performing update
 erasing 586752 blocks
wrote 199680 blocks; expected 199680
bytes_written_APP: 817889280
about to run program [/tmp/install/bin/backuptool.sh] with 2 args
run_program: execv failed: No such file or directory
script succeeded: result was [1.000000]I:Updater process ended with RC=0
I:Install took 36 second(s).
```

**结论：`install/` 缺失不会让刷包失败**，刷包实测 RC=0、36 秒、  
写入 817889280 字节，system 分区是被正常重写的。所以历史上  
「四清后刷入包不启动」的根因仍然是前面四章那四条链（SELinux /  
EGL / screencap / lmkd），**不是刷包失败**。这一条务必记牢，  
否则会把排查方向带偏到 recovery 上。

## 13.4 但缺失确实丢功能，必须补齐

1. 每次刷包在 TWRP 日志里刷 4 行 `execv failed`，容易掩盖真正的错误；
2. `backuptool.sh` 的 `backup` / `restore` 完全没跑，addon.d 机制失效  
   —— 设备上 `/system/addon.d/` 里确实有 `50-cm.sh` 和 `blacklist`，  
   将来装 GApps / su / 其它 addon.d 脚本时，刷包会把它们全冲掉；
3. `otasigcheck.sh` 没跑，跨 ROM 签名兼容性检查形同虚设。

## 13.5 补齐方式

改 `repack/tools/mkzip.py`：照抄模板条目之后，从  
`/home/dy/aosp14/vendor/cm/prebuilt/common/bin/` 追加三个条目：

| zip 内路径                            | 权限   | 用途                       |
| ---------------------------------- | ---- | ------------------------ |
| `install/bin/backuptool.sh`        | 0755 | addon.d backup / restore |
| `install/bin/backuptool.functions` | 0644 | addon.d 脚本依赖的函数库         |
| `install/bin/otasigcheck.sh`       | 0755 | 检查已装系统是否与本包同签名           |

实现要点（都写在 `mkzip.py` 的长注释里）：

- 时间戳固定 `2008-08-01`，与 `mzExtractRecursive()` 默认时间戳一致，  
  避免不同机器打出来的包因 mtime 而 md5 漂移；
- `create_system=3`（UNIX）+ `external_attr` 显式写权限，否则 recovery  
  解出来的文件可能没有可执行位（`updater-script` 第 6 行的  
  `set_metadata_recursive("/tmp/install/bin", ..., "fmode", 0755)` 也会兜一次）；
- 用 `ZIP_DEFLATED`，不引入 zip64；
- **签名不受影响**：`sign_ota.py` 是 whole-file 签名，覆盖 unsigned.zip  
  除末 2 字节外的全部字节，新条目自动落在签名范围内；TWRP 日志里  
  「跳过 Digest 校验：未找到 Digest 文件」也说明本机不看  
  `MANIFEST.MF` / `CERT.SF` 的条目摘要，无需重算 JAR 清单。

`repack/make_ota.sh` 头部补「例外 3」说明，避免以后有人看到 17 个条目  
以为是打包脚本写错了。

## 13.6 补齐后的安全性（四清场景）

- `otasigcheck.sh`：开头先 `grep -q "Command:.*--wipe_data"` 检查  
  `/tmp/recovery.log`，四清后即便是走 GUI 不带这个标记，  
  `/data/system/packages.xml` 也不存在，整个签名比对块被跳过，  
  末尾 `exit 0` → wait status `0` → `!= "31744"` → **不 abort**；
- `backuptool.sh`：四清后 `/system/build.prop` 不存在，  
  `check_prereq()` 直接 `return 0`，最坏情况是脚本 `exit 127`；  
  但 `updater-script` 第 8 / 25 行是独立语句、**没有**把返回值接  
  `|| abort(...)`，所以不会中止刷入；
- 因此补齐是纯增益，不引入新的 abort 路径。

## 13.7 验证口径

新包生成后必须复核：

```
zipfile.namelist() 里 install/bin/ 三条齐全
三条的 external_attr 解出来是 0100755 / 0100644 / 0100755
zip entries = 17（原 14 + 新增 3）
sign_ota.py 自检 OK、openssl 验签 OK、testzip() is None
原有 14 个条目的内容 / md5 与 lmkdfix-1106-2255 完全一致
```

以及实机 TWRP 日志里 `execv failed` 计数应从 4 降到 0。

## 13.8 实机验证结果与 TWRP 3.1.1 的 PATH 细节

用 `installfix-1106-2309` 在 TWRP 里做四清 + 安装，日志实测：

```
I:operation_start: 'OpenRecoveryScript'
I:command is: 'install'
Installing zip file '/cache/cm_ardbeg_tv-ota-eng.dy.zip'
about to run program [/tmp/install/bin/backuptool.sh] with 2 args
/tmp/install/bin/backuptool.sh[11]: cp: not found
run_program: child exited with status 127
about to run program [/tmp/install/bin/otasigcheck.sh] with 1 args
/tmp/install/bin/otasigcheck.sh[6]: grep: not found
/tmp/install/bin/otasigcheck.sh[12]: grep: not found
wrote 199680 blocks; expected 199680
bytes_written_APP: 817889280
about to run program [/tmp/install/bin/backuptool.sh] with 2 args
Not backing up files from incompatible version: 14.1
run_program: child exited with status 127
script succeeded: result was [1.000000]I:Updater process ended with RC=0
I:Install took 29 second(s).
```

- `execv failed` 计数 **4 → 0** ✓（补齐生效，脚本确实被找到并执行了）
- `Updater process ended with RC=0` ✓，刷包 29 秒成功
- 但多了 `cp: not found` / `grep: not found`

**原因**：TWRP 3.1.1 里 `run_program` 的 PATH 是

```
/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin
```

`/sbin` 只有 `adbd / healthd / ueventd / usb_mtp_default.sh / watchdogd`  
五个条目，**没有 busybox**；`cp` / `grep` / `sh` 全是 `/system/bin/toybox`  
的符号链接。四清之后 `/system` 是空的，所以 `backup` 阶段（install 之前）  
那两个脚本拿不到工具；到了 `restore` 阶段 `/system` 已经写好，日志里  
就能看到 `Not backing up files from incompatible version: 14.1` 正常输出了。

**影响评估（为什么不再折腾）**：

1. `otasigcheck.sh` 的 `grep` 失败只是让两处 `--wipe_data` / `--headless`  
   快速跳过失效，后面 `/data/system/packages.xml` 在四清后不存在，  
   签名比对整块被跳过，末尾仍然 `exit 0` → 不 abort；
2. `backuptool.sh` 的 `cp` 失败影响的是 `backuptool.functions` 的拷贝，  
   但四清后 `/system/addon.d/` 也不存在，本来就没有可备份的东西；  
   `restore` 阶段脚本自己判断版本不匹配后主动返回；
3. 两处 `run_program` 的返回值 updater-script 都没接 `|| abort(...)`，  
   所以 `exit 127` 完全不影响刷入。

**如果将来要让 addon.d 真正生效**（例如要刷 GApps / su 后仍能跨 OTA 保留），  
需要额外做：往 `install/bin/` 塞一个静态 busybox，或把  
`backuptool.sh` / `otasigcheck.sh` 改成调用 OTA 自带的工具绝对路径。  
本项目是自用 eng ROM、四清刷入，当前行为足够，不引入这个复杂度。

---

# 十四、【2026-11-06 收官】TWRP 四清 → 刷最终包 → 冷启动的端到端验证

前面十三章修的都是「某个具体 bug」。本章要回答的是一个更关键的问题：

> **这些修复到底有没有真的进刷机包？四清之后还能不能自己站起来？**

## 14.1 为什么非做这一轮不可

本项目长期在「调试态」工作：发现一个文件有问题就 `adb push` 一个修正版，  
重启看效果。这条路快，但会系统性地骗人：

- `/data/user_de/0/<pkg>`、`/data/misc/profiles/cur/0/<pkg>`、  
  `/data/system/packages.xml`、`/data/dalvik-cache/arm/`、  
  `security.selinux` xattr 全都还在，SELinux / installd 的问题被缓存掩盖；
- 手工推入的文件会一直留在 `/system`，和刷机包里那份**不是同一个字节**。

最典型的证据是两版 `libselinux_bypass.so`：设备上是调试期临时推入的  
`de312353...`，包里是 `8652d544...`。两者同为 5512 字节、10 个导出符号，  
`.text` / `.rodata` 逐字节一致（差异 328 字节只在 `.dynsym` / `.dynstr` /  
`.hash` 的符号串顺序，同一源码重复链接），功能等价但 md5 不同。  
只要不四清，就永远发现不了设备跑的根本不是包里的文件。

所以闭环判据只有一条：**TWRP 四清 → 从 `/cache` 刷入最终 OTA 包 →  
冷启动 → 设备里每个关键文件的 md5 都等于包里的 md5，且运行时一条根因日志都没有。**

## 14.2 最终交付包

| 项                      | 值                                                                                            |
| ---------------------- | -------------------------------------------------------------------------------------------- |
| 路径                     | `ardbeg-cm-14.1/dist/installfix-1106-2309/cm_ardbeg_tv-ota-eng.dy.zip`                       |
| 大小                     | 395977044 字节                                                                                 |
| md5                    | `d0230a1d9797186b306c2fd4eae0fd9c`                                                           |
| `boot.img`             | 8597504 字节 / md5 `9aa6a27985baad70637aee30752fd134`                                          |
| `system.transfer.list` | 4031 字节                                                                                      |
| zip 条目                 | **17**（原 14 + `install/bin/` 三条）                                                             |
| 校验                     | `e2fsck -f -y` rc=0、`zipfile.testzip()=None`、openssl whole-file 验签 OK、`otacert` 与签名证书规范化比对一致 |

相对上一包 `lmkdfix-1106-2255`（395974470 字节 /  
`c8c71a642fde91cb2c534d0e9112eac8`）只多了三个 `install/bin/` 条目，  
其余 14 个条目内容 / md5 完全一致，`boot.img` 也没动。

**OTA 往返校验**：从签名 zip 解出 `system.new.dat` / `system.transfer.list` /  
`boot.img` / `system/build.prop`，用 `otablocks.py unpack` 还原 `system.img`，  
`e2fsck` 干净，`debugfs -R "cat ..."` 回读 `libEGL.so`、`lmkd.rc`、  
`sf_hwc_off.sh`、`libselinux_bypass.so`、`libminijail.so`、首启脚本、  
home watchdog、`build.prop`（第 201 行 `persist.sys.ui.hw=0`）；  
boot ramdisk 解包确认 `wifiloader oneshot`、`init.zygote32.rc LD_PRELOAD`、  
`fstab.ardbeg` 齐全。全部 md5 / 权限 / 语义断言通过。

## 14.3 两阶段 OpenRecoveryScript

**不能一阶段做完**：四清会清掉 `/cache` 和 `/data`，如果先把 zip 放进去再四清，  
包自己就没了；放 `/sdcard` 也一样（`/data/media` 一起被清）。

TWRP 3.1.1-raphaelcfrajuca，分区 LNX=p9 / APP=p10 / CAC=p11 / UDA=p21，  
`/cache` 744 MB（可用 702 MB），396 MB 的包放得下。

阶段 1 —— `ors-stage1.txt`：

```
wipe dalvik
wipe system
wipe data
wipe cache
```

`OpenRecoveryScript` 日志明确记录四次 wipe。wipe 之后 `/system/bin/sh`  
不存在，`adb shell` 报  
`error: exec '/system/bin/sh' failed: No such file or directory`。

> **这不是掉线、不是变砖。** `adb push/pull` 仍然可以访问 `/cache`。  
> 此时千万不要 `adb kill-server`——历史上在沙箱里杀掉宿主 adb server  
> 导致过 5037 refused，恢复起来很麻烦。

阶段 2 —— 先 `adb push` zip 到 `/cache/cm_ardbeg_tv-ota-eng.dy.zip`，  
pull 回来校验 md5 完全一致（`d0230a1d...`），再写 `ors-stage2.txt`：

```
install /cache/cm_ardbeg_tv-ota-eng.dy.zip
```

重启进 TWRP 执行安装。

## 14.4 安装结果

`/cache/recovery/last_log` 实测：

```
about to run program [/tmp/install/bin/backuptool.sh] with 2 args
/tmp/install/bin/backuptool.sh[11]: cp: not found
about to run program [/tmp/install/bin/otasigcheck.sh] with 1 args
/tmp/install/bin/otasigcheck.sh[6]: grep: not found
wrote 199680 blocks; expected 199680
bytes_written_APP: 817889280
about to run program [/tmp/install/bin/backuptool.sh] with 2 args
Not backing up files from incompatible version: 14.1
script succeeded: result was [1.000000]
I:Updater process ended with RC=0
I:Install took 29 second(s).
```

- `execv failed` 计数 **4 → 0**，`install/` 补齐生效，脚本确实被找到并执行；
- `Updater process ended with RC=0`，29 秒刷完；
- `cp: not found` / `grep: not found` 是 13.8 已经查清的 TWRP PATH 问题  
  （`/sbin` 没 busybox，`cp/grep` 来自 `/system/bin/toybox`，四清后 `/system` 为空），  
  四清场景这些脚本本应 no-op，返回值没接 `|| abort`，不影响刷入；
- `restore` 阶段 `/system` 已刷入，所以能正常打印  
  `Not backing up files from incompatible version: 14.1`。

## 14.5 首次冷启动

约 30 秒 `sys.boot_completed=1`，`system_server=1434`。logcat 里只有 **1 条**  
transient：

```
E/libEGL validate_display:99 error 3008 (EGL_BAD_DISPLAY)
```

没有 `Failed to choose config`、没有 tombstone、没有 ANR。  
这一条是开机早期某次 display 初始化竞态，**不等于黑屏链复发**；  
判据是「有没有走到 `eglChooseConfig` 并 SIGABRT」，而不是「字符串出现过」。  
第二次重启 + 静置 120 秒后该计数彻底为 0（见 14.8）。

## 14.6 验收工具收编时挖出的四个「假绿 / 假红」陷阱

调试期的临时验收脚本 `work/flash-final-2255/verify_after_boot.sh` 只打印、  
不判定，而且先后踩了四个坑。正式收编到  
`device/nvidia/ardbeg/tools/verify_after_boot.sh` 时全部修掉并写进头部注释：

1. **adb 路径含空格**：写成 `S="$A shell"` 再用 `$S` 展开会被切碎成  
   `/home/dy/WorkBuddy: 没有那个文件或目录`。改成 shell 函数  
   `S() { "$A" shell "$@"; }`。
2. **logcat 塞进 shell 变量**：`L=$(logcat -d -v brief)` 再 `printf "%s\n" "$L"`  
   触发 `/system/bin/printf: Argument list too long`，grep 拿到空输入，  
   **所有关键字都返回 0 = 假绿**。正确做法是先落盘  
   `logcat -d -v brief > /data/local/tmp/verify_logcat.txt`，确认 `wc -l > 0`  
   再逐项 grep。
3. **toybox grep 的 `-A` / `-B` 遇 `-m1` 会丢上下文行**：  
   `grep -A14 -m1 "Launcher" | grep mViewVisibility` 只输出匹配行本身，  
   永远拿不到可见性。而且原始 `dumpsys window windows` 里 `Window #` 和  
   `mViewVisibility` 中间隔了一大堆别的信息。正确做法是先  
   `grep -E "Window #|mViewVisibility="` 压成「标题 + 可见性」两行一组，  
   再在紧凑列表上用**不带 `-m`** 的 `grep -B1 "mViewVisibility=0x0"` 反查。
4. **设备侧输出 `@key=value`，本地却按 `^key=` 取**：  
   37 项判定全部取到空值，显示一屏假 FAIL。改成 `grep -m1 "^@$1="`。  
   用 `@` 前缀本是为了避免误命中 logcat / dumpsys 残留文本里长得像  
   `key=` 的行，结果自己忘了补上。

另外两个老坑也一并固化在工具里：`grep -c` 为 0 时退出码是 1（一律  
`|| true`）、设备 toybox `grep` 不支持 BRE 的 `\|`（一律 `grep -E`）。

## 14.7 `KeyguardScrim` 计数 2 不是两个遮罩窗口

`dumpsys window windows | grep -c "KeyguardScrim"` 返回 2，曾经被当成  
「两个遮罩还在」。实际是一行 `Window{... KeyguardScrim}` 加一行  
`WindowStateAnimator{... KeyguardScrim}`，同一个窗口。  
真正的判据永远是 `mViewVisibility`。

最终四清开机后的窗口紧凑列表（关键行）：

```
Window #8 ... KeyguardScrim:
    mViewVisibility=0x8 mHaveFrame=true mObscured=false      <- GONE
Window #4 ... com.cyanogenmod.trebuchet/...Launcher}:
    mViewVisibility=0x0 mHaveFrame=true mObscured=false      <- 可见、没被遮
Window #1 ... com.cyanogenmod.trebuchet/...Launcher}:
    mViewVisibility=0x8 ...                                   <- 旧的那个已隐藏
Window #0 ... com.android.systemui.ImageWallpaper}:
    mViewVisibility=0x0 ...
```

`mResumedActivity` = `com.cyanogenmod.trebuchet/com.android.launcher3.Launcher`，  
`DisplayDeviceInfo` 里 `state ON`、`FLAG_SECURE`。  
注意这块屏是 secure，**绝对不要用 `screencap` 判断亮屏**  
（`sf_hwc_off.sh` 的 `check_screen()` 就是这么挂住 SurfaceFlinger 并引发全局  
ANR 的，已删除）。

## 14.8 二次重启 + 静置 120 秒稳定性复核

```
sys.boot_completed      = 1
system_server           = 1450
lmkd                    = 212
init.svc.lmkd           = running
init.svc.ardbeg_homewd  = running
init.svc.fb_fix         = stopped      (oneshot)
init.svc.wifiloader     = stopped      (oneshot)
persist.sys.ui.hw       = 0
display                 = state ON
mResumedActivity        = Trebuchet Launcher
WDT trace / anr / tombstone = 0 / 0 / 0
logcat lines            = 14374
```

八个根因关键字全部为 0：

```
EGL_BAD_DISPLAY                             0
Failed to choose config                     0
WATCHDOG KILLING                            0
SLOW OOM ADJ                                0
lowmemorykiller daemon socket open failed   0
Failed to setexeccon                        0
Unknown package                             0
could not get context                       0
```

## 14.9 文件级 / 分区级一致性

设备里 7 个关键文件的 md5 与 `installfix-1106-2309` 的 OTA 往返校验结果  
逐字节一致（这也证明调试期那版 `de312353...` 的  
`libselinux_bypass.so` 已被四清彻底清掉）：

```
4ac10584321c81f8dcddd21a025bced6  /system/lib/libEGL.so
4635029e48b1ef36190332742188bf65  /system/etc/init/lmkd.rc
f1223c35f9d7ea3706d74cbe83a4a24b  /system/bin/sf_hwc_off.sh
8652d544f226ee8de7127f30dca2fff1  /system/lib/libselinux_bypass.so
29f2b8bb047cac7473cb1b77e3a21a14  /system/lib/libminijail.so
fb4043dea6d6d42d3da50b2597104bf0  /system/bin/zz-ardbeg-firstboot-fix.sh
3833dfaf28b1e2dbb54a6d810ee1813d  /system/bin/zz-ardbeg-home-watchdog.sh
```

boot 分区回读（`8597504 / 4096 = 2099`，正好整除，一次 dd 搞定）：

```sh
adb shell 'dd if=/dev/block/mmcblk0p9 bs=4096 count=2099 2>/dev/null | md5sum'
# 9aa6a27985baad70637aee30752fd134  -
```

与包内 `boot.img` 的 md5 完全一致，说明 ramdisk 里的  
`wifiloader oneshot` / `init.zygote32.rc LD_PRELOAD` 也确实刷进去了。

## 14.10 正式收编到设备树的改动

| 文件                           | 改动                                                                                                                        |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `tools/verify_after_boot.sh` | **新增**。37 项 PASS/FAIL 自动判定，含期望 md5 表、属性、logcat 关键字、窗口可见性、ANR/tombstone、TWRP 日志、boot 分区回读；`bash -n` 通过，退出码 0/1/2           |
| `patches/check.sh`           | 新增两段：「刷机后验收工具」核验（关键判据在、无 `screencap -p`、有可执行位）、「最终 OTA 包产物」核验（最新 dist 包的 17 条目 / 签名件 / `persist.sys.ui.hw=0` / `testzip`） |
| `patches/README.md`          | 本章                                                                                                                        |
| `repack/tools/mkzip.py`      | `EXTRA_ENTRIES` 追加 `install/bin/` 三条（第十三章）                                                                                |
| `repack/make_ota.sh`         | 头部「例外 3」说明（第十三章）                                                                                                          |

`check.sh` 现在的输出是：

```
共 23 个补丁：可应用 0 / 已应用 23 / 有问题 0
文件权限修复：待修 0 / 已修 1
二进制补丁产物（libEGL）：2 处 [已修]
lmkd 服务定义：3 处 [已修]
OTA 打包完整性（install/）：3 条 [已修]
刷机后验收工具：[已修] 37 项 PASS/FAIL 自动判定
最终 OTA 包产物：最新包 395977044 字节 / d0230a1d... / 17 条目 [已修]
```

验收脚本实跑结果：**PASS = 37 / FAIL = 0，退出码 0**，  
输出留档 `work/flash-final-2255/verify-final-37pass.txt`。

## 14.11 剩余已知限制（不藏着）

- **内核仍是原厂 4.4.4 预编译 kernel**：没有 `CONFIG_SECCOMP_FILTER`，靠  
  `libminijail.so` 的 softfail 二进制补丁绕过；`/sepolicy` 仍是 4.4.4 的  
  `307 types / 84 classes / 3023 rules / policyvers=28`，靠  
  `libselinux_bypass.so` + 各 rc 的 `seclabel u:r:mediaserver:s0` 绕过。  
  也就是说**这不是真正 enforcing 的 7.1 SELinux**，是 eng ROM 的兼容方案。
- **没有做全量编译**：`out/` 被清空后，`mmm frameworks/native/opengl/libs/EGL`  
  也没有产物，因此 `libEGL.so` 用的是调试期验证过的**等价二进制补丁产物**  
  （只改 `0xA3C8` 两字节 `80 b9 -> 00 bf`）。源码补丁  
  `egl_display.cpp.patch` 已应用、构建期断言已在 `device.mk`；  
  将来恢复全量编译会自动产出正确的 `libEGL.so`。  
  注意别再用 `PRODUCT_COPY_FILES` 去覆盖 AOSP 已有模块 `libEGL`——  
  build/core 会静默打 `PRODUCT_COPY_FILES ... ignored` 丢掉。
- **`install/bin/` 脚本在四清场景仍是 no-op**：TWRP 3.1.1 的 PATH 没有  
  busybox，`cp/grep` 找不到。若以后要刷 GApps / su 并跨 OTA 保留，  
  需要往 `install/bin/` 塞静态 busybox 或改用绝对路径工具。
- **屏是 `FLAG_SECURE`**：`screencap` 会挂死，取日志走  
  `logcat` / pstore / `/cache` bootlog，不要再用截图判亮屏。
- **这是 eng / TV 自用包**，不是 user 发布版；SetupWizard 在四清后被首启  
  脚本禁用并标记 `device_provisioned=1`。

## 14.12 结论

「为什么 TWRP 四清之后重新刷包会不启动」的四条独立根因链——

1. 4.4.4 `/sepolicy` 撑不起 7.1 用户空间（六层 SELinux 失败）；
2. `persist.sys.ui.hw=1` + 旧 Tegra EGL TLS → `EGL_BAD_DISPLAY` →  
   `KeyguardScrim` 残留 / 窗口 alpha 卡 `0x00`；
3. `sf_hwc_off.sh` 在 `FLAG_SECURE` 屏上 `screencap` 挂住 SurfaceFlinger → 全局 ANR；
4. `lmkd` 起不来 → `ProcessList.writeLmkd()` 持 AMS 大锁 sleep → Watchdog 杀 `system_server`；

——已经全部固化进设备树、AOSP 源码补丁、overlay、`check.sh` 和最终 OTA 包，  
并通过「四清 → 刷包 → 冷启动 → 二次重启静置」的最严格路径验证。  
`dist/installfix-1106-2309/cm_ardbeg_tv-ota-eng.dy.zip` 可直接刷入使用。

---

# 十五、【2026-11-06 续】WiFi / 蓝牙开机自启、自动连接与浏览器「闪退」

> 对应需求：`adb 连接设备调试，抓取日志wifi 蓝牙 开机就启动，自动连接并解决浏览器闪退的问题`
>
> 这一章和第十四章是**同一条严格验收链**的延续：第十四章解决「能不能开机看到桌面」，  
> 本章解决「开机之后 WiFi/蓝牙能不能自己开、能不能自己连、浏览器能不能一直待在前台」。  
> 所有结论都是 `0123456789ABCDEF` 实机抓日志 + 重启验证得来的，不是推断。

## 15.1 抓到的一手日志

调试目录：`ardbeg-cm-14.1/work/debug-wifibt-browser/`

| 文件                                     | 内容                                                              |
| -------------------------------------- | --------------------------------------------------------------- |
| `logcat-boot.txt`                      | 开机全量 logcat，26805 行 / 3.8 MB                                    |
| `dmesg.txt`                            | 内核日志（bcmdhd / wifiloader / rfkill / bt HIDP 时序）                 |
| `dumpsys_wifi.txt`                     | `Wi-Fi is enabled` / `SSID: CPE-0C3FB8` / `CONNECTED/CONNECTED` |
| `dumpsys_bt.txt`                       | `enabled: true` / `state: ON` / `Bonded devices:` 为空            |
| `dumpsys_conn.txt` / `dumpsys_act.txt` | ConnectivityService / AMS 前台栈                                   |
| `logcat-jelly.txt`                     | 主动启动 Jelly 浏览器后的日志                                              |
| `verify-browser-105s.txt`              | 增强版验收脚本含 105 秒交互项的实跑留档                                          |

设备当时状态：`sys.boot_completed=1`、`wifi_on=1`、`bluetooth_on=1`、  
`airplane_mode_on=0`、`device_provisioned=1`；WiFi 已连  
`CPE-0C3FB8`（BSSID `3c:9f:cd:0c:3f:b8`，IP `192.168.10.110/24`）；  
蓝牙 ON（地址 `22:22:83:39:12:06`，名称 `Tegra-Android`），无配对设备；  
浏览器 `org.lineageos.jelly/.MainActivity`，WebView `com.android.webview 52.0.2743.100`。

**这些值都是调试态**：`wifi_on` / `bluetooth_on` 是之前手工 `settings put` 和  
`svc wifi enable` 留下的，`/data/misc/wifi/wpa_supplicant.conf` 里也是手工配好的  
`network={...}`。四清之后这些全没了，不能拿它当「开机自启」的证据。

## 15.2 浏览器「闪退」：不是崩溃，是守护抢前台

`logcat-jelly.txt` 里没有任何 `FATAL EXCEPTION` / tombstone / ANR，反而有：

```text
I WebViewFactory: Loading com.android.webview version 52.0.2743.100
I cr_BrowserStartup: Initializing chromium process, singleProcess=true
E libEGL  : validate_display:99 error 3008 (EGL_BAD_DISPLAY)
I OpenGLRenderer: Initialized EGL, version 1.4
I ActivityManager: Displayed org.lineageos.jelly/.MainActivity: +1s365ms
```

`Displayed +1s365ms` 说明冷启动成功；那条单发 `EGL_BAD_DISPLAY` 是第十四章记过的  
transient，二次重启后为 0，不是崩溃原因。

真凶是 **`zz-ardbeg-home-watchdog.sh` 的 `launcher_visible()` 恒为 false**：

```sh
# 旧实现（错）
dumpsys window windows | grep -A1 '...Launcher' | grep -q 'mViewVisibility=0x0'
```

原始 `dumpsys window windows` 里 `Window #N Window{... Launcher}:` 的**紧邻下一行**是

```text
mDisplayId=0 stackId=1 mSession=... mClient=...
```

`mViewVisibility=0x0 mHaveFrame=...` 在十几行之后，`-A1` 永远取不到。更糟的是  
toybox `grep` 的 `-A/-B` 与 `-m1` 一起用会**只输出匹配行、丢掉上下文行**  
（第十四章 14.8 已经踩过一次）。

后果：主循环第 3 步每 90 秒无条件执行

```sh
wm dismiss-keyguard; am start -n "$HOME_ACT"; input keyevent 224; brightness_toggle
```

把用户从 Jelly / 设置 / 输入法等**任何** app 踢回桌面，主观表现就是「应用一闪就退」；  
`brightness_toggle` 还要起一个 ART VM 写 settings，卡顿也跟着来。

### 修法（两层，缺一不可）

1. 把 dumpsys 压成「窗口标题 + 可见性」两行一组的紧凑列表再反查：
   ```sh
   launcher_visible() {
       /system/bin/dumpsys window windows 2>/dev/null \
           | grep -E 'Window #|mViewVisibility=' \
           | grep -B1 'mViewVisibility=0x0' \
           | grep -q 'com.cyanogenmod.trebuchet/com.android.launcher3.Launcher'
   }
   ```
2. 加 `foreground_is_home()` 守卫，只有「前台理应是桌面、但桌面窗口却不可见」  
   才允许干预：
   ```sh
   foreground_is_home() {
       /system/bin/dumpsys activity activities 2>/dev/null \
           | grep -m1 'mResumedActivity' \
           | grep -q 'com.cyanogenmod.trebuchet'
   }
   ...
   if foreground_is_home && ! launcher_visible; then
       ... cooldown 90s ... dismiss-keyguard + am start HOME ...
   fi
   ```
   用户打开浏览器时 Launcher 窗口本来就会变成 `mViewVisibility=0x8 (GONE)`，  
   这是正常状态，绝不能当成「被 KeyguardScrim 挡住」。

`zz-ardbeg-firstboot-fix.sh` 第 8 步的 `launcher_visible()` 同样换成紧凑列表判据，  
避免首启时白跑三轮抢前台（首启阶段前台本就是桌面，不需要额外守卫）。

### 顺手挖出来的第二个 bug：`log()` 自递归

`zz-ardbeg-firstboot-fix.sh` 原来写的是

```sh
log() { log -t "$LOG_TAG" "$*" 2>/dev/null; echo "[$LOG_TAG] $*"; }
```

shell 里函数优先级高于外部命令，函数体内的 `log` 又调回自己 —— **永远执行不到  
`/system/bin/log`**。实测 `logcat -d -s fb_fix` 一条都没有，而每次调用会把递归回退栈  
打成一串 stdout 噪声。整条首启链路的日志白丢了，之前的黑屏排障因此少了一整类证据。

修法是写绝对路径（常驻守护本来就是这么写的，所以没中招）：

```sh
log() { /system/bin/log -t "$LOG_TAG" "$*" 2>/dev/null; echo "[$LOG_TAG] $*"; }
```

修完后一次正常开机的 `fb_fix` 日志：

```text
I/fb_fix: firstboot fix start
I/fb_fix: persist.sys.ui.hw=0 (HWUI/RenderThread off)
I/fb_fix: package manager ready after 7s
I/fb_fix: setupwizard disabled
I/fb_fix: wakeup + home started
I/fb_fix: provisioned / lockscreen flags set
I/fb_fix: animation scales = 0 (window layer alpha fix)
I/fb_fix: screen settings applied (timeout=MAX, stayon=7, brightness=255)
I/fb_fix: display is ON after 0 extra round(s)
I/fb_fix: launcher window VISIBLE after 0 extra round(s)
I/fb_fix: firstboot fix done: display ON + launcher window VISIBLE
I/fb_fix: wifi network already configured -> leave /data/misc/wifi untouched
I/fb_fix: wifi enabled after 0 retry(s)
I/fb_fix: bluetooth already ON (persisted state=1)
I/fb_fix: wifi auto-connected (mNetworkInfo CONNECTED/CONNECTED)
I/fb_fix: connectivity fix done
```

## 15.3 WiFi / 蓝牙开机自启：为什么必须做两条路径

### 全量编译路径（settings 数据库默认值）

`DatabaseHelper.java` 在 settings 数据库**首次创建**时写：

```java
2622: loadBooleanSetting(stmt, Settings.Global.WIFI_ON,      R.bool.def_wifi_on);
2628: loadBooleanSetting(stmt, Settings.Global.BLUETOOTH_ON, R.bool.def_bluetooth_on);
```

AOSP 默认两者都是 `false`。`vendor/cm/overlay/common` 已经把 `def_wifi_on` 改成  
`true`，但 `def_bluetooth_on` 没人改；`device/nvidia/shield-common/overlay/tv`  
那份同时带两个 `true`，可 ardbeg **没有继承 shield-common**，别拿它当依据。

所以 `overlay/packages/providers/SettingsProvider/res/values/defaults.xml`  
显式补上（带长注释）：

```xml
<bool name="def_wifi_on">true</bool>
<bool name="def_bluetooth_on">true</bool>
```

### 文件级重打包路径（当前交付走这条）为什么不能只靠 overlay

这个 XML 要被 aapt 编进 `SettingsProvider.apk` 的 `resources.arsc` 才生效。  
当前所有 ROM 都是「解包旧 `system.img` → debugfs 换文件 → 重切块」产出的，  
`SettingsProvider.apk` 原封不动，**改 XML 对现包完全无效**。

蓝牙还有一层硬约束：`BluetoothManagerService.java:315` 的构造函数只在  
`system_server` 启动时读一次

```java
if (isBluetoothPersistedStateOn()) {
    mEnableExternal = true;
}
```

而它注册的 `ContentObserver` 只监听 `BLE_SCAN_ALWAYS_AVAILABLE`，  
**不监听 `BLUETOOTH_ON`**。所以开机之后 `settings put global bluetooth_on 1`  
只影响**下一次**开机，当前这次蓝牙不会自己亮。

### 实测有效的运行时组合

Android 7.1 的 `svc` 只有 `power / data / wifi / usb / nfc`，**没有 `bluetooth`**  
（实机 `svc` help 已确认）。可用的是 `IBluetoothManager` 的 Binder 事务 6：

```text
IBluetoothManager.aidl
  1 registerAdapter      2 unregisterAdapter
  3 registerStateChangeCallback   4 unregisterStateChangeCallback
  5 isEnabled            6 enable(String packageName)   <-- 这里
  7 enableNoAutoConnect  8 disable(String, boolean persist)
  9 getState ...
```

`enable()` 对非 system 调用者要求 `BLUETOOTH_ADMIN`；首启脚本由 init 以  
`user root` 启动，`ActivityManager.checkComponentPermission` 对 uid 0 一律放行。

实机受控实验（`bluetooth_manager` 事务 8 带 `persist=false` 先关掉）：

```text
before                     : state 0x0c (STATE_ON), bluetooth_on=1
tx8 disable(persist=false) : state 0x0a (STATE_OFF), bluetooth_on 仍为 1
settings put global bluetooth_on 1
tx6 enable()               : 返回 Parcel(...00000001) = true
6 秒后                     : state 0x0c (STATE_ON), enabled: true
```

结论：**先写持久化值，再显式 enable**，顺序不能反（  
`onServiceUp()` 里的 `isBluetoothPersistedStateOnBluetooth()` 读的是 DB）。

WiFi 简单得多：实测 `svc wifi disable` → `wifi_on=0`，  
`svc wifi enable` → `wifi_on=1`，`svc` 自己就会持久化，不必手工 `settings put`。

## 15.4 WiFi 自动连接：预置 `network={...}` 模板

「开机自动打开」≠「自动连上」。四清后 `/data/misc/wifi/` 是空的，WiFi 开着也停在  
`DISCONNECTED`；TV 形态没触摸屏，让用户自己点网络输密码不现实。

实测有效的预置方式（2026-11-06，同一台设备）：

```sh
svc wifi disable
# 恢复一份只含 network 块的 wpa_supplicant.conf
rm -f /data/misc/wifi/networkHistory.txt
svc wifi enable
```

20 秒后 `dumpsys wifi`：

```text
mWifiInfo SSID: CPE-0C3FB8, Supplicant state: COMPLETED
mNetworkInfo [type: WIFI[], state: CONNECTED/CONNECTED, extra: "CPE-0C3FB8"]
mDhcpResults IP address 192.168.10.110/24
```

要点：

- **只预置 `wpa_supplicant.conf` 的 `network={}` 段就够**，`networkHistory.txt`  
  不必预置，反而必须删掉那份「空历史」，否则 `WifiConfigManager` 会用空内存态  
  把刚写进去的网络覆盖掉。
- `networkHistory.txt` 是带长度前缀的二进制序列化文本，`cat` 看着是空的，  
  要 `toybox strings` 才能读出 `CONFIG: "CPE-0C3FB8"WPA_PSK` /  
  `HAS_EVER_CONNECTED: true`。
- `dumpsys wifi | grep -m1` 会打印  
  `Failed to write while dumping service wifi: Broken pipe`，是管道提前关闭，  
  状态读取仍然有效，不是 WiFi 服务出错。
- 改 conf 前必须先 `svc wifi disable`：supplicant 带 `update_config=1`，  
  正在跑的时候会回写覆盖。

落地成 **`/system/etc/wifi/ardbeg_default_network.conf` 模板**，首启脚本第 9 节：

```sh
if [ -f "$NET_TEMPLATE" ]; then
    if [ ! -f "$WPA_CONF" ] || ! grep -q '^network=' "$WPA_CONF"; then
        svc wifi disable; sleep 2
        [ -f "$WPA_CONF" ] || cp /system/etc/wifi/wpa_supplicant.conf "$WPA_CONF"
        sed -n '/^network=/,$p' "$NET_TEMPLATE" >> "$WPA_CONF"
        rm -f "$NET_HISTORY"
        chown wifi:wifi "$WPA_CONF"; chmod 0660 "$WPA_CONF"
    fi
fi
```

**幂等是硬要求**：这个 rc 是 `class late_start` + `oneshot`，**每次开机都会跑**，  
不是「只跑第一次」。所以只要用户已经配过网络（`grep -q '^network='` 命中），  
脚本完全不碰 `/data/misc/wifi`。判据用 `^network=` 而不是 `network={`，  
是为了避开 toybox BRE 里 `{` 的转义坑。

`/system/etc/wifi/` 在底图里本来就存在（放 `wpa_supplicant.conf`），  
所以 `apply_overlay.py` 不需要往 `DIRS` 加目录。

> **隐私提示**：模板里是本实验室的 SSID / PSK，明文在 `/system`。  
> 分发 ROM 前请改成自己的网络，或直接删掉整个 `network={...}` 块  
> （首启脚本会跳过注入，WiFi 仍开机自启，只是不自动连）。  
> `bssid` 那行把连接锁在这台 AP 上，换路由器后删掉即可按 SSID 自由选 AP。

## 15.5 本轮改动清单（两条路径都注册了）

| 文件                                                                    | 作用                                                                                                           |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `overlay/packages/providers/SettingsProvider/res/values/defaults.xml` | 加 `def_wifi_on` / `def_bluetooth_on = true`，长注释说明 `DatabaseHelper:2622/2628` 与 `BluetoothManagerService:315` |
| `wifi/ardbeg_default_network.conf`                                    | **新增**出厂预置网络模板，含 `network={...}` 与改/删说明                                                                      |
| `device.mk` 第十九节                                                      | `PRODUCT_COPY_FILES` 注册模板到 `system/etc/wifi/`（全量编译）                                                          |
| `initfiles/zz-ardbeg-firstboot-fix.sh`                                | 头部「问题 5」长注释；修 `launcher_visible()`；修 `log()` 自递归；新增第 9 节 WiFi/BT 运行时兜底                                       |
| `initfiles/zz-ardbeg-home-watchdog.sh`                                | 修 `launcher_visible()`；新增 `foreground_is_home()`；主循环条件改为 `foreground_is_home && ! launcher_visible`          |
| `repack/tools/apply_overlay.py`                                       | `FILES` 注册 `/etc/wifi/ardbeg_default_network.conf`；`main()` 加「顶格 `network={` + 与真源 md5 一致」双重校验               |
| `repack/overlay/system/{bin,etc/wifi}/`                               | 上面三个文件的打包侧副本，md5 与设备树真源逐字节一致                                                                                 |
| `tools/verify_after_boot.sh`                                          | 期望 md5 表更新为 8 项；新增 8 条 WiFi/BT/浏览器自动判据 + `CHECK_BROWSER=1` 的 105 秒交互验收                                       |
| `patches/check.sh`                                                    | 新增「WiFi/BT/浏览器修复」核验段；验收工具关键字扩展；新增「最终包必须比关键源文件新」的 mtime 判据                                                    |

最终 md5（设备树真源 = overlay = 四清后设备）：

```text
21960cdd4b2c71db7f4dda534a56280b  zz-ardbeg-firstboot-fix.sh
977e12d55141bebe1e6964c36bc6bfa3  zz-ardbeg-home-watchdog.sh
d2e8dd68fab0df7e80b5373b372ba720  ardbeg_default_network.conf
```

旧值 `fb4043...` / `3833df...` 已作废；`verify_after_boot.sh` 的  
`EXPECT_MD5` 与 `check.sh` 都已同步，避免「补丁全绿但验收 FAIL」。

## 15.6 实机验证结果

### (1) 浏览器不再被踢回桌面

推送新版脚本 → `setprop ctl.stop/start ardbeg_homewd` 重载守护 →  
启动 `org.lineageos.jelly/.MainActivity`：

```text
mResumedActivity: ActivityRecord{... org.lineageos.jelly/.MainActivity t18}
foreground_is_home  : NO-NOT-HOME
launcher_visible    : 0   （Jelly 在前台时桌面窗口 GONE，完全正常）
```

静置 **105 秒**（跨过守护 90 秒冷却窗口）后：

```text
mResumedActivity: ActivityRecord{... org.lineageos.jelly/.MainActivity t18}  ← 仍是 Jelly
watchdog 抢前台日志 "HOME in foreground but window hidden" : 0
"launcher dead" 日志 : 0
pidof org.lineageos.jelly : 18357
```

### (2) 从「干净状态」重启，WiFi / 蓝牙自启并自动连

为不复现四清的破坏性，手工构造等价状态：

```sh
# 去掉 wpa_supplicant.conf 的 network 块，删 networkHistory.txt
# wifi_on=0 / bluetooth_on=0，两个 radio 都关掉
svc wifi disable
service call bluetooth_manager 8 s16 com.android.settings i32 0
timeout 30 settings put global wifi_on 0 &
timeout 30 settings put global bluetooth_on 0 & wait
adb reboot
```

冷启动后（boot_completed 40s + 静置 45s）：

```text
wifi_on=1                    bluetooth_on=1
Wi-Fi is enabled             state: ON / enabled: true
mNetworkInfo [type: WIFI[], state: CONNECTED/CONNECTED, extra: "CPE-0C3FB8"]
mWifiInfo SSID: CPE-0C3FB8, Supplicant state: COMPLETED
wpa_supplicant.conf: 1 个 network 块，597 字节，wifi:wifi / 0660
init.svc.fb_fix=stopped   init.svc.ardbeg_homewd=running
init.svc.lmkd=running     init.svc.wifiloader=stopped
```

**二次重启**再验一次幂等性：`fb_fix` 日志出现  
`wifi network already configured -> leave /data/misc/wifi untouched`、  
`bluetooth already ON (persisted state=1)`、  
`wifi auto-connected (mNetworkInfo CONNECTED/CONNECTED)`，  
`wpa_supplicant.conf` 仍是 1 个 network 块，没有被重复注入。

### (3) 验收脚本

`tools/verify_after_boot.sh` 增强后实跑：

```text
PASS = 45   FAIL = 0
```

在原 37 项基础上新增 8 条：8 个文件 md5（含新模板）、WiFi 开机已启用、  
WiFi 自动连上、连接的是预置 SSID、蓝牙 `state: ON`、  
`wpa_supplicant.conf` 有网络块、首启脚本 `connectivity fix done`、  
home 守护抢前台日志为 0。`CHECK_BROWSER=1` 时再加 3 条交互判据。

`patches/check.sh` 首次实跑：23/23 源码补丁已应用，新增的「WiFi/BT/浏览器修复」  
核验段全绿；唯一预期的红字是

```text
[错误] 源文件比最终包新，需重打包：...
```

这正是新增 mtime 判据在提醒「还没重打最终 OTA 包」。  
2026-11-07 重打 `dist/wifibt-1107-0023/` 之后再跑，该段已变成  
`[已修] 最终包比所有关键源文件新（已重打包）`，全脚本无错误项。  
完整审计与重打包记录见第十六章。

## 15.7 新增的踩坑记录

- **`svc` 在 7.1 没有 `bluetooth` 子命令**，别照抄 8.0+ 的做法；  
  `service call bluetooth_manager 6 s16 <pkg>` 才是本机可用途径。
- **`settings put` 不是「打开蓝牙」**，它只写 DB；当前 boot 必须显式 `enable()`。
- **`log()` 函数自递归**会让所有 `fb_fix` 日志静默消失，且只在 stdout 留噪声；  
  shell 里函数优先级高于外部命令，日志函数一律写 `/system/bin/log` 绝对路径。
- **`class late_start` + `oneshot` 是「每次开机跑一遍」**，不是「只跑第一次」，  
  所有写 `/data` 的逻辑必须自己判幂等。
- **判据不要写 `network={`**：toybox BRE 里 `{` 有转义含义，用 `^network=`。
- **`grep -Fq` 查「错误写法」会被解释这个坑的注释误伤**（check.sh 已改成  
  `grep -Eq '^log\(\) \{...'` 锚定行首），和 `device.mk` 里构建期断言要锚定  
  `^[[:space:]]*if` 是同一类问题。
- **`dumpsys wifi | grep -m1` 的 Broken pipe 无害**，别当成 WiFi 服务崩了。
- **判 WiFi/蓝牙状态用 dumpsys，不用 `settings get`**：后者是 app_process ART VM，  
  一次十几秒，而且值对不一定代表 radio 开着。

## 15.8 结论

「浏览器闪退」不是 Jelly / WebView / Chromium 崩溃，是 home 守护的  
`launcher_visible()` 恒 false 每 90 秒把用户踢回桌面；已修判据 + 加前台守卫，  
105 秒静置实机验证通过。WiFi / 蓝牙开机自启做了「全量编译 overlay + 文件级  
重打包运行时兜底」两条路径，WiFi 自动连接靠出厂预置网络模板 +  
删空 `networkHistory.txt` 实现，从「两个 radio 都关、无已保存网络」的干净状态  
冷启动实测自动连上 `CPE-0C3FB8`。所有改动已同步进设备树、overlay、  
`check.sh`、验收脚本和文档；最终 OTA 已重打为  
`dist/wifibt-1107-0023/cm_ardbeg_tv-ota-eng.dy.zip` 并完成包内文件级往返校验  
（第十六章），第 15.6 节的 mtime 红字已转绿。

# 十六、【2026-11-07 收官】全链路集成审计 → 重打包 → 干净四清刷机 → 全面功能调试

本章回答用户连续提出的四件事：

> `检查调试后有没有把补丁集成到设备树`  
> `把修改固化在刷机包中`  
> `设备全面调试功能`  
> `重新刷机调试`

## 16.1 六层集成审计结论

审计不是只看「`check.sh` 绿不绿」，而是把一条修复从源码到刷机包拆成六层逐层核对：

| 层            | 位置                                                                                             | 结论                                                                     |
| ------------ | ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| ① AOSP 源码补丁  | `patches/**/*.patch`（42 个文件，23 个纳入 `check.sh` 核验）                                              | 23/23 `[已应用]`，0 冲突 0 缺失                                                |
| ② 设备树真源      | `initfiles/`、`wifi/`、`overlay/`、`prebuilt/lib/`、`patches/tools/`                               | 全部落地，md5 与基准表一致                                                        |
| ③ 全量编译注册     | `device.mk` 的 `PRODUCT_PACKAGES` / `PRODUCT_COPY_FILES`、`initfiles/Android.mk`、`lineage_tv.mk` | `zz-ardbeg-*`、`ardbeg_default_network.conf`、`persist.sys.ui.hw=0` 均已注册 |
| ④ 文件级重打包注册   | `apply_overlay.py` 的 `FILES`、`mkzip.py` 的 `EXTRA_ENTRIES`、`mk_ramdisk4.py`                     | 43 个写入文件含全部新增项，`install/bin/*` 三条已补                                    |
| ⑤ overlay 副本 | `repack/overlay/system/**`                                                                     | 与设备树真源 md5 逐项一致                                                        |
| ⑥ 最终 OTA zip | `dist/*/cm_ardbeg_tv-ota-eng.dy.zip`                                                           | **审计时是旧包 `installfix-1106-2309`，唯一脱节处**                                |

关键判据：`patches/check.sh` 首次实跑，源码补丁、二进制产物、`lmkd.rc` 三处一致性、  
`install/`、WiFi/BT/浏览器修复、验收工具**全部 `[已修]`**，只有新增的 mtime 判据报  
7 条红字「源文件比最终包新，需重打包」。也就是说：**调试后的补丁已经完整集成进设备树，  
缺的只是把最新那批改动重打进刷机包**。

## 16.2 check.sh 的判据分层修正（避免两类假阳性）

修完包要回头把基准包路径写进 `tools/verify_after_boot.sh`，这个写动作本身又会  
触发「源文件比最终包新」。初版 mtime 判据把「只跑在宿主侧的验收工具 / 文档」  
和「决定 ROM 内容的源文件」混在一起，会形成死循环式误报。现改为两组：

- **A 组（真错误，计入 `PKG_BAD`）**：`zz-ardbeg-firstboot-fix.sh`、  
  `zz-ardbeg-home-watchdog.sh`、`ardbeg_default_network.conf`、`defaults.xml`、  
  `device.mk`、`apply_overlay.py` —— 这些变了必须重打包。
- **B 组（只提示）**：`tools/verify_after_boot.sh`、`patches/README.md` —— 不进 ROM。

### ★ `defaults.xml` 的边界，别误读

`overlay/.../SettingsProvider/res/values/defaults.xml` 的  
`def_wifi_on=true` / `def_bluetooth_on=true` 走的是  
**全量编译 → aapt 编进 `SettingsProvider.apk`** 路径。当前 ROM 是文件级重打包，  
只替换 `system.img` 里的文件，**不会重编 APK**，所以这两个默认值并不因此进入这个 zip。  
它在 A 组里的意义是提醒「若恢复全量编译，`SettingsProvider.apk` 必须重编」。

文件级 ROM 的等价效果由 `zz-ardbeg-firstboot-fix.sh` 第 9 节运行时兜底保证：  
`settings put global bluetooth_on 1` + `service call bluetooth_manager 6 s16 <pkg>`

- `svc wifi enable` + 出厂预置网络注入。本次 16.7 节已从「`/data` 清空、  
  两个 radio 全关、无任何已保存网络」的干净状态冷启动实测通过。

## 16.3 重打包 `wifibt-1107-0023`

```sh
cd "/home/dy/WorkBuddy AI/ardbeg-cm-14.1/repack"
./make_ota.sh wifibt-1107-0023
```

```text
2/7 WiFi 网络模板校验 OK / libEGL.so 补丁校验 OK / lmkd.rc 校验 OK
    目录 4 个, 文件 43 个, 合计 102.9 MB
3/7 debugfs 写入 overlay 完成
4/7 e2fsck rc=0
5/7 new 199680 块 (780.0 MB) / 命令 196 条
6/7 unsigned.zip 377.6 MB
7/7 whole-file 签名自检 OK
zip md5 : c5a3bc998b604d5915550c01d7045d17
boot md5: 9aa6a27985baad70637aee30752fd134   ← 与旧包完全一致，未改 ramdisk
```

最终包：`dist/wifibt-1107-0023/cm_ardbeg_tv-ota-eng.dy.zip`，  
395982671 字节，17 条目，`testzip` 干净，`persist.sys.ui.hw=0` 在包内 `build.prop`。  
因为 `boot.img` 未变，`verify_after_boot.sh` 的 `EXPECT_BOOT_MD5` 不用改。  
重打包后 `check.sh` 的 mtime 段转为  
`[已修] 最终包比所有关键源文件新（已重打包）`，全脚本无错误项。

## 16.4 新增 `tools/verify_ota_contents.sh`（刷机前的硬证据）

`check.sh` 验「设备树/overlay/打包脚本」和「zip 条目结构」，  
`verify_after_boot.sh` 验「刷机后设备分区」，中间缺一层：  
**zip 里 `system.new.dat` 还原出的 ext4 里，8 个关键文件到底是不是真源那一份**。  
历史上 `egl_display.cpp.patch` 显示「已应用」但 ROM 里 `libEGL.so` 一直是原版，  
就是这一层没验。新工具直接做

```text
zip -> system.new.dat + transfer.list -> otablocks.py unpack -> raw ext4
    -> debugfs dump 10 个文件 -> md5 逐项判定
```

新包实跑：

```text
条目数 17 / testzip 干净 / 必备条目齐全 / build.prop persist.sys.ui.hw=0 是
PASS /lib/libEGL.so                     4ac10584321c81f8dcddd21a025bced6
PASS /etc/init/lmkd.rc                  4635029e48b1ef36190332742188bf65
PASS /bin/sf_hwc_off.sh                 f1223c35f9d7ea3706d74cbe83a4a24b
PASS /lib/libselinux_bypass.so          8652d544f226ee8de7127f30dca2fff1
PASS /lib/libminijail.so                29f2b8bb047cac7473cb1b77e3a21a14
PASS /bin/zz-ardbeg-firstboot-fix.sh    21960cdd4b2c71db7f4dda534a56280b
PASS /bin/zz-ardbeg-home-watchdog.sh    977e12d55141bebe1e6964c36bc6bfa3
PASS /etc/wifi/ardbeg_default_network.conf d2e8dd68fab0df7e80b5373b372ba720
PASS /etc/init/zz-ardbeg-firstboot-fix.rc  存在
PASS /etc/init/zz-ardbeg-home-watchdog.rc 存在
PASS = 10   FAIL = 0
```

两张 `EXPECT_MD5` 表（包内 / 设备侧）逐项一致，`check.sh` 已增加对该工具的核验。

## 16.5 新坑：TWRP `framebuffer 0x0` 崩溃循环，四清被截断

两阶段 ORS 下发四清后，设备进入 recovery 但 TWRP **每 5 秒重启一次**：

```text
之前成功：fb0 vi.bits_per_pixel = 32 / framebuffer: 3 (1920 x 1080)
          I:Loading package: splash ... → ORS 正常处理
本次异常：fb0 vi.bits_per_pixel = 0  / framebuffer: 3 (0 x 0)
          Using fbdev graphics.  ← 日志到此为止，UI 崩溃
```

- `Starting TWRP ... (pid 123) (pid 136) (pid 149) ... (pid 554)` pid 递增，  
  说明**只有 TWRP 主进程在崩，kernel 和 adbd 稳定**，adb 通道一直可用。
- `/sys/class/graphics/fb0/`：  
  `BPP=0 / VSIZE=0,0 / STRIDE=7680`（7680 = 1920×4，证明原本是 1920×1080，  
  只是 var info 被清成 0）；`tegradc.0/enable=0`、mode 全 0。
- 尝试 `echo 1 > tegradc.0/enable`、`echo 0 > fb0/blank`、  
  写 `bits_per_pixel` / `virtual_size` 全部无效（这些是只读 show 属性），  
  需要 kernel 级重新初始化 display，而 TWRP UI 起不来就没法走 ORS。
- 结果：ORS 只完成了 `wipe dalvik / system / cache`，  
  **`wipe data` 没执行完**（`/data/misc/wifi` 里 23:18 的旧文件仍在），  
  首启日志因此出现 `wifi network already configured`，  
  验收里还残留 1 个 00:21 的 tombstone 和 1 个 00:22 的 ANR trace（46/48）。

## 16.6 绕行方案：按 OTA 块表直接写 system 分区

既然 `adbd` 稳定、boot 分区 `mmcblk0p9` 没有被 wipe 且回读 md5 与新包一致  
（`9aa6a279...`），可以完全绕开 TWRP UI：

```sh
# 1) 取最终 system 镜像的文件系统部分：199680 x 4K = 780MB
dd if=repack/work/system-wifibt-1107-0023.img of=system-fs.img \
   bs=4096 count=199680
# 宿主 md5 030f26047c100173930b4a1bc33a114d

# 2) 推到 recovery 的 /tmp（1.9G tmpfs，设备侧 md5 一致）
adb push system-fs.img /tmp/system-fs.img     # 8.0 MB/s，98 秒

# 3) 写 system 分区并逐字节回读比对
adb shell 'dd if=/tmp/system-fs.img of=/dev/block/mmcblk0p10 bs=4096'
#  199680+0 records / 817889280 bytes / 12.255 secs
adb shell 'cmp -n 817889280 /tmp/system-fs.img /dev/block/mmcblk0p10'   # RC=0

# 4) 确认 boot 分区
adb shell 'dd if=/dev/block/mmcblk0p9 of=/tmp/boot-readback.img bs=8597504 count=1; \
           md5 /tmp/boot-readback.img'   # 9aa6a27985baad70637aee30752fd134

# 5) 重启进系统；由正常 boot kernel 重新初始化 display，循环自然消失
adb reboot
```

注意：`transfer.list` 的 `new` 段正好覆盖前 199680 块（780MB 文件系统），  
`erase` 段是分区尾部剩余空间（`raw.img` 里本来就是 0），所以整段写 780MB  
与 OTA 的 `block_image_update` 完全等价，不需要解析 196 条命令。

### 踩坑：`adb shell` 的 stdin 是 pty，二进制不能走管道

试过 `cat raw.img | adb shell 'dd of=/dev/block/... bs=4096'`，  
输入被终端行规程改写（控制字符回显、`0x0A` 被转换），目标文件根本没建立。  
**大镜像一律用 `adb push` 落盘 + 设备侧 `dd`，不要走 stdin 管道。**

## 16.7 补齐 `wipe data`，真·干净冷启动

在 recovery 里手工补上被截断的那一步（保留 `/data/media`，与 TWRP 语义一致）：

```sh
adb reboot recovery
adb shell 'mount -t ext4 /dev/block/mmcblk0p21 /data
           for d in /data/* /data/.[!.]*; do
               [ "$d" = /data/media ] || rm -rf "$d"
           done
           sync; umount /data'
adb reboot
```

冷启动后 `fb_fix` 日志完整走通出厂模板路径（**这才是「自动连接」的真正证明**）：

```text
persist.sys.ui.hw=0 (HWUI/RenderThread off)
setupwizard disabled
launcher not running, restart it
launcher window not visible (round 0), dismiss keyguard + restart HOME
launcher window VISIBLE after 1 extra round(s)
no saved wifi network -> inject default from /system/etc/wifi/ardbeg_default_network.conf
default wifi network injected (owner wifi:wifi, mode 0660)
wifi enabled after 1 retry(s)
bluetooth enabled via binder tx6 after 1 x 2s
wifi auto-connected (mNetworkInfo CONNECTED/CONNECTED)
connectivity fix done
```

`CHECK_BROWSER=1 ./verify_after_boot.sh` 实跑  
（留档 `work/flash-wifibt-1107-0023/verify-48pass-clean.txt`）：

```text
PASS = 48   FAIL = 0
结论：四清 + 最终 OTA 包端到端验收通过，修复确实固化在 ROM 里。
```

8 个 `/system` 文件 md5、boot 分区回读、10 类根因关键字全 0、  
ANR/tombstone/WDT trace 全 0、桌面窗口可见、WiFi 自动连上 `CPE-0C3FB8`、  
蓝牙 `state: ON`、Jelly 静置 105 秒仍在前台、抢前台日志 0。

## 16.8 设备全面功能调试结果

留档 `work/flash-wifibt-1107-0023/full-audit-static.txt` 与  
`full-audit-interactive.txt`。

| 类别       | 结果                                                                                                                                     |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| 输入设备     | `event0 aw9201_ts`（触摸）/ `event1 2.4G Mouse` / `event2 gpio-keys.4` 全部识别                                                                |
| 输入法      | 默认 `com.baidu.input_baidutv/.ImeService`，已启用                                                                                           |
| U 盘 / 存储 | `vold public:8_1` → `/storage/94B5-BDEB`（15.5G，73%），**重启后自动挂载**；`/data` 22G 可用 23G                                                     |
| 音频       | `media.audio_flinger` / `media.audio_policy` / `audio` / `cmaudio` 服务齐全，`STREAM_MUSIC` 正常                                              |
| 媒体       | `media.camera` / `media.player` / `media.codec` / `media.extractor` / `media.camera.proxy` 全部注册                                        |
| 关键进程     | zygote / system_server / surfaceflinger / lmkd / mediaserver / audioserver / cameraserver / installd / vold / netd / wpa_supplicant 全在 |
| 网络       | 网关 `192.168.10.1` 与外网 `223.5.5.5` 各 2 包 0% 丢包；DNS `192.168.10.1`                                                                       |
| 蓝牙       | `enabled: true` / `state: ON`                                                                                                          |
| 设置二级菜单   | WIFI / BLUETOOTH / APPLICATION / DISPLAY / SOUND / DATE / LOCATION / ACCESSIBILITY / STORAGE 9 个全部打开，无闪退                               |
| 浏览器      | Jelly 打开 `http://www.baidu.com` 后仍在前台，`FATAL=0 / ANR=0 / Force finishing=0`                                                            |
| 回到桌面     | `mResumedActivity` 正常回到 Trebuchet Launcher                                                                                             |

## 16.9 新增踩坑记录

- **TWRP `framebuffer 0x0` ≠ 变砖**：只是 UI 进程崩溃循环，kernel/adbd 仍在；  
  看 pid 是否递增来区分「进程重启」和「整机重启」。
- **四清可能被截断**：ORS 处理依赖 UI 加载完成，UI 崩了 `wipe data` 就不会执行。  
  验收出现历史 ANR/tombstone、或首启日志是 `wifi network already configured`  
  而不是 `no saved wifi network -> inject`，第一反应应是查 `/data` 时间戳。
- **`adb shell` stdin 是 pty**，二进制镜像只能 `adb push` + 设备侧 `dd`。
- **`/tmp` 在 recovery 是 1.9G tmpfs**，够放 780MB 文件系统镜像；  
  但 `/tmp` 在容器侧是 2.3G tmpfs，别把大镜像放容器 `/tmp`。
- **`cmp -n <字节数> file /dev/block/...`** 是比 md5 更直接的分区回读校验，  
  recovery 自带 `cmp`。
- **不要用 `dd` 重写 boot 分区来「顺手更新」**：本包 boot.img 与旧包 md5 一致，  
  四清又不 wipe boot，直接回读确认即可，多写一次徒增变砖风险。

## 16.10 证据边界：`verify_after_boot.sh` 的 TWRP `last_log` 段不是本次安装证据

这一点必须写清楚，否则下次复看会误判。

`tools/verify_after_boot.sh` 里有一段「TWRP last_log」核验（检查  
`wrote 199680 blocks`、`script succeeded`、`Updater process ended with RC=0`  
等关键字）。它的语义是：

> **`/cache/recovery/last_log` 里存在一次成功的 ORS 安装记录。**

而 `/cache` 在四清里会被 `wipe cache` 清掉，只在「擦完再装」的正常顺序下  
才会留下本次安装的日志。本轮 `wifibt-1107-0023` 的实际情况是：

| 环节            | 实际做法                                                           | 是否产生 `last_log`                 |
| ------------- | -------------------------------------------------------------- | ------------------------------- |
| 四清            | 阶段 1 ORS 被 TWRP `framebuffer 0x0` 崩溃截断，只清了 dalvik/system/cache | TWRP 未走到 `install` 步骤，无日志       |
| 刷 system      | `adb push` 镜像到 `/tmp` + 设备侧 `dd` 写 `mmcblk0p10` + `cmp` 校验     | 走 shell，不经 TWRP updater，**不产生** |
| 补 `wipe data` | recovery shell 里手工 `rm -rf`（保留 `/data/media`）                  | 走 shell，**不产生**                 |
| boot          | `adb reboot`                                                   | —                               |

所以本轮 `verify_after_boot.sh` 里 `last_log` 那段 PASS，读到的是  
**上一轮 `installfix-1106-2309` 通过 ORS 正常安装时留在 cache 的旧日志**，  
不是 `wifibt-1107-0023` 的安装证据。

**本轮闭环真正的证据是这四环，缺一不可**：

1. **包内往返校验**：`tools/verify_ota_contents.sh` → `PASS = 10 / FAIL = 0`，  
   从 zip 本身还原 raw ext4 后 8 个关键文件 md5 全对、2 个 init rc 存在。  
   证明 **zip 内容正确**。
2. **system 分区回读**：`cmp -n 817889280 /tmp/system-fs.img /dev/block/mmcblk0p10`  
   → `RC=0`。证明 **分区内容 = zip 内 system 内容**。
3. **boot 分区回读**：md5 `9aa6a27985baad70637aee30752fd134`  
   → 与包内 `boot.img` 一致（本包未改 boot）。证明 **boot 正确**。
4. **干净 `/data` 冷启动 + 48/48 验收**：首启脚本日志走出厂模板路径  
   （`no saved wifi network -> inject default`），而不是 dirty flash 的  
   `wifi network already configured`。证明 **修复真的在运行时生效**。

也就是说，`last_log` 段应理解为「设备历史上成功跑过一次正常 ORS 安装」的  
**回归守门项**，而不是「本次包已装」的判据。要补强本次证据只有两条路：

- 修好 TWRP 的 `framebuffer 0x0`（换 TWRP 版本 / 进 recovery 前先点亮  
  display controller），让 ORS 正常跑完，`last_log` 自然变成本次的；
- 或把这四环证据固定下来，`last_log` 段降级为「可选 / 仅提示」。

当前采用后者。后续若改前者，需在 `make_ota.sh` 之外单独维护 recovery 侧  
改动，并重测 `block_image_update` 路径（`dd` 绕过了 OTA 的 `apply_patch` /  
`erase` 语义；本例 `new` 段覆盖了全部 199680 块、`erase` 段只是分区尾部剩余  
空间，结论等价，但手法不同，必须显式说明）。

## 16.11 验收判据修正：`EGL_BAD_DISPLAY` 从「必须 0」改为「容 1 条 transient」

收尾复跑时撞到一个**判据自相矛盾**的坑，值得单独记一笔。

### 现象

干净四清冷启动后第一次跑 `verify_after_boot.sh`，44 PASS / 1 FAIL：

```text
FAIL  logcat 'EGL_BAD_DISPLAY': 实际[1] 期望[0]
```

但文件头注释第 10 条明明白白写着：

> 首次冷启动允许出现 1 条 transient `libEGL validate_display:99 error 3008`  
> (EGL_BAD_DISPLAY)，只要没有 `Failed to choose config` / tombstone / ANR  
> 就不是黑屏链复发；二次重启静置后应彻底为 0。

**注释和实现是矛盾的**：`EXPECT_KW` 里 `EGL_BAD_DISPLAY` 直接按 `期望 0` 硬判，  
把「注释承诺的容差」判成了 FAIL。

### 这一条到底是什么

查 logcat 上下文（Jelly 首次启动那一段）：

```text
00:47:05.334  Start proc 5976:org.lineageos.jelly/u0a44
00:47:05.493  libEGL  loaded /system/lib/egl/libEGL_tegra.so
00:47:06.081  Loading GLESv2 implementation libGLESv2_tegra_impl
00:47:06.396  E/libEGL (5976): validate_display:99 error 3008 (EGL_BAD_DISPLAY)
00:47:06.538  I/OpenGLRenderer (5976): Initialized EGL, version 1.4
00:47:06.538  D/OpenGLRenderer (5976): Swap behavior 2
```

关键在最后两行：**报错之后立刻 EGL 初始化成功、Swap behavior 正常**。  
也就是老 Tegra 的 `libEGL_tegra_impl` 在进程首次 attach 时随手返回一次  
`EGL_BAD_DISPLAY`，上层重试就过了。整机生命周期里仅此 1 次，且这个进程是  
**Jelly 起 WebView 时创建的子进程**，不是 RenderThread 那条黑屏链。

真正的黑屏链复发长这样（可选，多条 + 伴随失败）：

```text
E/libEGL: validate_display:99 error 3008 (EGL_BAD_DISPLAY)      ← 连打
E/libEGL: eglInitialize(0x0) failed                              ← 初始化失败
E/OpenGLRenderer: Failed to choose config with EGL_SWAP_BEHAVIOR_PRESERVED
        （后面就该是 tombstone / ANR / 黑屏了）
```

### 修法

把 `EGL_BAD_DISPLAY` 从「必须 0」的硬判里摘出来，单独做**三段式判定**：

| 条件                                           | 判定                 | 理由                           |
| -------------------------------------------- | ------------------ | ---------------------------- |
| 计数 ≤ 1                                       | PASS（标注 transient） | 老 Tegra EGL 首 attach 的已知无害行为 |
| 计数 > 1 且 logcat 有 `Initialized EGL, version` | WARN 转 PASS        | 图形栈是活的，不是黑屏                  |
| 计数 > 1 且没有成功初始化                              | FAIL               | 真·黑屏链复发                      |

设备侧新增一个取值：

```sh
echo "@egl_init_ok=$(grep -c "Initialized EGL, version" \
    /data/local/tmp/verify_logcat.txt || true)"
```

本地判定：

```sh
egl_n=$(get kw_1)
egl_ok=$(get egl_init_ok)
if [ "${egl_n:-99}" -le 1 ] 2>/dev/null; then
    echo "  PASS  logcat 'EGL_BAD_DISPLAY' = $egl_n（<=1 条 transient，允许）"
elif [ "${egl_ok:-0}" = "1" ]; then
    echo "  WARN  logcat 'EGL_BAD_DISPLAY' = $egl_n（>1 条，但 EGL 已成功初始化，非黑屏）"
else
    echo "  FAIL  logcat 'EGL_BAD_DISPLAY' = $egl_n 且没有成功的 EGL 初始化 → 黑屏链复发"
fi
```

`Failed to choose config` / `WATCHDOG KILLING` / `Failed to setexeccon` /  
`Unknown package` 等其余 8 个关键字**仍严格按 0 判**，没有放宽。

### 修正后复跑

```text
PASS = 45   FAIL = 0
结论：四清 + 最终 OTA 包端到端验收通过，修复确实固化在 ROM 里。
```

这条修正只是**把实现拉回注释本来的语义**，不是为了让红变绿而放宽标准：  
判据依然能抓住「连打 + 初始化失败」的真复发，只是不再被 1 条无害  
transient 误伤。

## 16.12 验收前置状态归一化 + logcat 环形缓冲区滚动

同一轮收尾里，`CHECK_BROWSER=1 ./verify_after_boot.sh` 又报了 45 PASS / 3 FAIL：

```text
FAIL  Launcher mViewVisibility=0x0: 实际[0] 期望[1]
FAIL  前台 Activity 是 Launcher: 实际[0] 期望[1]
FAIL  首启脚本跑完 connectivity: 实际[0] 期望[1]
```

三项**都不是 ROM 回归**，逐条查清如下。

### FAIL 1/2：上一轮被中断的交互验收把前台留在了 Jelly

`CHECK_BROWSER=1` 的第 9 节会启动 Jelly、静置 105 秒，最后才 `am start`  
回桌面。若这次跑被中途 kill（用户中断 / adb 掉线 / 后台任务被回收），  
设备就停在 Jelly。下一轮验收的第 8 节窗口判据在**交互验收之前**执行，  
自然读到「前台不是 Launcher」「Launcher 窗口不可见」。

手工复核当时的真实状态：

```text
mResumedActivity: com.cyanogenmod.trebuchet/...Launcher   ← 已回桌面
Window #14 Launcher        mViewVisibility=0x0            ← 可见
Window #17 KeyguardScrim   mViewVisibility=0x8            ← 已消失
```

修法：脚本新增「**0. 归一化验收前置状态**」，在设备在线检查之后、  
第 1 节取数之前执行：

```sh
"$A" shell 'am start -n com.cyanogenmod.trebuchet/com.android.launcher3.Launcher ...'
"$A" shell 'input keyevent 224 ...'   # 仅唤醒屏幕
sleep 3
echo -n "  归一化后前台 : "
"$A" shell 'dumpsys activity activities ... | grep -m1 "mResumedActivity"'
```

**关键是这不会掩盖黑屏**：这里不改属性、不 `dismiss-keyguard`、  
不重启服务。若真黑屏 / KeyguardScrim 遮挡 / Launcher alpha 卡 0，  
切回 HOME 后 `mViewVisibility` 依然不是 `0x0`，判据照样 FAIL。  
它只消除「上次验收遗留的前台 app」，不制造本来不存在的可见性。  
归一化后的前台也打印出来，便于事后追溯。

### FAIL 3：logcat 是环形缓冲区，13 小时后首启日志必然被冲掉

`logcat -d | grep -c "connectivity fix done"` → **0**，  
`grep -c "fb_fix"` → **0**。但同一时刻：

```text
Wi-Fi is enabled
mNetworkInfo ... CONNECTED/CONNECTED ... "CPE-0C3FB8"
bluetooth state: ON
wpa_supplicant.conf 里 ^network= 计数 1
```

设备 00:47 冷启动、13:25 复跑，中间 12 小时多的日志早把 `fb_fix`  
那几行挤出环形缓冲区了。首启脚本明明跑过（WiFi 自动连 + BT ON +  
网络块就是它注入的），却被判成「没跑」。

修法：把 `首启脚本跑完 connectivity` 从单关键字硬判改成**三段式**：

| 条件                                                                    | 判定                       |
| --------------------------------------------------------------------- | ------------------------ |
| `connectivity fix done` 计数 ≥ 1                                        | PASS（logcat 直接证据）        |
| 日志为 0，但 `wifi_enabled=1` + `wifi_conn=1` + `bt_on=1` + `wpa_net≥1` 全绿 | PASS，标注「缓冲区已滚动，由运行时状态佐证」 |
| 其余                                                                    | FAIL                     |

**严格性没有降低**：四清后若首启脚本真没跑，这四项一项都不可能成立——  
`def_wifi_on` / `def_bluetooth_on` 只在全量编译（aapt 编进  
SettingsProvider.apk）时生效，当前文件级重打包 ROM 靠的正是首启脚本  
第 9 节运行时兜底；预置网络也是首启脚本从  
`/system/etc/wifi/ardbeg_default_network.conf` 注入的。

### 修正后复跑

```text
普通模式（45 项）              : PASS = 45   FAIL = 0   RC=0
交互模式 CHECK_BROWSER=1（48 项）: PASS = 48   FAIL = 0   RC=0
  ├ Jelly 启动后在前台            = 1
  ├ 静置 105 秒后仍在 Jelly       = 1     ← 跨过守护 90s 冷却窗口
  └ 期间抢前台日志               = 0
结论：四清 + 最终 OTA 包端到端验收通过，修复确实固化在 ROM 里。
```

留档：`work/flash-wifibt-1107-0023/verify-final-48pass.txt`。  
注意交互验收第 9 节末尾会 `am start` 回桌面，跑完设备停在 Launcher。

**通用教训**：验收脚本必须（a）自己归一化前置状态，不能假设设备停在桌面；  
（b）不能把「环形缓冲区里还留着关键字」当成「事件发生过」的唯一证据，  
长期运行后要有一条不依赖 logcat 的等价运行时判据。

## 16.13 结论

调试后的补丁**已完整集成进设备树**（AOSP patches / 真源 / 两条编译路径 /  
overlay / 验收体系全绿），并**已固化进最终刷机包**  
`dist/wifibt-1107-0023/cm_ardbeg_tv-ota-eng.dy.zip`。  
包内 10/10 文件级往返校验、干净四清冷启动 48/48 端到端验收、  
以及覆盖输入/存储/音频/媒体/网络/蓝牙/设置菜单/浏览器的全面功能调试均通过。  
之前第十五章留下的「剩下最后一步是重打最终 OTA 包并做往返校验」至此闭环。

最后 `patches/check.sh` 复跑结果（本次收尾确认，退出码 0）：

```text
共 23 个补丁：可应用 0 / 已应用 23 / 有问题 0
文件权限修复：待修 0 / 已修 1 / 文件缺失 0
二进制补丁产物：prebuilt/lib/libEGL.so 与 overlay 副本
                md5 4ac10584321c81f8dcddd21a025bced6
lmkd.rc 三处（真源 / AOSP / overlay）
        md5 4635029e48b1ef36190332742188bf65
OTA install/ 三条（backuptool.sh / backuptool.functions / otasigcheck.sh）齐全
WiFi / 蓝牙 / 浏览器修复 8 项全绿
验收工具 tools/verify_after_boot.sh + 包内校验 tools/verify_ota_contents.sh 均在
最终包 395982671 字节 / md5 c5a3bc998b604d5915550c01d7045d17 / 17 条目 / testzip 干净
[已修] 最终包比所有决定 ROM 内容的源文件新
```

仅两条 `[提示]`（`tools/verify_after_boot.sh`、`patches/README.md` 比包新），  
属 mtime A/B 分层里的 B 组（宿主侧工具/文档，不进 ROM），按设计**不计错误**。

### 已知限制：平板 `cm_ardbeg` 的 eng 包未同步后续修复

`AndroidProducts.mk` 注册了两个产品：

| 产品                         | 入口              | 历史包                                                              |
| -------------------------- | --------------- | ---------------------------------------------------------------- |
| `cm_ardbeg`（平板 / 盒子形态）     | `lineage.mk`    | `dist/eng-1104-1719/cm_ardbeg-ota-eng.dy.zip`（351077775 字节）      |
| `cm_ardbeg_tv`（Android TV） | `lineage_tv.mk` | `dist/tv-1104-1728/...` → **`dist/wifibt-1107-0023/...`（本轮最终包）** |

**用户在会话中要求的「编译 eng 版本，也编译 TV 版本」两个变体都曾产出过，  
但 1106/1107 的全部修复只固化在 TV 版最终包里。** 两个变体共用  
`device.mk` 与 `patches/`（源码层是同步的），但 `system.img` 是各自独立  
的底图 `chk.img`；平板包没有走后续任何一轮 `apply_overlay.py` 文件级重打包。

所以：**刷 `cm_ardbeg-ota-eng.dy.zip` 不会带 SELinux 旁路 / EGL / lmkd /  
WiFi-BT / 浏览器 / `install/` 目录这些修复**，它仍是 1104 的早期状态。  
本轮所有调试与验收（48/48）都只针对 TV 版。

若将来要发布平板版，需以平板底图重跑完整流水线：

```text
平板 chk.img -> apply_overlay.py（43 个文件写入 + 三处 md5 硬校验）
            -> e2fsck -> otablocks.py pack -> mkzip.py -> sign_ota.py
            -> verify_ota_contents.sh 包内校验
            -> 实机四清 + verify_after_boot.sh
```

注意 `lineage_tv.mk` 的 `persist.sys.ui.hw=0` 是 TV 产品专属的；  
平板版要单独确认 `Window.java:755` 那条 HWUI 链路是否同样受影响，  
不能想当然照抄。

## 十七、全面功能自动测试工具化 + `persist_logcat` 补修（2026-11-07 收官）

### 17.1 为什么要新增 `tools/full_function_test.sh`

第十六章收尾时已有两条验收链：`verify_after_boot.sh` 回答「修复有没有进  
ROM」，`verify_ota_contents.sh` 回答「包内文件对不对」。但两者都**不回答  
「这台机器现在能不能当一台电视用」**——输入设备、输入法、U 盘、音频、  
相机媒体、设置二级菜单、浏览器、adb 通道这些「用户可感知功能」此前一直  
靠手工 adb 命令逐项试，没有可复跑、可留档、可判定通过/失败的正式工具。

本轮把这套调试正式收编成设备树工具  
`device/nvidia/ardbeg/tools/full_function_test.sh`：

- 设备侧采集脚本落盘 19 个原始文件（`dumpsys` / `logcat` / `dmesg` /  
  `getevent` / `service list` / `settings list` / `ps`），用 `@key=value`  
  输出报告，本地统一 `expect` / `atleast` / `nonempty` 判定；
- 覆盖 16 类子系统：启动与核心服务、显示图形、输入设备、输入法、  
  存储/U 盘、音频、网络、蓝牙、相机媒体、稳定性、开机日志/pstore、  
  `/system` 关键文件 md5、设置二级菜单、浏览器、交互后稳定性、adb 通道；
- 交互判据用「基线 + 增量」判断崩溃，避免 logcat 历史里的旧 `FATAL`  
  误伤；菜单逐项记录实际前台到 `menu_check.txt`；
- 禁止 `screencap -p`（`FLAG_SECURE` 屏会挂住 SurfaceFlinger 客户端连接，  
  曾导致 system_server 拿不到 SF 锁全局 ANR）；
- 全程落盘再 grep，不把 `logcat` / `dumpsys` 塞进 shell 变量  
  （会触发 `printf: Argument list too long`，grep 拿到空输入造成「假绿 0」）。

### 17.2 首轮结果 `103 / 2 / 0`，两个失败项一假一真

连接 `0123456789ABCDEF`（`cm_ardbeg_tv-eng 7.1.2 NJH47F`），首轮完整跑：

```text
汇总：PASS = 103   FAIL = 2   WARN = 0
留档：work/function-test/20261107-1341
未通过项：
    - /dev/input/event* 数量: 实际[0] 期望 >= 3
    - /cache/persist_log.txt 非空: 实际[0] 期望[1]
```

**假 FAIL（工具判据写错）**：采集命令是 `ls -l /dev/input/`，输出的  
`devinput.txt` 里只有 basename：

```text
total 0
crw-rw---- 1 root input 13,  64 ... event0
crw-rw---- 1 root input 13,  65 ... event1
crw-rw---- 1 root input 13,  66 ... event2
```

行里**不含** `/dev/input/` 前缀，而判据却写  
`grep -c '/dev/input/event'`，必然数到 0。改成  
`grep -cE 'event[0-9]+$'` 后本地对同一份留档即得 3。  
注意这里必须用 `-E`：设备 toybox `grep` 不支持 BRE 的 `\|` 交替。  
（`kernel_oops` 判据之前也是同一个坑，已用 `-cE` 修过。）

**真 FAIL（功能缺口）**：`/cache/persist_log.txt` 根本不存在，  
`getprop init.svc.persist_logcat` 返回空（不是 `stopped`，是属性压根没建），  
`dmesg` 里只有一行：

```text
init: could not get context while starting 'persist_logcat'
```

而 `zz-persist-log.rc` 文件头早期那条「实测 init.svc.persist_logcat =  
running」的注释是 1105 写下的乐观结论，一直没被复核过——**这正是  
「注释说修好了」和「运行时真的好了」长期脱节的又一例**。

### 17.3 `persist_logcat` 根因：4.4.4 sepolicy 里没有 `logcat_exec`

先排除伪因：手动执行同一条命令

```sh
logcat -b all -D -f /cache/fft_probe_log.txt -r 4096 -n 4
```

能正常写文件并轮转（实测 `.txt` + `.1` + `.2` 共 8MB+），说明 logcat  
参数、`/cache` 挂载、root 权限、`-r/-n` 轮转都没问题，**问题只在 init  
的启动路径**。

`system/core/init/service.cpp:346-388` 的 `Service::Start()`：

```cpp
if (!seclabel_.empty()) { scon = seclabel_; }              // 347-348
else {
    getcon(&mycon);                                        // 354
    getfilecon(args_[0].c_str(), &fcon);                   // 360
    rc = security_compute_create(mycon, fcon,
             string_to_security_class("process"), &ret_scon);   // 368
    ...
    if (rc < 0) {
        ERROR("could not get context while starting '%s'\n", name_.c_str());
        return false;                                      // 384-387
    }
}
NOTICE("Starting service '%s'...\n", ...);                 // 390
pid_t pid = fork();                                        // 392
```

实机 `ls -Z` 的一手证据（最关键）：

| 可执行文件                | file context                | 4.4.4 `/sepolicy` 是否认识 | 对应服务                           | 需要 seclabel |
| -------------------- | --------------------------- | ---------------------- | ------------------------------ | ----------- |
| `/system/bin/logcat` | `u:object_r:logcat_exec:s0` | **否**（7.1 新增标签）        | `persist_logcat`               | **是，本次漏了**  |
| `/system/bin/lmkd`   | `u:object_r:lmkd_exec:s0`   | **否**（7.1 新增标签）        | `lmkd`                         | 是，1106 已加   |
| `/system/bin/sh`     | `u:object_r:shell_exec:s0`  | 是                      | `ardbeg_homewd` / `sf_hwc_off` | 否           |

原厂 4.4.4 kernel 的根分区 `/sepolicy` 只有 `307 types / 84 classes /
3023 rules`、`policyvers=28`，没有 `logcat_exec` 这个 type，自然也没有  
`init -> logcat_exec : process` 的 transition 规则，  
`security_compute_create()` 返回 -1，服务连 `fork()`（392 行）都走不到。

**为什么 Permissive 也救不了**：`getenforce = Permissive` 只影响内核是否  
拦截访问，而 384-387 行这个 `if (rc < 0) return false` 是 init 用户态的  
硬失败，不看 enforcing 状态。只有 374-380 行那种 `scon == mycon`  
（"Service X does not have a SELinux domain defined"）分支才会去查  
`selinux_status_getenforce()`。`libselinux_bypass.so` 垫片同样绕不过这里。

**对照组**：设备树里 `audioserver` / `cameraserver` / `mediacodec` /  
`mediaextractor` / `lmkd` 五个 rc 早都统一加了  
`seclabel u:r:mediaserver:s0` 来绕开同类问题；  
`ardbeg_homewd` / `sf_hwc_off` 用的是 `/system/bin/sh`（旧 policy 认识  
`shell_exec`）所以不需要。**`zz-persist-log.rc` 是唯一漏掉的一个**。

### 17.4 修法与实机验证

在 `initfiles/zz-persist-log.rc` 的 service 段加一行：

```ini
    seclabel u:r:init:s0
```

让 init 走 347-348 行的短路分支，完全不调用 `security_compute_create()`。  
选 `u:r:init:s0` 而不是 `mediaserver:s0` 的理由：4.4.4 policy 里确实存在  
（实机 `ps -Z` 中 logd 进程就跑在该域）、权限最宽（写 `/cache`、读 logd  
buffer 都不需要额外 allow）、语义上等价于「不切域」，比塞进 media 域更  
贴合 logcat 的身份。另五个 media 服务用 `mediaserver:s0` 是因为要共享  
media 资源，与这里不矛盾。

先用 `adb remount` 临时 push 新 rc、`adb reboot` 快速验证（避免白打一个  
395MB 的包），确认有效后再走正式重打包：

```text
getprop init.svc.persist_logcat = running
ps -Z  : u:r:init:s0  root  199  1  ...  S /system/bin/logcat
/cache/persist_log.txt : 928578 -> 964028 -> 982641 字节（8 秒内持续增长）
dmesg  : init: Starting service 'persist_logcat'...   （context 报错消失）
WiFi   : CONNECTED/CONNECTED  CPE-0C3FB8      BT: state ON
```

### 17.5 六层固化清单（这次不能只改真源）

| 层                    | 文件                                                                                                                      | 本轮改动                                                                                                                                                                                |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ① AOSP patches / 总检查 | `patches/check.sh`                                                                                                      | 新增「persist_logcat 全程日志」核验段：有效行含 `seclabel u:r:init:s0`、真源/overlay md5 一致、两张验收表锚定新 md5、`apply_overlay.py` 注册、全面测试 `input_events` 判据未退化；并把 `initfiles/zz-persist-log.rc` 加进 mtime A 组 |
| ② 设备树真源              | `initfiles/zz-persist-log.rc`                                                                                           | 加 `seclabel u:r:init:s0` + 约 60 行根因注释；纠正文件头那条错误的「实测 running」；md5 `6500a2babf94cec94c50e4e160517b2b`（旧版 `b9360f53...`）                                                               |
| ③ 全量编译注册             | `device.mk:264` / `initfiles/Android.mk:233`                                                                            | 原本就已注册 `zz-persist-log.rc`，无需改；真源内容自动随编译进包                                                                                                                                          |
| ④ 文件级重打包注册           | `repack/tools/apply_overlay.py`                                                                                         | `FILES` 原本已有该 rc；**新增双重硬校验**：只取非注释有效行必须含 `seclabel u:r:init:s0`（头部长注释里也提到这个字符串，全文 grep 会假绿）、且 overlay 与真源 md5 一致                                                                    |
| ⑤ overlay 副本         | `repack/overlay/system/etc/init/zz-persist-log.rc`                                                                      | 从真源重新拷贝，md5 对齐                                                                                                                                                                      |
| ⑥ 验收工具 / 最终包         | `tools/verify_after_boot.sh`、`tools/verify_ota_contents.sh`、`tools/full_function_test.sh`、`dist/fulltest-1107-1354/...` | 两处 `EXPECT_MD5` 增加第 9 个文件；端到端验收新增「服务 running + 日志非空」2 项；全面测试新增「服务 running + 字节数 + rc md5」3 项判据；重打包                                                                                  |


### 17.6 重打包 `fulltest-1107-1354`

`./make_ota.sh fulltest-1107-1354`，产物：

| 项 | 值 |
| --- | --- |
| 路径 | `dist/fulltest-1107-1354/cm_ardbeg_tv-ota-eng.dy.zip` |
| 大小 / md5 | 395983040 字节 / `fd550a7a662a21824ca635206a6f0e87` |
| zip 条目 | 17（含 `install/bin/*` 三条）、whole-file 签名、`testzip()` 干净 |
| `system.new.dat` | 817889280 字节 / `9b89543d514a8531c0c5678b6e36adb3` |
| `boot.img` | 8597504 字节 / `9aa6a27985baad70637aee30752fd134`（未改动） |
| `system/build.prop` | `persist.sys.ui.hw=0` |

### 17.7 三套验收最终结果（1107 收官前）

| 工具 | 结果 |
| --- | --- |
| `tools/verify_ota_contents.sh`（zip 包内往返） | **PASS = 11 / FAIL = 0** |
| `tools/verify_after_boot.sh`（普通） | **PASS = 48 / FAIL = 0** |
| `CHECK_BROWSER=1 tools/verify_after_boot.sh` | **PASS = 51 / FAIL = 0**（Jelly 静置 105s 未被踢） |
| `tools/full_function_test.sh`（16 类子系统） | **PASS = 108 / FAIL = 0 / WARN = 0** |
| `patches/check.sh` | **RC = 0 / 0 个 `[错误]` / 23 个补丁全应用** |

### 17.8 证据边界与本轮结论

17.7 的 `verify_after_boot.sh` 是在「`adb remount` + push 若干文件 + 重启」
的调试态设备上跑的。虽然每个关键文件的 md5 都与包内逐字节一致，但**没有
再重复一次「四清 → 完整分区写入 → 干净冷启动」**。第十八章补上这条最严格
的路径，并纠正了 16.6 里一个不能推广的绕行做法。

**已知限制不变**：平板 `cm_ardbeg` 的 eng 包仍是 1104 早期状态，1106/1107
的全部修复只固化在 TV 版，详见 16.13 末节。

---

## 十八、真机刷机实验：按块表重写 system → 写 boot → 手工四清 → 干净冷启动（2026-11-07 收官）

### 18.1 为什么要做这一步

第十七章的所有验收都建立在「调试态」上：先 `adb remount` 把修好的文件
push 进 `/system`，再重启跑测试。这能证明「文件内容对」，但证明不了
「**最终 OTA 包自己**从一张白纸（干净 `/data`）能不能把机器带起来」。
本轮把 `dist/fulltest-1107-1354/cm_ardbeg_tv-ota-eng.dy.zip` 真正刷进设备：

1. 在 recovery 里按 `system.transfer.list` 逐条写 `mmcblk0p10`；
2. 写 `boot.img` 到 `mmcblk0p9`；
3. 手工补齐被 TWRP UI 崩溃截断的 `wipe data`；
4. 干净冷启动，复跑四套验收。

### 18.2 刷写前基线：设备分区与最终包**并不一致**（本轮最重要的发现）

从 zip 解出 `system.new.dat` / `system.transfer.list` / `boot.img`，用
`otablocks.py unpack` 还原「刷完后分区应有的完整 3 GiB 镜像」，与设备
当前分区回读对比：

| 对象 | 前 3 GiB md5 |
| --- | --- |
| 设备当前 `mmcblk0p10`（调试态） | `a06035c725c77de8a23369de5017b793` |
| 最终包还原 `new_raw.img`（包内快照） | `957133f13c5aa72c00cff2b5b2cab75a` |

**不一样**。所以这次刷写不是空操作，而是把调试态分区真正替换成包内干净
快照 —— 上一轮「文件 md5 全对」并不等于「分区整体就是包」。

再看前 4 KiB（ext4 superblock）只差 **20 字节**，全是运行时字段：

| 字段 | 设备当前 | 包内快照 |
| --- | --- | --- |
| `s_mtime` | 1794030681 | 0 |
| `s_wtime` | 1793982225 | 1794031099 |
| `s_mnt_count` | 1 | 0 |

`s_inodes_count=196608`、`s_blocks_count_lo=786432`、
`s_free_blocks_count_lo=614754`、`s_uuid=da594c53…`、
`s_volume_name=system`、feature compat/incompat 全部一致 —— 同一个文件
系统，覆盖安全。

> **顺带纠正旧记录**：工作目录里的 `raw.img` md5 是 `957133f1…`，它其实是
> **包内还原的基准镜像**，不是设备分区回读，别拿它当回滚快照。

### 18.3 块表语义纠正：绝对不能把 `system.new.dat` 直接 dd 到分区开头

`otablocks.py pack` 把 3 GiB raw ext4 按 1024 块（4 MiB）分组：全零组走
`erase`，非零组才进 `new.dat`。所以 `new.dat` 是**非零组的紧凑拼接**，
目标块号是分散的：

```text
版本 4 / 第 2 行 199680（这是「new 块数」，不是分区块数）
命令 196 条（erase 1 条带 20 个区间 + new 195 条），共 215 个区间
最大区间端 786432 块 = 3.00 GiB（ext4 文件系统大小；分区本身 5.53 GiB）
new   199680 块 -> 817889280 字节 = system.new.dat 实际大小
erase 586752 块 -> 分区内清零
new 段目标块号：0、12288、13312、…、720896、753664（分散，不是连续前 780MB）
```

**README 16.6 记过「`dd ... bs=4096 count=199680` 连续写前 780MB」的绕行
做法，当时那个包的底图恰好数据连续，不能推广到所有包。** 本轮一律按块表
逐条写，语义严格等价于 recovery 的 `block_image_update()`。

### 18.4 新增 `tools/gen_flash_blocks.py`

把块表翻译成设备侧 `dd` 脚本的唯一真源，自带静态自检：

```text
生成：gen_flash_blocks.py <transfer.list> <new.dat> <输出.sh> [设备侧 new.dat 路径]
复验：gen_flash_blocks.py --verify <transfer.list> <待校验.sh> <new.dat>
```

自检内容：把产出的 215 条 `dd` **反解析回来**，与原始块表逐条比对 ——
区间覆盖 0..786432 无重叠/无空洞、`new` 的 `skip` 严格连续且总字节
等于 `new.dat` 实际大小、`erase` 的 `seek/count` 与块表一致。任何一条
不符直接退出非零，绝不产出可疑脚本。

最终产物 `flash_blocks.sh` md5 `a412b5cbe5b0aec64e7a5fba52a74a17`，
215 条 `dd` + 4 条 progress + `run_dd` 失败即停 + `sync` +
`BLOCK-FLASH-DONE`。生成器改动后重新生成，md5 不变，可复现。

### 18.5 recovery 环境与四条坑

本轮进的是 **TWRP recovery（4.4.4 kernel ramdisk）**：
`PATH=/sbin:/system/bin` 但 `/system` 未挂载，`sys.boot_completed` 为空，
`/data`、`/cache` 都要手工 `mount -t ext4`，`/tmp` 是 tmpfs。

| 坑 | 现象 | 处理 |
| --- | --- | --- |
| 后台执行被 SIGHUP | `adb shell 'sh /tmp/flash_blocks.sh &'` 立即返回，但 `/tmp/flash_blocks.log` 根本没创建，轮询 300 秒全空 | 必须**前台**执行 `adb shell 'sh /tmp/flash_blocks.sh; echo SCRIPT_RC=$?'`；TWRP 崩的只是 UI 主进程，kernel/adbd 稳定 |
| toybox `dd` 的 `skip` 2^31 边界 | `bs=4096 skip=524288`（正好 2147483648 字节）读回**空数据**，md5 变成空串的 `d41d8cd9…`，错误还被 `2>/dev/null` 吞掉 | 分区校验一律用**不带 skip 的全量读取**；或把分区 dump 成文件再算 md5 |
| recovery 工具集极简 | 没有 `wc` / `grep` / `cut` / `head` / `md5sum`；`/sbin/md5` 存在但**不接受 stdin**；`bu` 直接段错误、`toolbox` 无 `wc` | 完整性检查用 `set -- $(md5 "$DAT")` + shell 内建分词，零外部依赖 |
| 判「是否在 recovery」 | 用 `/system` 是否 rw 会误判，因为 TWRP 刷包也会 rw 挂 `/system` | 判 `sys.boot_completed` 是否为空 |
| 宿主路径写进脚本 | 生成器第一版把含空格的宿主绝对路径写进设备侧 `DAT=`，设备上不存在 | 显式传设备侧路径参数，默认 `/data/local/tmp/flash-exp/system.new.dat` |

### 18.6 分区写入与逐字节校验

```text
recovery: mount -t ext4 /dev/block/mmcblk0p21 /data
          mount -t ext4 /dev/block/mmcblk0p11 /cache
          adb push flash_blocks.sh /tmp/flash_blocks.sh     (md5 a412b5cb…)
          adb shell 'sh /tmp/flash_blocks.sh; echo SCRIPT_RC=$?'

结果：SCRIPT_RC=0
      /tmp/flash_blocks.log: BLOCK-FLASH-START → progress 50/100/150/200/215
                             → BLOCK-FLASH-DONE，无 FATAL
      dd 记录条数 = 215（与块表区间数完全一致）
```

刷完后把分区前 3 GiB dump 成文件再算 md5（`/sbin/md5` 不读 stdin）：

| 校验项 | 实测 | 期望 | 结论 |
| --- | --- | --- | --- |
| `mmcblk0p10` 前 3 GiB（刷写前） | `a06035c725c77de8a23369de5017b793` | — | 调试态 |
| `mmcblk0p10` 前 3 GiB（刷写后） | `957133f13c5aa72c00cff2b5b2cab75a` | `957133f1…` | **PASS** |
| `mmcblk0p9` 回读 2099 块 | `9aa6a27985baad70637aee30752fd134` | 同包内 `boot.img` | **PASS** |

分区已逐字节变成最终 OTA 包内的干净快照。

### 18.7 手工 wipe data + 干净冷启动，首启脚本全链路

TWRP UI 因 `framebuffer: 3 (0 x 0)` 反复重启，ORS 的 `wipe data` 会被
截断（16.5 / 16.7 记过）。在 recovery shell 里手工补齐，保留 `/data/media`
（与 TWRP 语义一致）：

```sh
for d in /data/* /data/.[!.]*; do
    [ "$d" = /data/media ] || rm -rf "$d"
done
sync; umount /data
adb reboot
```

清完 `/data` 顶层只剩 `media`（`user_de`、`packages.xml`、
`misc/profiles`、`dalvik-cache` 等全部清除）。冷启动约 75 秒
`sys.boot_completed=1`，`/data` 由框架完整重建。

**`/cache` 刻意保留**：`verify_after_boot.sh` 的 TWRP 段依赖
`/cache/recovery/last_log` 里的历史成功记录（16.10 证据边界），清掉会
制造假 FAIL；且清 `/cache` 不影响首启逻辑。因此本轮「四清」逐项对应是：
system（按块表完全重写）、data + dalvik（手工 wipe）、cache（保留，理由如上）。

持久日志 `logcat -b all -D` 里 `fb_fix` 首启脚本**自己跑完全链路**：

```text
firstboot fix start
persist.sys.ui.hw=0 (HWUI/RenderThread off)
package manager ready after 18s
setupwizard disabled
wakeup + home started / provisioned + lockscreen flags set
animation scales = 0 (window layer alpha fix)
display is ON after 0 extra round(s)
launcher window VISIBLE after 1 extra round(s)
firstboot fix done: display ON + launcher window VISIBLE
no saved wifi network -> inject default from /system/etc/wifi/ardbeg_default_network.conf
default wifi network injected (owner wifi:wifi, mode 0660)
wifi enabled after 1 retry(s)
bluetooth enabled via binder tx6 after 5 x 2s
wifi auto-connected (mNetworkInfo CONNECTED/CONNECTED)
connectivity fix done
init: Service 'fb_fix' (pid 263) exited with status 0
```

这是「**修复全部来自包内、不依赖任何 adb push 调试态补丁**」的直接证据：
干净 `/data` 下没有已保存网络，脚本走的是出厂模板注入路径（16.7 说过，
这才是「自动连接」的真正证明）。

### 18.8 干净冷启动后四套验收

| 工具 | 结果 |
| --- | --- |
| `tools/verify_ota_contents.sh`（包内往返） | **PASS = 11 / FAIL = 0** |
| `tools/verify_after_boot.sh`（普通） | **PASS = 48 / FAIL = 0** |
| `CHECK_BROWSER=1 tools/verify_after_boot.sh` | **PASS = 51 / FAIL = 0** |
| `tools/full_function_test.sh`（16 类子系统） | **PASS = 108 / FAIL = 0 / WARN = 0** |
| `patches/check.sh` | **RC = 0 / 0 个 `[错误]`** |

普通模式 48 项里包含：9 个 `/system` 关键文件 md5 与最终包逐字节一致、
boot 分区 md5、`Launcher mViewVisibility=0x0` / `KeyguardScrim=0x8`、
WiFi 自动连上预置 `CPE-0C3FB8`、蓝牙开机 ON、ANR/tombstone/Watchdog
trace 全 0。交互模式 Jelly 静置 105 秒仍在前台、抢前台日志 0。

### 18.9 已知限制与证据边界（本节务必别跳过）

**（1）`could not get context` 14 条，是已知遗留，不是回归。**
`/cache/persist_log.txt`（`logcat -b all -D`，含 kernel buffer）里有 14 条
`init: could not get context while starting 'X'`，涉及 `bootanim`、
`bootlog_logcat`(2)、`gatekeeperd`、`mediadrm`、`pbc`、`perfprofd`、
`set_hwui_params`、`sysinit`、`tzdatacheck`、`bootstat`(4)。根因仍是
4.4.4 `/sepolicy` 缺 7.1 的 type（第十七章同一条链）。它们都是次要或
已有替代的服务：开机动画有 `zz-bootanim-fix`、日志有 `persist_logcat`
（已 `seclabel u:r:init:s0` 且实测 running）、HWUI 有
`persist.sys.ui.hw=0`。**真机 108 项功能测试未发现功能缺失**，故本轮
不擅自改动 ROM（动它们要改 ramdisk + 多个 rc、重打包、重刷验证，风险
远大于收益）。后续若要补齐，做法与 `zz-persist-log.rc` 相同：给对应
service 加 `seclabel u:r:init:s0`。

**（2）验收脚本判 `could not get context = 0` 不矛盾。**
`verify_after_boot.sh` / `full_function_test.sh` 抓的是 `logcat -d`
（main/system buffer），这 14 条来自 `(logd.klogd)` 转发的 **kernel
buffer**；`persist_logcat` 用 `-b all -D` 才收得到。两个 buffer 不同，
不是「验收漏判」，是判据作用域不同。以后若要把这类日志纳入判据，
必须显式 `logcat -b all` 并单独定性，否则会制造假红。

**（3）`Watchdog` 4 条 / `wifiloader` 12 条都是正常日志。**
Watchdog 全是 `SystemServer: InitWatchdog`、
`WifiConnectivityManager: scheduleWatchdogTimer`、
`WifiStateMachine: Start Dhcp Watchdog`，**没有**
`WATCHDOG KILLING SYSTEM PROCESS`。`wifiloader` 是开机一次性加载
（BCM4354 识别、load bcmdhd），末尾 `exited with status 0`，不再是
16.5 那种每 5 秒重启 990 条 —— `oneshot` 修复有效。

**（4）`last_log` 的边界不变（16.10）。**
本轮 system 是 `dd` 按块表写入的，**不经过 TWRP updater**，所以
`/cache/recovery/last_log` 里那次成功 ORS 安装记录属于更早的安装，
不是本次的证据。本次证据是分区逐字节 md5 + 首启脚本全链路日志。

### 18.10 六层固化与最终结论

| 层 | 文件 | 本轮改动 |
| --- | --- | --- |
| ① 工具真源 | `tools/gen_flash_blocks.py` | **新建**，块表展开 + 静态自检 + `--verify` + 五类坑位注释 |
| ② 生成物 / 证据 | `work/flash-experiment-fulltest-1107-1354/` | `flash_blocks.sh`(md5 `a412b5cb…`)、`preflash-baseline.txt`、`flash-write-evidence.txt`、`persist_log-cleanboot.txt`、四套验收 log |
| ③ 总检查 | `patches/check.sh` | 新增「真机刷机实验工具链」核验段（工具存在、`py_compile`、11 个坑位关键字、`--verify` 块表/脚本一致）；`doc_keys` B 组加入 `gen_flash_blocks.py` |
| ④ 全量编译注册 | 无 | 本轮**没有改动任何进 `system.img` 的文件**，无需注册 |
| ⑤ 文件级重打包 | 无 | **不需要重打包**，最终包 md5 仍是 `fd550a7a662a21824ca635206a6f0e87` |
| ⑥ 文档 / 日志 | `patches/README.md` 第十八章、`.workbuddy-ai/memory/2026-11-07.md` | 完整根因、命令、证据、已知限制 |

**最终结论**：`dist/fulltest-1107-1354/cm_ardbeg_tv-ota-eng.dy.zip`
（395983040 字节 / md5 `fd550a7a662a21824ca635206a6f0e87`）已在真机上
完成「按块表重写 system → 写 boot → 手工四清 → 干净冷启动」的最严格
路径验证：分区逐字节等于包内镜像，首启脚本从零配置走完
SetupWizard 禁用 / 显示点亮 / WiFi 出厂模板自动连接 / 蓝牙 Binder 自启，
四套验收 **11/11、48/48、51/51、108/108** 全通过，`check.sh RC=0`。
该包即为最终可刷入 ROM，无需再重打包。

### 18.11 收官补强：六层**字节级**一致性矩阵

**【为什么要补这一层】**
18.10 的六层表列的是「改动落在哪一层」，仍然是**文件与注册**层面的
证据；`check.sh` 也只做存在性 / 静态判据。历史上出现过 `check.sh`
22/22 全绿、但设备上 `/system/lib/libEGL.so` 的 md5 始终是原版
`3cd50337…` 的脱节 —— 因为 `PRODUCT_COPY_FILES +=
…/libEGL.so:system/lib/libEGL.so` 的目标已由 AOSP `libEGL` 模块产出，
被 `build/core` 静默 `ignored`（详见 `device.mk` 第 632~691 节注释）。
**「补丁应用了」≠「补丁进 ROM 了」≠「补丁在真机生效」。**

**【新增工具】** `tools/verify_six_layers.py`（设备树真源，宿主侧运行，
不进 ROM）把同一个文件在六层上的 md5 摆成一张表：

| 层 | 来源 | 判据类型 |
| --- | --- | --- |
| L1 期望基准 | `tools/verify_ota_contents.sh` / `verify_after_boot.sh` 的 `EXPECT_MD5` | 声明 |
| L2 源码补丁 | `patches/**/*.patch`（42 个）+ `device.mk` 构建期断言 | 全量编译侧注册 |
| L3 设备树真源 | `initfiles/` `prebuilt/lib/` `wifi/` | 字节 |
| L4 overlay + 注册 | `repack/overlay/system/` + `apply_overlay.py` 的 `FILES` | 字节 + 声明 |
| L5 最终包内 | zip → 还原 3 GiB raw ext4 → `debugfs dump` → md5 | 字节 |
| L6 真机 | `adb shell md5sum /system/...` | 字节 |

**【工具自身的坑位】**

1. 容器里没有 `debugfs`，必须 `flatpak-spawn --host debugfs`；
   `debugfs -f cmdfile` 的参数按空格切分，dump 目标路径必须走无空格
   软链 `/home/dy/wbrp`。
2. debugfs 看到的是 **ext4 根**，`/system/lib/libEGL.so` 要写成
   `/lib/libEGL.so`。
3. `system.new.dat` 是紧凑拼接（见 18.3），必须按 `transfer.list`
   还原成 raw 再 dump，不能直接当镜像读。
4. 工具默认复用 `work/flash-experiment-fulltest-1107-1354/new_raw.img`，
   但**强制校验全量 md5** `957133f13c5aa72c00cff2b5b2cab75a` 才允许
   复用，防止拿旧底图冒充当前包；磁盘只剩 22G 时不重复还原第二份
   3 GiB。
5. `libminijail.so` 是 AOSP 构建产物的二进制补丁结果，设备树没有
   真源，矩阵里记 `N/A`，**不是漏文件**。
6. 设备侧 `adb shell` 输出带 `\r` 必须 strip；`md5sum` 失败返回空串
   要算 FAIL，不能当成 0。
7. 工具头部保留「禁止 `screencap -p`」的坑位注释，但**静态检查脚本
   grep 危险命令时要按注释行剔除**，否则说明文字会被误判成实际调用。
8. **【续跑实测踩到并已修】** `--offline` 时 L6 是 `SKIP` 占位符，
   首次实现把它塞进了 `md5 == expect` 的判据列表，结果前五层全对
   却报出 9 个假 FAIL。跳过的层必须**整体从判据列表剔除**，不能给
   一个「假相等」的值；修复后 offline 复跑 `共 0 个 FAIL`。

**【实测结果】** 续跑后留档
`work/flash-experiment-fulltest-1107-1354/six-layer-md5-matrix.txt`：

```text
L0 [PASS] 包 md5 fd550a7a662a21824ca635206a6f0e87 / 395983040 字节
L0 [PASS] zip 17 条目、testzip 干净、build.prop persist.sys.ui.hw=0
L2 [PASS] AOSP 源码补丁 42 个
L4 [PASS] apply_overlay.py FILES 已注册 9 个目标路径
L5 [PASS] raw 3221225472 字节 / md5 957133f13c5aa72c00cff2b5b2cab75a
L6 [PASS] 9/9 个设备侧 md5
逐文件 9 行全 PASS，汇总：前置层 FAIL=0，逐文件 FAIL=0，共 0 个 FAIL
```

9 个关键文件（`libEGL.so`、`lmkd.rc`、`sf_hwc_off.sh`、
`libselinux_bypass.so`、`libminijail.so`、首启脚本、home watchdog、
默认 WiFi 模板、`zz-persist-log.rc`）在**包内 / overlay / 真源 / 设备**
四处 md5 全部等于期望基准，这是「补丁确实集成到设备树并固化进刷机包」
最硬的一层证据。

**【固化】**
`patches/check.sh` 新增「六层字节一致性矩阵」核验段（工具存在、
`py_compile`、11 个坑位关键字、矩阵报告必须 `共 0 个 FAIL`）；
`doc_keys` B 组加入 `tools/verify_six_layers.py`。
本轮**没有改动任何进入 `system.img` 的文件**，最终 OTA 包 md5 仍是
`fd550a7a662a21824ca635206a6f0e87`，不需要重打包。

**【复跑方式】**

```sh
cd /home/dy/aosp14/device/nvidia/ardbeg
python3 tools/verify_six_layers.py             # 全六层，需 adb 在线
python3 tools/verify_six_layers.py --offline  # 设备不在线时跳过 L6
python3 tools/verify_six_layers.py --zip /path/x.zip --raw /path/raw.img --raw-md5 <md5>
```

## 十九、硬件解码专项：NVIDIA OMX 真机验证 + 首启脚本抢前台修复（2026-11-07 收官）

### 19.1 本轮用户要求与最终结论

用户在「adb 连接设备 → 全面测试 → 固化刷机包 → 更新设备树 → 真机 TWRP
刷入验证 → 重复以上操作」这个闭环里追加了 **「重点检查硬件解码能力」**。
它的验收含义不是「`libnvomx.so` 在 `system/lib` 里就算通过」，而是必须逐级
证明：

1. `OMXMaster::addVendorPlugin()` 真的 `dlopen` 了 `libstagefrighthw.so`；
2. `OMX.Nvidia.*` 真的被 `MediaCodecList` 枚举、`ACodec` 能创建实例；
3. H.264 / H.265 真的由 NVIDIA OMX 组件解码并跑到 `EOS detected`，
   没有回落到软解，没有 `0x80001000` / `NvxNvMMTransformOpen failed` /
   `Could not get AVP handle`。

**最终结论：通过。** 干净四清 + 冷启动后 `tools/verify_hwdec.sh` 得到
`PASS = 26  FAIL = 0`，两种编码都出现
`TVMR: NvMMLiteTVMRDecDoWork: 3999: NVMMLITE_TVMR: EOS detected`。
当前交付包：

```text
dist/homeguard-1107-1705/cm_ardbeg_tv-ota-eng.dy.zip
  395989153 字节 / md5 2ed2bde2b433d07979c9e163cbbd21ca
  boot.img 8597504 字节 / md5 9aa6a27985baad70637aee30752fd134（未改动）
  raw ext4 3221225472 字节 / md5 fdd9f6d4465fffcb45a3f5e8d390be31
```

### 19.2 先推翻一个历史误判：`createOMXPlugin(bool secure)`

`vendor/nvidia/ardbeg/blobs-blacklist.txt` 和 `device.mk` 旧注释都写过
「7.1 要求 `createOMXPlugin(bool secure)`，4.4 blob 是无参版，所以排除」。
这个判断是错的，直接导致此前所有 ROM 里**完全没有** `libstagefrighthw.so`。

读本树源码即可证伪：

```cpp
// frameworks/av/media/libstagefrighthw/omx/OMXMaster.cpp
typedef OMXPluginBase *(*CreateOMXPluginFunc)();      // 无参
...
void *vendorPlugin = dlopen("libstagefrighthw.so", RTLD_NOW);
createOMXPlugin = (CreateOMXPluginFunc)dlsym(vendorPlugin, "createOMXPlugin");
if (!createOMXPlugin)
    createOMXPlugin = (CreateOMXPluginFunc)dlsym(
        vendorPlugin, "_ZN7android15createOMXPluginEv");  // 正是无参符号
```

`hardware/nvidia/libstagefrighthw/omxplugin.cpp` 里 NVIDIA 官方 14.1 桥
同样是无参 `createOMXPlugin()`。原厂 4.4 的 `libstagefrighthw.so` 正好
导出该符号，可以原样复用。`device.mk` 注释已改写，并注册：

```make
$(LOCAL_PATH)/prebuilt/lib/libstagefrighthw.so:system/lib/libstagefrighthw.so
$(LOCAL_PATH)/media/media_codecs.xml:system/etc/media_codecs.xml
```

注意这里用的是 `PRODUCT_COPY_FILES` **新增目标**，不会撞上 18.11 里
`libEGL.so` 那种「目标已由 AOSP 模块产出被 build/core 静默 ignored」的坑。

### 19.3 三条独立根因，缺一条硬解就不成立

| # | 缺失项 | 精确症状 | 修复 |
| --- | --- | --- | --- |
| 1 | `system/lib/libstagefrighthw.so` | 临时 push 之前，所有 `OMX.Nvidia.*` 都是 `InvalidComponentName(0x80001002)`；`dumpsys media.codec` 里只有软解组件 | 正式收录原厂 4.4 blob（5420 字节 / md5 `7221cb3656b33b54846e34b5e406163c`） |
| 2 | `system/etc/media_codecs.xml` 7.1 兼容版 | 4.4 风格「同一组件名重复声明多个 mime」触发 `MediaCodecList.cpp:737` 的 `if (mUpdate != (index >= 0)) return -EINVAL`，随后 `parseTopLevelXMLFile()` 执行 `mCodecInfos.clear()`；`ACodec` 报 `Unable to instantiate a decoder for type 'video/avc' with err 0xfffffffe` | 重写为 7.1 版（9495 字节 / md5 `9c884d66a4e7d44a0b7227cc2ec8ddb5`）：53 个组件名唯一，多 mime 改用 `<Type>` 子元素 |
| 3 | `system/etc/init/mediacodec.rc` 的 `group ... media` | 组件能创建、`NvMMLiteOpen` 也起来了，但 `NvxVideoDecoderAcquireResources : NvxNvMMTransformOpen failed` → `ACodec [OMX.Nvidia.h264.decode] ERROR(0x80001000)`；内核日志另有 `TVMR: NvMMDecTVMRCreateParser: 4567: - Could not get AVP handle` | 服务组补 `media`（`/dev/tegra_avpchannel` 是 `media:media 0660`），文件 4290 字节 / md5 `e5dfd2d55c04eb72cbb89ff2327ce4f1` |

三条根因的因果解释：

- `0xfffffffe` **不是 OMX 组件返回的错误**。`ACodec.cpp:6828` 里
  `status_t err = NAME_NOT_FOUND;`，`findMatchingCodecs()` 返回空列表时
  for 循环一次都不进、`node == 0`，最后打印 `Unable to instantiate a
  decoder ... err 0xfffffffe`。它只是「codec 列表被清空」的结果。
- 7.1 的 `MediaCodecList::addMediaCodecFromAttributes()` 是**探测式解析**：
  对每个 `<MediaCodec>` 调 `initializeCapabilities()` →
  `MediaCodec::QueryCapabilities()` → `ACodec::queryCapabilities()`，
  组件创建与能力查询成功后才加入 `mCodecInfos`，失败则静默丢弃该 mime。
  因此 XML 一旦写错，表现是「整个 codec 表空了」而不是「报错说 XML 错了」。
- 第三条最隐蔽：`nvavp` 固件加载成功，`/dev/tegra_avpchannel` 也存在，
  但 `mediacodec` 进程没有 `media` 补充组就打不开 AVP 通道。事后
  `chmod 666` 节点**无效**——失败的 handle 已在进程内缓存，必须让服务
  从启动那一刻就带上正确的组，所以只能冷启动验证。
  补组后日志改走 `NvMMLiteOpen / NvMMLiteBlockCreate` 并成功解码。

顺带排查但**排除**的干扰项：`media_codecs_performance.xml` 缺失
（`ignore_errors=true`，不清空主列表）、`libavcodec.so` text relocations
与 `FFMPEGSoftCodec: Failed to load FFMPEG plugin`（软解侧问题）、
`libnvcap_video.so` / `libnvomxadaptor.so` 的
`_ZN7android12MemoryDealerC1EjPKc` 符号缺口（`libnvomx.so` 并不引用它们，
属 hwcomposer / video capture 路径，不是普通 H.264 解码路径）。

### 19.4 静态检查必须剔除注释（同类坑第二次踩到）

AOSP `media_codecs.xml` 头部注释自带示例
`<MediaCodec name="OMX.foo.bar" ...>` 且出现多次。若直接对全文做
`findall` 检查重名，会把**注释里的示例**当成重复组件名误报。这与
18.11 坑位第 7 条「`check.sh` 用 `grep -Fq 'screencap -p'` 撞上
『禁止使用』说明注释」完全同类。现在 `apply_overlay.py` 里先

```python
xeff = re.sub(r'<!--.*?-->', '', xbody, flags=re.S)
```

再做组件名重名检查，输出 `53 个组件，无重名`。

### 19.5 第一次真机闭环：23 PASS / 1 FAIL，但**不是硬解故障**

刷入 `dist/hwdec-1107-1650/...`（395987639 字节 /
md5 `52a0d8eecac76db843dcd24b63de1241`）后，两条根因已全部验证通过：

```text
PASS  libstagefrighthw.so / media_codecs.xml / mediacodec.rc 三个 md5
PASS  /dev/tegra_avpchannel 保持 media:media 0660
PASS  mediacodec supplementary groups 含 media(1013)
PASS  冷启动 OMX 组件枚举条数 = 63
PASS  h265 EOS detected = 2
FAIL  h264 EOS detected: 实际[0] 期望 >= 1
```

H.265 完整跑完、H.264 组件实例和 `NvMMLiteOpen` 都成功，却拿不到 EOS。
翻 `logcat-h264.txt` 找到真因：

```text
16:54:09.748  OMXMaster: makeComponentInstance(OMX.Nvidia.h264.decode)
16:54:09.772  NvMMLiteOpen : Block : BlockType = 261
16:54:09.885  fb_fix: launcher window not visible (round 0), dismiss keyguard + restart HOME
16:54:11.621  ActivityManager: START u0 {... com.cyanogenmod.trebuchet/...Launcher}
16:54:11.639  NuPlayerDriver: reset(...)
16:54:11.649  NvMMDecTVMRDestroyParser: 4134: NvAvpClose
```

也就是说：**首启脚本把「用户打开视频播放器导致 Launcher 窗口 GONE」
误判成黑屏**，`am start HOME` 抢前台，播放在 1.9 秒处被打断。

这里推翻了 15.2 之后的一个旧假设：「首启阶段前台本就应该是桌面，
所以 `zz-ardbeg-firstboot-fix.sh` 不需要 `foreground_is_home()` 守卫」。
该脚本是 `class late_start` + `oneshot`，**每次开机跑一遍**，但因为
`settings put` / WiFi / BT 轮询会持续 1~2 分钟，期间用户完全可能已经
打开视频或浏览器。常驻守护 `zz-ardbeg-home-watchdog.sh` 早就补了守卫，
首启脚本却没有，形成漏网。

### 19.6 修复：`foreground_is_home()` 守卫 + 新增验收判据

`initfiles/zz-ardbeg-firstboot-fix.sh` 第 8 步改为：

```sh
# 前台 Activity 是不是 HOME。四清首启时若用户/测试已经打开别的应用，
# 这里返回 false，第 8 步必须立刻收手，不能把人踢回桌面。
foreground_is_home() {
    dumpsys activity activities 2>/dev/null \
        | grep -m1 'mResumedActivity' \
        | grep -q 'com.cyanogenmod.trebuchet'
}

q=0
while [ $q -lt 3 ]; do
    if launcher_visible; then ... break; fi
    if ! foreground_is_home; then
        log "non-HOME app in foreground, skip HOME restart (normal, not black screen)"
        break
    fi
    wm dismiss-keyguard >/dev/null 2>&1
    am start -n "$HOME_ACT" >/dev/null 2>&1
    ...
done
```

新文件：34402 字节 / md5 `231f397b82a71d94f16c9846140ed9a1` / 权限 755 /
`sh -n` 通过。README 15.x 里出现的旧 md5
`21960cdd4b2c71db7f4dda534a56280b` **保留为历史留档**，已被本值覆盖。

`tools/verify_hwdec.sh` 的 `play_one()` 新增一条判据，专治这种「硬解明明
正常却被别的子系统打断」的假红：

```sh
expect "$tag 播放期间 HOME 抢前台" \
       "$(cnt 'ActivityManager: START u0.*com.cyanogenmod.trebuchet' "$log")" "0"
```

另外要区分清楚：**EOS 之后**出现 `NuPlayerDriver: reset` / `NvAvpClose`
是播放结束后的正常释放（第二轮 17:10:21.346 EOS → 17:10:22.07 reset）；
**起播 1.9 秒就** reset 才是异常。

### 19.7 第二次真机闭环：26 PASS / 0 FAIL

按同样流程重来一遍：四清（清 `/data/*` 保留 `/data/media`、清 `/cache/*`
保留 pstore）→ 按 OTA 块表 215 条 `dd` 写 `mmcblk0p10` → 写 boot →
`adb reboot` 冷启动 → 硬解专项。留档
`work/homeguard-flash-1107-1705/verify-hwdec-after-flash.log`：

```text
PASS  /dev/tegra_avpchannel 保持 media:media 0660
PASS  mediacodec supplementary groups 含 media(1013)
PASS  冷启动 OMX 组件枚举条数 = 63 (>= 50)
PASS  h264 组件实例 / NvMMLiteOpen / EOS detected = 1
PASS  h265 组件实例 / NvMMLiteOpen / EOS detected = 1
PASS  h264/h265 0x80001000 / NvxNvMMTransformOpen failed /
      Unable to instantiate / Could not get AVP handle = 0
PASS  h264/h265 播放期间 HOME 抢前台 = 0
汇总：PASS = 26   FAIL = 0
```

关键日志（可复核到具体 pid）：

```text
17:10:13.809  292 I OMXMaster: makeComponentInstance(OMX.Nvidia.h264.decode) in mediacodec process
17:10:13.824  292 D NvOsDebugPrintf: NvMMLiteOpen : Block : BlockType = 261
17:10:21.346  292 D NvOsDebugPrintf: NVMMLITE_TVMR: EOS detected
17:10:34.245  292 I OMXMaster: makeComponentInstance(OMX.Nvidia.h265.decode) in mediacodec process
17:10:41.389  292 D NvOsDebugPrintf: NVMMLITE_TVMR: EOS detected
```

### 19.8 六层固化清单（这是「集成到设备树」的完整答案）

| 层 | 硬解三文件 + 首启守卫的落点 |
| --- | --- |
| L1 期望基准 | `verify_ota_contents.sh` / `verify_after_boot.sh` / `verify_six_layers.py` / `full_function_test.sh` 四张 `EXPECT_MD5` 表均已换成 `231f397b...`，并补 3 个硬解文件 |
| L2 全量编译 | `device.mk` 注册 2 个 `PRODUCT_COPY_FILES`；`patches/frameworks/av/services/mediacodec/mediacodec.rc.patch` 补 `group ... media` 的长注释与 diff；`check.sh` 语义检查 `^\+[[:space:]]*group .*media` |
| L3 设备树真源 | `prebuilt/lib/libstagefrighthw.so`、`media/media_codecs.xml`、`initfiles/mediacodec.rc`（4290 字节）、`initfiles/zz-ardbeg-firstboot-fix.sh` |
| L4 文件级重打包 | `repack/overlay/system/{lib,etc/init,etc,bin}/…` 四份副本 + `apply_overlay.py` 的 `FILES` 注册；`apply_overlay.py` 对 XML 重名 / rc 的 `media` 组做硬校验 |
| L5 最终 OTA zip | `verify_ota_contents.sh` 包内往返 `14 PASS / 0 FAIL`；zip md5 `2ed2bde2…` |
| L6 真机 | `work/homeguard-flash-1107-1705/system-md5-after-flash.txt` 12 个文件回读全对；`verify_hwdec.sh` 26/0 |

`check.sh` 也新增了对首启脚本**有效守卫**的语义检查，防止有人只改注释：

```sh
if ! grep -Eq '^[[:space:]]*if ! foreground_is_home; then' "${FB_DEV}"; then
    echo "  [错误] 首启脚本缺 foreground_is_home() 有效守卫..."
fi
```

### 19.9 证据边界修正：`last_log` 三项从「假 FAIL」改成 SKIP 分流

16.10 当年只在文档里写了「`last_log` 段不是本次安装证据，应降级为
可选 / 仅提示」，**代码并没有跟着改**。于是第二轮闭环
`CHECK_BROWSER=1 verify_after_boot.sh` 得到 `51 PASS / 3 FAIL`，三个 FAIL
全是：

```text
FAIL  last_log execv failed:           实际[] 期望[0]
FAIL  Updater process ended with RC=0: 实际[] 期望[1]
FAIL  script succeeded:                实际[] 期望[1]
```

真机上 `/cache/recovery/` 是空目录，实测 `NOT PRESENT`。原因有两条，
都是设计使然：四清脚本显式清空 `/cache/recovery/*`；刷 system 走
recovery shell 按块表 `dd`，**不经 TWRP updater**，自然不写 `last_log`。
链式后果是 `grep -c ... 2>/dev/null || true` 返回空串，被
`expect ... "1"` 判成功能故障。

现在 `verify_after_boot.sh` 先采 `@last_log_present`，再二选一：

- **证据链 A**（`last_log` 存在）：严格判「文件有内容 / execv failed=0 /
  RC=0 / script succeeded=1」四项。
- **证据链 B**（不存在）：`SKIP` 一项，并强制
  `expect "分区级字节证据（12 文件 md5 + boot md5）全绿" $MD5_SECTION_FAIL 0`。
  即「跳过 updater 日志」的代价是分区字节证据必须整段 0 FAIL，
  严格性没有降低，只是换成能覆盖当前刷入路径的证据链。

汇总行改为 `PASS = xx   FAIL = x   SKIP = n`，并显式说明 SKIP 不是功能缺失。
`check.sh` 增加非注释行的分流代码检查，防止这段又被删回假红。

**修复后复跑**（同一台设备、同一个包、`CHECK_BROWSER=1` 含 105 秒浏览器
静置），留档 `work/homeguard-flash-1107-1705/verify_after_boot_v2.log`：

```text
VAB_RC=0
PASS = 52   FAIL = 0   SKIP = 1
  证据链 B：四清 + recovery shell 按 OTA 块表 dd 写入（不经 updater）
  SKIP  last_log updater 三项（证据边界，非 ROM 故障）
  PASS  分区级字节证据（12 文件 md5 + boot md5）全绿 = 0
  PASS  Jelly 启动后在前台 = 1 / 静置 105 秒后仍在 Jelly = 1
  PASS  WiFi 自动连上 CPE-0C3FB8 = 1 / 蓝牙 state: ON = 1
  PASS  logcat 落盘行数 8416（非空，根因关键字全 0）
  PASS  display ON / Launcher 0x0 / KeyguardScrim 0x8 / 前台是 Launcher
```

也就是说 3 个假红消失后，端到端验收从 `51/3` 变成 `52/0/1`，
并且浏览器静置、WiFi/BT 自启、窗口可见性这些真正的功能项全部仍绿。

`full_function_test.sh` 第 11 节有完全相同的硬判据，第二次全面测试
同样得到 `110 PASS / 1 FAIL`（唯一 FAIL 也是 `last_log` 非空）。已按
同样思路加 `skip()` / `SKIP` 计数与存在性分流；缺失时由第 12 节
12 项 `/system` md5 独立承担分区字节证据（任一项失败脚本仍 RC=1）。
复跑结果 `110 PASS / 0 FAIL / 0 WARN / 1 SKIP`。两个工具的 `SKIP` 都
指向同一个证据边界，不是两处功能缺失。

### 19.9b 收官全套复验矩阵（同一包 / 同一台真机）

| 工具 | 范围 | 结果 |
| --- | --- | --- |
| `patches/check.sh` | 补丁 / 设备树 / overlay / 打包注册 / 产物静态总检 | `RC=0`，0 个 `[错误]` |
| `verify_ota_contents.sh` | zip → raw ext4 → debugfs，12 文件 md5 + 2 个 rc | `14 PASS / 0 FAIL` |
| `verify_six_layers.py`（在线） | L1~L6 六层字节矩阵，12 个文件逐行 | `共 0 个 FAIL` |
| `verify_after_boot.sh CHECK_BROWSER=1` | 四清冷启动端到端 + 105 秒浏览器静置 | `52 PASS / 0 FAIL / 1 SKIP` |
| `full_function_test.sh` | 16 类子系统 / 设置二级菜单 / 浏览器 / adb 通道 | `110 PASS / 0 FAIL / 0 WARN / 1 SKIP` |
| `verify_hwdec.sh`（第二轮） | 冷启动 OMX 枚举 63 + H.264/H.265 到 EOS | `26 PASS / 0 FAIL` |
| `verify_hwdec.sh`（重复闭环第三次） | 再冷启动一次，重跑同一专项 | `26 PASS / 0 FAIL` |

第三轮留档 `work/homeguard-flash-1107-1705/verify-hwdec-recheck.log`：
H.264 `17:28:17.068 makeComponentInstance` → `17:28:24.580 EOS detected`，
H.265 `17:28:37.606` → `17:28:44.746 EOS detected`，
`HOME 抢前台 = 0`。冷启动后轻量复核：`sys.boot_completed=1`、
`init.svc.persist_logcat=running`、`ardbeg_homewd=running`、
`fb_fix=stopped`、WiFi `CONNECTED/CONNECTED "CPE-0C3FB8"`、蓝牙
`state: ON`、四个硬解/首启关键文件 md5 全对、抢前台计数 0。
这构成用户要求的「重复以上操作」闭环：两次完整四清刷入 + 三次
冷启动硬解专项，结论一致。

### 19.10 复现命令

```sh
cd /home/dy/aosp14/device/nvidia/ardbeg/patches && ./check.sh
cd /home/dy/WorkBuddy\ AI/ardbeg-cm-14.1/repack && ./make_ota.sh <tag>
cd /home/dy/aosp14/device/nvidia/ardbeg
./tools/verify_ota_contents.sh                  # 包内往返 14/0
./tools/verify_hwdec.sh                          # 真机硬解 26/0（需冷启动）
CHECK_BROWSER=1 ./tools/verify_after_boot.sh    # 端到端（含 105 秒浏览器静置）
python3 tools/verify_six_layers.py               # 六层字节矩阵
./tools/full_function_test.sh                   # 16 类子系统 108 项
```

### 19.11 仍然存在的已知限制（不藏着）

- TWRP GUI 因 `framebuffer 0x0` 反复崩溃，`twrp install` / ORS 引擎都依赖
  主进程，本机无法走原生 updater 安装；真机闭环用按块表 `dd` 等价实现
  `block_image_update()`，代价就是没有本次 `last_log`（见 19.9）。
- `dumpsys media.codec` 实测 RC=0 但输出为空，不能用「0 字节」判定服务
  不存在；必须结合 `service list`、`ps`、`/proc/<pid>/maps` 与 logcat。
- `stop; start` 在本机不会重建 `media.codec`（pid 不变，随后 `am` 报
  `DeadObjectException`），硬解修复必须 `adb reboot` 冷启动验证。
- 14 条 `could not get context` 仍来自 4.4.4 sepolicy 缺域的次要服务，
  真机 108 项功能测试未发现功能缺失，未擅自改 ROM。
- `libnvomxadaptor.so` 的 `MemoryDealer` 符号缺口影响 video capture /
  hwcomposer 路径，普通 H.264/H.265 解码不经过它；若日后要验摄像头录屏
  编码需另开一轮。

### 19.12 结论

硬件解码三条独立根因已全部定位、修复并固化到设备树 / AOSP patches /
overlay / 打包注册 / 验收工具 / 最终 OTA / 真机六层；首启脚本抢前台这一
「非硬解根因但会让硬解验收假红」的问题也已一并修掉。两次真机闭环
（23/1 → 定位 → 26/0）构成完整证据链，**本章当时的交付包**为
`dist/homeguard-1107-1705/cm_ardbeg_tv-ota-eng.dy.zip`；后续重打包见第二十章。

## 二十、app 视频播放 / 开机自启复核 + 全量固化重打包（2026-11-07 晚间）

### 20.1 本轮用户要求与结论

用户连续提出：adb 连接设备验证硬件解码能力 → 检查 app 视频播放 →
把修改固化进刷机包并更新设备树 → adb 抓日志复核 WiFi / 蓝牙开机自启与
自动连接、解决浏览器闪退。**复核结论：这几项功能在真机上全部正常，
本轮没有发现需要再次修改 `system.img` 的缺陷**；固化动作是新增可重复
验收工具、把基准全面对齐到重新打包的最终 OTA，并留下运行时证据链。

### 20.2 硬件解码（adb 连接后的运行时证据）

`verify_hwdec.sh` 冷启动后 **26 PASS / 0 FAIL**：OMX 组件枚举 63 条；
H.264 `makeComponentInstance(OMX.Nvidia.h264.decode)` → `NvMMLiteOpen` →
19:50:24.465 `EOS detected`；H.265 → 19:50:50.319 `EOS detected`；
`0x80001000` / `NvxNvMMTransformOpen failed` / `Unable to instantiate` /
`Could not get AVP handle` 全 0。即时采集还确认：
`/dev/tegra_avpchannel` 为 `media:media 0660`，`mediacodec`（uid 1046）
补充组含 `1013`，进程已映射 `libstagefrighthw.so` / `libnvomx.so` /
`libnvmmlite.so` / `libnvavp.so` / `libnvmmlite_utils.so` / `libnvavp.so`。

### 20.3 app 视频播放四类入口（新增 `tools/verify_app_video.sh`）

| 入口 | 关键证据 | 结论 |
| --- | --- | --- |
| Gallery3d `.app.MovieActivity`（本地 mp4） | `am start -W` 617 ms 落到该 Activity；`OMX.Nvidia.h264.decode` → `NvMMLiteOpen` → `EOS detected` | 硬解播放正常 |
| 第三方在线 app `com.starcor.mango`（HLS） | 上报 `dectp=OMX.Nvidia.h264.decode`；`video decode succeeded` / `onPlayerFirstFrame`；SurfaceFlinger 帧时间戳 5 秒内 `280120000000 → 285520000000` | 走系统硬解且画面持续刷新 |
| AOSP `HTMLViewerActivity`（file:// HTML5） | `<video>` 触发 `makeComponentInstance` / `NvMMLiteOpen` / `EOS detected` 各 1 | 播放正常，但该查看器不执行 JS |
| Jelly 浏览器（http:// HTML5） | `button_clicked=1` → `play_resolved=1` → `ARDVID playing` → `t=5.78→ended@8.00` → `EOS detected`；前台 25 秒后仍是 `org.lineageos.jelly/.MainActivity` | 浏览器内视频播放正常、未闪退 |

工具实跑 **31 PASS / 0 FAIL / 1 SKIP**（SKIP 是 `CHECK_ONLINE` 未开启的
第三方在线 app 可选段，可 `CHECK_ONLINE=1` 打开）。

### 20.4 本轮新增的坑位（全部写进工具判据与 `check.sh`）

1. `cmd package resolve-activity --brief -d file://... -t video/mp4` 返回
   `No activity found`，但 `am start -W` 正常落到 Gallery3d。**不要用
   resolve-activity 的阴性结果判断「没有播放器」**。
2. Jelly 的 VIEW 过滤器只有 `http/https`，`file://` 的 HTML 会被
   `com.android.htmlviewer/.HTMLViewerActivity` 接管（不执行 JS）。
   验真浏览器必须走 HTTP。
3. 让设备访问宿主页面用 `adb reverse tcp:<port> tcp:<port>`，端口必须
   **动态探测**：8000 被占用时 `http.server` 抛
   `OSError: [Errno 98] Address already in use`，表面是「浏览器白屏」，
   极易误判成 ROM 缺陷。本轮第一次 Jelly 测试就是这样假失败的。
4. WebView 拒绝自动播放：`play() can only be initiated by a user gesture.`
   此时 `readyState=4` 但 `paused=true / currentTime=0`，必须用
   `input tap` 在真实触摸手势里调 `play()`。这是 Chromium 策略，不是 bug。
5. `ACodec: setting nBufferCountActual to 13/12/11 failed: -1010` 是
   NVIDIA OMX 不支持动态 buffer count，ACodec 降级重试后仍到 EOS，
   **属无害警告**。
6. 本机 SurfaceFlinger `isSecure=1`，再次确认**禁止 `screencap -p`**；
   判画面是否刷新用 `dumpsys SurfaceFlinger --latency <layer>` 的时间戳。
7. 宿主磁盘 100% 占满导致 `otablocks.py unpack` 抛 `ENOSPC`、留档
   `tee` 失败。清理了 9 个历史 `ota-verify-*` / `verify-*` 中间目录
   （约 34 GiB），交付包、`chk.img` / `system.patched.img` 底图、源码产物
   一律未动。**回收站机制在磁盘满时无法写入 trashinfo，且同分区移入
   回收站不释放空间**，这种构建中间产物需直接删除。

8. 【第二次复跑抓到】`input tap` 坐标脆弱：早期测试页的 PLAY 按钮只覆盖
   顶部 `28vh`，tap 取 `(W/2, H/8)`，复跑时点击落到 Jelly 原生工具栏，
   `button_clicked=0` 连带 `play_resolved` / `playing` / 硬解实例 /
   `EOS` 共 6 个假 FAIL；页面其实已 `loadedmetadata` / `canplay` /
   `readyState=4`。修法：按钮改为覆盖整个 WebView 视口
   (`width:100vw;height:100vh;z-index:99`)、点击后立即隐藏，tap 取屏幕
   正中 `(W/2, H/2)`（必然在内容区，避开 StatusBar / 地址栏 /
   NavigationBar），并保留两处兜底 tap。

9. 【工具自修改竞态】第二次复跑时脚本正在运行，又往同一个文件插入头部
   注释，bash 按原偏移继续读取，报出
   `./verify_app_video.sh: 行 293: 未预期的记号 "(" 附近有语法错误`
   这种伪语法错误（此前 `bash -n` 是通过的，文件内容本身也没问题）。
   **验收工具运行期间绝不能编辑脚本自身**；文件稳定后重跑即恢复 31/0/1。

### 20.5 WiFi / 蓝牙开机自启与自动连接（冷启动日志）

`adb reboot` 后 13×3 秒拿到 `sys.boot_completed=1`，再静置 110 秒：

```text
@wifi_on=1  @bt_on=1
@wifi_network=mNetworkInfo [type: WIFI[], state: CONNECTED/CONNECTED,
                           extra: "CPE-0C3FB8", ...]
@bt_state=  state: ON
@homewd=running  @persistlog=running  @fb_fix=stopped
20:04:53.816 BluetoothManagerService: Startup: Bluetooth persisted state is ON.
20:04:55.787 BluetoothManagerService: Auto-enabling Bluetooth.
20:05:07.319 BluetoothManagerService: TURNING_ON > ON
20:05:15.961 fb_fix: wifi network already configured -> leave /data/misc/wifi untouched
20:05:16.095 fb_fix: wifi enabled after 0 retry(s)
20:05:17.483 fb_fix: bluetooth already ON (persisted state=1)
20:05:20.976 fb_fix: wifi auto-connected (mNetworkInfo CONNECTED/CONNECTED)
```

首启脚本的 `leave ... untouched` 证明写 `/data` 的逻辑是幂等的，用户
自己配过的网络不会被覆盖。`WifiStateMachine: Failed to start HAL` /
`NETWORK_STATUS_UNWANTED_VALIDATION_FAILED` 是开机阶段的 transient，
随后已 CONNECTED，不影响结论。

### 20.6 浏览器「闪退」复核：已解决，不需要再改 ROM

冷启动后立刻把 Jelly 放到前台，静置 **110 秒**（跨过 home 守护 90 秒
冷却窗口）：

```text
@resumed = org.lineageos.jelly/.MainActivity
@focus   = org.lineageos.jelly/.MainActivity
@cnt[FATAL EXCEPTION] = 0      @cnt[ANR] = 0
@cnt[HOME in foreground but window hidden] = 0
@cnt[non-HOME app in foreground] = 2
20:05:15.714 fb_fix: non-HOME app in foreground, skip HOME restart (normal, not black screen)
```

`@cnt[HOME_START]=1` 曾被怀疑是守护抢前台，查完整时序后确认它发生在
**20:05:00.798**（`FallbackHome` → `Launcher` 的开机启动），而 Jelly 是
20:05:02.940 才启动；静置期内没有任何 HOME START。旧根因（home 守护
`launcher_visible()` 恒 false + 缺 `foreground_is_home()`）与首启脚本
抢前台两处修复都仍然有效。

### 20.7 固化动作（设备树 + 刷机包）

| 层 | 动作 |
| --- | --- |
| 新增工具 | `tools/verify_app_video.sh`（可执行，`bash -n` 通过，实跑 31/0/1） |
| 补丁总检查 | `patches/check.sh` 新增「app 视频播放验收」语义检查段（19 个关键字 + 非注释行 `screencap -p` 防回退），并把工具加入 B 组（宿主侧，不进 ROM） |
| 期望表 | `verify_after_boot.sh` / `verify_ota_contents.sh` 基准包注释切到新包；`EXPECT_MD5` 表不变 |
| 六层矩阵 | `verify_six_layers.py` 的 `EXP` / `PKG_MD5_DEFAULT` / `RAW_MD5_DEFAULT` 切到新包基准，新增 `work/appvideo-flash-1107-2005`（硬链复用，不重复占 3 GiB） |
| 最终 OTA | 按最新设备树重打包 `dist/appvideo-1107-2005/cm_ardbeg_tv-ota-eng.dy.zip` |
| 文档 / 日志 | 本章 + 项目工作日志 `2026-11-07.md` |

新包：**395989155 字节 / md5 `f23add70d0e028e5602d0d85824ad1df`**，
`boot.img` md5 仍是 `9aa6a27985baad70637aee30752fd134`，
`system.new.dat` md5 `722c7e4aa0942323cc506bae266d8e3d`，
还原 raw ext4 md5 `5488394af925e6835916cbe32630de96`。

**A 组（进 `system.img` 的文件）本轮一字未改**，重打包只是把「设备树
↔ 包 ↔ 真机」重新对齐并要求可复现交付。raw 全量 md5 变了是因为 ext4
`s_mtime` / `s_wtime` 等运行时字段被重写；判「ROM 内容有没有变」只能
看包内 debugfs dump 出来的关键文件 md5，不能看 raw 全量 md5。

### 20.8 重新打包后的验收

- `verify_ota_contents.sh`（新包）：**14 PASS / 0 FAIL**，17 条目 / 签名件在 / testzip 干净 / `persist.sys.ui.hw=0`
- `verify_hwdec.sh`：**26 PASS / 0 FAIL**
- `verify_app_video.sh`：首次 **31 PASS / 0 FAIL / 1 SKIP**；修掉 tap 坐标与
  工具自修改竞态后再次复跑仍是 **31 PASS / 0 FAIL / 1 SKIP**
  （留档 `work/appvideo-verify-final3-1107-2017`）
- `verify_six_layers.py` 在线六层：**前置层 FAIL=0、逐文件 FAIL=0，12 个关键
  文件 L1/L3/L4/L5/L6 全 PASS**；raw md5 `5488394a...` 与新包基准一致
- `check.sh`：**RC=0，0 个 `[错误]`**；自动识别最新包为
  `dist/appvideo-1107-2005`，只提示 B 组工具/文档比包新（不进 ROM）
- `full_function_test.sh`：**110 PASS / 0 FAIL / 0 WARN / 1 SKIP**
  （留档 `work/appvideo-verify-1107-2001/full_function_test_appvideo.log`）

### 20.9 已知边界（不藏着）

- TWRP GUI 仍因 `framebuffer 0x0` 崩溃，原生 updater 安装无法走通；本轮
  没有再次四清刷入（会清掉用户刚装的第三方 app），而是用「包内 debugfs
  dump md5 ↔ 真机 `/system` md5 逐字节一致」证明现有真机已包含全部固化
  内容。需要干净刷机实验时按第十八章按块表 `dd` 流程执行。
- `verify_after_boot.sh` 的 `last_log` 段是证据边界 SKIP（见 19.9）。
- `libnvomxadaptor.so` 的 `MemoryDealer` 符号缺口只影响 capture /
  hwcomposer 路径，不影响本轮验证的 H.264 / H.265 解码。



## 21. 2026-11-12 验收体系固化：把 check.sh 对齐到当前构建链路

### 21.1 背景：改动其实早已固化，错的是验收判据

`device/nvidia/ardbeg` 的 15 个提交、29 个 patch 全部已应用，真机刷入的
`5002791a80`（2026-11-11 21:50，`make otapackage` 产物）里 4 个关键脚本与
设备树真源 md5 逐字节一致。但 `check.sh` / `_common.sh` 仍停留在 11-07 的
「TV 产品 + 文件级 overlay 重打包」时代，`./check.sh` 会报出一串与现状
无关的 `[错误]`，造成「改动没固化」的错觉。

### 21.2 三处根因与修复

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| 1 | `gen_flash_blocks.py` / `verify_six_layers.py` 报「语法检查失败」 | `find_python()` 只判 `-x`，选中了缺动态 loader 的 `prebuilts/python/linux-x86/2.7.5/bin/python2.7`，`py_compile` rc=127 | 新增 `_py_can_run()` 真实执行探测；系统 `python3` 优先，源码树 `python2.7` 降为兜底且同样要过探测 |
| 2 | OTA 段报「条目数 1 < 17 / 缺 install/bin / 缺签名件 / testzip 损坏」 | 选包写死 `dist/*/cm_ardbeg_tv-ota-eng.dy.zip`，永远拿 1107 那份旧实验包 | 候选合并 `out/target/product/ardbeg/cm_ardbeg-ota-*.zip`，按 mtime 取最新；17 条目判据对标准 otapackage 产物同样适用 |
| 3 | 报「包内 build.prop 没有 persist.sys.ui.hw=0，这是 HWUI 黑屏根因」 | 该属性是 `lineage_tv.mk`（TV 产品）专属；当前 `cm_ardbeg-eng`（`lineage.mk`，tablet 产品）不 inherit 它 | 判据按产品自适应：含 `ro.ardbeg.sf_hwc_off=1` 时改验 `persist.ardbeg.fps_match` / `persist.ardbeg.gpu_video`；TV 包沿用旧判据 |

### 21.3 新增最终判据：真源 ↔ ROM 产物

`overlay/` 是 11-07 的 legacy 链路（`apply_overlay.py` 的 `FILES` 未注册
`ardbeg_fps_match.sh` / `ardbeg_gpu_video.sh`，往里补文件也不会进包），
所以「真源 / overlay 一致」不足以证明改动进了 ROM。新增一段直接比对
`initfiles/` 真源与 `out/.../target_files-*/SYSTEM/bin/` 产物的 md5，
覆盖 4 个关键脚本，缺一或字节不符都计入 `N_BAD`。

### 21.4 同步的派生副本

`repack/overlay/` 里 3 个陈旧副本同步到设备树真源（旧版备份在
`wb_tmp/overlay_backup_20261112/`）：

- `system/bin/zz-ardbeg-firstboot-fix.sh`（补上 `5cc3094` 的 4c 节 + 第 10 节，共 108 行）
- `system/bin/sf_hwc_off.sh`
- `system/etc/init/zz-sf-hwc-off.rc`

### 21.5 验收结果

`./check.sh` → **RC=0，0 个 `[错误]`**；29 个补丁「已应用 29 / 有问题 0」；
最新包正确识别为 `cm_ardbeg-ota-5002791a80.zip`（17 条目）；
4 个关键脚本「真源 = 产物」。`install.sh` / `uninstall.sh` / `_common.sh`
`sh -n` 全过，`_udiff.py` 在 python3 下 `py_compile` 与非参数调用均正常。

本轮未改任何功能代码、未改默认属性、未重打包、未刷分区、未重启设备。
