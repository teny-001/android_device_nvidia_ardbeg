#!/bin/bash
# =============================================================================
# verify_app_video.sh —— ardbeg CM14.1「app 视频播放」真机验收（可重复执行）
#
# 用法:
#     ./verify_app_video.sh                    # 默认跑运行时链路 + Gallery + Jelly
#     ./verify_app_video.sh /path/to/outdir   # 指定留档目录
#     CHECK_ONLINE=1 ./verify_app_video.sh    # 额外验当前第三方在线视频 app
#
# 退出码 0 = 全部通过；非 0 = 有 FAIL（报告里逐条列出）。
#
# -----------------------------------------------------------------------------
# 【为什么不能只跑 verify_hwdec.sh】
#   verify_hwdec.sh 用 `am start -a VIEW -t video/mp4` 触发 H.264/H.265
#   样片，证明的是「OMX.Nvidia.* 组件能创建并解出 EOS」。但用户问的是
#   「app 视频播放」，还要覆盖另外三类入口：
#       1) 系统播放器 Gallery3d/.app.MovieActivity（本地文件）
#       2) 浏览器 Jelly 里的 HTML5 <video>（HTTP 流，需用户手势）
#       3) 第三方在线视频 app（HLS，自带播放器但走系统 MediaCodec）
#   这三类各有独立的坑，md5 全绿也抓不到，必须有行为层验收工具。
#
# -----------------------------------------------------------------------------
# 【真机踩过的坑，全部写进判据】
#   * 绝对不要用 `screencap -p` 判亮屏：本机 SurfaceFlinger 报
#     `isSecure=1`，screencap 会挂住 SF 客户端连接引发全局 ANR。
#     画面是否在刷新改用 `dumpsys SurfaceFlinger --latency <layer>`
#     的帧时间戳推进来判断。
#   * `cmd package resolve-activity --brief -d file://... -t video/mp4`
#     会返回 `No activity found`，但 `am start -W` 能正常落到
#     Gallery3d/.app.MovieActivity。别拿 resolve-activity 的阴性结果
#     当「没有播放器」；必须以 `am start -W` 的 `Activity:` 行为准。
#   * Jelly 的 VIEW 过滤器只有 http/https，不认 file://。file:// 的
#     HTML 会被 AOSP `com.android.htmlviewer/.HTMLViewerActivity` 接管，
#     该查看器不执行 JS（console 回写为 0），但 <video> 仍会走系统
#     硬解。要验真浏览器必须用 http://。
#   * 让设备访问宿主页面用 `adb reverse tcp:<port> tcp:<port>`，不要
#     依赖 WiFi 同网段 IP。端口必须动态探测：8000 常被别的服务占用，
#     `http.server` 会 `OSError: [Errno 98] Address already in use`，
#     表面现象是「浏览器白屏 / 页面不加载」，很容易误判成 ROM 缺陷。
#   * WebView 按 Chromium 策略拒绝自动播放：
#       "play() can only be initiated by a user gesture."
#     必须 `input tap` 一个大按钮，在真实触摸手势里调 play()，否则
#     `readyState=4` 但 `paused=true / currentTime=0`，看起来像解码坏了。
#   * `ACodec: setting nBufferCountActual to 13/12/11 failed: -1010`
#     是 NVIDIA OMX 组件不支持动态 buffer count，ACodec 会降级重试，
#     播放仍到 EOS，属无害警告，不要判 FAIL。
#   * 第三方在线 app 的 `AV_SYNC_ERROR / avdiff` 与 gfxinfo jank 是 app
#     自身 HLS 同步与 UI 渲染问题；只要帧时间戳在推进、无 FATAL/ANR、
#     且上报 `dectp=OMX.Nvidia.h264.decode`，就不算 ROM 视频能力故障。
#   * `input tap` 坐标必须落在 WebView 内容区：按钮只覆盖顶部 28vh +
#     tap (W/2,H/8) 的旧写法，第二次复跑时点击被 Jelly 原生工具栏吃掉，
#     button_clicked=0 连带 6 个假 FAIL。现在按钮覆盖整个视口、点击后
#     隐藏，tap 取屏幕正中 (W/2,H/2)，另留两处兜底坐标。
#   * 设备侧 logcat/dumpsys 一律落盘再 grep，绝不塞进 shell 变量，否则
#     会 `printf: Argument list too long` 导致所有关键字「假绿 0」。
#   * toybox `grep -c` 计数 0 时退出码是 1；所有计数都要 `|| true`。
# =============================================================================

set -uo pipefail

A="/home/dy/WorkBuddy AI/k1flash/adb"
DEV="-s 0123456789ABCDEF"
ROOT="/home/dy/WorkBuddy AI/ardbeg-cm-14.1"
PY="/home/dy/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3"
SAMPLE_DIR="$ROOT/work/hwdec-1107-1522"
DEV_DIR=/data/local/tmp/appvideo-verify

OUT=""
for arg in "$@"; do
    case "$arg" in
        -h|--help) echo "用法: $0 [输出目录]"; exit 0 ;;
        *) OUT="$arg" ;;
    esac
done
[ -n "$OUT" ] || OUT="$ROOT/work/appvideo-verify-$(date +%m%d-%H%M)"
mkdir -p "$OUT"

S() { "$A" $DEV shell "$1"; }

PASS=0
FAIL=0
SKIP=0
FAILED=""
expect() {
    if [ "$2" = "$3" ]; then
        printf '  PASS  %-48s = %s\n' "$1" "$2"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %-48s 实际[%s] 期望[%s]\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1)); FAILED="${FAILED}\n    - $1: 实际[$2] 期望[$3]"
    fi
}
atleast() {
    if [ "$((${2:-0}))" -ge "$3" ] 2>/dev/null; then
        printf '  PASS  %-48s = %s (>= %s)\n' "$1" "$2" "$3"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %-48s 实际[%s] 期望 >= %s\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1)); FAILED="${FAILED}\n    - $1: 实际[$2] 期望 >= $3"
    fi
}
skip() {
    printf '  SKIP  %-48s （%s）\n' "$1" "$2"; SKIP=$((SKIP + 1))
}
cntf() { grep -cF "$1" "$2" 2>/dev/null || true; }
cnte() { grep -cE "$1" "$2" 2>/dev/null || true; }
get()  { grep -m1 "^@$1=" "$OUT/state.txt" 2>/dev/null | cut -d= -f2- | tr -d '\r'; }

PORT=""
SRV=""
cleanup() {
    if [ -n "$SRV" ]; then kill "$SRV" 2>/dev/null || true; fi
    if [ -n "$PORT" ]; then "$A" $DEV reverse --remove "tcp:$PORT" >/dev/null 2>&1 || true; fi
    S 'am start -n com.cyanogenmod.trebuchet/com.android.launcher3.Launcher' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "======================================================================"
echo " ardbeg CM14.1 app 视频播放验收"
echo " 设备   : 0123456789ABCDEF"
echo " 在线app: $([ "${CHECK_ONLINE:-0}" = 1 ] && echo 检查 || echo 跳过)"
echo " 留档   : $OUT"
echo "======================================================================"

# ---------------------------------------------------------------------------
# 0) 前置：设备必须在线且已启动 Android（不是 recovery）
# ---------------------------------------------------------------------------
BOOT=$(S 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r')
if [ "$BOOT" != "1" ]; then
    echo "FATAL: 设备不在已启动的 Android 系统里（sys.boot_completed='${BOOT}'）"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1) 运行时链路静态证据：三条修复字节 + AVP 权限 + 进程补充组 + OMX 映射
# ---------------------------------------------------------------------------
echo
echo "========== 1. 硬解运行时链路 =========="
S '
echo "@bridge=$(md5sum /system/lib/libstagefrighthw.so 2>/dev/null | cut -d" " -f1)";
echo "@codecxml=$(md5sum /system/etc/media_codecs.xml 2>/dev/null | cut -d" " -f1)";
echo "@mediacodecrc=$(md5sum /system/etc/init/mediacodec.rc 2>/dev/null | cut -d" " -f1)";
echo "@avp_perm=$(ls -l /dev/tegra_avpchannel 2>/dev/null | grep -c "media media" || true)";
echo "@svc=$(service list 2>/dev/null | grep -c "media.codec" || true)";
set -- $(ps 2>/dev/null | grep "[m]ediacodec");
if [ -n "$2" ]; then
  echo "@groups=$(grep "^Groups:" /proc/$2/status 2>/dev/null | grep -c "1013" || true)";
  echo "@maps=$(grep -oE "/system/(lib|vendor/lib)/[^ ]*(libstagefrighthw|libnvomx|libnvmmlite|libnvavp)[^ ]*\.so" /proc/$2/maps 2>/dev/null | sort -u | wc -l)";
else
  echo "@groups=0"; echo "@maps=0";
fi;
' 2>&1 | tr -d '\r' > "$OUT/state.txt"

expect "libstagefrighthw.so md5" "$(get bridge)"        "7221cb3656b33b54846e34b5e406163c"
expect "media_codecs.xml md5"   "$(get codecxml)"      "9c884d66a4e7d44a0b7227cc2ec8ddb5"
expect "mediacodec.rc md5"      "$(get mediacodecrc)"  "e5dfd2d55c04eb72cbb89ff2327ce4f1"
expect "/dev/tegra_avpchannel media:media" "$(get avp_perm)" "1"
expect "media.codec binder 服务" "$(get svc)"           "1"
expect "mediacodec 补充组含 media(1013)" "$(get groups)" "1"
atleast "mediacodec 已映射 NVIDIA OMX 库" "$(get maps)"  "4"

# ---------------------------------------------------------------------------
# 2) 片源准备（本地 + HTTP 共用同一个文件）
# ---------------------------------------------------------------------------
SAMPLE=""
if [ -f "$SAMPLE_DIR/test-h264-720p.mp4" ]; then
    cp "$SAMPLE_DIR/test-h264-720p.mp4" "$OUT/sample.mp4"
    SAMPLE="$OUT/sample.mp4"
elif [ -f "$OUT/hwdec-test.mp4" ]; then
    cp "$OUT/hwdec-test.mp4" "$OUT/sample.mp4"
    SAMPLE="$OUT/sample.mp4"
else
    "$A" $DEV pull /sdcard/Movies/hwdec-test.mp4 "$OUT/sample.mp4" >/dev/null 2>&1 || true
    [ -s "$OUT/sample.mp4" ] && SAMPLE="$OUT/sample.mp4"
fi
if [ -z "$SAMPLE" ]; then
    echo "FATAL: 找不到 H.264 样片（${SAMPLE_DIR}/test-h264-720p.mp4 或设备 /sdcard/Movies/hwdec-test.mp4）"
    exit 1
fi

# Jelly 用的页面：大按钮在真实触摸手势里调 play()，状态用 console.log 回写
cat > "$OUT/appvideo.html" <<'HTML'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ardbeg app video test</title>
</head>
<body style="margin:0;background:#101820;color:#e8f0f8;font-family:sans-serif">
<button id="b" style="position:fixed;top:0;left:0;width:100vw;height:100vh;font-size:7vh;background:#2b6cb0;color:#fff;border:0;z-index:99">TAP TO PLAY</button>
<div style="padding:29vh 2vw 0 2vw">
  <video id="v" width="96vw" height="58vh" controls playsinline src="sample.mp4"></video>
  <div id="s" style="margin-top:1vh;font-size:3vh">init</div>
</div>
<script>
var v = document.getElementById('v');
var s = document.getElementById('s');
var b = document.getElementById('b');
function log(x) { s.textContent += ' | ' + x; console.log('ARDVID ' + x); }
['loadedmetadata','canplay','playing','ended','error','stalled','waiting','pause'].forEach(function(e) {
    v.addEventListener(e, function() { log(e + '@' + (v.currentTime || 0).toFixed(2)); });
});
v.addEventListener('error', function() { log('mediaError=' + (v.error ? v.error.code : 'unknown')); });
setInterval(function() { log('t=' + (v.currentTime || 0).toFixed(2) + ' paused=' + v.paused + ' ready=' + v.readyState); }, 3000);
b.addEventListener('click', function() {
    log('button_clicked');
    b.style.display = 'none';
    var p = v.play();
    if (p && p.then) {
        p.then(function() { log('play_resolved'); })
         .catch(function(e) { log('play_rejected=' + e); });
    } else { log('play_called_legacy'); }
});
log('src=' + v.currentSrc);
</script>
</body>
</html>
HTML

# ---------------------------------------------------------------------------
# 3) 系统播放器 Gallery3d/.app.MovieActivity 播放本地 mp4
# ---------------------------------------------------------------------------
echo
echo "========== 2. 系统播放器 Gallery3d（本地 mp4）=========="
S "mkdir -p $DEV_DIR" >/dev/null 2>&1
"$A" $DEV push "$SAMPLE" "$DEV_DIR/sample.mp4" >/dev/null 2>&1
S "chmod 666 $DEV_DIR/sample.mp4" >/dev/null 2>&1
S 'logcat -c' >/dev/null 2>&1
S "am start -W -a android.intent.action.VIEW -d file://$DEV_DIR/sample.mp4 -t video/mp4" \
    > "$OUT/am_gallery.txt" 2>&1
sleep 18
S 'logcat -d -v threadtime' 2>&1 | tr -d '\r' > "$OUT/gallery.log"

atleast "am start -W 落到 MovieActivity" \
    "$(cntf 'MovieActivity' "$OUT/am_gallery.txt")" "1"
atleast "Gallery 组件实例 OMX.Nvidia.h264.decode" \
    "$(cntf 'makeComponentInstance(OMX.Nvidia.h264.decode)' "$OUT/gallery.log")" "1"
atleast "Gallery NvMMLiteOpen" "$(cntf 'NvMMLiteOpen' "$OUT/gallery.log")" "1"
atleast "Gallery EOS detected" "$(cntf 'EOS detected' "$OUT/gallery.log")" "1"
expect  "Gallery 0x80001000 错误" "$(cntf '0x80001000' "$OUT/gallery.log")" "0"
expect  "Gallery Unable to instantiate" "$(cntf 'Unable to instantiate a decoder' "$OUT/gallery.log")" "0"
expect  "Gallery FATAL EXCEPTION" "$(cntf 'FATAL EXCEPTION' "$OUT/gallery.log")" "0"
expect  "Gallery 播放期间 HOME 抢前台" \
    "$(cnte 'ActivityManager: START u0.*com.cyanogenmod.trebuchet' "$OUT/gallery.log")" "0"

# ---------------------------------------------------------------------------
# 4) 浏览器 Jelly 里的 HTML5 <video>（HTTP + 真实触摸手势）
# ---------------------------------------------------------------------------
echo
echo "========== 3. 浏览器 Jelly（HTML5 video over HTTP）=========="
# 动态找空闲端口，避开「8000 被占用」造成的服务端假失败
PORT=$("$PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null)
if [ -z "$PORT" ]; then PORT=18123; fi
"$A" $DEV reverse "tcp:$PORT" "tcp:$PORT" >/dev/null 2>&1
"$PY" -m http.server "$PORT" --bind 127.0.0.1 --directory "$OUT" > "$OUT/http.log" 2>&1 &
SRV=$!
sleep 2
LOCAL_OK=$("$PY" -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:${PORT}/appvideo.html', timeout=3).status)" 2>/dev/null || true)
expect "宿主 HTTP 服务可访问" "${LOCAL_OK:-}" "200"

# 屏幕尺寸决定 tap 坐标：按钮覆盖整个 WebView 视口，取屏幕正中 (W/2,H/2)，
# 避开 Jelly 原生地址栏 / StatusBar / NavigationBar。
# 【坑·2026-11-07 第二次复跑】早期版本按钮只有 28vh、tap 取 (W/2,H/8)，
#   点击落到 Jelly 原生工具栏上，button_clicked=0，连带产生 6 个假 FAIL。
#   页面其实已 loadedmetadata/canplay/readyState=4，不是解码故障。
RES=$(S 'wm size' 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+x[0-9]+' | head -1)
W=${RES%x*}; H=${RES#*x}
TX=$((W / 2)); TY=$((H / 2))

S 'logcat -c' >/dev/null 2>&1
S "am start -W -a android.intent.action.VIEW -d http://127.0.0.1:$PORT/appvideo.html -t text/html" \
    > "$OUT/am_jelly.txt" 2>&1
sleep 5
S "input tap $TX $TY" >/dev/null 2>&1
sleep 6
PLAYING=$(S 'logcat -d' 2>/dev/null | tr -d '\r' | grep -c 'ARDVID playing' || true)
if [ "${PLAYING:-0}" = "0" ]; then
    # 兜底 1：再点一次按钮区域（第一次可能被启动动画 / 系统层吃掉）
    S "input tap $TX $((H / 8))" >/dev/null 2>&1
    # 兜底 2：若按钮已被 JS 隐藏，点视频控件自带的播放键
    S "input tap 80 $((H - 180))" >/dev/null 2>&1
fi
sleep 16
S 'logcat -d -v threadtime' 2>&1 | tr -d '\r' > "$OUT/jelly.log"
S 'dumpsys activity activities' 2>&1 | tr -d '\r' > "$OUT/jelly_act.txt"

atleast "Jelly 页面由 org.lineageos.jelly 接管" \
    "$(cntf 'org.lineageos.jelly' "$OUT/am_jelly.txt")" "1"
atleast "按钮收到真实触摸手势" "$(cntf 'button_clicked' "$OUT/jelly.log")" "1"
atleast "play() 在手势内 resolve" "$(cntf 'play_resolved' "$OUT/jelly.log")" "1"
expect  "play() 未被手势策略拒绝" "$(cntf 'play_rejected' "$OUT/jelly.log")" "0"
expect  "HTMLMediaElement 无 mediaError" "$(cntf 'mediaError' "$OUT/jelly.log")" "0"
atleast "ARDVID playing 事件" "$(cntf 'ARDVID playing' "$OUT/jelly.log")" "1"
atleast "Jelly 组件实例 OMX.Nvidia.h264.decode" \
    "$(cntf 'makeComponentInstance(OMX.Nvidia.h264.decode)' "$OUT/jelly.log")" "1"
atleast "Jelly NvMMLiteOpen" "$(cntf 'NvMMLiteOpen' "$OUT/jelly.log")" "1"
atleast "Jelly EOS detected" "$(cntf 'EOS detected' "$OUT/jelly.log")" "1"
expect  "Jelly 播放结束后仍在浏览器前台" \
    "$(grep -m1 'mResumedActivity' "$OUT/jelly_act.txt" | grep -c 'org.lineageos.jelly' || true)" "1"
expect  "Jelly FATAL EXCEPTION" "$(cntf 'FATAL EXCEPTION' "$OUT/jelly.log")" "0"
expect  "Jelly ANR" "$(cnte 'ANR in |Input dispatching timed out' "$OUT/jelly.log")" "0"
expect  "Jelly HOME 抢前台" \
    "$(cnte 'ActivityManager: START u0.*com.cyanogenmod.trebuchet' "$OUT/jelly.log")" "0"
expect  "Jelly 网络错误 net::ERR" "$(cntf 'net::ERR' "$OUT/jelly.log")" "0"
expect  "Jelly 0x80001000 错误" "$(cntf '0x80001000' "$OUT/jelly.log")" "0"

# ---------------------------------------------------------------------------
# 5) 可选：当前第三方在线视频 app（HLS）画面帧时间戳是否在推进
# ---------------------------------------------------------------------------
echo
echo "========== 4. 第三方在线视频 app（可选）=========="
if [ "${CHECK_ONLINE:-0}" != "1" ]; then
    skip "在线 app 帧刷新" "CHECK_ONLINE 未开启"
else
    S 'dumpsys activity activities' 2>&1 | tr -d '\r' > "$OUT/online_act.txt"
    if ! grep -m1 'mResumedActivity' "$OUT/online_act.txt" | grep -q 'com.starcor.mango'; then
        skip "在线 app 帧刷新" "当前前台不是在线视频 app"
    else
        L="SurfaceView - com.starcor.mango/com.mgtv.tv.vod.activity.VodDynamicActivity"
        T1=$(S "dumpsys SurfaceFlinger --latency \"$L\"" 2>/dev/null | tr -d '\r' | grep '^[0-9]' | tail -1 | cut -f1)
        sleep 5
        T2=$(S "dumpsys SurfaceFlinger --latency \"$L\"" 2>/dev/null | tr -d '\r' | grep '^[0-9]' | tail -1 | cut -f1)
        if [ -n "${T1:-}" ] && [ -n "${T2:-}" ] && [ "$T2" -gt "$T1" ] 2>/dev/null; then
            printf '  PASS  %-48s = %s -> %s\n' "在线 app 视频帧时间戳推进" "$T1" "$T2"
            PASS=$((PASS + 1))
        else
            printf '  FAIL  %-48s 实际[%s -> %s]\n' "在线 app 视频帧时间戳推进" "${T1:-}" "${T2:-}"
            FAIL=$((FAIL + 1)); FAILED="${FAILED}\n    - 在线 app 视频帧时间戳没有推进"
        fi
        S 'logcat -d -v threadtime' 2>&1 | tr -d '\r' > "$OUT/online.log"
        atleast "在线 app 上报 OMX.Nvidia 解码器" "$(cntf 'OMX.Nvidia' "$OUT/online.log")" "1"
        expect  "在线 app FATAL EXCEPTION" "$(cntf 'FATAL EXCEPTION' "$OUT/online.log")" "0"
        expect  "在线 app ANR" "$(cnte 'ANR in |Input dispatching timed out' "$OUT/online.log")" "0"
    fi
fi

echo
echo "======================================================================"
echo " 汇总：PASS = ${PASS}   FAIL = ${FAIL}   SKIP = ${SKIP}"
echo " 留档：${OUT}"
if [ "$FAIL" -gt 0 ]; then
    printf ' 失败项：%b\n' "${FAILED}"
    echo " 结论：app 视频播放验收未通过。"
    exit 1
fi
echo " 结论：系统播放器、浏览器 HTML5 视频均走 NVIDIA OMX 硬解并跑到 EOS。"
exit 0
