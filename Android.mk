# Copyright (C) 2012 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

LOCAL_PATH := $(call my-dir)
# 保存一份本目录路径。下面每个子目录的 Android.mk 都会把 LOCAL_PATH
# 改成自己的目录，所以不能直接用 $(LOCAL_PATH)/xxx/Android.mk 连续 include
# （第二个就会变成 audio/configmgr/Android.mk 这种错误路径）。
ARDBEG_PATH := $(LOCAL_PATH)

ifeq ($(TARGET_DEVICE),ardbeg)

# ============================================================================
# 【7.1 移植改动】从 all-subdir-makefiles 改成显式列出子目录
# ============================================================================
# cm-11 版本用的是
#     include $(call all-subdir-makefiles,$(LOCAL_PATH))
# 它会无条件把设备树下**所有**子目录的 Android.mk 都 include 进来。
# 7.1 上有四个子目录的 Android.mk 会直接让编译失败：
#
#   power/Android.mk      用的是 NVIDIA_DEFAULTS / NVIDIA_SHARED_LIBRARY
#                         这两个宏是 NVIDIA 私有 build 系统的，7.1 没有，
#                         报 "*** NVIDIA_DEFAULTS is not defined"。
#                         7.1 的 power HAL 由 hardware/nvidia/power 提供
#                         （TARGET_POWERHAL_VARIANT := tegra 自动选中）。
#
#   healthd/Android.mk    同样用 NVIDIA_DEFAULTS，且 healthd_board_init()
#                         在 7.1 改成带 struct healthd_config * 参数，
#                         源码本身也编不过。
#
#   libstagefrighthw/     里面的 NVOMXPlugin.cpp 是 4.4 的 libstagefrighthw
#                         接口（createOMXPlugin 无参数），7.1 改成了
#                         createOMXPlugin(bool secure)，编译不过。
#                         7.1 用 hardware/nvidia/libstagefrighthw。
#
#   cmhw/                 实现的是 org.cyanogenmod.hardware.* 接口，
#                         14.1 已改名为 org.lineageos.hardware.*，
#                         编出来的 jar 没人加载（白编）。
#
# 所以这里显式只 include 真正需要的五个子目录。
# 如果以后要给上面四个补 7.1 版本，再把对应目录加回这个列表。
# ============================================================================
include $(ARDBEG_PATH)/audio/Android.mk
include $(ARDBEG_PATH)/configmgr/Android.mk
include $(ARDBEG_PATH)/tinyalsa/Android.mk
include $(ARDBEG_PATH)/liblights/Android.mk
include $(ARDBEG_PATH)/initfiles/Android.mk

# 【2026-11-06 新增】轻量输入法 ArdbegIME 的预编译模块。
#   为什么需要：cm_ardbeg_tv 走的是 vendor/cm/config/common_full_tv.mk，
#   那条配置不含 LatinIME，导致 ROM 里一个输入法都没有，
#   「设置 → WLAN」输密码时弹不出键盘。
#   详见 ime/Android.mk 头部注释。
include $(ARDBEG_PATH)/ime/Android.mk

include $(CLEAR_VARS)

endif
