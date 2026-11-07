# tools/repack —— 不做全量编译，直接改已有 OTA 包

改了设备树里的几个文件，却不想花两三个小时重编整个 ROM 时用这套工具。

思路：把 OTA 包里的 `system.new.dat` / `system.transfer.list` 还原成 raw ext4，
用 `debugfs` 直接把文件写进去（不挂载，容器里没有 CAP_SYS_ADMIN 也能跑），
ramdisk 用 cpio 拆开改，最后重新生成块数据、重新打包、重新做整包签名。

## 一条龙

```sh
R=/path/to/repack
PY=python3

# 0) 从原包里取出四个东西
#    system.transfer.list / system.new.dat / boot.img / META-INF/...

# 1) 块数据 -> raw ext4（3 GB）
$PY otablocks.py unpack system.transfer.list system.new.dat work/system.raw.img

# 2) 准备 overlay/ 目录（结构跟 system 分区一样，但**不带** /system 前缀），
#    再生成 debugfs 命令脚本。注意 SELinux 标签必须用 ea_set 单独补，
#    debugfs 的 write 不带 xattr。
$PY apply_overlay.py
debugfs -w -f work/overlay.cmds work/system.raw.img
e2fsck -f -y work/system.raw.img

# 3) boot.img：拆 -> 改 ramdisk -> 合
$PY bootimg.py unpack boot.img work/boot
$PY bootimg.py ramdisk-unpack work/boot/ramdisk.cpio.gz work/ramdisk
#    ...改 work/ramdisk 里的文件...
$PY bootimg.py ramdisk-pack work/ramdisk work/boot/ramdisk.cpio.gz
$PY bootimg.py pack work/boot work/boot.img

# 4) raw ext4 -> 块数据
$PY otablocks.py pack work/system.raw.img work/out/system

# 5) 重打包 + 整包签名
$PY mkzip.py work/out/unsigned.zip
$PY sign_ota.py work/out/unsigned.zip work/out/signed.zip
```

## 几个必须知道的坑

### boot header 的 `id[8]` 是 SHA1 校验，改了 ramdisk 必须重算

`boot.img` 的 header v0 在 offset 576 处有 32 字节 `id[8]`，其中前 20 字节
是 `mkbootimg` 的 `update_sha()` 算出来的 SHA1：

```python
sha = sha1()
sha.update(kernel);  sha.update(pack('<I', len(kernel)))    # 先内容，再长度
sha.update(ramdisk); sha.update(pack('<I', len(ramdisk)))
sha.update(second);  sha.update(pack('<I', len(second)))
id[0:20] = sha.digest()
```

Tegra 的原厂 bootloader 会校验这个值。**只要 ramdisk 变了而 id 没跟着变，
bootloader 就判定镜像损坏，然后静默回落到 recovery 分区** ——
misc 分区是干净的、dmesg 里一个错误都没有，极难定位。
`bootimg.py` 的 `pack` 已经重算这个值。

> 这个坑的实际表现：刷完 boot.img 重启，直接进了 TWRP。
> 查 misc 分区（`mmcblk0p12`）前 128 字节全零，不是 `boot-recovery` 命令触发的，
> 才想到是 bootloader 拒绝了镜像。

### `.cpio_order` 会静默吞掉新加的文件

`ramdisk-unpack` 会把原始条目清单写进 `.cpio_order`，`ramdisk-pack` 按它打包。
**之后往 ramdisk 目录里新加的文件不在清单里，会被静默丢掉** ——
打印的还是"60 个条目"，刷进设备才发现脚本根本不存在。
`bootimg.py` 的 `cpio_pack` 现在会自动扫描目录、补齐漏项并打警告。

### ramdisk 基底必须用设备实际运行的那份，不能用构建产物

从 `out/` 或 `dist/` 里解出来的 ramdisk 和设备上实际跑的可能不是同一构建，
带进去的 `init` / `sepolicy` / `file_contexts.bin` 版本对不上，会直接开不了机：

```
SELinux:  policydb version 30 does not match my version range 15-28
init: failed to load policy: Invalid argument
init: Security failure; rebooting into recovery mode...
```

`init` 二进制只支持 policydb version 15-28。所以增量重打包时应该
**从设备 dump 出 boot 分区**、解出 ramdisk 作为基底，只叠必要改动。
`mk_ramdisk4.py` 就是这么做的。

### `system.transfer.list` 第 2 行不是分区大小

是 `new` + `zero` 命令的块数合计（`blockimgdiff.py` 里那个 `total` 累加变量）。
真正的分区大小由所有区间的最大 `end` 隐含决定。写错 recovery 会报
`failed to parse transfer list`。

区间是 `start,end`（**右闭区间不含 end**），命令后面的数字是
**区间数字个数**（2 × 区间数），不是区间数。见 `RangeSet.to_string_raw()`。

### `new` / `zero` 每条最多 1024 块

`blockimgdiff.py` 的 `WriteSplitTransfers()` 硬限制，拆开是为了避免单条
fsync 数据量过大。

### recovery 只认整包签名

`bootable/recovery/verifier.cpp` 的 `verify_file()` 先看文件尾部 6 字节的
`$ff $ff` 标记，不匹配直接 `VERIFY_FAILURE`，**根本走不到 JAR 签名那条路**。
所以改了任何字节都必须重新做整包签名。

`sign_ota.py` 用 `openssl` 复刻了 `SignApk.signWholeFile()`，因为源码树里那份
`prebuilts/sdk/tools/lib/signapk.jar` 依赖 `org.conscrypt` + BouncyCastle，
在桌面 JDK 上跑不起来。

两个硬约束：
* PKCS#7 必须**不带 authenticatedAttributes**（`openssl smime -sign -noattr`），
  否则 `read_pkcs7()` 的偏移对不上；
* 摘要必须用 **SHA1**，因为 `testkey.x509.pem` 是 `sha1WithRSA`，
  recovery 按证书的签名算法决定 `hash_len`。

### 输出 zip 不能带 zip64

7.1 的 `libziparchive` 对 zip64 支持很有限。整包 < 4 GB 用不上，
`mkzip.py` 会在写完时检查 EOCD 前 20 字节有没有 zip64 locator。

### 输出 zip 不能带 archive comment

`sign_ota.py` 要往 comment 里塞签名，输入带 comment 会直接失败。

## 验证清单

```sh
# 1) 块数据往返一致（pack 完再 unpack 回来，md5 必须相同）
# 2) 模拟 recovery 校验签名：按 verifier.cpp 的算法抠出 PKCS#7，
#    用 openssl smime -verify 验一遍
# 3) 解包后 e2fsck 干净
# 4) boot header id 重算对不对：拿原厂 boot.img 用同一段算法算一遍，
#    应该和它 header 里的 id 一字不差
```

## `mk_ramdisk4.py` 的定位

这个脚本是**增量重打包专用**的，全量编译不需要它。

它做的是「以设备 dump 出来的 ramdisk 为基底，只叠 USB 修复需要的改动」。
这些改动现在**已经全部固化到设备树里**了：

| 改动 | 固化位置 |
|---|---|
| `init.usb.rc` 补 MTP/PTP 规则 + `on init` 段 | `patches/system/core/rootdir/init.usb.rc.patch` |
| `init.tegra.rc` 停用 sdcard / boot_completed 起服务 / 服务定义 | `initfiles/init.tegra.rc` |
| `init.nv_dev_board.usb.rc` 注释 6 段 + `enable 0` | `initfiles/init.nv_dev_board.usb.rc` |
| `default.prop` 的 `ro.logd.size` | `BoardConfig.mk` 的 `ADDITIONAL_DEFAULT_PROPERTIES` |
| `/sbin/usb_mtp_default.sh` | `initfiles/usb_mtp_default.sh` + `initfiles/Android.mk` |

所以正常情况下**全量编译就能得到同样的镜像**，不需要跑这个脚本。
只有在「不想花两三个小时重编」的时候，才用它从已有 OTA 包增量改。

跑之前要先准备 `work/ramdisk2`（设备实际运行的 ramdisk）：

```sh
adb shell 'dd if=/dev/block/mmcblk0p9 of=/data/local/tmp/boot.img'
adb pull /data/local/tmp/boot.img
python3 bootimg.py unpack boot.img work/boot
python3 bootimg.py ramdisk-unpack work/boot/ramdisk.cpio.gz work/ramdisk2
```

脚本里的路径常量（`BASE` / `SRC` / `DST` / `REF`）都是相对 `repack/work/` 的，
按实际目录结构调整即可。

