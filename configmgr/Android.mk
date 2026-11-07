#
# Copyright (C) 2014 Cirrus Logic, Inc.
# Copyright (C) 2012 Wolfson Microelectronics plc
# Copyright (C) 2011 The Android Open Source Project
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

include $(CLEAR_VARS)

LOCAL_MODULE := libaudiohalcm
LOCAL_MODULE_PATH := $(TARGET_OUT_SHARED_LIBRARIES)
LOCAL_MODULE_TAGS := optional

LOCAL_CFLAGS += -Werror -Wno-error=unused-parameter -Wno-unused-parameter

# ============================================================================
# [修复 2026-10-28] 同 audio/Android.mk：external/tinyhal 在 cm-11.0 里不存在，
#   改用设备树自带的 device/nvidia/ardbeg/include/tinyhal/audio_config.h。
#   audio_config.c 里只 include 了 <tinyhal/audio_config.h>，没有别的外部依赖。
# ============================================================================
LOCAL_C_INCLUDES += \
	external/tinycompress/include \
	device/nvidia/ardbeg/include \
	device/nvidia/ardbeg/tinyalsa/include \
	external/expat/lib \
	$(call include-path-for, audio-utils)

LOCAL_SRC_FILES := \
	audio_config.c

LOCAL_SHARED_LIBRARIES := \
	libcutils \
	libutils \
	libdl	\
	liblog	\
	libexpat	\
	libtinyalsa_ardbeg	\

include $(BUILD_SHARED_LIBRARY)

