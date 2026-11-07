#!/system/bin/sh
# =============================================================================
# bootlog.sh —— 开机日志采集脚本（ardbeg / cm-14.1 / Android 7.1.2）
#
# 【为什么需要这个脚本】
#   这块板子跑的是原厂 4.4.4 预编译内核，一旦音频、显示或者 adb 出问题，
#   设备很可能根本进不了系统，/data 也读不到，只剩 /cache 还能在 recovery
#   里直接看。所以必须在启动过程中主动把日志落到 /cache。
#
#   而 logcat 单独是不够的，原因有两个：
#     1) logcat 只有在 logd 起来之后才有内容，内核早期打印（ASoC 声卡注册、
#        RT5639 codec 探测、I2C 失败、regulator 没起来之类）完全看不到。
#        （cm-11/4.4.4 时代连 logd 都没有，logcat 只读 /dev/log 下的固定
#        几个 buffer；7.1 换成了 logd + -b all，能读的 buffer 更多，
#        但"看不到内核早期打印"这一点没变。）
#     2) 音频这类问题恰恰要靠内核打印 + mixer 控件状态才能定位。
#   所以这里额外抓 dmesg 和 tinymix 的控件快照。
#
# 【调用方式】
#   bootlog.sh <阶段标签>
#     post-fs-data  —— /data 刚挂上、system_server 还没起来
#     booted        —— sys.boot_completed=1，系统完全起来
#   由 init.tegra.rc 里的 bootlog_snapshot / bootlog_booted
#   两个 oneshot 服务分别在对应阶段调用一次。
#   （服务名必须 ≤16 字符，所以叫 bootlog_booted 而不是
#     bootlog_snapshot_booted —— 后者 24 字符，init 会直接拒绝。）
#
# 【产物】全部在 /cache/bootlog/ 下，取日志：
#   adb pull /cache/bootlog
#   （没有 adb 时可以在 recovery 里挂 /cache 直接拷）
#     dmesg_<阶段>.log             内核环形缓冲快照（全量，不清空）
#     audio_<阶段>.log             声卡 / mixer 控件状态，音频调试专用
#     props_<阶段>.log             关键属性快照
#     pstore_console_ramoops.log   上一次开机的内核控制台输出（崩溃现场）
#     last_kmsg.log                老接口 /proc/last_kmsg（部分内核配置才有）
#
# 【注意】dmesg 在 4.4.4 里是用 klogctl(KLOG_READ_ALL) 实现的，
#   也就是 syslog(2) 的 type 3 —— 只读取、不清空环形缓冲，也不会阻塞，
#   所以可以放心反复调用，不会把内核日志"吃掉"。
# =============================================================================

STAGE="${1:-unknown}"
DEST=/cache/bootlog

# -----------------------------------------------------------------------------
# /cache 是在 init.ardbeg.rc 的 "on fs" 里由 mount_all /fstab.ardbeg 挂上的
# （fstab 第 7 行：CAC 分区 -> /cache，ext4）。
#
# 这里不能只判断 "目录存在" —— 挂载失败时 /cache 这个目录仍然在 ramdisk
# (rootfs) 上，往里写会成功但重启就没了，日志等于白抓。所以要看
# /proc/mounts 里到底有没有 /cache 这个挂载点。
# 万一没挂上就直接退出，免得刷一屏无用的东西。
# -----------------------------------------------------------------------------
if ! grep -q ' /cache ' /proc/mounts 2>/dev/null; then
    echo "bootlog: /cache 未挂载，跳过（阶段 ${STAGE}）"
    exit 0
fi

mkdir -p "$DEST" 2>/dev/null

# -----------------------------------------------------------------------------
# 1) 内核环形缓冲全量快照
#    每个阶段各存一份，这样 post-fs-data 那份保留的是"最早期"的启动打印，
#    不会被后面 booted 那份覆盖掉。
# -----------------------------------------------------------------------------
dmesg > "$DEST/dmesg_${STAGE}.log" 2>/dev/null

# -----------------------------------------------------------------------------
# 2) 声卡 / mixer 状态
#    音频故障排查的核心证据：
#      - /proc/asound/cards 里能不能看到 tegra-snd-rt5639（声卡有没有注册成功）
#      - tinymix 列出的控件名，必须和 /system/etc/audio.ardbeg.xml 里的
#        <ctl name="..."/> 一一对应，对不上的那些会在 audio HAL 里报
#        "Control 'xxx' not found"，路由就是空转
# -----------------------------------------------------------------------------
{
    echo "========== /proc/asound/cards =========="
    cat /proc/asound/cards 2>/dev/null
    echo
    echo "========== /proc/asound/pcm =========="
    cat /proc/asound/pcm 2>/dev/null
    echo
    echo "========== /proc/asound/devices =========="
    cat /proc/asound/devices 2>/dev/null
    echo
    echo "========== tinymix_ardbeg (全部控件) =========="
    # tinymix 不带参数就是列出所有控件；设备树里的模块名带 _ardbeg 后缀
    /system/bin/tinymix_ardbeg 2>&1
    echo
    echo "========== 音频相关属性 =========="
    getprop | grep -i audio 2>/dev/null
    echo
    echo "========== /system/etc 下的音频配置 =========="
    ls -l /system/etc/audio.*.xml /system/etc/nvaudio_*.xml 2>/dev/null
} > "$DEST/audio_${STAGE}.log" 2>&1

# -----------------------------------------------------------------------------
# 3) 上一次开机的内核控制台输出（pstore / ramoops）
#    init.tegra.rc 的 "on fs" 里已经 mount pstore pstore /sys/fs/pstore，
#    所以这里能读到上一次崩溃/重启前的 console 打印。
#    不同内核版本文件名不一样，两种都试一下。
# -----------------------------------------------------------------------------
# [7.1 新增] 把 /sys/fs/pstore 下的所有文件**逐个拷到 /cache/pstore/**。
#
# 为什么要整目录拷，而不只是读 console-ramoops：
#   pstore 里除了 console 输出，还可能有 pmsg-ramoops-0（用户态最后打印）、
#   dmesg-ramoops-0/1（崩溃时的内核栈 + 寄存器）。7.1 的 init 崩溃、
#   HAL 崩溃时，dmesg-ramoops 是唯一能看到"死在哪一行"的证据。
#
# 为什么要拷走而不是只读：
#   pstore 是 RAM 里的环形区，**下次写入会覆盖**。系统起来后如果发生第二次
#   崩溃，上一次的现场就没了。拷到 /cache（eMMC）才能真正留住。
#
# 注意：读取 pstore 文件会触发它被清空（内核实现是 read-once 语义，
#   读完就把这块 ramoops 标记为已消费）。所以只读一次、立刻落盘。
mkdir -p /cache/pstore 2>/dev/null
for f in /sys/fs/pstore/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    cat "$f" > "/cache/pstore/${base}.${STAGE}.log" 2>/dev/null
done

# 兼容老名字：把 console 那份单独留一个固定文件名，方便脚本/人肉查看
#
# 【注意，这里有个坑】pstore 是 read-once 语义：上面的 for 循环已经
#   cat 过一次 console-ramoops 了，再 cat 一次只会得到空内容。
#   所以这里**不能**再读 /sys/fs/pstore，而是把刚才已经落盘的那份复制一份。
for _src in "/cache/pstore/console-ramoops.${STAGE}.log" \
            "/cache/pstore/console-ramoops-0.${STAGE}.log"; do
    if [ -s "$_src" ]; then
        cp -f "$_src" "$DEST/pstore_console_ramoops.log" 2>/dev/null
        break
    fi
done

# -----------------------------------------------------------------------------
# 4) 老接口 /proc/last_kmsg
#    3.10 内核如果开了 CONFIG_ANDROID_RAM_CONSOLE，这个文件还在；
#    新配置一般已经换成上面的 pstore 了，没有就跳过。
# -----------------------------------------------------------------------------
if [ -f /proc/last_kmsg ]; then
    cat /proc/last_kmsg > "$DEST/last_kmsg.log" 2>/dev/null
fi

# -----------------------------------------------------------------------------
# 5) 关键属性快照
#    排 adb / USB 问题最直接的东西：sys.usb.config、sys.usb.state、
#    persist.sys.usb.config、ro.debuggable、ro.adb.secure 一眼就能看到。
# -----------------------------------------------------------------------------
{
    echo "========== 全部属性 =========="
    getprop 2>/dev/null
    echo
    echo "========== USB / adb 相关 =========="
    getprop | grep -i "usb\|adb" 2>/dev/null
    echo
    echo "========== adbd 进程 =========="
    ps 2>/dev/null | grep -i adb
    echo
    echo "========== 挂载点（确认 /cache 真的挂上了） =========="
    grep -E " /(cache|data|system|vendor) " /proc/mounts 2>/dev/null
    echo
    echo "========== /cache 空间 =========="
    df /cache 2>/dev/null
} > "$DEST/props_${STAGE}.log" 2>&1

# -----------------------------------------------------------------------------
# 6) 系统起来之后额外抓一份 dumpsys audio
#    post-fs-data 阶段 system_server 还没起，dumpsys 必然失败，所以用
#    阶段标签做判断，只在 booted 阶段抓。失败也无所谓，重定向兜住了。
# -----------------------------------------------------------------------------
if [ "$STAGE" = "booted" ]; then
    {
        echo "========== dumpsys audio =========="
        dumpsys audio 2>&1
        echo
        echo "========== dumpsys media.audio_flinger =========="
        dumpsys media.audio_flinger 2>&1
    } > "$DEST/dumpsys_audio.log" 2>&1
fi

echo "bootlog: 阶段 ${STAGE} 的日志已写入 ${DEST}"
exit 0
