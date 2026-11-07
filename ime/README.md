# ArdbegIME —— 轻量输入法（cm_ardbeg_tv 兜底键盘）

> **目录里现在有两个输入法：**
> - `ArdbegIME`（本目录，手搓 ASCII 键盘，兜底用）
> - `BaiduInput/`（原厂百度输入法，中文主力，详见该目录的 `Android.mk` 头部注释）
>
> 中文输入请用 `BaiduInput`。本 README 主要讲 `ArdbegIME`。

## 为什么需要它

`cm_ardbeg_tv` 这个产品在 `lineage_tv.mk` 里 inherit 的是
`vendor/cm/config/common_full_tv.mk`，而 LineageOS 只把 `LatinIME` 放进这四个配置：

| 配置 | 含 LatinIME |
|---|---|
| `common_full_phone.mk` | 是 |
| `common_mini_phone.mk` | 是 |
| `common_full_tablet_wifionly.mk` | 是 |
| `common_mini_tablet_wifionly.mk` | 是 |
| `common_full_tv.mk` | **否** |

所以 TV 版 ROM 里**一个输入法都没有**：

```
# ime list -a -s
（空）
# pm list packages | grep -i latin
（空）
```

表现出来就是：进「设置 → WLAN」点一个热点、弹出输入密码的对话框，
点输入框没有任何软键盘出来，WiFi 密码根本没法输。

注意这**不是** `InputMethodManagerService` 的问题：

```
# service check input_method
Service input_method: found
```

服务一直在，只是没有任何 IME 向它注册。

## 三条修法，本设备树三条都做了

1. **正规修法**：`device.mk` 第二十一节把 `LatinIME` 加回 `PRODUCT_PACKAGES`，
   并 inherit `vendor/cm/config/dictionaries.mk` 拿到多语言词典 overlay。
   功能完整，但依赖构建系统把 `packages/inputmethods/LatinIME` 编出来。
   **只有英文，没有中文拼音方案。**

2. **兜底修法（本目录）**：`ArdbegIME` 是一个 11 KB 的预编译 APK，
   不参与任何编译，靠 `BUILD_PREBUILT` 直接装进 `/system/app/ArdbegIME/`。
   即使 LatinIME 编不过，系统里也一定有能打字的键盘。
   **同样只有 ASCII。**

3. **中文主力（`BaiduInput/`）**：原厂 4.4.4 线刷包里的百度输入法
   `com.baidu.input_baidutv` 4.0.8.9，带拼音全键 / 拼音九键 / 笔画键盘
   三套中文方案和中英切换，连同 4 个 armeabi 原生库一起放进 `BaiduInput/`。

   它是加固包，在 ART 7.1 上会因 `RegisterNatives` 注册了 dex 里不存在的
   方法而触发 CheckJNI 致命中止，**必须配合 `system.prop` 里的
   `dalvik.vm.checkjni=false`** 才能跑起来。完整排查链见
   `BaiduInput/Android.mk` 头部注释。

三个输入法包名各不相同，互不冲突，用户可在
「设置 → 语言和输入法 → 当前输入法」里切换。

确认 LatinIME 能正常编出来并且用着没问题后，可以把 `ArdbegIME` 一行注释掉
（但建议留着，它是唯一不依赖任何编译产物的那个）。

## 文件说明

```
ime/
├── Android.mk                         预编译模块定义（LOCAL_CERTIFICATE := PRESIGNED）
├── ArdbegIME.apk                      产物：已用 platform 密钥签名的 APK
├── AndroidManifest.xml                声明 InputMethodService + BIND_INPUT_METHOD
├── res/xml/method.xml                 subtype 声明（isAsciiCapable=true，密码框才会默认选它）
├── res/values/strings.xml             IME 列表里显示的名字
├── src/com/ardbeg/ime/ArdbegIME.java  全部实现（约 400 行，键盘布局用代码搭）
├── build.sh                           手工打包脚本（aapt + javac + dx + signapk）
└── BaiduInput/                        原厂百度输入法（中文主力）
    ├── Android.mk                     模块定义 + 全部排查记录（先读这个）
    ├── BaiduInput.apk                 原厂包，10.7 MB，保留原签名
    └── lib/armeabi/*.so               4 个 armeabi 原生库
                                       -> 安装到 /system/app/BaiduInput/lib/arm/
```

## 重新构建

改完 `src/` 或 `res/` 后，在**宿主机**执行（容器里没有 java）：

```sh
flatpak-spawn --host bash \
  "/home/dy/WorkBuddy AI/2026-10-23-16-34-21/aosp-src/device/nvidia/ardbeg/ime/build.sh"
```

脚本会重新生成并覆盖本目录下的 `ArdbegIME.apk`。

## build.sh 的关键点（踩过的坑）

| 坑 | 现象 | 原因与对策 |
|---|---|---|
| 路径带空格 | `javac: 无效的标记: /home/dy/WorkBuddy` | `javac @argfile` 按空白切分参数。用 `find -printf '"%p"\n'` 给每行加引号 |
| Java 版本 | `PARSE ERROR: unsupported class file version 52.0` | 树内 `prebuilts/sdk/tools/lib/dx.jar` 只认到 class file 51，必须 `-source 1.7 -target 1.7` |
| signapk 缺 JNI | `UnsatisfiedLinkError: no conscrypt_openjdk_jni` | 必须加 `-Djava.library.path=<src>/prebuilts/sdk/tools/linux/lib64` |
| 装不进 /data | `INSTALL_FAILED_INVALID_INSTALL_LOCATION: Cannot install platform packages to user storage!` | 用 platform 密钥签名的包只能进 `/system`，所以要 `adb push` 到 `/system/app/`，不能 `adb install` |
| 改了 APK 不生效 | 键盘行为没变 | `/system` 下的 APK 换掉后要删掉 `"/data/dalvik-cache/arm/system@app@ArdbegIME@ArdbegIME.apk@classes.dex"` 再重启，否则 ART 继续用旧 dex 编出来的 oat |

## 键盘能力

- 字母页：q-p / a-l / Shift+z-m+退格 / `?123` + 逗号 + 空格 + 句号 + 回车
- 符号页一：0-9 与 `@ # $ % & * - _ + =`、`! " ' : ; / ? ~`
- 符号页二：括号、`| \ ^ ` , .` 以及若干货币/标点
- Shift 输一个字母后自动落下；退格长按一次删 12 个字符
- 数字/电话/日期类输入框自动从符号页开始，其余（含密码框）从字母页开始
- 不使用全屏抽取编辑模式（`onEvaluateFullscreenMode()` 恒 false），
  避免在 TV/盒子上盖住应用界面

## 已知限制

ArdbegIME 本身：

- 没有词库、联想、自动纠错（那是 LatinIME 的活）
- 没有长按输入符号的二级菜单
- 只有英文布局，没有中文拼音（**中文请用 `BaiduInput/`**）

BaiduInput：

- 是 2015 年的加固包，必须靠 `dalvik.vm.checkjni=false` 才能跑
- 键位布局是按原厂 TV 版设计的，左侧几列的多行标签（`分词` / `?12` / `中/英`）
  在 240 dpi 下略有溢出，但功能正常
- 语音、手写、云输入这些依赖联网和百度账号的功能没有验证

## 实测记录（2026-11-06）

设备：g100 / ardbeg，1920x1080 @ 240dpi，`cm_ardbeg_tv-eng`

```
# ime list -a -s
com.baidu.input_baidutv/.ImeService
com.ardbeg.ime/.ArdbegIME

# settings get secure default_input_method
com.baidu.input_baidutv/.ImeService

# getprop dalvik.vm.checkjni
false
```

进「设置 → WLAN → 添加网络」，点 SSID 输入框：
键盘正常弹出，顶部是 `拼音全键 / 拼音九键 / 笔画键盘` 三个页签，
点 `n i h a o` 出候选，点候选能把汉字上屏（SSID 框里出现「不改」，
「保存」按钮由灰变蓝）。整机 `has died` 计数为 0。

