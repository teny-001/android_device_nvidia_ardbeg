#!/system/bin/sh
# ============================================================================
# ardbeg_fps_match.sh —— 让显示刷新率跟随片源帧率（帧率匹配）
#
# ============================================================================
# 【这个脚本解决什么问题】
#
# 本机的显示输出只有 60Hz 一档在用（HDMI 1080p60），而绝大多数片源是
# 23.976 / 24 / 25 / 30 fps。60 不是 25 的整数倍，于是每一帧的显示时长
# 只能取 2 个 vsync(33.3ms) 或 3 个 vsync(50ms)，交替出现 ——
# 这就是 3:2 pulldown，俗称「抖」。25fps 在 60Hz 上的理想平均是 2.4 个
# vsync，除不尽，所以抖动是数学上必然的，跟解码性能无关。
#
# 把显示刷新率切到 50Hz，25fps 每帧正好 2 个 vsync，抖动消失。
# 同理：24fps -> 24Hz(1:1) 或 48Hz(2:2)；30fps -> 60Hz(2:2) 本来就对；
#       50fps -> 50Hz(1:1)。
#
# ============================================================================
# 【为什么需要两步，而且顺序不能反】
#
#   第 1 步：切 DC 的时序（真正改变 HDMI 输出的像素时钟）
#       echo D:1920x1080p-50 > /sys/class/graphics/fb0/mode
#
#   第 2 步：告诉 SurfaceFlinger「现在是 50Hz」
#       service call SurfaceFlinger 1040 i32 50
#
# ★ 为什么只做第 1 步不够（2026-11-10 实测）：
#   厂商的 hwcomposer.tegra.so 的 getDisplayAttributes(HWC_DISPLAY_VSYNC_PERIOD)
#   永远返回 60Hz，它不看 DC 当前实际跑的是什么时序。
#   SF 启动时 queryDisplayProperties() 从 HWC 取一次 refresh 存进
#   mDisplayData[disp].configs[c].refresh，之后 resyncToHardwareVsync()
#   再拿这个值去设 mPrimaryDispSync.setPeriod()。
#   结果就是：DC 已经 50Hz 了，SF 仍然按 60Hz 排帧，画面反而更乱
#   （dumpsys SurfaceFlinger 的 "refresh-rate" 行仍然是 60.0000xx，
#     sys.tegra.refresh 属性也还是 60）。
#
# ★ 为什么第 2 步要用自己加的 binder 命令 1040：
#   AOSP 原本没有任何运行期改刷新率的入口（只在 HWC hotplug 时被动更新）。
#   1040 是本项目往 SurfaceFlinger_hwc1.cpp 里新加的事务码，它做两件事：
#       getHwComposer().setRefreshPeriod(HWC_DISPLAY_PRIMARY, period);
#       mPrimaryDispSync.setPeriod(period);
#   前者改 SF 缓存里的 refresh（让 dumpsys 和后续 resync 都用新值），
#   后者改 DispSync 的 vsync 模型（真正影响出帧节奏）。
#   源码改动见：
#       patches/frameworks/native/services/surfaceflinger/
#           SurfaceFlinger_hwc1.cpp.patch
#           DisplayHardware/HWComposer_hwc1.cpp.patch
#           DisplayHardware/HWComposer_hwc1.h.patch
#
# ★ 顺序为什么不能反：
#   1040 只是改 SF 的软件模型，不会去动 DC 的硬件时序。
#   如果先 1040 后切 DC，中间那一小段时间 SF 按 50Hz 出帧而 DC 还在 60Hz 扫，
#   会看到明显的顿挫 + 撕裂。所以必须「先硬件后软件」。
#   脚本里 apply_hz() 严格执行这个顺序，并在切完 DC 后回读 fb0/mode 确认生效
#   才发 1040。
#
# ============================================================================
# 【没有 EDID 时会怎样（重要）】
#
#   /sys/class/graphics/fb0/modes 的内容完全来自 HDMI sink 的 EDID。
#   HDMI 没插 / 电视关着的时候，这个文件是**空的**，
#   此时无法切模式（连 60Hz 都写不进去），脚本会直接跳过并记一条日志。
#   实测：拔掉 HDMI 后内核状态机走到
#       hdmi_state_machine_set_state_l: switching from state 1 (Check Plug)
#                                       to state 3 (Disabled)
#   但 DC 仍然保留拔线前的 1080p 时序在输出，所以 SF 不会崩、画面还是黑的。
#   这种情况属于物理层没信号，脚本无能为力，也不应该反复重试刷日志。
#
# ============================================================================
# 【怎么用】
#
#   ardbeg_fps_match.sh status            看当前 fb0 模式 / SF 刷新率 / 开关状态
#   ardbeg_fps_match.sh list              列出当前显示器支持的所有模式
#   ardbeg_fps_match.sh apply 50          强制切到 50Hz（先 DC 后 1040）
#   ardbeg_fps_match.sh match 25          按片源 25fps 自动挑最合适的刷新率并应用
#   ardbeg_fps_match.sh detect            采 5 条样本(约 8 秒, 取后 4 条算)测片源帧率
#                                        （用 media.player 的 numFramesTotal 增量，
#                                          不再受在线 App 多层/同名层/50Hz 刷新周期干扰）
#   ardbeg_fps_match.sh auto              测一次 -> 区间分类 -> 应用（约 8 秒）
#   ardbeg_fps_match.sh reset             回到默认 60Hz
#   ardbeg_fps_match.sh watch             常驻守护（由 zz-ardbeg-fps-match.rc 拉起）
#
#   开关：persist.ardbeg.fps_match
#       0（默认）= watch 常驻但待机，不做任何显示改动
#       1        = watch 常驻并自动匹配
#   watch 是常驻进程（见 IDLE_INTERVAL 处的补记 #2），开关开了/关了
#   它自己会在下一轮轮询里感知，所以运行时只需 setprop，不必 stop/start：
#       setprop persist.ardbeg.fps_match 1    # 5 秒内自动开始
#       setprop persist.ardbeg.fps_match 0    # 5 秒内停止并回到 60Hz
#   其它子命令（status/list/apply/match/detect/auto/reset）与开关无关，
#   任何时候都能手动跑。
#
# ============================================================================
# 【和 sf_hwc_off.sh 的关系】
#
#   两个脚本互不依赖，但都在跟 SF 打交道：
#     sf_hwc_off.sh  -> 关掉厂商 HWC 合成，逼 SF 走 GLES（因为厂商 glcomposer
#                       在 7.1 上会崩野指针，见该脚本顶部崩溃栈）
#     ardbeg_fps_match.sh -> 改刷新率
#   因为 HWC 合成被关了，画面是 SF 自己用 GLES 合成后整屏送出去的，
#   所以刷新率只由 DispSync 决定，1040 改 setPeriod 的效果非常直接。
#   反过来，如果哪天把 HWC 合成打开了，1040 依然有效（它改的是 SF 层），
#   但厂商 HWC 内部还按 60Hz 假设做 overlay 规划，可能会出现新的时序问题。
#   也就是说：**这个脚本的效果是在 sf_hwc_off=1 的前提下验证的**。
#
# ============================================================================
# 【实测记录】
#
#   2026-11-10，HDMI 接 1080p 电视，播放 25.000fps / 425 帧 / 17 秒测试片
#   （1280x720 H.264，stts 单一 delta=4，timescale=100）。
#
#   机制验证：
#     1040 i32 50  -> dumpsys refresh-rate 50.000000 fps，SF 不崩，画面正常
#     1040 i32 60  -> dumpsys refresh-rate 60.000002 fps
#     1040 i32 10  -> Error 0xffffffea "Invalid argument"（保护生效）
#     合法区间 20~240Hz。
#
#   ★ 掉帧率（numFramesDropped）测不出本功能的效果 —— 这是设计使然
#     每次完整播放结束后的终值：
#         60Hz: 844 帧丢 58 = 6.87%
#         50Hz: 421 帧丢 28 = 6.65%
#     几乎没差别。原因是 3:2 pulldown 下每一帧都正常上屏了，只是被保持
#     2 个或 3 个 vsync，numFramesDropped 只统计「来不及被丢掉」的帧，
#     对节奏不匀完全不敏感。拿它判断 pulldown 是选错了指标。
#
#   ★ 正确指标：渲染端请求的上屏时刻（desiredPresentTime）的间隔分布
#     用 dumpsys SurfaceFlinger --latency <视频层> 取 128 帧的时间戳，
#     算相邻间隔。25fps 片源的理想值恒为 40.0ms。
#
#         60Hz: 40.0ms 占 84.7%，83.3ms（跳过一帧）占 12.4%，标准差 22.46ms
#         50Hz: 40.0ms 占 94.5%，83.3ms（跳过一帧）占  4.4%，标准差 11.93ms
#
#     结论：切到 50Hz 后节奏明显更均匀，被跳过的帧少了约 3 倍。
#     残余的 4.4% 跳帧是另一个原因（SF 每帧 GLES 合成耗时偏高，
#     实测 eglSwapBuffers 到 27ms），帧率匹配管不到，需要单独解决。
#
#   踩过的坑（写脚本时验证过，别再犯）：
#     - --latency 输出里大量 "0 0 0" 是环形缓冲空槽；
#       actualPresentTime 的 9223372036854775807(INT64_MAX) 是「未上屏」
#       哨兵值，不认它会被当成 9.2e18 ns 的超大时间戳，把样本全筛掉。
#     - 128 槽会跨越多次播放，必须按时间窗截断，否则间隔能算到几十万 ms。
#     - 不要用「每 2 秒读 numFramesTotal 求差」的方法：am force-stop 之后
#       旧 NuPlayer 实例会残留一小段时间，dumpsys 里同时出现新旧两个 block，
#       会算出「2 秒 69 帧 = 34fps」这种 25fps 片源物理上不可能的数。
#       用「播放结束后的终值」才干净。
#
# ============================================================================
# 【2026-11-10 补记：在线视频 App 实测推翻了「测到 25fps 就固定切 50Hz」】
#
# 上面那套 --latency 测量法只对**本地单视频层、单一帧率**的测试片成立，
# 拿到真实在线视频 App（com.cibn.tv / CIBN 优酷）上立刻失效：
#
#   1) 在线 App 同时挂多个 SurfaceView 层，而且**名字可以完全相同**
#      （实测 4 个同名层）。dumpsys SurfaceFlinger --latency <层名> 按名字
#      只匹配第一个，同名层无法区分；广告层 / 正片层 / 贴片层还会动态增删。
#   2) --latency 环形缓冲里混着 INT64_MAX 哨兵、0 0 0 空槽、跨阶段的大跳，
#      正片期算出来的间隔有 45% 以上落在「其他」，根本得不到干净的片源节奏。
#   3) 最致命的：一旦切到 50Hz，--latency 第一行（刷新周期）变成 20000000ns
#      = 20ms，旧的 measure_fps_x100() 会把 20ms 当成帧间隔、算出 50fps，
#      于是吸附到 5000 -> 又切 50Hz，形成「越切越认定自己是对的」的死循环。
#
# 用 dumpsys media.player 的 numFramesTotal 增量重测，才看清真实情况：
#   - 片前广告：约 25fps（60Hz 下 desired 40.0ms 占 82.8%、83.3ms 占 14.1%，
#     和本地 25fps 测试片在 60Hz 下的 12.4% 跳帧同量级）
#   - 正片《谜案一九三七》：numFramesTotal 6676 -> 7128，15 秒 +452 帧
#     = 30.13fps，numFramesDropped 只 +13
#   → **同一段观看里帧率从 25 变到 30，不是固定的。**
#
# 而 30fps 在 60Hz 上本来就是 2:2 完美匹配，切到 50Hz 反而是 5:3 pulldown，
# 比不切更差。所以自动模式不能见帧率就套 fps_to_hz()，改成区间分类：
#   - 实测 22.00~27.50fps（24/25 类，60Hz 上正吃 3:2 pulldown）-> 50Hz
#     25fps 在 50Hz 是精确 2:2（本地片 + App 广告期都验证过收益）；
#     24fps 在 50Hz 是 2.08:1，不完美但不比 60Hz 的 2.5:1 差。
#   - 30/50/60fps -> 保持 60Hz（60Hz 上分别是 2:2 / 5:6 / 1:1，不切更好）
#   - 不切 24Hz/25Hz：本机 1080p 没有 48Hz，24Hz 会让整个系统 UI 降到
#     24fps、且 App 帧率动态变化时会反复重同步 HDMI。想要真正 24p
#     观感请用 `match 24` 手动切，不要放进自动匹配。
#
# 因此本次改动做了三件事（下面每处代码旁都有详细注释）：
#   A. 帧率检测从 --latency 换成 media.player 的 numFramesTotal 累计增量，
#      用 /proc/uptime 的百分之一秒时钟计时，取最近 4 条样本（约 6 秒
#      窗口）平滑短时抖动，并丢掉最早一条避开起播缓冲。
#      这个计数来自视频解码器（NuPlayerDecoder 的 frames-total），
#      与 SurfaceFlinger 层、与显示刷新率完全无关，所以切到 50Hz 后
#      读数不变，不会像 --latency 那样自我强化误判。
#   B. 自动模式不做精确吸附，改成「区间分类」：只有实测落在
#      22.00~27.50fps 才切 50Hz，其余一律保持 60Hz。
#      → 30fps 正片在 60Hz 是 2:2，绝不会被误切到 50Hz 的 5:3。
#   C. 加滞回 / 最短驻留 / 最短播放时长，避免广告<->正片切换时
#      反复切 HDMI 模式把电视闪黑。
#
# 本次真机验证（同片 25.000fps / 425 帧）：
#   60Hz 与 50Hz 下各采 7 个点、跨约 13 秒，全程差分分别得
#     23.8fps / 24.0fps —— 两者一致，证明增量法测的是片源帧率、
#     与刷新率无关；但也说明本机播放器对该片有约 -5% 系统性偏低。
#   单个 2 秒窗口在 20.8~26.2fps 之间跳；6 秒窗口可能低到 22.68fps
#     （实测一次 detect 得 22.68，被吸附成 23.98fps）。
#   → 所以 B 用区间分类而不是精确吸附：24 与 25 只差 4%，
#     在 ±5% 测量噪声下无法可靠区分，硬吸附只会在边界上摇摆。
#   另有 App 正片实测 30.13fps（numFramesTotal 15 秒 +452 帧），
#     落在区间外 -> 自动模式保持 60Hz，正是想要的结果。
# ============================================================================

FBMODE=/sys/class/graphics/fb0/mode
FBMODES=/sys/class/graphics/fb0/modes
TAG=ardbeg_fps

# SF 的 binder 事务码。定义在这里而不是散在代码里，方便将来再改。
#   1040 = 本项目新增：设主显示刷新率（单位 Hz）
SF_TX_SET_REFRESH=1040

# 没有视频时回到这一档。60 是 HDMI 最常见、兼容性最好的模式。
DEFAULT_HZ=60

# watch 轮询间隔（秒）。2 秒是权衡：太短会频繁 dumpsys 拉高负载，
# 太长则切视频后要等很久才生效。
WATCH_INTERVAL=2

# ---------------------------------------------------------------------------
# 【2026-11-11 补记 #2：待机轮询间隔，修复 init 反复重启服务】
#
# 刷机验证时发现 init.svc.ardbeg_fps_match 一直是 restarting：
#   init: Starting service 'ardbeg_fps_match'...
#   init: Service 'ardbeg_fps_match' (pid N) exited with status 0
#   （每 5 秒一轮，dmesg 被刷满）
# 根因：zz-ardbeg-fps-match.rc 把它声明成一个**常驻 service**（没有 oneshot），
#   而旧版 watch_loop() 在 persist.ardbeg.fps_match != 1 时直接 `return 0`。
#   Android init 对非 oneshot 服务是「退出就重启」的语义：
#     system/core/init/service.cpp:96-124 Service::Reap()
#       非 oneshot 且未置 SVC_DISABLED -> 杀进程组并排 5 秒后重启；
#       oneshot 才会在退出时置 SVC_DISABLED 并 NotifyStateChange("stopped")。
#   所以「脚本正常退出 0」在 init 眼里等同于「服务挂了」，必然无限重启。
#   它不致命（待机时什么都不做），但每 5 秒 fork 一次 + 刷 2 条 dmesg，
#   还把 "does not have a SELinux domain defined" 告警也放大成刷屏。
#
# 修法（本脚本 + rc 两处）：不在开关关闭时退出，而是让 watch 保持常驻、
#   进入下面的「待机」分支：不 dumpsys、不读 sysfs、不写 fb0，只每
#   IDLE_INTERVAL 秒 getprop 一次。这样 init 看到的是 running，不再重启；
#   而且 persist.* 运行时可 setprop，开关一变下一轮就生效，用户不需要
#   stop/start 服务（旧注释里的做法已作废）。
#
# 为什么不用 oneshot 了事：oneshot 会让「watch 真的崩了」也得不到重启，
#   看门狗语义反而丢了；而且 oneshot + 属性触发 start 在 persist 属性
#   开机早期（post-fs-data 载入 /data/property）就可能抢在
#   sys.boot_completed / HDMI EDID 就绪之前启动。常驻 + 待机是这套 init
#   语义下最稳的组合，也顺带保住了 init 原有的崩溃自动拉起能力。
#
# 5 秒是「setprop 之后多久生效」的上限，对这个功能足够快；
#   待机时一次 getprop 的开销可以忽略。
# ---------------------------------------------------------------------------
IDLE_INTERVAL=5

# 连续几次读数一致才动作（去抖）。2026-11-10 从 2 提到 3：
# 在线 App 的广告层/正片层切换时，numFramesTotal 会换一套新的累计计数，
# 单轮读数很容易刚好落在过渡帧上。3 轮（每轮约 2 秒）都得到同一目标才动，
# 配合下面 4 秒测量窗口，实际是「连续确认约 10 秒」才切一次 HDMI 时序。
WATCH_STABLE_NEED=3

# ---------------------------------------------------------------------------
# ↓↓↓ 以下是 2026-11-10 在线 App 实测后新增的常量 ↓↓↓
# ---------------------------------------------------------------------------

# 帧率采样历史文件，每行一条 "<百分之一秒时刻> <累计解码帧数>"。
# 【为什么落盘而不是放 shell 变量】
#   watch 是常驻循环，但 detect/auto/status 都是一次性调用；把历史放在
#   文件里，两种调用方式能共用同一套 sample_once()/measure_fps_x100()，
#   而且脚本被 stop/start 重启后历史不会凭空消失（由 sample_once 负责
#   在计数归零时清空，见该函数注释）。
HIST=/data/local/tmp/.ardbeg_fps_hist

# 测量窗口下限，单位「百分之一秒」。400 = 4 秒。
# 【为什么是 4 秒】真机实测：2 秒窗口算同一 25fps 片会在 20.8~26.2fps
#   之间跳（起播缓冲、解码器批量提交、AVSync 微调都会让瞬时帧数不均），
#   吸附容差虽有 8%，但 20.8 已经贴到 25 的下限边缘。4 秒以上窗口
#   实测稳定在 25.08~25.19fps。窗口越长越稳，但切档响应也越慢，4 秒
#   是「稳」和「不要等太久」的折中。
MIN_WINDOW_CS=400

# 历史最多保留几条。每条约 2 秒，8 条约 16 秒，足够覆盖 4 秒窗口，
# 又不会让文件无限增长（watch 可能连续跑几天）。
HIST_MAX=8

# 最短驻留时间（秒）：成功切过一次模式后，这段时间内即使测到新帧率
# 也不再切。2026-11-10 App 实测广告 25fps、正片 30fps 会来回变，
# 若不加驻留，广告结束进正片会立刻切回 60Hz，正片里插播广告又切回 50Hz，
# 每切一次 HDMI 时序电视就黑一下重新同步，观感比 pulldown 本身更糟。
MIN_DWELL_SEC=20

# 起播后至少播够这么久才允许自动切档（秒）。
# 短视频（几十秒以内）切一次黑屏的代价远大于 3:2 pulldown 那点抖动，
# 用户此前也明确说过「看短视频比 pulldown 更烦」。用历史第一条样本
# 的时刻当作起播时刻，见 watch_loop 里的 _play_started。
MIN_PLAY_SEC=10

# 自动模式切 50Hz 的「实测帧率区间」（帧率*100，闭区间）。
#
# 【为什么用区间分类，而不是精确吸附到 2500】
#   1) 24 与 25 只差 4%，而 numFramesTotal 增量在 2 秒窗口有 ±20% 抖动、
#      6~12 秒窗口仍有约 -5% 的系统性偏低（本机 25.000fps 测试片实测
#      收敛到 23.8~24.5fps，见文件头实测记录）。精确吸附会把它判成
#      24fps，若只认精确 2500 就永远切不了 50Hz，等于功能失效。
#   2) 下界 2200：低于这个基本是起播缓冲 / 换片过渡，不该动作。
#   3) 上界 2750：30fps 的 8% 容差下限是 2760。把上界卡在 2750，
#      即使 30fps 正片因短暂扰动测低一点，也不会被误切到 50Hz ——
#      30fps 在 50Hz 是 5:3 pulldown，比 60Hz 的 2:2 更差，这是本轮
#      App 实测最要防的误切。
#   4) 区间内统一切 50Hz：25fps 在 50Hz 是精确 2:2（收益最明确）；
#      24fps 在 50Hz 是 2.08:1，虽不完美但不比 60Hz 的 2.5:1 差。
#      本机 1080p 没有 48Hz、24Hz 会把整个 UI 拖到 24fps，所以自动
#      模式不做 24p，统一用 50Hz 这一档。
# 手动 `match <fps>` 不走这里，仍按 fps_to_hz() 的完整映射表执行。
AUTO_PULLDOWN_MIN=2200
AUTO_PULLDOWN_MAX=2750
AUTO_TARGET_HZ=50

# ---------------------------------------------------------------------------
# 日志：同时打到 stdout 和 logcat（tag=ardbeg_fps）
#   为什么两边都要：手动跑的时候要看得见，常驻时只能靠 logcat 回溯。
# ---------------------------------------------------------------------------
log_msg() {
    echo "ardbeg_fps: $*"
    log -t "$TAG" "$*" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 读当前 fb0 的模式名，如 "D:1920x1080p-60"
# ---------------------------------------------------------------------------
cur_mode() {
    cat "$FBMODE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 列出显示器支持的模式（每行一个）
#   HDMI 未连接时这里是空的 —— 调用方必须先判断。
# ---------------------------------------------------------------------------
modes_list() {
    cat "$FBMODES" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 在模式列表里挑一个刷新率恰好等于 $1 的模式
#
#   $1 = 目标 Hz（整数，如 50）
#   $2 = 期望分辨率（可选，默认 1920x1080）
#
#   返回：模式名（成功）/ 空（没有这个刷新率）
#
#   为什么优先匹配 1920x1080：
#     modes 里同一刷新率可能有多个分辨率（720p/1080p/4K），
#     本机 HDMI 走 1080p，选别的分辨率会让画面变模糊。
#
#   为什么要排除 U:/V: 前缀：
#     tegrafb 的 modes 里除了 "D:"（真实 display 模式）还有 "U:"（用户
#     自定义）和 "V:"（虚拟）条目，那些不是 HDMI 能实际输出的时序。
# ---------------------------------------------------------------------------
pick_mode() {
    _hz="$1"
    _want="${2:-1920x1080}"
    _fallback=""

    _all=$(modes_list)
    [ -z "$_all" ] && return 1

    # 用 for 逐词遍历（modes 是空白/换行分隔，for 正好按空白切）
    for _m in $_all; do
        # 只看真实模式
        case "$_m" in
            D:*) ;;
            *)   continue ;;
        esac
        # 取 "p-" 之后的部分做**精确**比较。
        # 不能用 case 的 *p-$_hz 通配，那会把 p-60 匹配到 p-600 上。
        _suf=${_m##*p-}
        [ "$_suf" = "$_hz" ] || continue

        # 分辨率部分：D:1920x1080p-50 -> 1920x1080
        _res=${_m#D:}
        _res=${_res%p-"$_hz"}
        if [ "$_res" = "$_want" ]; then
            echo "$_m"
            return 0
        fi
        [ -z "$_fallback" ] && _fallback="$_m"
    done

    [ -n "$_fallback" ] && { echo "$_fallback"; return 0; }
    return 1
}

# ---------------------------------------------------------------------------
# 从 dumpsys SurfaceFlinger 里读 SF 认定的刷新率（整数 Hz）
#   这一行是 SF 打印 hwc.getRefreshPeriod(HWC_DISPLAY_PRIMARY) 算出来的，
#   也就是「SF 以为自己在按多少 Hz 出帧」，正是 1040 要改的东西。
#   输出形如：  refresh-rate              : 60.000002 fps
# ---------------------------------------------------------------------------
read_sf_rate() {
    dumpsys SurfaceFlinger 2>/dev/null \
        | sed -n 's/^ *refresh-rate *: *\([0-9][0-9]*\)\..*/\1/p' \
        | head -1
}

# ---------------------------------------------------------------------------
# 把刷新率告诉 SurfaceFlinger（1040）
#   注意：这只是软件侧，必须先由 apply_hz() 把 DC 硬件时序切好。
# ---------------------------------------------------------------------------
set_sf_rate() {
    _hz="$1"
    service call SurfaceFlinger $SF_TX_SET_REFRESH i32 "$_hz" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 应用一个刷新率：先硬件（fb0/mode），再软件（1040），最后回读校验
#
#   $1 = 目标 Hz
#   返回 0 成功 / 非 0 失败（失败原因已记日志）
#
# ★ 顺序固定：DC -> SF。反了会看到顿挫+撕裂，原因见文件头。
# ---------------------------------------------------------------------------
apply_hz() {
    _hz="$1"

    # ---- 前置检查 1：显示器在不在 ----
    if [ -z "$(modes_list)" ]; then
        log_msg "跳过 ${_hz}Hz：$FBMODES 为空（HDMI 未连接/无 EDID，无法切模式）"
        return 2
    fi

    # ---- 前置检查 2：这个刷新率支不支持 ----
    _m=$(pick_mode "$_hz")
    if [ -z "$_m" ]; then
        log_msg "跳过 ${_hz}Hz：显示器不支持该刷新率"
        return 3
    fi

    # ---- 第 1 步：切 DC 硬件时序 ----
    _cur=$(cur_mode)
    if [ "$_cur" != "$_m" ]; then
        echo "$_m" > "$FBMODE" 2>/dev/null
        if [ $? -ne 0 ]; then
            log_msg "写 $FBMODE 失败（目标 $_m）"
            return 4
        fi
        # 给 DC 一点时间完成时序重配。
        # 不 sleep 直接发 1040 的话，偶尔会赶上 DC 还没切完，
        # SF 拿到的 config 还是旧的。
        sleep 1
    fi

    _now=$(cur_mode)
    if [ "$_now" != "$_m" ]; then
        log_msg "切模式未生效：期望 $_m，实际 $_now"
        return 5
    fi

    # ---- 第 2 步：告诉 SF ----
    _sfnow=$(read_sf_rate)
    if [ "$_sfnow" = "$_hz" ]; then
        # 已经是对的，不用再发命令（避免无谓的 repaintEverything 造成闪一下）
        return 0
    fi
    set_sf_rate "$_hz"
    sleep 1

    # ---- 第 3 步：回读校验 ----
    # 为什么要校验：1040 里有 invalidateHwcGeometry() + repaintEverything()，
    # 如果此时恰好来了一次 HWC hotplug，SF 会重新 queryDisplayProperties()
    # 把 refresh 覆盖回 HWC 报的 60。校验能发现这种情况，下面重试一次。
    _after=$(read_sf_rate)
    if [ "$_after" != "$_hz" ]; then
        log_msg "1040 未生效（回读 ${_after}Hz），重试一次"
        set_sf_rate "$_hz"
        sleep 1
        _after=$(read_sf_rate)
        if [ "$_after" != "$_hz" ]; then
            log_msg "1040 仍然未生效，回读 ${_after}Hz，放弃"
            return 6
        fi
    fi

    log_msg "已切到 ${_hz}Hz（fb0=$(cur_mode)）"
    return 0
}

# ---------------------------------------------------------------------------
# 片源帧率 -> 显示刷新率
#
#   $1 = 帧率 * 100（整数，如 2500 表示 25.00fps）
#   输出：最合适的 Hz（从显示器实际支持的模式里挑）
#
#   映射原则：优先整数倍（1:1 或 2:2），避免 pulldown。
#     23.976/24  ->  24 (1:1)  > 48 (2:2)  > 72 (3:3)  > 60
#     25         ->  50 (2:2)  > 25 (1:1)  > 75 (3:3)  > 60
#     29.97/30   ->  60 (2:2)  > 30 (1:1)              > 60
#     50         ->  50 (1:1)  > 100(2:2)              > 60
#     59.94/60   ->  60 (1:1)
#
#   为什么 24fps 首选 24 而不是 48：
#     24Hz 是标准 24p，绝大多数电视原生支持；48Hz 很多电视不认。
#     只有在 24 不可用（或想要更低闪烁感）时才退到 48。
#
#   为什么 25fps 首选 50 而不是 25：
#     25Hz 整屏闪烁很明显（人眼对 25Hz 临界闪烁频率以下很敏感），
#     50Hz 是 2:2，同样没有 pulldown，观感好得多。
# ---------------------------------------------------------------------------
fps_to_hz() {
    _fps100="$1"
    case "$_fps100" in
        2398|2400) _cands="24 48 72 60" ;;
        2500)      _cands="50 25 75 60" ;;
        2997|3000) _cands="60 30" ;;
        5000)      _cands="50 100 60" ;;
        5994|6000) _cands="60" ;;
        *)         _cands="60" ;;
    esac

    for _h in $_cands; do
        if [ -n "$(pick_mode "$_h")" ]; then
            echo "$_h"
            return 0
        fi
    done
    echo "$DEFAULT_HZ"
    return 0
}

# ---------------------------------------------------------------------------
# 把测出来的原始值吸附到最近的标准帧率
#
#   $1 = 帧率 * 100（可能带测量误差，比如 2487）
#   输出：标准帧率 * 100（如 2500），偏差超过 8% 则返回非 0
#
#   为什么要吸附：片源是 25fps，但测量会受丢帧、起播抖动影响，
#   测出 24.1 / 26.3 都正常。直接拿去映射会挑错档位。
#
#   ★ 2026-11-10 起**自动模式已不再依赖本函数**（改用 auto_target_hz()
#     的区间分类），因为实测本机对 25fps 片源有约 -5% 系统性偏低，
#     精确吸附会把它判成 24fps，在 24/25 边界上摇摆。
#     现在本函数只服务于 `match <fps>` 手动命令和 detect/status 的
#     参考显示。手动命令由用户直接给帧率，不受测量偏差影响。
# ---------------------------------------------------------------------------
snap_fps_x100() {
    _v="$1"
    _best=0
    _bd=999999
    for _c in 2398 2400 2500 2997 3000 5000 5994 6000; do
        _d=$((_v - _c))
        [ "$_d" -lt 0 ] && _d=$((-_d))
        if [ "$_d" -lt "$_bd" ]; then
            _bd=$_d
            _best=$_c
        fi
    done
    # 8% 容差。25fps 的 8% 是 200，够覆盖测量噪声，
    # 又不会把 30fps(3000) 误判成 25fps。
    _lim=$((_best * 8 / 100))
    if [ "$_bd" -le "$_lim" ]; then
        echo "$_best"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 取当前单调时钟，单位「百分之一秒」
#
# 【为什么不用 date +%s%N】
#   设备上的 toybox date 不认 %N，实测 `date +%s%N` 会原样输出
#   "1794395689N"（把 N 当字面量），拿不到纳秒。
#   /proc/uptime 第一行形如 "2161.02 2058.97"，小数点后正好两位，
#   去掉小数点就是百分之一秒，纯 sh 字符串操作即可，无需浮点。
#   uptime 单调递增，不受用户改系统时间 / setprop 影响，适合算增量。
# ---------------------------------------------------------------------------
now_cs() {
    _u=$(cat /proc/uptime 2>/dev/null)
    set -- $_u
    _ip=${1%%.*}             # 整数秒
    _fp=${1#*.}              # 小数部分（通常两位）
    _fp="${_fp}00"           # 不足两位补 0
    _fp=${_fp%"${_fp#??}"}   # 只保留前两位
    echo $((_ip * 100 + _fp))
}

# ---------------------------------------------------------------------------
# 读当前视频解码器的累计输出帧数
#
# 【字段来源，已对过 7.1 源码】
#   frameworks/av/media/libmediaplayerservice/nuplayer/NuPlayerDriver.cpp:694
#     "    numFramesTotal(%lld), numFramesDropped(%lld), percentageDropped(%.2f%%)\n"
#   只在 stats 的 mime 以 "video/" 开头时才打印。计数由
#   NuPlayerDecoder.cpp:722 的 `mNumFramesTotal += !mIsAudio;` 累加，
#   即「视频解码器每提交一帧 +1」。
#   ★ 这个量与 SurfaceFlinger 层、显示刷新率、3:2 pulldown 全都无关 ——
#     这正是它比 --latency 可靠的原因：切到 50Hz 之后它仍然报 25fps。
#
# 【为什么取所有行里的最大值】
#   在线 App 换片 / 广告转正片时，dumpsys media.player 里可能短暂同时
#   存在新旧两个 NuPlayer client（旧的不再增长）。活跃的那个累计值最大
#   且仍在增长，取最大值能避开残留的死 client。
#   若整个输出里没有 numFramesTotal 行 = 当前没有视频在解码，返回非 0，
#   调用方据此判定「无视频」。这比靠 SurfaceView 层名判断更通用：
#   用 TextureView / SurfaceTexture 渲染的播放器同样有视频解码器。
# ---------------------------------------------------------------------------
read_decoder_frames() {
    _vals=$(dumpsys media.player 2>/dev/null \
        | sed -n 's/.*numFramesTotal(\([0-9][0-9]*\)).*/\1/p')
    [ -z "$_vals" ] && return 1
    _max=0
    for _v in $_vals; do
        case "$_v" in
            *[!0-9]*) continue ;;
        esac
        [ "$_v" -gt "$_max" ] && _max="$_v"
    done
    [ "$_max" -gt 0 ] || return 1
    echo "$_max"
    return 0
}

# ---------------------------------------------------------------------------
# 采一条样本写进历史，并维护历史的生命周期
#
# 【为什么要检测计数归零】
#   numFramesTotal 是每个解码器实例自己的累计值。广告 -> 正片、换集、
#   播放器重建时，新解码器从 0 开始，新旧样本之间的差值会变成负数或
#   大跳，算出来的帧率毫无意义。检测到「当前值 < 历史最后一条」就清空
#   历史重新攒窗口，让过渡期的 4~10 秒自然表现为「样本不足」，
#   正好和滞回一起挡住切换瞬间的乱切。
#
# 【为什么无视频时清空历史】
#   退出播放后历史会一直留着，下次起播若不清空，首尾会跨两次播放，
#   算出几十 fps 这种荒唐值。
# ---------------------------------------------------------------------------
sample_once() {
    _t=$(now_cs)
    _f=$(read_decoder_frames)
    if [ -z "$_f" ]; then
        rm -f "$HIST"
        return 1
    fi

    if [ -s "$HIST" ]; then
        _lastf=0
        while read -r _lt _lf; do
            [ -n "$_lf" ] && _lastf="$_lf"
        done < "$HIST"
        if [ "$_lastf" -gt 0 ] && [ "$_f" -lt "$_lastf" ]; then
            rm -f "$HIST"
        fi
    fi

    echo "$_t $_f" >> "$HIST"

    # 只保留最近 HIST_MAX 条。用纯 sh 读写而不是 tail -n，避免多一层
    # 外部命令依赖，也避免管道子进程改不了文件的麻烦。
    _n=0
    while read -r _lt _lf; do
        _n=$((_n + 1))
    done < "$HIST"
    if [ "$_n" -gt "$HIST_MAX" ]; then
        _skip=$((_n - HIST_MAX))
        _i=0
        : > "$HIST.tmp"
        while read -r _lt _lf; do
            _i=$((_i + 1))
            [ "$_i" -gt "$_skip" ] && echo "$_lt $_lf" >> "$HIST.tmp"
        done < "$HIST"
        mv "$HIST.tmp" "$HIST"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 一次性命令（detect / auto）用的采样：连续采 5 条，间隔 2 秒，
# 总跨度约 8 秒；measure_fps_x100() 只取后 4 条（约 6 秒窗口）。
#
# 【为什么要多采一条再丢掉第一条】
#   真机实测：起播后前 2~4 秒解码器在填缓冲，提交帧数明显偏慢
#   （2 秒窗口只有 20.8~22.2fps），第 5 秒以后才稳定到 25~26fps。
#   若直接用全部 4 条算首尾，25.000fps 的片会被测成 24.47fps，
#   正好卡在 24 与 25 的吸附边界上被误判成 24fps。
#   丢掉第一条（起播缓冲期）后再算，实测稳定在 25.0~25.2fps。
#
# 【为什么 watch 不用它】
#   watch_loop 本来就是每 2 秒一轮的常驻循环，每轮调一次 sample_once()
#   即可自然攒出窗口；再在这里 sleep 会把轮询周期拉到 10 秒，反应太慢。
#   但两条路径共用同一个 HIST 文件和同一个「取后 4 条」的
#   measure_fps_x100()，保证「手动测一次」和「守护常驻」同一种判据。
# ---------------------------------------------------------------------------
collect_samples() {
    rm -f "$HIST"
    _i=0
    while [ "$_i" -lt 5 ]; do
        sample_once || return 1
        _i=$((_i + 1))
        [ "$_i" -lt 5 ] && sleep 2
    done
    return 0
}

# ---------------------------------------------------------------------------
# 找到当前正在显示的视频层名字 —— **仅供 status 打印，不参与帧率决策**
#
# 【2026-11-10 改了用途】
#   旧版本拿它的返回值去 --latency 测帧率。在线 App 实测这条路上有四个坑：
#   多个 SurfaceView 层同名、--latency 按名字只匹配第一个、广告/正片层
#   动态增删、切到 50Hz 后刷新周期行变成 20ms 被误判成 50fps。
#   现在帧率一律由 read_decoder_frames()/measure_fps_x100() 从解码器侧测，
#   本函数只用来给用户看「当前有哪些视频层」，有没有同名层、有没有
#   TextureView 渲染的层都无所谓，也不会影响切档。
# ---------------------------------------------------------------------------
find_video_layer() {
    dumpsys SurfaceFlinger 2>/dev/null \
        | sed -n 's/^+ Layer 0x[0-9a-fA-F]* (\(SurfaceView - [^)]*\)).*$/\1/p' \
        | head -1
}

# ---------------------------------------------------------------------------
# 用历史窗口算帧率 * 100
#
#   输出：帧率*100（如 2500）/ 空（样本不足）
#
# 【算法】只取历史里最后 4 条样本的首尾 (t, frames)，
#     fps*100 = Δframes / (Δt/100) * 100 = Δframes * 10000 / Δt_cs
#   Δt 用 now_cs() 的百分之一秒，避免整数秒精度不够（2 秒窗口差 1 秒
#   就能把 30fps 算成 20 或 60）。
#
# 【为什么只取后 4 条，而不是全历史首尾】
#   1) 起播缓冲：真机实测起播后前 2~4 秒解码器提交偏慢（20.8~22.2fps），
#      若把这段算进去，25.000fps 的片会被测成 24.47fps，卡在 24/25 的
#      吸附边界上误判成 24fps。
#   2) 片源会变：在线 App 广告 25fps -> 正片 30fps，用「最近一段」才能
#      跟上当前片源；拿十几秒前的样本算出来的还是广告的帧率。
#   watch 的 HIST 最多 8 条，取后 4 条也保证跨度约 6 秒，足够平滑。
#
# 【为什么用首尾而不是逐条平均】
#   逐条算再平均等价于给每个短窗口同等权重，仍会被个别异常增量带偏；
#   首尾差分覆盖整个 >= 4 秒窗口，短时抖动被自然摊平。
#
# 【为什么不再看 actualPresentTime / desiredPresentTime】
#   那两个是 SF 侧的排帧时刻，会被刷新率、pulldown、层切换、INT64_MAX
#   哨兵污染（详见文件头补记）。解码器累计帧数是播放链路更上游的量，
#   只反映片源节奏，跟显示端怎么摆帧完全解耦。
#
# 真机校验（25.000fps 测试片，取稳定段）：
#   60Hz: 162 帧 / 6.43s -> 2519 (25.19fps)
#   50Hz: 164 帧 / 6.54s -> 2507 (25.07fps)
#   两者一致 -> 增量法测的是片源帧率，不是刷新率。
# ---------------------------------------------------------------------------
measure_fps_x100() {
    [ -s "$HIST" ] || return 1

    # 第一遍：数有效样本数
    _n=0
    while read -r _t _f; do
        [ -z "$_t" ] && continue
        case "$_t" in
            *[!0-9]*) continue ;;
        esac
        _n=$((_n + 1))
    done < "$HIST"
    [ "$_n" -lt 2 ] && return 1

    # 第二遍：跳过前面的样本，只用最后 _use 条
    _use=4
    [ "$_n" -lt "$_use" ] && _use="$_n"
    _skip=$((_n - _use))

    _i=0; _m=0; _first_t=0; _first_f=0; _last_t=0; _last_f=0
    while read -r _t _f; do
        [ -z "$_t" ] && continue
        case "$_t" in
            *[!0-9]*) continue ;;
        esac
        _i=$((_i + 1))
        [ "$_i" -le "$_skip" ] && continue
        if [ "$_m" -eq 0 ]; then
            _first_t="$_t"; _first_f="$_f"
        fi
        _last_t="$_t"; _last_f="$_f"
        _m=$((_m + 1))
    done < "$HIST"

    [ "$_m" -lt 2 ] && return 1

    _dt=$((_last_t - _first_t))
    [ "$_dt" -lt "$MIN_WINDOW_CS" ] && return 1
    _df=$((_last_f - _first_f))
    [ "$_df" -le 0 ] && return 1

    echo $((_df * 10000 / _dt))
    return 0
}

# ---------------------------------------------------------------------------
# 自动模式的目标刷新率（区间分类，不做精确吸附）
#
#   $1 = measure_fps_x100() 的**原始**帧率*100（不是吸附值）
#   输出：Hz
#
# 【为什么不做精确吸附、也不直接用 fps_to_hz()】
#   fps_to_hz() 是「物理上最优」的映射表，但自动匹配要权衡的不是物理
#   最优，而是「切一次 HDMI 时序的代价」+「测量本身有多不准」。
#   本机 1080p 模式表只有 60/59/50/30/25/24，没有 48Hz；在线 App 又
#   实测会在 25fps(广告) 与 30fps(正片) 之间跳。而 numFramesTotal
#   增量法对 25fps 片源实测有约 -5% 系统性偏低，精确吸附会把它判成
#   24fps、甚至 23.976fps，落在 24/25 边界上摇摆。
#   所以自动模式只回答一个问题：「当前是不是 24/25 类片源、在 60Hz
#   上正吃 3:2 pulldown？」是 -> 切 50Hz；不是 -> 一律保持 60Hz。
#   30/50/60fps 在 60Hz 上本来就比切到 50Hz 好（2:2 / 5:6 / 1:1），
#   保持不动才是对的。
#   手动 `match <fps>` 不走这里，仍可用完整映射表体验 24p。
# ---------------------------------------------------------------------------
auto_target_hz() {
    _raw="$1"
    if [ "$_raw" -ge "$AUTO_PULLDOWN_MIN" ] && [ "$_raw" -le "$AUTO_PULLDOWN_MAX" ]; then
        # 还要确认显示器确实支持 50Hz（HDMI 没接 / 模式表为空时
        # pick_mode 返回空，此时保持 60Hz，由 apply_hz 的前置检查兜底）
        if [ -n "$(pick_mode "$AUTO_TARGET_HZ")" ]; then
            echo "$AUTO_TARGET_HZ"
        else
            echo "$DEFAULT_HZ"
        fi
    else
        echo "$DEFAULT_HZ"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 一次性自动匹配：采窗口 -> 测帧率 -> 区间分类挑刷新率 -> 应用
#   返回 0 = 做了决定（无论成功应用与否），1 = 没有视频在解码，2 = 样本不足
#
# 【2026-11-10 改了三处】
#   1) 判「有没有视频」从 find_video_layer() 换成 collect_samples()：
#      只要有视频解码器在跑就能测，不再受在线 App 多个同名 SurfaceView
#      层 / TextureView 渲染 / 同名层只匹配第一个的影响。
#   2) measure_fps_x100() 不再需要层名参数，读的是 HIST 窗口。
#   3) 目标刷新率走 auto_target_hz() 的区间分类（传**原始**测量值），
#      30fps 正片不会被切到 50Hz；吸附值只用来打日志。
# ---------------------------------------------------------------------------
auto_once() {
    if ! collect_samples; then
        return 1
    fi

    _raw=$(measure_fps_x100)
    if [ -z "$_raw" ]; then
        # 窗口不够（起播不足 4 秒 / 刚换了解码器），这一轮不动
        return 2
    fi

    # 自动模式按原始测量值做区间分类，吸附值只用于日志显示：
    # 精确吸附在 24/25 边界上不可靠（见 auto_target_hz 注释）。
    _hz=$(auto_target_hz "$_raw")
    _snap=$(snap_fps_x100 "$_raw")
    if [ -n "$_snap" ]; then
        log_msg "实测 $(($_raw / 100)).$(($_raw % 100))fps -> 吸附 $(($_snap / 100)).$(($_snap % 100))fps -> 自动目标 ${_hz}Hz"
    else
        log_msg "实测 $(($_raw / 100)).$(($_raw % 100))fps -> 非标准帧率 -> 自动目标 ${_hz}Hz"
    fi
    apply_hz "$_hz"
    return 0
}

# ---------------------------------------------------------------------------
# 常驻循环
#
# 【2026-11-10 加了三层保险，全是针对在线 App 实测的】
#   1) 每轮只 sample_once() 一次，靠 WATCH_INTERVAL 自然攒出 >= 4 秒窗口，
#      不再每轮额外 sleep 8 秒；测量统一走 measure_fps_x100()。
#   2) MIN_PLAY_SEC：起播不足 10 秒不切（短视频不值得为它黑一次屏）。
#      起播时刻取 HIST 第一条样本；sample_once() 在换解码器时会清空 HIST，
#      所以广告->正片会被当成一次新的起播，同样要重新攒够 10 秒，
#      天然避免在切换瞬间动作。
#   3) MIN_DWELL_SEC：切过一次后 20 秒内不再切，挡住广告<->正片来回
#      重同步 HDMI。只有「真的发生过一次模式切换」才记 _last_switch：
#      目标本来就等于当前刷新率时只记 _applied，不算切换。
#   目标刷新率一律走 auto_target_hz() 的区间分类
#   （实测 2200~2750，即 22.00~27.50fps -> 50Hz；其余保持 60Hz）。
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# watch_loop —— 常驻主循环
#
# 【2026-11-11 补记 #2：这里为什么不再 `return 0`】
#   旧版在开关关闭时直接 return 0，结果被 init 当成「服务退出」每 5 秒
#   拉起一次（完整推导见上面 IDLE_INTERVAL 常量处的补记）。
#   现在改成「一个外层循环 + 两个状态」：
#     _active=0 待机：只 getprop + sleep(IDLE_INTERVAL)，零显示副作用
#     _active=1 自动匹配：走原来的采帧率 / 去抖 / 驻留 / apply_hz 逻辑
#   状态切换点统一放在循环开头，所以：
#     * setprop 1 -> 最多 IDLE_INTERVAL 秒后进入自动匹配，且所有计数
#       （_stable / _applied / _last_switch / HIST）都会重新初始化，不会
#       带着待机前的旧样本误判；
#     * setprop 0 -> 最多 IDLE_INTERVAL 秒后退出自动匹配，并主动把显示
#       恢复到 DEFAULT_HZ，避免用户关了功能却还停在 50Hz。
#   注意：循环体里原有的 `continue` 现在会跳回「读开关」这一步，
#   因此开关变化响应比改之前更及时，不影响原有去抖 / 滞回语义。
# ---------------------------------------------------------------------------
watch_loop() {
    # 0 = 待机（开关关）；1 = 自动匹配中。服务常驻，不随开关退出。
    _active=0
    # 待机日志只打一次，避免常驻期间每轮刷屏
    _idle_logged=0

    rm -f "$HIST"

    while true; do
        # ---- 每轮开头读开关：persist.* 运行时可 setprop，不必重启服务 ----
        if [ "$(getprop persist.ardbeg.fps_match)" != "1" ]; then
            if [ "$_active" = "1" ]; then
                # 启用 -> 关闭：把显示拉回默认档、清历史、复位状态。
                # apply_hz 内部先做 cur_mode 比对，本来就在 60Hz 时不会写
                # sysfs、不会发 1040，不会造成无谓的 HDMI 重新同步。
                log_msg "persist.ardbeg.fps_match != 1，停止自动匹配并回到 ${DEFAULT_HZ}Hz"
                apply_hz "$DEFAULT_HZ" 2>/dev/null
                _active=0
            fi
            if [ "$_idle_logged" = "0" ]; then
                log_msg "persist.ardbeg.fps_match != 1，自动帧率匹配待机（服务常驻，不改显示）"
                _idle_logged=1
            fi
            rm -f "$HIST"
            sleep "$IDLE_INTERVAL"
            continue
        fi

        # ---- 开关刚打开：初始化本轮自动匹配的全部状态 ----
        if [ "$_active" = "0" ]; then
            log_msg "自动帧率匹配已启动（间隔 ${WATCH_INTERVAL}s，默认 ${DEFAULT_HZ}Hz，区间 ${AUTO_PULLDOWN_MIN}~${AUTO_PULLDOWN_MAX}->${AUTO_TARGET_HZ}Hz，窗口 ${MIN_WINDOW_CS}cs，驻留 ${MIN_DWELL_SEC}s）"
            _active=1
            _idle_logged=0
            _last_target=""
            _stable=0
            _applied=""
            _noedid_logged=0
            _last_switch=0
            rm -f "$HIST"
        fi

        # 没有 EDID 时（HDMI 拔了）什么都不做，且只记一次日志
        if [ -z "$(modes_list)" ]; then
            if [ "$_noedid_logged" = "0" ]; then
                log_msg "显示器无 EDID（HDMI 未连接），帧率匹配待机"
                _noedid_logged=1
            fi
            sleep "$WATCH_INTERVAL"
            continue
        fi
        _noedid_logged=0

        # 采一条样本。返回非 0 = 当前没有视频解码器（退出播放/换片过渡），
        # 此时回默认档。注意 sample_once() 已经把 HIST 清空了，下面的
        # 起播时长判断会把「无视频」视为已满足条件（否则会永远卡在
        # MIN_PLAY_SEC 里切不回 60Hz）。
        if ! sample_once; then
            _target="$DEFAULT_HZ"
        else
            _raw=$(measure_fps_x100)
            if [ -n "$_raw" ]; then
                # 传**原始**测量值做区间分类，不依赖精确吸附
                # （吸附在 24/25 边界不可靠，见 auto_target_hz 注释）
                _target=$(auto_target_hz "$_raw")
            else
                # 窗口不足：本轮维持现状，不参与去抖计数
                sleep "$WATCH_INTERVAL"
                continue
            fi
        fi

        # ---- 去抖：连续 WATCH_STABLE_NEED 轮同一目标才考虑动作 ----
        if [ "$_target" = "$_last_target" ]; then
            _stable=$((_stable + 1))
        else
            _last_target="$_target"
            _stable=1
        fi

        if [ "$_stable" -ge "$WATCH_STABLE_NEED" ] && [ "$_target" != "$_applied" ]; then
            _now=$(now_cs)

            # 起播时刻 = HIST 第一条样本（换解码器后重新起算）
            _pstart=0
            if [ -s "$HIST" ]; then
                while read -r _lt _lf; do
                    _pstart="$_lt"
                    break
                done < "$HIST"
            fi
            # 默认视为已满足；只有确实在播、且 HIST 有起点时才用真实跨度。
            # 这样「无视频要回 60Hz」不会被 MIN_PLAY_SEC 永久挡住。
            _played=$((MIN_PLAY_SEC * 100 + 1))
            [ "$_pstart" -gt 0 ] && _played=$((_now - _pstart))

            _since=999999
            [ "$_last_switch" -gt 0 ] && _since=$((_now - _last_switch))

            _cur_sf=$(read_sf_rate)

            if [ "$_cur_sf" = "$_target" ]; then
                # 本来就在目标档：只记账，不算一次切换，不启动驻留计时
                _applied="$_target"
                _stable=0
            elif [ "$_played" -lt $((MIN_PLAY_SEC * 100)) ]; then
                # 静默跳过（不刷日志）；下一轮条件满足会再判断
                :
            elif [ "$_since" -lt $((MIN_DWELL_SEC * 100)) ]; then
                # 静默跳过：距上次真正切模式不足 MIN_DWELL_SEC
                :
            else
                if apply_hz "$_target"; then
                    _applied="$_target"
                    _last_switch=$(now_cs)
                fi
                _stable=0
            fi
        fi

        sleep "$WATCH_INTERVAL"
    done
}

# ===========================================================================
# 入口
# ===========================================================================
cmd="$1"
shift 2>/dev/null

case "$cmd" in
    status)
        echo "开关 persist.ardbeg.fps_match = $(getprop persist.ardbeg.fps_match)"
        echo "fb0 mode      = $(cur_mode)"
        echo "SF refresh    = $(read_sf_rate) Hz"
        echo "sys.tegra.refresh = $(getprop sys.tegra.refresh)"
        echo "显示器模式数  = $(modes_list | grep -c . 2>/dev/null)"
        # 视频层名字现在只是给人看的，不参与帧率决策（见 find_video_layer 注释）
        _l=$(find_video_layer)
        echo "视频层(仅显示) = ${_l:-(无)}"
        _f=$(read_decoder_frames)
        if [ -n "$_f" ]; then
            echo "解码累计帧数  = $_f"
            # status 是快速查询，不主动采 6 秒窗口；有历史就直接算，
            # 没有就提示用 detect 或让 watch 跑一会儿。
            _r=$(measure_fps_x100)
            if [ -n "$_r" ]; then
                echo "窗口帧率      = $(($_r / 100)).$(($_r % 100)) fps"
                _s=$(snap_fps_x100 "$_r")
                [ -n "$_s" ] && echo "吸附帧率      = $(($_s / 100)).$(($_s % 100)) fps"
                echo "自动模式目标  = $(auto_target_hz "$_r")Hz（区间 ${AUTO_PULLDOWN_MIN}~${AUTO_PULLDOWN_MAX}）"
            else
                echo "窗口帧率      = (窗口不足，跑 detect 或启动 watch 后再看)"
            fi
        else
            echo "解码累计帧数  = (当前没有视频在解码)"
        fi
        ;;

    list)
        if [ -z "$(modes_list)" ]; then
            echo "(无模式：HDMI 未连接或无 EDID)"
        else
            modes_list
        fi
        ;;

    apply)
        [ -z "$1" ] && { echo "用法: $0 apply <Hz>"; exit 1; }
        apply_hz "$1"
        exit $?
        ;;

    match)
        [ -z "$1" ] && { echo "用法: $0 match <fps>"; exit 1; }
        # 允许传 "25" / "23.976" / "29.97"，统一换成 *100 的整数。
        # 设备上没有 awk/bc，只能用纯 sh 的字符串操作：
        #   ${_s%%.*}        取整数部分
        #   ${_s#*.}         取小数部分（没有小数点时结果等于原串）
        #   ${_fp%"${_fp#??}"}  只保留前两位（POSIX 惯用法）
        _s="$1"
        _ip=${_s%%.*}
        _fp=${_s#*.}
        [ "$_fp" = "$_s" ] && _fp=""          # 没有小数点
        _fp="${_fp}00"                        # 不足两位用 0 补
        _fp=${_fp%"${_fp#??}"}                # 截到两位
        _v=$((_ip * 100 + _fp))
        _snap=$(snap_fps_x100 "$_v")
        if [ -z "$_snap" ]; then
            echo "不是标准帧率：$1"
            exit 1
        fi
        _hz=$(fps_to_hz "$_snap")
        echo "片源 ${1}fps -> 目标 ${_hz}Hz"
        apply_hz "$_hz"
        exit $?
        ;;

    detect)
        # 2026-11-10：detect 现在采 5 条样本（约 8 秒）、取后 4 条再算，
        # 不再依赖单个 --latency 层。在线 App 的多层/同名层、以及切到
        # 50Hz 后 --latency 首行变成 20ms 的干扰，全都不会再影响结果。
        # 丢掉第一条是为了避开起播缓冲（否则 25fps 会被测成 24.47fps）。
        # 会阻塞约 8 秒，属预期行为。
        echo "采样中（5 条 / 约 8 秒，取后 4 条算）..."
        if ! collect_samples; then
            echo "当前没有视频在解码（media.player 里没有 numFramesTotal 行）"
            exit 1
        fi
        _r=$(measure_fps_x100)
        if [ -z "$_r" ]; then
            echo "样本不足（视频可能刚起播 / 刚换片，窗口 < 4 秒）"
            exit 1
        fi
        echo "实测: $(($_r / 100)).$(($_r % 100)) fps"
        echo "自动模式目标  : $(auto_target_hz "$_r")Hz（区间 ${AUTO_PULLDOWN_MIN}~${AUTO_PULLDOWN_MAX}；30fps 保持 60Hz）"
        _snap=$(snap_fps_x100 "$_r")
        if [ -n "$_snap" ]; then
            echo "吸附: $(($_snap / 100)).$(($_snap % 100)) fps（仅参考：24/25 只差 4%，不可靠）"
        else
            echo "吸附: 非标准帧率（自动模式按区间分类，不受吸附结果影响）"
        fi
        echo "手动: 切 50Hz 用 match 25，试 24p 用 match 24（手动不走区间分类）"
        ;;

    auto)
        auto_once
        _rc=$?
        [ "$_rc" = "1" ] && echo "当前没有视频层在播"
        [ "$_rc" = "2" ] && echo "样本不足，未动作"
        exit 0
        ;;

    reset)
        apply_hz "$DEFAULT_HZ"
        exit $?
        ;;

    watch)
        watch_loop
        ;;

    *)
        # detect / auto 会阻塞约 8 秒采窗口；status / list 是即时查询。
        echo "用法: $0 {status|list|apply <Hz>|match <fps>|detect|auto|reset|watch}"
        echo "  detect/auto: 采 5 条样本约 8 秒(取后 4 条)，用 media.player 的 numFramesTotal 增量测帧率"
        exit 1
        ;;
esac

exit 0
