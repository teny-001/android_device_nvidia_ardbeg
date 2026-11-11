#!/system/bin/sh
# ============================================================================
# ardbeg_gpu_video.sh —— 视频播放时的 GPU 调频（2026-11-11 新增）
#
# 【这个功能解决什么】
#   本机 ro.ardbeg.sf_hwc_off=1（厂商 hwcomposer.tegra.so 的 glcomposer 在
#   7.1 上会 SIGSEGV，必须关掉 HWC 合成），于是 1920x1080 全屏画面全部由
#   SurfaceFlinger 用 GLES 合成，GPU 成了每帧出图的必经路径。
#
#   但 nvhost_podgov（本机 GPU devfreq governor）默认 load_target=700（70%）。
#   actmon 统计的是「GPU 忙 / 总时间」，而每帧合成完到下一个 vsync 之间
#   GPU 是空闲的，60Hz 下这个空闲占比很大；实测播放 25fps 片源时 load
#   平均只有 372/1000，远低于 700，governor 因此一直判定「不忙」，把
#   GPU 压在最低档：
#       播放 16 秒 cur_freq 分布 72MHz x13 / 108MHz x7 / 180MHz x3 /
#       396MHz x3，平均 131.5MHz；max_freq=852MHz 一次都没上过
#       （trans_stat 里 756/804/852MHz 三行 time(ms) 全 0）。
#   同时 gr_idle_timeout_default_us=10000（10ms），60Hz 每 16.67ms 才一帧，
#   帧间必然进一次 ELPG 电源门控，实测 20~32 次/秒的睡/醒切换。
#   每次唤醒都要重新升频，单帧 GLES 合成耗时因此忽长忽短，经常赶不上
#   16.67ms 的 vsync 截止 -> 帧被推迟 -> 叠加 pulldown 就表现成
#   desiredPresentTime 间隔 83.3ms 的「跳过一帧」。
#
# 【实测 A/B（同一 25.000fps 本地片、同一 60Hz、同一指标）】
#   BASE  原厂默认(load_target=700 / hint=0 / idle=10ms)：
#     desired 40.0ms 81.6% / 83.3ms 跳帧 14.6%
#     上屏延迟(actual-desired) 平均 46.5ms，最大 164.9ms
#     GPU 均频 75.6MHz，ELPG 20.0 次/秒
#     解码 24.21fps，丢帧增量 10
#   FIXED 本脚本的三项参数：
#     desired 40.0ms 93.2% / 83.3ms 跳帧 6.8%
#     上屏延迟平均 32.4ms
#     GPU 均频 102.6MHz，ELPG 21.3 次/秒
#     解码 25.10fps，丢帧增量 10（没变）
#   => 跳帧 -7.7pp、理想帧 +11.6pp、上屏延迟 -14.1ms。
#      解码侧两轮完全一样，证明改善来自「合成/上屏链路」而不是解码能力。
#
# 【帧率层面的根因（2026-11-11「在帧率上找原因」的结论）】
#   片源 25.000fps -> 帧周期 40.0ms；显示 60Hz -> vsync 16.67ms。
#   40 / 16.67 = 2.4 不是整数 -> 每帧只能保持 2 或 3 个 vsync
#   （33.3ms / 50.0ms 交替，即 3:2 pulldown）。这是结构性的，
#   调 GPU 参数消除不了，只能切 50Hz（40/20=2 整除，干净 2:2）。
#   本机 50Hz 实测本地片理想帧 94.5% / 跳帧 4.4%。
#   叠加在上面的第二层就是本脚本修的「GPU 低频 -> 合成超时 -> 错过
#   vsync」。两项都解决才接近无跳帧。
#
#   在线视频 App 更复杂：同一段观看里片源帧率会变（片前广告约 25fps、
#   正片约 30.13fps，numFramesTotal 15 秒 +452 帧）。30fps 在 60Hz 上
#   本来就是 2:2 完美匹配，切到 50Hz 反而是 5:3 pulldown、更差。
#   所以 ardbeg_fps_match.sh 的自动匹配用区间分类且默认关闭
#   （persist.ardbeg.fps_match=0），不能无条件切 50Hz。
#
# 【视频解码能力（顺带查清，不是瓶颈）】
#   media_codecs.xml 里 H.264 只有 OMX.ffmpeg.h264.decoder 与
#   OMX.google.h264.decoder（media.sf.omx-plugin=libffmpeg_omx.so），
#   没有 NVIDIA 视频硬解；但本机 720p/25fps 软解完全够：
#   上面 A/B 两轮解码都是 24~25fps、丢帧增量都只有 10 帧，
#   改 GPU 参数前后解码速率不变而卡顿变了 -> 瓶颈不在解码侧。
#
# 【哪些节点真能写（2026-11-11 逐个验证过）】
#   可写且生效：
#     /sys/kernel/debug/gk20a.0/scaling/load_target
#     /sys/kernel/debug/gk20a.0/scaling/use_throughput_hint
#     /sys/kernel/debug/gk20a.0/gr_idle_timeout_default_us
#   写不动 / 写了没用：
#     /sys/class/devfreq/gk20a.0/min_freq  写 396MHz 读回仍 72MHz（governor 覆盖）
#     /sys/kernel/debug/gk20a.0/rate       写 396MHz 读回 396MHz 但 cur_freq 不变
#                                          （只是请求值，不是实际频率）
#     /sys/class/devfreq/gk20a.0/max_freq  可写，但本来就 852MHz，无意义
#   sysfs 不持久，每次开机都要重写一遍 -> 所以做成 init 服务。
#
# 【风险与开关】
#   降 load_target 会让 GPU 更容易升频，代价是待机功耗/发热略增；
#   本机有 thermal 节流，长时间高负载可能触发。故做成可关：
#     persist.ardbeg.gpu_video=1（默认）开机应用
#     persist.ardbeg.gpu_video=0 恢复原厂三项默认值
#   运行时可 `ardbeg_gpu_video.sh restore` / `apply` 手动切换，
#   也可 setprop 后重启让其生效。
#
# 【用法】
#   ardbeg_gpu_video.sh apply     应用修改值
#   ardbeg_gpu_video.sh restore  恢复原厂默认
#   ardbeg_gpu_video.sh status   打印当前三项参数与实际频率
#   ardbeg_gpu_video.sh          开机默认入口（读开关后 apply/restore）
#
# 【和另外两个脚本的关系】
#   sf_hwc_off.sh 关 HWC；本脚本让「关掉 HWC 之后」的 GPU 跑得动；
#   ardbeg_fps_match.sh 处理片源帧率与显示刷新率不整除。三者都在
#   zz-*.rc 里由 init 拉起、互不依赖，但本脚本的效果是在
#   ro.ardbeg.sf_hwc_off=1 的前提下验证的。
# ============================================================================

TAG=ardbeg_gpu_video

# 三项参数节点。都在 debugfs 下，开机时由 zz-ardbeg-gpu-video.rc 在
# sys.boot_completed=1 之后拉起，此时 debugfs 已挂载。
P_LOAD=/sys/kernel/debug/gk20a.0/scaling/load_target
P_HINT=/sys/kernel/debug/gk20a.0/scaling/use_throughput_hint
P_IDLE=/sys/kernel/debug/gk20a.0/gr_idle_timeout_default_us

# 原厂默认值（restore 用）
D_LOAD=700
D_HINT=0
D_IDLE=10000

# 修改值（apply 用）
#   load_target 700->300：目标负载从 70% 降到 30%，实测播放时 load
#     平均 372/1000，原厂门槛下 governor 一直不升频；降到 300 后
#     同样的负载就会触发升频（实测均频 75.6 -> 102.6MHz）。
#   use_throughput_hint 0->1：让调频参考实际吞吐，而不只是 actmon
#     的空闲比（actmon 会把「等 vsync」算成空闲，系统性低估合成负载）。
#   gr_idle_timeout 10000->50000：60Hz 帧间隔 16.67ms，10ms 超时导致
#     每帧之间必进一次 ELPG；放宽到 50ms，整段播放里 GPU 保持唤醒。
V_LOAD=300
V_HINT=1
V_IDLE=50000

log() {
    # init 服务的 stdout 走 /dev/null，开机时这些看不到；留着是为了
    # 手动执行 / adb shell 时能直接看到结果。开机后的验证靠 status 回读。
    echo "$TAG: $*"
}

# ---------------------------------------------------------------------------
# 写三项参数。逐一判断节点是否存在：
#   debugfs 没挂 / 内核没这个节点时只记日志，绝不让开机流程失败。
# ---------------------------------------------------------------------------
write3() {
    _load="$1"
    _hint="$2"
    _idle="$3"

    for _pair in "$P_LOAD:$_load" "$P_HINT:$_hint" "$P_IDLE:$_idle"; do
        _p=${_pair%%:*}
        _v=${_pair#*:}
        if [ -e "$_p" ]; then
            echo "$_v" > "$_p" 2>/dev/null || log "写 $_p 失败（值 $_v）"
        else
            log "节点不存在，跳过：$_p（debugfs 可能尚未挂载）"
        fi
    done
}

status() {
    echo "load_target          = $(cat $P_LOAD 2>/dev/null)"
    echo "use_throughput_hint  = $(cat $P_HINT 2>/dev/null)"
    echo "gr_idle_timeout_us   = $(cat $P_IDLE 2>/dev/null)"
    echo "cur_freq             = $(cat /sys/class/devfreq/gk20a.0/cur_freq 2>/dev/null)"
    echo "target_freq          = $(cat /sys/class/devfreq/gk20a.0/target_freq 2>/dev/null)"
    echo "governor             = $(cat /sys/class/devfreq/gk20a.0/governor 2>/dev/null)"
    echo "persist.ardbeg.gpu_video = $(getprop persist.ardbeg.gpu_video)"
}

apply() {
    write3 "$V_LOAD" "$V_HINT" "$V_IDLE"
    log "已应用视频播放 GPU 调频（load_target=$V_LOAD hint=$V_HINT idle=$V_IDLE）"
}

restore() {
    write3 "$D_LOAD" "$D_HINT" "$D_IDLE"
    log "已恢复原厂 GPU 调频（load_target=$D_LOAD hint=$D_HINT idle=$D_IDLE）"
}

case "$1" in
    apply)   apply ;;
    restore) restore ;;
    status)  status ;;
    *)
        # 开机默认入口。persist.* 在 load_persist_props 之后才就绪，
        # 本服务挂在 sys.boot_completed=1，那时已经能读到正确值。
        if [ "$(getprop persist.ardbeg.gpu_video)" = "0" ]; then
            restore
        else
            apply
        fi
        ;;
esac

exit 0
