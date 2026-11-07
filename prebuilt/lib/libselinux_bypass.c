/*
 * libselinux_bypass.c —— 在 4.4.4 老策略上跑 7.1 用户空间的 SELinux 旁路垫片
 * ============================================================================
 *
 * 【为什么需要它】
 *
 * g100 用的是原厂 Android 4.4.4 的预编译内核（Linux 3.10.24）和原厂 ramdisk 里的
 * /sepolicy。这份策略是 4.4.4 时代的，dmesg 里能看到它的真实规模：
 *
 *     SELinux:  1 users, 2 roles, 307 types, 1 bools, 1 sens, 1024 cats
 *     SELinux:  84 classes, 3023 rules
 *
 * 而 Android 7.1 的用户空间需要一批 4.4.4 时代不存在的东西：
 *
 *   1) type system_server、priv_app —— 策略里压根没有这两个 type。
 *      zygote fork 出 system_server 后调 selinux_android_setcontext()，
 *      内部 security_check_context("u:r:system_server:s0") 在 type 表里查不到，
 *      返回 -1/EINVAL，然后
 *          F/art: JNI FatalError called: com_android_internal_os_Zygote.cpp:631:
 *                 selinux_android_setcontext failed
 *      system_server 直接 SIGABRT，zygote 跟着 "Exit zygote because system server
 *      has terminated" 退出，init 重启 zygote，无限循环 —— 表现就是"设备不启动"。
 *
 *   2) class service_manager —— 7.1 把 binder 的服务注册权限检查从 binder class
 *      拆到了新的 service_manager class（frameworks/native/cmds/servicemanager/
 *      service_manager.c:83 的 selinux_check_access(sctx, tctx,
 *      "service_manager", perm, ...)）。老策略里没有这个 class，
 *      security_compute_av() 因为 class 查不到返回 -1，于是：
 *          E/SELinux (213): Unknown class service_manager
 *          E/ServiceManager(213): add_service('batterystats',...) uid=1000
 *                                 - PERMISSION DENIED
 *      system_server 启动 AMS 时 BatteryStatsService.publish() 抛
 *      SecurityException → "FATAL EXCEPTION IN SYSTEM PROCESS"。
 *
 * 【为什么 permissive 救不了】
 *
 * androidboot.selinux=permissive 只影响"已判定为 deny 的操作是否真的拦"。
 * 上面两种失败都不是 deny，而是**决策过程本身出错**（type/class 不存在），
 * permissive 分支根本走不到。所以必须让这些调用直接返回成功。
 *
 * 【为什么不能关掉 SELinux】
 *
 * 内核配置（device/nvidia/ardbeg/kernel-config/ardbeg_defconfig）：
 *     CONFIG_SECURITY_SELINUX=y
 *     # CONFIG_SECURITY_SELINUX_BOOTPARAM is not set   ← 所以 selinux=0 无效
 *     # CONFIG_SECURITY_SELINUX_DISABLE is not set     ← 运行时也关不掉
 *
 * 试过在 cmdline 加 lsm=capability，这个 4.4 内核的 security_module_enable()
 * 不认，策略照旧加载（dmesg 依旧是 307 types）。所以只能从用户空间旁路。
 *
 * 【为什么不能用 7.1 自己的 sepolicy】
 *
 * 7.1 的策略是 policydb version 30，本机内核只支持 15-28：
 *     SELinux: policydb version 30 does not match my version range 15-28
 *     init: SELinux: Could not load policy: Invalid argument
 *     init: failed to load policy: Invalid argument
 *     init: Security failure; rebooting into recovery mode...
 * 一加载就重启进 recovery。所以策略只能继续用原厂那份 28 版本。
 *
 * 【用法】
 *
 * 只对需要的进程 LD_PRELOAD，不要全局设（全局设会让所有进程的 avc 日志失去
 * 意义，也没必要）。当前挂载点与各自依赖的符号：
 *
 *   - zygote         : selinux_android_setcontext   （init.zygote32.rc）
 *   - servicemanager : selinux_check_access         （servicemanager.rc）
 *   - installd       : selinux_android_restorecon*  （installd.rc）
 *
 * 注意 **vold 没有挂**：vold 那条路走的是 device 树里的
 * system/vold/Utils.cpp.patch，把 ForkExecvp() 里 setexeccon 失败从 abort()
 * 降级成 WARNING。setexeccon 仍然导出了，留给文件级重打包场景兜底。
 *
 * 另外第 4 层根因（audioserver / cameraserver 起不来）不是这个垫片修的：
 * 那两个是 init 在 Start() 里调 security_compute_create() 失败直接 return
 * false，发生在 exec 之前，LD_PRELOAD 根本还没生效。修法是在对应 .rc 里写
 * 死 seclabel u:r:mediaserver:s0，让 init 跳过自动算域。
 *
 * 完整四层根因见 patches/README.md 文末「SELinux 旁路」专章。
 *
 * 编译（预编译 gcc 没有 Android 的 crtbegin_so.o 和 bionic 的 -lc，必须
 * -nostdlib -nostartfiles；本文件不调用任何 libc 函数，所以没问题）：
 *
 *   GCC=/home/dy/aosp14/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/bin/arm-linux-androideabi-gcc
 *   $GCC -shared -fPIC -O2 -Wall -nostdlib -nostartfiles \
 *        -o libselinux_bypass.so libselinux_bypass.c
 *
 * 编译完用 readelf -sW --dyn-syms 数一下，应该是 **10 个** FUNC：
 *   is_selinux_enabled / security_check_context / security_getenforce /
 *   selinux_android_restorecon / selinux_android_restorecon_pkgdir /
 *   selinux_android_restorecon_recursive / selinux_android_setcon /
 *   selinux_android_setcontext / selinux_check_access / setexeccon
 *
 * 少一个就可能少修一层，刷包后表现为对应服务崩溃或整机起不来。
 *
 * 【长期正解】
 *
 * 等换用自编内核（支持 policydb 30）并配上 7.1 的完整 sepolicy 后，这个垫片
 * 和所有 LD_PRELOAD 都可以整体删掉。在那之前它是唯一能开机的手段。
 * ============================================================================
 */

#define EXPORT __attribute__((visibility("default")))

/*
 * servicemanager 的服务注册/查找权限检查。
 * frameworks/native/cmds/servicemanager/service_manager.c:83
 *     int selinux_check_access(const char *scon, const char *tcon,
 *                              const char *class, const char *perm, void *aux)
 * 返回 0 = 允许。老策略没有 service_manager class，只能无条件放行。
 */
EXPORT int selinux_check_access(const char *scon, const char *tcon,
                                const char *cls, const char *perm, void *aux) {
    (void)scon; (void)tcon; (void)cls; (void)perm; (void)aux;
    return 0;
}

/*
 * zygote fork 出子进程后切换 SELinux 域。
 * external/libselinux/src/android.c:905
 *     int selinux_android_setcontext(uid_t uid, bool isSystemServer,
 *                                    const char *seinfo, const char *pkgname)
 * 注意第二个参数在 C 里是 bool（1 字节），ARM AAPCS 下和 int 一样走 r1，
 * 这里用 int 接是安全的。
 *
 * 返回 0 表示"不切换域"，子进程保持 zygote 的域。permissive 下不产生任何
 * deny 副作用，只是 avc 日志里的 scontext 会统一显示成 zygote/kernel 域。
 */
EXPORT int selinux_android_setcontext(unsigned int uid, int isSystemServer,
                                      const char *seinfo, const char *pkgname) {
    (void)uid; (void)isSystemServer; (void)seinfo; (void)pkgname;
    return 0;
}

/*
 * 直接设置进程 context（selinux_android_setcontext 内部用的就是这个）。
 */
EXPORT int selinux_android_setcon(const char *con) {
    (void)con;
    return 0;
}

/*
 * vold 在 fork/exec 子进程（blkid、sgdisk、fsck_msdos）前后设置执行域。
 * system/vold/Utils.cpp 的 ForkExecvp() 里原生写法是失败就 abort()，
 * 我们虽然也打了 Utils.cpp.patch 把它降级成 WARNING，但文件级重打包的包里
 * 用的还是原版 vold，所以这里也要兜住。
 */
EXPORT int setexeccon(const char *context) {
    (void)context;
    return 0;
}

/*
 * ---- installd 的 restorecon 三兄弟（第 3 层根因）----
 *
 * 现象：installd 起来几十毫秒就 SIGSEGV，/data/tombstones/tombstone_09：
 *
 *     pid: 25711, name: installd
 *     signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x4
 *     #00 pc 0000c612  /system/lib/libselinux.so
 *     #01 pc 0000b993  /system/lib/libselinux.so
 *     #02 pc 00004e5b  /system/bin/installd
 *
 * 根因不是权限问题，是**数据结构不配套**：
 * 7.1 的 libselinux 解析 file_contexts.bin 用的是新版二进制格式
 * （SELABEL_CTX_FILE 的 0x2f 段布局），而 ramdisk 里那份
 * file_contexts.bin 是原厂 4.4.4 的（11273 字节）。
 * selabel_open() 返回的 handle 里正则/字面量表是空的，紧接着
 * selabel_lookup() 解引用空表 → 读 0x4 偏移 → SIGSEGV。
 *
 * 后果：installd 一崩，包管理相关的目录全建不出来，
 * 特别是 7.1 新引入的 device-encrypted 存储
 * /data/user_de/0/<pkg>/ —— SettingsProvider 的 settings.db 就在那里：
 *     E/SQLiteLog: (14) os_unix.c:32493: (2) open(
 *         /data/user_de/0/com.android.providers.settings/databases/settings.db)
 * (14)=SQLITE_CANTOPEN, (2)=ENOENT。于是 SettingsProvider 初始化失败，
 * 系统卡在 SetupWizard 之前。
 *
 * 这里把三个入口全部拦成"什么也没做，返回成功"。目录由 installd 自己
 * mkdir（它不依赖 restorecon 的结果），只是文件的安全标记会保持创建者
 * 的默认值 —— permissive 下没有实际影响。
 *
 * 签名见 external/libselinux/include/selinux/android.h
 */
EXPORT int selinux_android_restorecon(const char *pathname, unsigned int flags) {
    (void)pathname; (void)flags;
    return 0;
}

EXPORT int selinux_android_restorecon_pkgdir(const char *pkgdir,
                                             const char *seinfo,
                                             unsigned int uid,
                                             unsigned int flags) {
    (void)pkgdir; (void)seinfo; (void)uid; (void)flags;
    return 0;
}

EXPORT int selinux_android_restorecon_recursive(const char *pathname,
                                                unsigned int flags) {
    (void)pathname; (void)flags;
    return 0;
}

/*
 * 校验 context 字符串在策略里是否合法。老策略 type 表太小，7.1 大量 context
 * 都会在这里被判非法，直接放行。
 */
EXPORT int security_check_context(const char *con) {
    (void)con;
    return 0;
}

/*
 * 有些调用方（例如 libselinux 自己的 selinux_android_setcontext 第 914 行
 * `if (is_selinux_enabled() <= 0) return 0;`）会先问这个。
 * 返回 0 让它们走"没启用 SELinux"的快路径。
 */
EXPORT int is_selinux_enabled(void) {
    return 0;
}

/*
 * 同理，getenforce 走的接口。返回 0 表示 permissive。
 */
EXPORT int security_getenforce(void) {
    return 0;
}
