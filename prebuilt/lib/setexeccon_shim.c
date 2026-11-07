/*
 * setexeccon_shim.c —— 让 vold 在 SELinux 不可用时不再自杀
 *
 * 【问题】
 * system/vold/Utils.cpp 的 ForkExecvp() 里：
 *
 *     if (setexeccon(context)) {
 *         LOG(ERROR) << "Failed to setexeccon";
 *         abort();                      // <- 直接 SIGABRT
 *     }
 *     status_t res = android_fork_execvp(argc, argv, NULL, false, true);
 *     if (setexeccon(nullptr)) {
 *         LOG(ERROR) << "Failed to setexeccon";
 *         abort();                      // <- 又来一次
 *     }
 *
 * 本机 SELinux 处于 Disabled（is_selinux_enabled() 返回 0），
 * setexeccon() 必然失败，于是 vold 每次 ForkExecvp 都 abort：
 *
 *     signal 6 (SIGABRT), code -6
 *     #04 abort+4
 *     #05 pc 0002b297  /system/bin/vold
 *
 * 后果：vold 挂载 U 盘时调 blkid 读分区表 -> abort -> init 重启 vold
 * -> 再挂载 -> 再 abort，无限循环，volume 永远停在 CHECKING，
 * /storage/usbdrive0 永远不出现。
 *
 * 【这个 shim 做什么】
 * LD_PRELOAD 覆盖 libselinux 的 setexeccon，永远返回 0（成功）。
 * 其它 libselinux 符号照常透传到真正的 libselinux.so。
 *
 * 【为什么安全】
 * SELinux 本来就是关闭的，不设置 exec context 不会降低任何安全性 ——
 * 现在所有进程都跑在 u:r:kernel:s0，本来就没有域隔离。
 *
 * 【这是权宜之计】
 * 正解是改 Utils.cpp 把 abort() 去掉后重编 vold（补丁已放在
 * device/nvidia/ardbeg/patches/system/vold/Utils.cpp.patch）。
 * 在没重编 system.img 之前先用这个 shim 兜底。
 */

/* 必须是全局可见的默认符号，才能覆盖 libselinux.so 里的同名函数 */
__attribute__((visibility("default")))
int setexeccon(const char *context) {
    (void)context;
    return 0;   /* 假装成功 */
}
