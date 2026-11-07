#!/system/bin/sh
# ============================================================================
# bootanim_killer.sh —— 保证开机动画不会在 SF 重启后一直盖住桌面
#
# 安装位置：/system/bin/bootanim_killer.sh
#           （initfiles/Android.mk，LOCAL_MODULE_CLASS := EXECUTABLES）
# 由谁拉起：/system/etc/init/zz-bootanim-fix.rc 的 bootanim_killer 服务，
#           on property:sys.boot_completed=1 时 start。
#
# ----------------------------------------------------------------------------
# 【现象】
#   开机流程本来是对的：
#       SurfaceFlinger::bootFinished()             -> sf_stop_bootanim
#       WindowManagerService.performEnableScreen() -> service.bootanim.exit=1
#       bootanimation 读到 exit=1，退出（dmesg 里能看到 exited with status 0）
#   但是本机上 SurfaceFlinger 会因为厂商 4.4.4 hwcomposer.tegra.so 的
#   堆越界在开机约 74 秒时崩一次。init 重启 SF 之后，新的 SF 在
#   onFirstRef() 里又会执行 startBootAnimation()：
#       property_set("service.bootanim.exit", "0");
#       property_set("ctl.start", "bootanim");
#   而 WindowManagerService 里的 mBootAnimationStopped 是一次性标志，
#   早就置位了，不会再调 performEnableScreen() 去把 exit 设回 1。
#   结果 bootanimation 被重新拉起后永远不退出，一直盖住 Launcher。
#
# 【做法】
#   sys.boot_completed=1 之后，每 5 秒检查一次 service.bootanim.exit，
#   只要不是 1 就置 1。bootanimation 每帧都会读这个属性，读到 1 就自行退出。
#   sys.boot_completed 为 0 时什么都不做，所以不影响正常开机动画。
#
# 【为什么 sleep 5 而不是更短】
#   setprop 本身很便宜，但没必要每 100ms 打一次。5 秒的代价是
#   最坏情况下多盖 5 秒，可以接受；好处是这个脚本几乎不占 CPU，
#   在 Tegra K1 这种老 SoC 上，开机阶段 CPU 越省越好。
#
# 【为什么不用 `while getprop ...; do :; done` 死等属性变化】
#   mksh 没有 inotify 能力，getprop 也不支持 -w（4.4/7.1 的 toolbox 都没有），
#   只能轮询。init 的 on property 触发器只对"变化"敏感，
#   而 SF 每次重启都会把它改回 0，所以用触发器 + 轮询是最稳的组合。
# ============================================================================

while true; do
    if [ "$(getprop sys.boot_completed)" = "1" ]; then
        if [ "$(getprop service.bootanim.exit)" != "1" ]; then
            setprop service.bootanim.exit 1
        fi
    fi
    sleep 5
done
