# webview —— 7.1 版 WebView 及 Tegra K1 GPU 规避补丁

## 为什么需要这个目录

设备上原来的 WebView 是 **119.0.6045.134**，它引用了 `android.webkit.PacProcessor`
——那是 **Android 8.0 才加进 framework 的类**。7.1 里 PAC 是独立系统服务
`com.android.pacprocessor`，类名 `com.android.pacprocessor.PacNative`。
所以浏览器一启动就：

```
java.lang.NoClassDefFoundError: Failed resolution of: Landroid/webkit/PacProcessor;
```

根子在源码树：`external/chromium-webview` 被整体覆盖成了新版
（`Android.mk` 里 `LOCAL_PRODUCT_MODULE := true` 是 Android 9+ 的变量，cm-14.1 不认）。

换成 Chrome 52 之后又撞上第二层问题：Tegra K1 的 GPU 厂商库是原厂 4.4.4 的，
`eglWaitSyncKHR()` 返回 `EGL_BAD_MATCH`，Chromium 合成器紧接着 `abort()`：

```
E chromium: [ERROR:gl_fence_egl.cc(62)] Failed to wait for EGLSync. error:EGL_BAD_MATCH
F libc    : Fatal signal 6 (SIGABRT), code -6 in tid xxxx (RenderThread)
```

## 两个文件是怎么来的

```sh
# 1. 从 USTC 的 AOSP 镜像取 android-7.1.2_r39 标签下的 arm 版 WebView
#    （prebuilt/arm/webview.apk，29,995,246 字节，版本 52.0.2743.100）
git clone --depth 1 -b android-7.1.2_r39 \
    https://mirrors.ustc.edu.cn/aosp/platform/external/chromium-webview.git

# 2. 从 APK 里解出 libwebviewchromium.so（lib/armeabi-v7a/，36,022,552 字节）
#    注意 APK 内部目录叫 lib/armeabi-v7a/，而落盘目录必须叫 lib/arm/
#    （armeabi 的 isa 名是 arm，见 PackageManagerService.setNativeLibraryPaths）

# 3. 给 .so 打 GPU 规避补丁
python3 patch_webview_gpu.py libwebviewchromium.so libwebviewchromium.patched.so
```

`patch_webview_gpu.py` 的完整原理写在脚本头部注释里，一句话概括：
Chromium 内嵌的 GPU 驱动 bug 规避表（纯文本 JSON，在 .so 的只读数据段里）
本来就有「Android ≤ 4.4.4 的厂商驱动 EGL 栅栏是坏的」这几条，
但用 `os.version` 当条件，我们是 7.1.2 的 framework + 4.4.4 的厂商库，匹配不上。
把它改成「所有 Android 都禁用 `EGL_KHR_fence_sync` / `EGL_KHR_wait_sync`」即可，
JSON 用空格补齐保持长度不变，所以 .so 里其它偏移一个字节都不动。

## 落盘位置（关键）

```
/system/app/webview/webview.apk                          29,995,246  0644
/system/app/webview/lib/arm/libwebviewchromium.so        36,022,552  0644
```

`lib/arm/` 这一层不能省。7.1 的 `PackageManagerService.setNativeLibraryPaths()`
对**目录式系统应用**算出来的 `nativeLibraryDir` 就是 `<codePath>/lib/<isa>`，
而 `VMRuntime.getInstructionSet("armeabi")` 返回的是 **`arm`**（不是 `armeabi`）。
少了这一层，WebView 会退回去用 APK 内部的那份 .so，补丁就白打了。

实测加载顺序（`ApplicationLoaders` 打的日志）：

```
/system/app/webview/lib/arm : /system/app/webview/webview.apk!/lib/armeabi-v7a
                            : /system/lib : /vendor/lib
```

磁盘上那份优先，所以补丁生效。

## 同步回源码树（下次全量编译前必须做）

```sh
cp webview_7.1_arm.apk      $TOP/external/chromium-webview/prebuilt/arm/webview.apk
cp libwebviewchromium.patched.so  .../   # 由 Makefile 装到 lib/arm/ 下
```

另外 `external/chromium-webview/Android.mk` 里那句 `LOCAL_PRODUCT_MODULE := true`
必须去掉（cm-14.1 没有这个变量，留着不影响但会误导）。

> 注意：不要在这个目录里再建一个 `LOCAL_MODULE := webview` 的 prebuilt 模块，
> 会跟 `external/chromium-webview` 的模块重名，`make` 直接报冲突。
> 正确做法是替换源码树里那份 prebuilt。

## 实测

```
pid 存活，fence_err=0，fatal6=0
页面完整渲染：中文、ASCII、渐变色块、JavaScript 已执行
```
