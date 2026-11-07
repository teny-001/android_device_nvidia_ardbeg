#
# lineage.mk — cm_ardbeg_tv 的产品入口（TV 形态）
#
# 【为什么 TV 产品要单独一个目录】
#   LineageOS 14.1 的 build/core/product_config.mk 在 CM_BUILD 非空时，用
#       find device -path "*/$(CM_BUILD)/lineage.mk"
#   定位产品文件。lunch cm_ardbeg_tv-eng 会把 CM_BUILD 设成 ardbeg_tv，
#   于是它只会去 device/*/ardbeg_tv/lineage.mk 找。
#   如果只在 device/nvidia/ardbeg/ 下放 lineage_tv.mk，这条路找不到文件，
#   lunch 会直接报 "Cannot locate config makefile for product cm_ardbeg_tv"。
#
#   所以这里保留一个极薄的转发文件：真正的产品配置在
#   device/nvidia/ardbeg/lineage_tv.mk，避免两份配置漂移。
#
$(call inherit-product, device/nvidia/ardbeg/lineage_tv.mk)
