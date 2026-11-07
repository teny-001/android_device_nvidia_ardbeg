# 这些 SELinux 策略文件已停用（cm-11 / Android 4.4.4 时代的版本）

## 为什么整体归档

7.1 的 `BoardConfig.mk` 里

```make
BOARD_SEPOLICY_DIRS += \
    device/nvidia/shield-common/sepolicy/common \
    device/nvidia/shield-common/sepolicy/lineage-common \
    device/nvidia/ardbeg/sepolicy
```

也就是说 `shield-common/sepolicy/common` 和本设备目录是**同时**参与编译的。
而 `shield-common/sepolicy/common` 里有一整套 NVIDIA 2015-2017 年为 7.1
更新的同名文件（`app.te` / `file.te` / `usb.te` / `ussrd.te` /
`ussr_setup.te` / `vold.te` / `installd.te` / `netd.te` / `healthd.te` /
`untrusted_app.te` / `te_macros` / `file_contexts` / `genfs_contexts`）。

ardbeg 目录下这同一批文件是 4.4 时代的旧版，两者叠在一起会连续出问题：

### 1) type 重复声明（硬错误）

```
device/nvidia/ardbeg/sepolicy/comms.te:12:ERROR
    'duplicate declaration of type/attribute' at token ';'
```

一共 10 处：`wifi_loader`、`wifi_loader_exec`、`phsd_socket`、
`proc_wmem_default_writable`、`proc_wmem_max_writable`、`rebindEthernet`、
`rebindEthernet_exec`、`ussr_setup`、`ussr_setup_exec`、`ussrd`、`ussrd_exec`。

### 2) 宏重复展开（更隐蔽）

`usb.te` / `ussrd.te` / `ussr_setup.te` 里都调用了 `init_daemon_domain(...)`。
这个宏（定义在 `te_macros`）会顺带声明一个 `type xxx_tmpfs, file_type;`。
两个目录各调一次，就又多出一个重复声明：

```
device/nvidia/ardbeg/sepolicy/usb.te:20:ERROR
    'duplicate declaration of type/attribute' at token ';'
type rebindEthernet_tmpfs, file_type;
```

这一条特别坑：**在整个源码树里 grep `rebindEthernet_tmpfs` 是搜不到的**，
因为它不是写在文件里，而是 m4 宏展开出来的。

### 3) 引用了 7.1 里已不存在的 type

比如 `installd.te` 里的
`allow installd sdcard_internal:dir search;`
—— `sdcard_internal` 是 4.4 的 sdcard 守护进程用的 type，7.1 早已删掉。
这类问题会在前两类修完之后继续以 `unknown type` 报出来。

## 现在的状态

`device/nvidia/ardbeg/sepolicy/` 里**只保留 `comms.te`**，内容只有三条
shield-common 里没有、而 ardbeg 确实需要的 allow：

```te
allow bluetooth sysfs:file write;
allow gpsd sysfs:file write;
allow hostapd wifi_data_file:lnk_file read;
```

其余全部由 `shield-common/sepolicy/common` 提供（它是超集：
`file_contexts` 152 行 vs 这里 29 行，`genfs_contexts` 也是超集，
连 `/dev/ov5693`、`/dev/ttyTHS2`、`tlk_daemon`、`/data/misc/phs`、
`ussrd`、`wifi loader` 这些 ardbeg 专属路径都已经包含）。

## 如果以后发现丢了某条策略

先在这个目录里 `grep` 找原始规则，再对照
`device/nvidia/shield-common/sepolicy/common/` 里同名文件确认是不是已经有了。
**确认没有**才往 `device/nvidia/ardbeg/sepolicy/comms.te` 里加，
并且**只加 allow，不要加 type 声明**。
