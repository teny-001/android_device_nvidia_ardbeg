#!/system/bin/sh
# ============================================================================
# ardbeg_media_watchdog.sh —— media.extractor / media.codec 服务自愈守护
#   目标设备：g100 (ardbeg / Tegra K1 T124 / TN8 P1761)
#   系统：LineageOS 14.1 (Android 7.1.2)  cm_ardbeg_tv-eng
#   作者：2026-11-06 巡检时新增
# ============================================================================
#
# ■ 为什么要这个脚本（现场记录）
#
#   症状：开机一段时间后，**所有视频都放不出来**，Gallery 弹「无法播放此视频。」，
#         音乐/任何走 MediaPlayer 的应用同样失败。日志里是：
#             E/MediaPlayerService: Unable to connect to media extractor service
#             E/MediaPlayer       : Unable to create media player
#
#   排查过程（可复现）：
#     1) `service list | grep media` 里明明有
#            112  media.extractor: []
#            117  media.codec: []
#        但描述符是空的 `[]`，而且
#            service check media.extractor   -> not found
#            service check media.codec       -> not found
#        其余 media.* 服务（media.player / media.drm / media.audio_flinger ...）
#        全部 found。也就是说：**只有这两个服务的句柄被清空了**。
#
#     2) 翻 /cache/persist_log.txt 找到关键时序：
#            23:57:39  ServiceManager: add_service('media.extractor',7b) uid=0
#                                        - ALREADY REGISTERED, OVERRIDE
#            23:57:39  ServiceManager: service 'media.extractor' died
#            23:59:41  ServiceManager: service 'media.extractor' died   ← 致命的一行
#            00:00:34  ServiceManager: add_service('media.codec',a) uid=0
#                                        - ALREADY REGISTERED, OVERRIDE
#            00:00:34  ServiceManager: service 'media.codec' died
#            00:02:40  ServiceManager: service 'media.codec' died       ← 致命的一行
#
#     3) 对照 AOSP 源码 frameworks/native/cmds/servicemanager/service_manager.c：
#
#            si = find_svc(s, len);
#            if (si) {
#                if (si->handle) {
#                    ALOGE("... ALREADY REGISTERED, OVERRIDE\n");
#                    svcinfo_death(bs, si);     // ← 立刻记一条 "service 'X' died"
#                }
#                si->handle = handle;           // ← 换成新 handle
#            }
#            ...
#            binder_link_to_death(bs, handle, &si->death);   // ← 但 death 回调的 cookie
#                                                            //    还是同一个 &si->death
#
#        以及
#
#            static void svcinfo_death(struct binder_state *bs, void *ptr) {
#                struct svcinfo *si = (struct svcinfo *)ptr;
#                ALOGI("service '%s' died\n", str8(si->name));
#                if (si->handle) { binder_release(bs, si->handle); si->handle = 0; }
#            }
#
#        结论：**一个 svcinfo 只挂了一个 binder_death，cookie 永远是同一个 &si->death。**
#        发生 OVERRIDE 时，旧 handle 的死亡订阅并没有被撤销；等旧 binder 节点真正
#        死掉（本例里晚了 2 分钟），svcinfo_death 会再次被回调，把**刚刚装上的
#        新 handle 又清成 0**。于是服务永久失联，而进程本身还活着
#        （pid 268 media.codec / pid 270 media.extractor 全程没死）。
#        这是 7.1 servicemanager 的固有缺陷，不是我们设备树写错。
#
#     4) 为什么会有「第二次注册」？
#        同一时刻会有一个新的 mediaextractor/media.codec 进程去 add_service
#        （日志里 uid=0、且没有对应的 init "Starting service ..." 记录，
#         说明不是 init 拉起的，是被别的进程 fork/exec 出来的）。
#        具体触发者尚未完全定位；但**只要重复注册发生过一次，服务就废了**。
#
# ■ 这个脚本干什么
#
#   每 15 秒检查一次这两个服务在 servicemanager 里是否还活着；
#   一旦发现 not found，就用 init 的 `ctl.restart` 把服务重拉一遍，
#   重新 add_service 后句柄恢复正常，MediaPlayer 立刻可用。
#   实测：restart 之后 `service check media.extractor` 变回 found，
#        Gallery 立即能放 720p H.264 + AAC。
#
# ■ 为什么用 /system/etc/init/ 而不是改 ramdisk
#
#   init 会解析 /system/etc/init/*.rc（开机日志里能看到
#   "init: (Parsing /system/etc/init/mediacodec.rc took 0.00s.)"）。
#   所以把 rc 放在 /system/etc/init/ 下**不需要重打 boot.img**，
#   直接 adb push 就能生效（下次开机会自动拉起本守护）。
#
#   配套文件：/system/etc/init/zz-ardbeg-media-watchdog.rc
#   卸载：    rm /system/etc/init/zz-ardbeg-media-watchdog.rc
#             rm /system/bin/ardbeg_media_watchdog.sh
#
# ■ 长期正解（需要重编 system.img）
#
#   patch servicemanager：给每个 handle 单独的 binder_death 结构体，
#   或者 OVERRIDE 时先 binder_unlink_to_death(&si->death)。
#   在 device/nvidia/ardbeg/patches/ 下已有整套 patch 机制可以直接放进去。
# ============================================================================

TAG="ardbeg_mediawd"
INTERVAL=15

# init 服务名        servicemanager 里的服务名
#  mediaextractor -> media.extractor
#  mediacodec     -> media.codec
# 注意：这两组名字不一样，别搞混。init 用前者，`service check` 用后者。
PAIRS="mediaextractor:media.extractor mediacodec:media.codec"

log -t "$TAG" "watchdog started (interval=${INTERVAL}s)"

while true; do
    for pair in $PAIRS; do
        init_svc="${pair%%:*}"
        sm_svc="${pair##*:}"

        # service check 的输出形如：
        #   Service media.extractor: not found
        #   Service media.extractor: found
        out=$(service check "$sm_svc" 2>/dev/null)

        case "$out" in
            *"not found"*)
                log -t "$TAG" "lost: $sm_svc -> ctl.restart $init_svc"
                setprop ctl.restart "$init_svc"
                # 给 init 一点时间把新进程拉起来并完成 add_service
                sleep 2
                ;;
        esac
    done
    sleep "$INTERVAL"
done
